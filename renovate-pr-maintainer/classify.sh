#!/usr/bin/env bash
# Classify in-scope Renovate PRs into maintenance actions.
#
# READ-ONLY: never mutates a PR. Inspects each in-scope Renovate PR, decides one
# of skip / rerun / rebase / none, and writes a JSON plan to $PLAN_FILE that
# apply.sh consumes.
#
# Decision model (first match wins; a human-edited head always downgrades an
# actionable state to skip, since Renovate won't auto-rebase it):
#   rebase label present  -> pending (rebase already queued; report only, no fetch)
#   dirty (conflict)      -> skip    (Renovate rebases conflicts itself)
#   behind                -> rebase if require-up-to-date, else treat like blocked
#   blocked / unstable    -> rebase if stale, else rerun a failing required run, else none
#   clean / has_hooks     -> rebase if stale, else none
#   unknown               -> none    (mergeability pending; never act on a guess)
#
# Stale = behind_by >= BEHIND_THRESHOLD OR head age >= STALE_HOURS (both reset by a rebase).
set -euo pipefail

: "${REPOSITORY:?REPOSITORY is required (owner/name)}"
: "${PLAN_FILE:?PLAN_FILE is required}"
# Login identifying Renovate's PRs: selects which PRs are in scope and is the
# trusted head author/committer (see GITHUB_SIGNING_COMMITTER, EXTRA_TRUSTED_LOGINS).
RENOVATE_AUTHOR="${RENOVATE_AUTHOR:-renovate[bot]}"
# Comma-separated labels that take a PR out of scope (e.g. Renovate already keeps
# `keep-updated` PRs continuously rebased, so this action leaves them alone).
EXCLUDE_LABELS="${EXCLUDE_LABELS:-keep-updated,stop-updating}"
# Staleness signals (OR'd, both reset by a rebase): rebase once the head is at
# least this many commits behind base, or at least this many hours old.
BEHIND_THRESHOLD="${BEHIND_THRESHOLD:-60}"
STALE_HOURS="${STALE_HOURS:-24}"
# Max workflow-run attempts per head SHA before reruns stop. 0 (default) disables
# reruns; the count derives from run_attempt, so a fresh SHA resets it.
RERUN_BUDGET="${RERUN_BUDGET:-0}"
# Extra check-run names (comma/newline-separated) treated as required for the
# rerun decision, unioned with the ruleset-discovered contexts (this action reads
# only rulesets, not classic branch protection).
EXTRA_RERUN_CHECKS="${EXTRA_RERUN_CHECKS:-}"
# Optional exact base-branch filter; empty (default) means all base branches.
BASE_BRANCH="${BASE_BRANCH:-}"
# When true, treat the `behind` mergeable_state ("Require branches up to date")
# as a hard merge blocker and rebase immediately. When false (default), ignore it
# and decide a behind PR by staleness, like a clean one.
REQUIRE_UP_TO_DATE="${REQUIRE_UP_TO_DATE:-false}"
# Renovate's one-off rebase label. A PR already carrying it has a rebase queued,
# so it is reported, not acted on. Must match apply.sh's REBASE_LABEL.
REBASE_LABEL="${REBASE_LABEL:-rebase}"
# Committer GitHub stamps on Renovate's API-created (signed) commits; counts as
# Renovate-owned, not a human edit. Any other non-Renovate author/committer does.
GITHUB_SIGNING_COMMITTER="${GITHUB_SIGNING_COMMITTER:-web-flow}"
# Extra logins (comma/newline-separated) also treated as Renovate-owned, beyond
# RENOVATE_AUTHOR and GITHUB_SIGNING_COMMITTER, so trusted automation pushing
# follow-up commits (e.g. github-actions[bot]) isn't misread as a human edit.
EXTRA_TRUSTED_LOGINS="${EXTRA_TRUSTED_LOGINS:-}"
# Polling for GitHub's async mergeable_state: every base-branch push resets it to
# "unknown", so poll a few times with linear backoff before giving up.
MERGEABLE_MAX_POLLS="${MERGEABLE_MAX_POLLS:-5}"
MERGEABLE_POLL_DELAY="${MERGEABLE_POLL_DELAY:-3}"
# Bounded worker pool for the independent per-PR classification. Workers are bash
# forks inheriting the pre-warmed REQUIRED_CACHE (read-only), so concurrency adds
# no ruleset discovery. Set to 1 for fully serial execution.
CLASSIFY_CONCURRENCY="${CLASSIFY_CONCURRENCY:-8}"
# Coerce a bad override (non-integer or < 1) to 1: the throttle test below is
# numeric and would fail under `set -e` or spin forever otherwise.
if ! [[ "$CLASSIFY_CONCURRENCY" =~ ^[0-9]+$ ]] || [ "$CLASSIFY_CONCURRENCY" -lt 1 ]; then
  echo "::warning::invalid CLASSIFY_CONCURRENCY='${CLASSIFY_CONCURRENCY}'; falling back to 1" >&2
  CLASSIFY_CONCURRENCY=1
fi

# Bounded retries for transient gh api failures (see gh_api below).
MAX_API_RETRIES=3
API_RETRY_DELAY=5
# Single reference time so every PR's age is measured against the same "now".
NOW_EPOCH=$(date -u +%s)

# gh api with bounded retries on transient failures. Prints body on success.
gh_api() {
  local attempt=1 out rc
  while [ "$attempt" -le "$MAX_API_RETRIES" ]; do
    set +e
    out=$(gh api "$@" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      printf '%s' "$out"
      return 0
    fi
    echo "::warning::gh api $* failed (attempt ${attempt}/${MAX_API_RETRIES}, exit ${rc})" >&2
    attempt=$((attempt + 1))
    [ "$attempt" -le "$MAX_API_RETRIES" ] && sleep "$API_RETRY_DELAY"
  done
  return 1
}

# Resolve a PR's mergeable_state, polling with linear backoff past the transient
# "unknown" GitHub returns while (re)computing it after a base push. A residual
# "unknown" is returned as-is so the caller defers. Non-zero only if the GET fails.
mergeable_state_for_pr() {
  local num="$1" attempt=1 ms pr
  while [ "$attempt" -le "$MERGEABLE_MAX_POLLS" ]; do
    pr=$(gh_api "repos/${REPOSITORY}/pulls/${num}") || return 1
    ms=$(echo "$pr" | jq -r '.mergeable_state // "unknown"')
    if [ "$ms" != "unknown" ]; then
      printf '%s' "$ms"
      return 0
    fi
    if [ "$attempt" -lt "$MERGEABLE_MAX_POLLS" ]; then
      sleep "$(( MERGEABLE_POLL_DELAY * attempt ))"
    fi
    attempt=$((attempt + 1))
  done
  printf 'unknown'
  return 0
}

# Required status-check contexts for a base branch, discovered from repository
# rulesets targeting it (not classic branch protection, mirroring the
# wait-for-required-checks action). Newline-separated, cached per base branch.
DEFAULT_BRANCH=$(gh_api "repos/${REPOSITORY}" --jq '.default_branch' 2>/dev/null || echo "")
declare -A REQUIRED_CACHE
required_checks_for_base() {
  local base="$1"
  if [ -n "${REQUIRED_CACHE[$base]+x}" ]; then
    printf '%s' "${REQUIRED_CACHE[$base]}"
    return 0
  fi

  local target="refs/heads/${base}" checks="" ids id ruleset
  ids=$(gh_api "repos/${REPOSITORY}/rulesets?per_page=100" --paginate --jq '.[].id' 2>/dev/null || echo "")
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    ruleset=$(gh_api "repos/${REPOSITORY}/rulesets/${id}" 2>/dev/null || echo "")
    [ -z "$ruleset" ] && continue

    # Does this ruleset target the base branch? Handles GitHub's special refs
    # `~ALL` and `~DEFAULT_BRANCH` plus glob includes; case-glob avoids regex injection.
    local matches=false include
    while IFS= read -r include; do
      [ -z "$include" ] && continue
      if [ "$include" = "~ALL" ]; then
        matches=true; break
      fi
      if [ "$include" = "~DEFAULT_BRANCH" ]; then
        [ -n "$DEFAULT_BRANCH" ] && [ "$base" = "$DEFAULT_BRANCH" ] && { matches=true; break; }
        continue
      fi
      # shellcheck disable=SC2254
      case "$target" in
        $include) matches=true; break ;;
      esac
    done < <(echo "$ruleset" | jq -r '.conditions.ref_name.include[]? // empty')

    if [ "$matches" = true ]; then
      local c
      while IFS= read -r c; do
        [ -n "$c" ] && checks="${checks}${c}"$'\n'
      done < <(echo "$ruleset" | jq -r '.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[].context')
    fi
  done <<< "$ids"

  checks=$(printf '%s' "$checks" | sort -u | grep -v '^$' || true)
  REQUIRED_CACHE[$base]="$checks"
  printf '%s' "$checks"
}

echo "Scanning open PRs in ${REPOSITORY} authored by '${RENOVATE_AUTHOR}'"
echo "Thresholds: behind_by>=${BEHIND_THRESHOLD}, age>=${STALE_HOURS}h, rerun-budget=${RERUN_BUDGET}, require-up-to-date=${REQUIRE_UP_TO_DATE}"
[ -n "$BASE_BRANCH" ] && echo "Base-branch filter: ${BASE_BRANCH}"
[ -n "$EXTRA_TRUSTED_LOGINS" ] && echo "Extra trusted logins (author/committer): ${EXTRA_TRUSTED_LOGINS}"
[ -n "$EXTRA_RERUN_CHECKS" ] && echo "Extra rerun checks: ${EXTRA_RERUN_CHECKS}"

# List open PRs (the list endpoint omits mergeable_state, so we only collect
# cheap metadata here and fetch mergeable_state per-PR below).
pulls_ndjson=$(gh_api "repos/${REPOSITORY}/pulls?state=open&per_page=100" --paginate \
  --jq '.[] | {number, draft, base: .base.ref, head_sha: .head.sha, user: .user.login, labels: [.labels[].name]}') \
  || { echo "::error::failed to list pull requests for ${REPOSITORY}"; exit 1; }

candidates=$(printf '%s\n' "$pulls_ndjson" | jq -s \
  --arg author "$RENOVATE_AUTHOR" --arg excl "$EXCLUDE_LABELS" --arg base "$BASE_BRANCH" '
  ($excl | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $ex
  | map(select(
      .user == $author
      and .draft == false
      and (((.labels // []) - $ex) == (.labels // []))
      and ($base == "" or .base == $base)
    ))')

candidate_count=$(echo "$candidates" | jq 'length')
echo "In-scope Renovate PRs: ${candidate_count}"

# Pre-warm the required-checks cache once per base branch in THIS shell: the
# workers below run in subshells that inherit REQUIRED_CACHE but can't write back,
# so warming here turns their lookups into cache hits instead of re-discovery.
while IFS= read -r warm_base; do
  [ -z "$warm_base" ] && continue
  required_checks_for_base "$warm_base" >/dev/null
done < <(echo "$candidates" | jq -r '.[].base' | sort -u)

# True when $1 is listed in EXTRA_TRUSTED_LOGINS (split on commas and newlines,
# each entry trimmed, so a YAML block scalar or a CSV string both work). An empty
# login or empty list never matches.
login_is_extra_allowed() {
  local login="$1" extra
  { [ -z "$login" ] || [ -z "$EXTRA_TRUSTED_LOGINS" ]; } && return 1
  # `|| [ -n "$extra" ]` also reads the final entry when it has no trailing newline.
  while IFS= read -r extra || [ -n "$extra" ]; do
    [ -n "$extra" ] && [ "$login" = "$extra" ] && return 0
  done < <(printf '%s' "$EXTRA_TRUSTED_LOGINS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  return 1
}

# Fetch the head commit once to derive age + edit ownership: sets age_hours and
# head_modified (globals), memoized per PR via head_meta_done. Mirrors Renovate's
# refusal to auto-rebase a branch it didn't author by flagging head_modified when
# the head author/committer is anyone but Renovate (GITHUB_SIGNING_COMMITTER and
# EXTRA_TRUSTED_LOGINS still count as Renovate; an unmapped null login is treated
# as Renovate-owned to avoid skipping legitimate PRs). If the commit GET fails we
# fail closed (head_modified=true): an unverifiable branch is never rebased.
# Cost: 1 commit GET (shared with compute_staleness).
fetch_head_meta() {
  local head_sha="$1" head_json author committer head_date head_epoch
  [ "$head_meta_done" = "true" ] && return 0
  head_meta_done=true
  head_json=$(gh_api "repos/${REPOSITORY}/commits/${head_sha}" 2>/dev/null || echo "")
  if [ -z "$head_json" ]; then
    # Fail closed: ownership unverifiable, so block any rebase of this branch.
    head_modified=true
    age_hours=0
    return 0
  fi
  author=$(echo "$head_json" | jq -r '.author.login // ""')
  committer=$(echo "$head_json" | jq -r '.committer.login // ""')
  if { [ -n "$author" ] && [ "$author" != "$RENOVATE_AUTHOR" ] && ! login_is_extra_allowed "$author"; } ||
     { [ -n "$committer" ] && [ "$committer" != "$RENOVATE_AUTHOR" ] && [ "$committer" != "$GITHUB_SIGNING_COMMITTER" ] && ! login_is_extra_allowed "$committer"; }; then
    head_modified=true
  fi
  head_date=$(echo "$head_json" | jq -r '.commit.committer.date // ""')
  if [ -n "$head_date" ]; then
    head_epoch=$(date -u -d "$head_date" +%s 2>/dev/null || echo "$NOW_EPOCH")
  else
    head_epoch=$NOW_EPOCH
  fi
  age_hours=$(( (NOW_EPOCH - head_epoch) / 3600 ))
}

# Staleness for one PR: sets behind_by, age_hours, stale, head_modified (globals).
# Called only for states whose decision depends on staleness. Cost: 1 compare +
# 1 commit GET (the latter via fetch_head_meta).
compute_staleness() {
  local base="$1" head_sha="$2" base_enc
  # URL-encode '/' so base branches like `stable/8.7` don't break the compare path.
  base_enc="${base//\//%2F}"
  behind_by=$(gh_api "repos/${REPOSITORY}/compare/${base_enc}...${head_sha}" --jq '.behind_by' 2>/dev/null || echo 0)
  [ -z "$behind_by" ] && behind_by=0
  fetch_head_meta "$head_sha"
  if [ "$behind_by" -ge "$BEHIND_THRESHOLD" ] || [ "$age_hours" -ge "$STALE_HOURS" ]; then
    stale=true
  fi
}

# Rerun eligibility for one PR, scoped to REQUIRED checks only (never reruns
# non-blocking workflows): failing required check-run -> its suite -> the workflow
# run that produced it. Required set = ruleset contexts ∪ EXTRA_RERUN_CHECKS. Sets
# required_count, eligible_ids, eligible_count, checks_in_progress (globals).
# Cost: 1 check-runs + 1 actions/runs GET (paginated, the costliest pair);
# short-circuits when reruns are off.
compute_rerun_eligibility() {
  local base="$1" head_sha="$2" required_checks required_json checkruns_ndjson failing_suites runs_ndjson
  # Reruns disabled (budget < 1): nothing can be eligible, so short-circuit
  # before the two costly paginated GETs.
  if [ "$RERUN_BUDGET" -lt 1 ]; then
    required_count=0; eligible_ids="[]"; eligible_count=0; checks_in_progress=false; failing_required_count=0
    return 0
  fi
  required_checks=$(required_checks_for_base "$base")
  # Union ruleset contexts with EXTRA_RERUN_CHECKS (split, trimmed, de-duped);
  # with no extras this is just the ruleset set.
  required_json=$(
    { printf '%s\n' "$required_checks"
      printf '%s' "$EXTRA_RERUN_CHECKS" | tr ',' '\n'
    } | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s 'map(select(length > 0)) | unique')
  required_count=$(echo "$required_json" | jq 'length')

  # Suites on the head SHA with a failing REQUIRED check-run. Status is carried
  # too so the caller can tell "failing" from "still running": `unstable` covers
  # both a failing and a merely-pending non-required check.
  checkruns_ndjson=$(gh_api "repos/${REPOSITORY}/commits/${head_sha}/check-runs?per_page=100" --paginate \
    --jq '.check_runs[] | {name, status, conclusion, suite: .check_suite.id}' 2>/dev/null || echo "")
  checks_in_progress=$(printf '%s\n' "$checkruns_ndjson" | jq -s 'any(.[]; .status != "completed")' 2>/dev/null || echo false)
  failing_suites=$(printf '%s\n' "$checkruns_ndjson" | jq -s --argjson req "$required_json" \
    '[.[] | select(.conclusion == "failure" and ((.name as $n | $req | index($n)) != null)) | .suite] | unique' 2>/dev/null || echo "[]")
  # Failing REQUIRED suites regardless of budget, so the caller can tell "failing
  # but over budget" from "nothing required failing" (both give eligible_count 0).
  failing_required_count=$(echo "$failing_suites" | jq 'length' 2>/dev/null || echo 0)

  # Workflow runs whose suite has a failing required check, still within rerun budget.
  runs_ndjson=$(gh_api "repos/${REPOSITORY}/actions/runs?head_sha=${head_sha}&per_page=100" --paginate \
    --jq '.workflow_runs[] | {id, run_attempt, suite: .check_suite_id}' 2>/dev/null || echo "")
  eligible_ids=$(printf '%s\n' "$runs_ndjson" | jq -s --argjson n "$RERUN_BUDGET" --argjson suites "$failing_suites" \
    '[.[] | select(((.suite as $s | $suites | index($s)) != null) and .run_attempt <= $n) | .id] | unique' 2>/dev/null || echo "[]")
  eligible_count=$(echo "$eligible_ids" | jq 'length' 2>/dev/null || echo 0)
}

# Human-readable reason a fresh PR gets no rerun ($1 = context prefix): a
# no-candidate PR is often just mid-CI, not failing. Reads RERUN_BUDGET,
# checks_in_progress, failing_required_count (globals).
no_rerun_reason() {
  if [ "$RERUN_BUDGET" -lt 1 ]; then
    printf '%sreruns disabled (rerun-budget=0)' "$1"
  elif [ "$failing_required_count" -gt 0 ]; then
    printf '%sfailing required check but rerun budget exhausted (attempt > %s)' "$1" "$RERUN_BUDGET"
  elif [ "$checks_in_progress" = "true" ]; then
    printf '%schecks still in progress, nothing to rerun yet' "$1"
  else
    printf '%sno failing required check to rerun' "$1"
  fi
}

entries=()

# Classify one candidate PR and write its plan entry (one JSON object) to
# <out_file>; logs progress to stderr. Safe to fork as a worker: only reads the
# pre-warmed REQUIRED_CACHE, never writes it. A PR that fails its GET writes nothing.
classify_one_pr() {
  local cand="$1" out_file="$2"
  local num base head_sha ms
  num=$(echo "$cand" | jq -r '.number')
  base=$(echo "$cand" | jq -r '.base')
  head_sha=$(echo "$cand" | jq -r '.head_sha')

  # Rebase already queued: the PR still carries the label (Renovate strips it once
  # done), so acting now is wasted — the SHA is about to change. Decided from the
  # candidate's labels alone, before any per-PR fetch: the cheapest exit.
  if [ -n "$REBASE_LABEL" ] && echo "$cand" | jq -e --arg l "$REBASE_LABEL" '(.labels // []) | index($l)' >/dev/null; then
    echo "PR #${num} [rebase-labeled] -> pending (rebase already requested; awaiting Renovate)" >&2
    jq -nc --argjson num "$num" \
      '{number: $num, state: "rebase-labeled", action: "pending", reason: "rebase label already set; awaiting Renovate", run_ids: [], behind_by: 0, age_hours: 0}' \
      > "$out_file"
    return 0
  fi

  # mergeable_state is async and reset by base pushes; poll with backoff. A
  # residual "unknown" is deferred (never acted on) in the case below.
  ms=$(mergeable_state_for_pr "$num") || { echo "::warning::skip PR #${num}: GET failed" >&2; return 0; }

  # Per-PR fields, defaulted here and filled lazily by the case below — each state
  # fetches only what its decision needs: staleness (compare + commit GET) gates
  # the rebase-on-stale states, rerun eligibility (the costly check-runs + runs
  # pair) only a fresh PR with a rerun path, head ownership rides along on the
  # staleness commit GET. dirty/unknown fetch nothing further.
  local behind_by=0 age_hours=0 required_count=0 eligible_ids="[]" eligible_count=0 stale=false
  local head_modified=false head_meta_done=false checks_in_progress=false failing_required_count=0
  local action="none" reason=""
  case "$ms" in
    dirty)
      action="skip"; reason="merge conflict; Renovate owns the rebase" ;;
    behind)
      if [ "$REQUIRE_UP_TO_DATE" = "true" ]; then
        # "Require branches up to date" blocks merge until a rebase, so rebase is
        # unavoidable regardless of staleness — but honor an edited branch first.
        fetch_head_meta "$head_sha"
        if [ "$head_modified" = "true" ]; then
          action="skip"; reason="branch edited by non-Renovate author; leave for human (rebase would discard manual commits)"
        else
          action="rebase"; reason="behind base (require-up-to-date blocks merge)"
        fi
      else
        # require-up-to-date disabled: `behind` outranks (masks) blocked/unstable
        # in mergeable_state, so decide it identically — staleness first, then
        # rerun failing required checks on a fresh SHA. Otherwise a behind PR's
        # failing checks would never rerun, and on busy repos nearly all are behind.
        compute_staleness "$base" "$head_sha"
        if [ "$head_modified" = "true" ]; then
          action="skip"; reason="branch edited by non-Renovate author; leave for human (Renovate won't auto-rebase it)"
        elif [ "$stale" = "true" ]; then
          action="rebase"; reason="stale (behind_by>=${BEHIND_THRESHOLD} or age>=${STALE_HOURS}h)"
        else
          compute_rerun_eligibility "$base" "$head_sha"
          if [ "$eligible_count" -gt 0 ]; then
            action="rerun"; reason="behind (ignored) + failing required checks on fresh SHA; rerun ${eligible_count} run(s) (budget left)"
          else
            action="none"; reason="$(no_rerun_reason "behind (ignored), fresh; ")"
          fi
        fi
      fi ;;
    blocked|unstable)
      # Staleness wins over rerun: a stale PR rebases to merge anyway, so
      # rerunning its stale SHA burns CI for nothing. Only when fresh do we pay
      # for rerun eligibility. compute_staleness also sets head_modified.
      compute_staleness "$base" "$head_sha"
      if [ "$head_modified" = "true" ]; then
        action="skip"; reason="branch edited by non-Renovate author; leave for human (Renovate won't auto-rebase it)"
      elif [ "$stale" = "true" ]; then
        action="rebase"; reason="stale -> rebase (fresh SHA; rerun skipped on stale code)"
      else
        compute_rerun_eligibility "$base" "$head_sha"
        if [ "$eligible_count" -gt 0 ]; then
          action="rerun"; reason="failing required checks on fresh SHA; rerun ${eligible_count} run(s) (budget left)"
        else
          action="none"; reason="$(no_rerun_reason "fresh; ")"
        fi
      fi ;;
    clean|has_hooks)
      compute_staleness "$base" "$head_sha"
      if [ "$head_modified" = "true" ]; then
        action="skip"; reason="branch edited by non-Renovate author; leave for human (Renovate won't auto-rebase it)"
      elif [ "$stale" = "true" ]; then
        action="rebase"; reason="stale (behind_by>=${BEHIND_THRESHOLD} or age>=${STALE_HOURS}h)"
      else
        action="none"; reason="fresh & green"
      fi ;;
    *)
      # unknown: GitHub hadn't finished (re)computing mergeability (base likely
      # moved mid-run). Acting would be a guess, so defer to the next run.
      action="none"; reason="indeterminate mergeable_state ('${ms}'); deferring to next run" ;;
  esac

  echo "PR #${num} [${ms}] behind_by=${behind_by} age=${age_hours}h required=${required_count} -> ${action} (${reason})" >&2

  jq -nc \
    --argjson num "$num" \
    --arg state "$ms" \
    --arg action "$action" \
    --arg reason "$reason" \
    --argjson rids "$eligible_ids" \
    --argjson behind "$behind_by" \
    --argjson age "$age_hours" \
    '{number: $num, state: $state, action: $action, reason: $reason, run_ids: $rids, behind_by: $behind, age_hours: $age}' \
    > "$out_file"
}

# Fan out classification across a bounded worker pool. Each PR writes to a
# separate index-named file so the plan reassembles in stable input order.
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

idx=0
while read -r cand; do
  [ -z "$cand" ] && continue
  # Throttle: keep at most CLASSIFY_CONCURRENCY workers in flight.
  while [ "$(jobs -rp | wc -l)" -ge "$CLASSIFY_CONCURRENCY" ]; do
    wait -n 2>/dev/null || break
  done
  classify_one_pr "$cand" "$work_dir/$(printf '%05d' "$idx").json" &
  idx=$((idx + 1))
done < <(echo "$candidates" | jq -c '.[]')
wait

# Reassemble entries in stable order (skipped PRs simply have no file).
while IFS= read -r f; do
  [ -z "$f" ] && continue
  entries+=("$(cat "$f")")
done < <(find "$work_dir" -type f -name '*.json' | sort)

if [ "${#entries[@]}" -gt 0 ]; then
  printf '%s\n' "${entries[@]}" | jq -s '.' > "$PLAN_FILE"
else
  echo '[]' > "$PLAN_FILE"
fi

# Optional human-readable summary.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Renovate PR maintainer — plan"
    echo ""
    echo "| PR | state | behind_by | age (h) | action | reason |"
    echo "|---:|:------|----------:|--------:|:-------|:-------|"
    jq -r '.[] | "| #\(.number) | \(.state) | \(.behind_by) | \(.age_hours) | \(.action) | \(.reason) |"' "$PLAN_FILE"
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "Plan written to ${PLAN_FILE}"
