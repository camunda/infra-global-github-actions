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
#   behind                -> rebase now if require-up-to-date-strategy=all, or =automerge and
#                            the PR auto-merges; else treat like blocked
#   blocked / unstable    -> rebase if stale, else rerun a failing required run, else none
#   clean / has_hooks     -> rebase if stale, else none
#   unknown               -> none    (mergeability pending; never act on a guess; a PR
#                            in the merge queue is surfaced as `queued`, also none)
#
# Stale = behind AND (behind_by >= BEHIND_THRESHOLD OR head age >= STALE_HOURS): a rebase only
# helps a PR that is behind its base, so a PR level with base (behind_by=0) is never stale and
# is never rebased on age alone (its failing checks are re-run instead). A rebase resets both.
# After classification, when require-up-to-date-strategy=automerge, behind auto-merging PRs are
# rebased immediately (see the behind case); when automerge-optimized, a per-base post-pass
# instead rebases just one least-behind MERGEABLE behind automerge PR per base (blocked ones
# excluded). Every plan entry also carries `blockers`: the human-readable merge gate(s)
# GitHub enforces (failing/pending required check, awaiting required review, changes
# requested, conflict, behind base), surfaced in the step summary. For `blocked` PRs (and,
# in automerge-optimized mode, behind automerge PRs) the review gate is read via GraphQL
# reviewDecision, since REST mergeable_state collapses "failing required check" and "missing
# required review" into the same `blocked` value (and `behind` masks both).
set -euo pipefail

: "${REPOSITORY:?REPOSITORY is required (owner/name)}"
: "${PLAN_FILE:?PLAN_FILE is required}"
# Login identifying Renovate's PRs: selects which PRs are in scope and is the
# trusted head author/committer (see GITHUB_SIGNING_COMMITTER, EXTRA_TRUSTED_LOGINS).
RENOVATE_AUTHOR="${RENOVATE_AUTHOR:-renovate[bot]}"
# Comma-separated labels that take a PR out of scope (e.g. Renovate already keeps
# `keep-updated` PRs continuously rebased, so this action leaves them alone).
EXCLUDE_LABELS="${EXCLUDE_LABELS:-keep-updated,stop-updating}"
# Staleness signals (both reset by a rebase, and both gated on the PR actually
# being behind base): rebase once the head is at least this many commits behind
# base, or -- while behind -- at least this many hours old. A PR level with base
# is never rebased.
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
# How to handle the `behind` mergeable_state ("Require branches up to date"):
#   none       (default) ignore it; decide a behind PR by staleness, like a clean one.
#   automerge  rebase every behind auto-merging PR immediately so Renovate can merge it
#              next scan; non-automerge PRs are still decided by staleness.
#   automerge-optimized  keep just one auto-merging PR per base branch fresh: a post-pass
#              rebases the single least-behind MERGEABLE behind automerge PR (blocked ones
#              are excluded so they can't stall the train) only when that base has no
#              auto-merging PR already merge-ready or being rebased. Minimal-churn variant
#              of `automerge` for busy repos where Renovate merges few PRs per run.
#   all        treat behind as a hard merge blocker and rebase immediately.
REQUIRE_UP_TO_DATE_STRATEGY="${REQUIRE_UP_TO_DATE_STRATEGY:-none}"
case "$REQUIRE_UP_TO_DATE_STRATEGY" in
  none|automerge|automerge-optimized|all) ;;
  *)
    echo "::warning::invalid require-up-to-date-strategy='${REQUIRE_UP_TO_DATE_STRATEGY}'; falling back to 'none'" >&2
    REQUIRE_UP_TO_DATE_STRATEGY="none" ;;
esac
# PR labels (comma/newline-separated) that mark a Renovate PR as auto-merging, used
# by require-up-to-date-strategy=automerge and automerge-optimized. Native GitHub
# auto-merge is detected too; empty relies on native auto-merge only.
AUTOMERGE_LABELS="${AUTOMERGE_LABELS:-automerge}"
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
# "unknown" is returned as-is so the caller defers. The same GET also yields native
# auto-merge state, printed after the state as "<mergeable_state> <true|false>".
# Non-zero only if the GET fails.
mergeable_state_for_pr() {
  local num="$1" attempt=1 ms am pr
  while [ "$attempt" -le "$MERGEABLE_MAX_POLLS" ]; do
    pr=$(gh_api "repos/${REPOSITORY}/pulls/${num}") || return 1
    ms=$(echo "$pr" | jq -r '.mergeable_state // "unknown"')
    am=$(echo "$pr" | jq -r 'if .auto_merge then "true" else "false" end')
    if [ "$ms" != "unknown" ]; then
      printf '%s %s' "$ms" "$am"
      return 0
    fi
    if [ "$attempt" -lt "$MERGEABLE_MAX_POLLS" ]; then
      sleep "$(( MERGEABLE_POLL_DELAY * attempt ))"
    fi
    attempt=$((attempt + 1))
  done
  printf 'unknown %s' "${am:-false}"
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
echo "Thresholds: behind_by>=${BEHIND_THRESHOLD}, age>=${STALE_HOURS}h, rerun-budget=${RERUN_BUDGET}, require-up-to-date-strategy=${REQUIRE_UP_TO_DATE_STRATEGY}"
[[ "$REQUIRE_UP_TO_DATE_STRATEGY" == automerge* ]] && echo "Automerge labels: ${AUTOMERGE_LABELS:-<none> (native auto-merge only)}"
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

# True when the candidate PR ($1, a candidate JSON object) carries any label listed
# in AUTOMERGE_LABELS (comma/newline-separated, trimmed). Lets require-up-to-date-strategy=
# automerge spot auto-merging Renovate PRs from labels alone (no extra API call).
# An empty list never matches.
labels_has_automerge() {
  local cand="$1"
  [ -z "$AUTOMERGE_LABELS" ] && return 1
  echo "$cand" | jq -e --arg lbls "$AUTOMERGE_LABELS" '
    ([$lbls | splits("[,\n]")] | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $am
    | ((.labels // []) | any(. as $l | ($am | index($l)) != null))
  ' >/dev/null 2>&1
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
  behind_measured=true
  fetch_head_meta "$head_sha"
  # A rebase only helps a PR that is actually behind its base; one level with base
  # (behind_by=0) would just get an identical tree re-run through CI. So staleness
  # requires being behind, then fires when far behind OR sitting too long unrebased.
  if [ "$behind_by" -gt 0 ] && { [ "$behind_by" -ge "$BEHIND_THRESHOLD" ] || [ "$age_hours" -ge "$STALE_HOURS" ]; }; then
    stale=true
  fi
}

# Required-check status for one PR's head SHA, independent of rerun budget so it can
# also feed blocker reporting: the REQUIRED contexts (ruleset ∪ EXTRA_RERUN_CHECKS),
# whether any check is still running, and the suites with a failing required check.
# Memoized per PR via check_status_done. Sets required_count, checks_in_progress,
# failing_suites, failing_required_count (caller locals). Cost: 1 check-runs GET.
compute_required_check_status() {
  local base="$1" head_sha="$2" required_checks required_json checkruns_ndjson
  [ "$check_status_done" = "true" ] && return 0
  check_status_done=true
  required_checks=$(required_checks_for_base "$base")
  # Union ruleset contexts with EXTRA_RERUN_CHECKS (split, trimmed, de-duped);
  # with no extras this is just the ruleset set.
  required_json=$(
    { printf '%s\n' "$required_checks"
      printf '%s' "$EXTRA_RERUN_CHECKS" | tr ',' '\n'
    } | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s 'map(select(length > 0)) | unique')
  required_count=$(echo "$required_json" | jq 'length')

  # Suites on the head SHA with a failing REQUIRED check-run. Status is carried too
  # so we can tell "failing" from "still running": `unstable` covers both a failing
  # and a merely-pending non-required check.
  checkruns_ndjson=$(gh_api "repos/${REPOSITORY}/commits/${head_sha}/check-runs?per_page=100" --paginate \
    --jq '.check_runs[] | {name, status, conclusion, suite: .check_suite.id}' 2>/dev/null || echo "")
  checks_in_progress=$(printf '%s\n' "$checkruns_ndjson" | jq -s 'any(.[]; .status != "completed")' 2>/dev/null || echo false)
  failing_suites=$(printf '%s\n' "$checkruns_ndjson" | jq -s --argjson req "$required_json" \
    '[.[] | select(.conclusion == "failure" and ((.name as $n | $req | index($n)) != null)) | .suite] | unique' 2>/dev/null || echo "[]")
  failing_required_count=$(echo "$failing_suites" | jq 'length' 2>/dev/null || echo 0)
}

# Rerun eligibility for one PR, scoped to REQUIRED checks only (never reruns
# non-blocking workflows): a failing required check's suite -> the workflow run that
# produced it, still within budget. Sets eligible_ids, eligible_count (globals) and,
# via compute_required_check_status, the check-status globals. Cost: 1 actions/runs GET
# (plus the shared check-runs GET); short-circuits the runs GET when reruns are off.
compute_rerun_eligibility() {
  local base="$1" head_sha="$2" runs_ndjson
  # Reruns disabled (budget < 1): nothing can be eligible, so skip the runs GET.
  # Check status is computed on demand by compute_required_check_status (for blocker
  # reporting), so we don't force the check-runs GET here either.
  if [ "$RERUN_BUDGET" -lt 1 ]; then
    eligible_ids="[]"; eligible_count=0
    return 0
  fi
  compute_required_check_status "$base" "$head_sha"

  # Workflow runs whose suite has a failing required check, still within rerun budget.
  runs_ndjson=$(gh_api "repos/${REPOSITORY}/actions/runs?head_sha=${head_sha}&per_page=100" --paginate \
    --jq '.workflow_runs[] | {id, run_attempt, suite: .check_suite_id}' 2>/dev/null || echo "")
  eligible_ids=$(printf '%s\n' "$runs_ndjson" | jq -s --argjson n "$RERUN_BUDGET" --argjson suites "$failing_suites" \
    '[.[] | select(((.suite as $s | $suites | index($s)) != null) and .run_attempt <= $n) | .id] | unique' 2>/dev/null || echo "[]")
  eligible_count=$(echo "$eligible_ids" | jq 'length' 2>/dev/null || echo 0)
}

# Review gate for one PR via GraphQL reviewDecision: REST mergeable_state collapses a
# missing required approval and a failing required check into the same `blocked`
# value, so this disambiguates the review side. Prints REVIEW_REQUIRED |
# CHANGES_REQUESTED | APPROVED | NONE (null/none/unreadable -> NONE). Cost: 1 GraphQL
# call; only invoked for `blocked` PRs. The pull-requests token scope covers it.
review_decision_for_pr() {
  local num="$1" owner repo rd
  owner="${REPOSITORY%%/*}"; repo="${REPOSITORY##*/}"
  # SC2016: $o/$r/$n are GraphQL variables (bound by gh via -f/-F), not shell vars.
  # shellcheck disable=SC2016
  rd=$(gh_api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewDecision}}}' \
    -f o="$owner" -f r="$repo" -F n="$num" \
    --jq '.data.repository.pullRequest.reviewDecision' 2>/dev/null || echo "")
  { [ -z "$rd" ] || [ "$rd" = "null" ]; } && rd="NONE"
  printf '%s' "$rd"
}

# Merge-queue entry for one PR via GraphQL: a PR sitting in the merge queue reports
# mergeable_state `unknown` over REST (GitHub is testing it on the queue branch),
# which otherwise reads as "indeterminate". This disambiguates that case. Prints
# "<state> <position>" (e.g. "QUEUED 3", "AWAITING_CHECKS 1") or "NONE 0" when the
# PR is not queued (or the repo has no merge queue — the field is then null). Cost:
# 1 GraphQL call; only invoked for `unknown` PRs. The pull-requests token scope covers it.
merge_queue_for_pr() {
  local num="$1" owner repo entry
  owner="${REPOSITORY%%/*}"; repo="${REPOSITORY##*/}"
  # shellcheck disable=SC2016
  entry=$(gh_api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){mergeQueueEntry{state position}}}}' \
    -f o="$owner" -f r="$repo" -F n="$num" \
    --jq '.data.repository.pullRequest.mergeQueueEntry | if . == null then "NONE 0" else "\(.state) \(.position // 0)" end' 2>/dev/null || echo "NONE 0")
  { [ -z "$entry" ] || [ "$entry" = "null" ]; } && entry="NONE 0"
  printf '%s' "$entry"
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

# Human-readable merge blocker(s) for one PR — why GitHub won't merge it right now —
# derived from mergeable_state plus, for `blocked`, the required-check status and review
# decision read above. Independent of the maintainer's action: e.g. a PR awaiting review
# is action=none but blockers="awaiting required review" (only a human approval unblocks
# it). Joins parts with "; " and sets `blockers` (caller local); empty when unblocked.
compute_blockers() {
  local parts=() b="" p
  case "$ms" in
    dirty)    parts+=("merge conflict") ;;
    behind)
      parts+=("behind base branch")
      [ "$failing_required_count" -gt 0 ] && parts+=("failing required check")
      [ "$checks_in_progress" = "true" ] && parts+=("required check pending")
      # In automerge-optimized mode behind automerge PRs also have reviewDecision read
      # (REST `behind` masks it), so surface the review gate too; otherwise stays empty.
      case "$review_decision" in
        REVIEW_REQUIRED)   parts+=("awaiting required review") ;;
        CHANGES_REQUESTED) parts+=("changes requested") ;;
      esac
      ;;
    unstable)
      # Differentiate pending from failing: if any check is still running, report
      # pending (it may yet pass); once nothing is pending, the non-passing one is a
      # failure. Falls back to the combined wording if check status wasn't fetched.
      if [ "$check_status_done" = "true" ]; then
        if [ "$checks_in_progress" = "true" ]; then
          parts+=("non-required check pending")
        else
          parts+=("non-required check failing")
        fi
      else
        parts+=("non-required check failing or pending")
      fi
      ;;
    unknown)  parts+=("mergeability not yet computed") ;;
    queued)   parts+=("in merge queue") ;;
    blocked)
      [ "$failing_required_count" -gt 0 ] && parts+=("failing required check")
      [ "$checks_in_progress" = "true" ] && parts+=("required check pending")
      case "$review_decision" in
        REVIEW_REQUIRED)   parts+=("awaiting required review") ;;
        CHANGES_REQUESTED) parts+=("changes requested") ;;
      esac
      # Inspected (not head-edited) but no specific signal: name the residual required
      # gate class so the row is never silently empty (e.g. unresolved conversation,
      # required deployment, or signature).
      if [ "${#parts[@]}" -eq 0 ] && [ "$head_modified" != "true" ]; then
        parts+=("required branch-protection gate (review, conversation, deployment, or signature)")
      fi
      ;;
  esac
  [ "$head_modified" = "true" ] && parts+=("branch edited by non-Renovate author")
  if [ "${#parts[@]}" -gt 0 ]; then
    for p in "${parts[@]}"; do b="${b:+$b; }$p"; done
  fi
  blockers="$b"
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

  # Automerge detection (for require-up-to-date-strategy=automerge): labels are known from
  # the candidate alone; native GitHub auto-merge is added after the pulls GET
  # below. Computed even when unused so every plan entry carries a stable
  # `automerge` field.
  local is_automerge=false
  # Head age + ownership (fetch_head_meta) and behind_by/staleness (compute_staleness),
  # declared up here (not only in the case block below) so the rebase-labeled early
  # return can also report a real head age AND behind_by, which stuck detection needs.
  local age_hours=0 head_modified=false head_meta_done=false
  local behind_by=0 behind_measured=false stale=false
  labels_has_automerge "$cand" && is_automerge=true

  # Rebase already queued: the PR still carries the label (Renovate strips it once
  # done), so acting now is wasted — the SHA is about to change. Decided from the
  # candidate's labels alone. We still measure staleness (head-commit age + behind_by,
  # one commit + one compare GET) so a caller can tell a freshly-labeled PR from one
  # Renovate has left awaiting a rebase for too long / far behind (stuck). We do NOT
  # poll the mergeable_state, so blockers are reported as not-evaluated rather than
  # empty (empty renders as "—" = "nothing blocking", which we can't claim here).
  if [ -n "$REBASE_LABEL" ] && echo "$cand" | jq -e --arg l "$REBASE_LABEL" '(.labels // []) | index($l)' >/dev/null; then
    compute_staleness "$base" "$head_sha"
    echo "PR #${num} [rebase-labeled] -> pending (rebase already requested; awaiting Renovate; head ${age_hours}h old, behind_by=${behind_by})" >&2
    jq -nc --argjson num "$num" --arg base "$base" --argjson am "$is_automerge" --argjson age "$age_hours" --argjson behind "$behind_by" \
      '{number: $num, base: $base, state: "rebase-labeled", action: "pending", reason: "rebase label already set; awaiting Renovate", run_ids: [], behind_by: $behind, age_hours: $age, automerge: $am, blockers: "not evaluated (rebase queued)"}' \
      > "$out_file"
    return 0
  fi

  # mergeable_state is async and reset by base pushes; poll with backoff. A
  # residual "unknown" is deferred (never acted on) in the case below. The same
  # GET also yields native auto-merge state, appended after a space.
  local ms_am auto_merge_native
  ms_am=$(mergeable_state_for_pr "$num") || { echo "::warning::skip PR #${num}: GET failed" >&2; return 0; }
  ms="${ms_am%% *}"
  auto_merge_native="${ms_am##* }"
  [ "$auto_merge_native" = "true" ] && is_automerge=true

  # Per-PR fields, defaulted here and filled lazily by the case below — each state
  # fetches only what its decision needs: staleness (compare + commit GET) gates
  # the rebase-on-stale states, rerun eligibility (the costly check-runs + runs
  # pair) only a fresh PR with a rerun path, head ownership rides along on the
  # staleness commit GET. dirty also runs staleness (compare + commit GET) for its
  # stuck context (head age + behind_by) but never acts; unknown fetches nothing
  # further. (age_hours/head_modified/head_meta_done/behind_by/stale are declared
  # above so the rebase-labeled early return can use them too.)
  # behind_by is only measured by compute_staleness (a compare API call). The one
  # state that still skips it (unknown) must NOT report 0 — that reads as "level
  # with base" when it is really "not measured" — so it emits null instead.
  local required_count=0 eligible_ids="[]" eligible_count=0
  local checks_in_progress=false failing_required_count=0
  local check_status_done=false failing_suites="[]" review_decision="" blockers=""
  local action="none" reason=""
  case "$ms" in
    dirty)
      # Renovate owns the conflict rebase; we only READ staleness (head age +
      # behind_by) so a caller can flag a PR that has stayed conflicted too long /
      # far behind (Renovate not processing it). We never act on it ourselves.
      compute_staleness "$base" "$head_sha"
      action="skip"; reason="merge conflict; Renovate owns the rebase" ;;
    behind)
      # Rebase a behind PR immediately when require-up-to-date-strategy demands it: `all`
      # covers every PR, `automerge` only the auto-merging ones (so Renovate can
      # merge them next scan on a base that requires up-to-date branches). Any
      # other case (none, or automerge mode + non-automerge PR) falls through to
      # the staleness path below.
      local immediate_rebase=false
      if [ "$REQUIRE_UP_TO_DATE_STRATEGY" = "all" ]; then
        immediate_rebase=true
      elif [ "$REQUIRE_UP_TO_DATE_STRATEGY" = "automerge" ] && [ "$is_automerge" = "true" ]; then
        immediate_rebase=true
      fi
      if [ "$immediate_rebase" = "true" ]; then
        # "Require branches up to date" blocks merge until a rebase, so rebase is
        # unavoidable regardless of staleness — but honor an edited branch first.
        fetch_head_meta "$head_sha"
        if [ "$head_modified" = "true" ]; then
          action="skip"; reason="branch edited by non-Renovate author; leave for human (rebase would discard manual commits)"
        elif [ "$REQUIRE_UP_TO_DATE_STRATEGY" = "all" ]; then
          action="rebase"; reason="behind base (require-up-to-date-strategy=all blocks merge)"
        else
          action="rebase"; reason="behind automerge PR (require-up-to-date-strategy=automerge); rebased so Renovate can merge it next scan"
        fi
      else
        # require-up-to-date-strategy none, or automerge mode but this PR doesn't auto-merge:
        # `behind` outranks (masks) blocked/unstable in mergeable_state, so decide it
        # identically — staleness first, then rerun failing required checks on a fresh
        # SHA. Otherwise a behind PR's failing checks would never rerun, and on busy
        # repos nearly all are behind.
        compute_staleness "$base" "$head_sha"
        if [ "$head_modified" = "true" ]; then
          action="skip"; reason="branch edited by non-Renovate author; leave for human (Renovate won't auto-rebase it)"
        elif [ "$stale" = "true" ]; then
          action="rebase"; reason="stale: behind & (>=${BEHIND_THRESHOLD} commits or >=${STALE_HOURS}h old)"
        else
          compute_rerun_eligibility "$base" "$head_sha"
          if [ "$eligible_count" -gt 0 ]; then
            action="rerun"; reason="behind (ignored) + failing required checks on fresh SHA; rerun ${eligible_count} run(s) (budget left)"
          else
            action="none"; reason="$(no_rerun_reason "behind (ignored), not stale; ")"
          fi
        fi
      fi
      # automerge-optimized: a behind auto-merging PR that the per-PR pass left as `none`
      # is a candidate for the per-base merge-train prime. `behind` masks its real
      # mergeability, so compute the blockers now: required-check status (cheap, memoized;
      # shared with rerun) and — only when checks are clean, where it actually decides
      # candidacy — the GraphQL reviewDecision. A behind PR whose only blocker is "behind
      # base branch" is a mergeable candidate; anything else (failing/pending check,
      # awaiting review, changes requested) excludes it so it can't stall the train.
      if [ "$REQUIRE_UP_TO_DATE_STRATEGY" = "automerge-optimized" ] && [ "$is_automerge" = "true" ] && [ "$action" = "none" ]; then
        compute_required_check_status "$base" "$head_sha"
        if [ "$failing_required_count" -eq 0 ] && [ "$checks_in_progress" != "true" ]; then
          review_decision=$(review_decision_for_pr "$num")
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
        action="rebase"; reason="stale: behind & (>=${BEHIND_THRESHOLD} commits or >=${STALE_HOURS}h old); rebased not rerun (stale SHA)"
      else
        compute_rerun_eligibility "$base" "$head_sha"
        if [ "$eligible_count" -gt 0 ]; then
          action="rerun"; reason="failing required checks on fresh SHA; rerun ${eligible_count} run(s) (budget left)"
        else
          action="none"; reason="$(no_rerun_reason "fresh; ")"
        fi
      fi
      # Surface the true merge gate: REST collapses "failing required check" and
      # "missing required review" into `blocked`, and `unstable` hides whether the
      # non-required check is failing vs still pending. So for an unmodified PR fetch
      # check status (cheap, memoized), plus reviewDecision (1 GraphQL) for `blocked`.
      if [ "$head_modified" != "true" ]; then
        case "$ms" in
          blocked)
            compute_required_check_status "$base" "$head_sha"
            review_decision=$(review_decision_for_pr "$num") ;;
          unstable)
            compute_required_check_status "$base" "$head_sha" ;;
        esac
      fi ;;
    clean|has_hooks)
      compute_staleness "$base" "$head_sha"
      if [ "$head_modified" = "true" ]; then
        action="skip"; reason="branch edited by non-Renovate author; leave for human (Renovate won't auto-rebase it)"
      elif [ "$stale" = "true" ]; then
        action="rebase"; reason="stale: behind & (>=${BEHIND_THRESHOLD} commits or >=${STALE_HOURS}h old)"
      else
        action="none"; reason="fresh & green"
      fi ;;
    *)
      # unknown: either GitHub hadn't finished (re)computing mergeability (base
      # likely moved mid-run), or the PR is in the merge queue (REST reports
      # `unknown` while GitHub tests it on the queue branch). Disambiguate via the
      # merge-queue entry so a healthy queued PR isn't mislabeled indeterminate.
      local mq mq_state mq_pos
      mq=$(merge_queue_for_pr "$num")
      mq_state="${mq%% *}"; mq_pos="${mq##* }"
      if [ "$mq_state" != "NONE" ]; then
        ms="queued"
        action="none"; reason="in merge queue (${mq_state}, position ${mq_pos}); GitHub owns the merge — no maintainer action"
      else
        action="none"; reason="indeterminate mergeable_state ('${ms}'); deferring to next run"
      fi ;;
  esac

  compute_blockers

  # Report behind_by only when actually measured; otherwise null ("n/a" in the log)
  # so a skipped compare never masquerades as 0 (= level with base).
  local behind_json behind_disp
  if [ "$behind_measured" = "true" ]; then behind_json="$behind_by"; behind_disp="$behind_by"; else behind_json=null; behind_disp="n/a"; fi

  echo "PR #${num} [${ms}] behind_by=${behind_disp} age=${age_hours}h required=${required_count} blockers=[${blockers}] -> ${action} (${reason})" >&2

  jq -nc \
    --argjson num "$num" \
    --arg base "$base" \
    --arg state "$ms" \
    --arg action "$action" \
    --arg reason "$reason" \
    --arg blockers "$blockers" \
    --argjson rids "$eligible_ids" \
    --argjson behind "$behind_json" \
    --argjson age "$age_hours" \
    --argjson am "$is_automerge" \
    '{number: $num, base: $base, state: $state, action: $action, reason: $reason, blockers: $blockers, run_ids: $rids, behind_by: $behind, age_hours: $age, automerge: $am}' \
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

# Automerge merge-train priming (require-up-to-date-strategy=automerge-optimized only), decided
# independently PER BASE BRANCH — each base is its own Renovate merge-train. Goal: keep
# exactly one auto-merging PR per base fresh, with minimal rebases, and never let a blocked
# PR hold the front of the train (the caveat of the eager `automerge` mode).
#
# A base needs no prime when it already has a "merge-progressing" automerge PR — one that
# will merge, or is being made fresh, without our help:
#   - action rebase/pending (a fresh SHA is incoming), or
#   - up-to-date (behind_by==0) and not hard-blocked: blockers empty (clean/has_hooks) or
#     only "required check pending" (fresh & mid-CI — the running workflow is respected).
# Otherwise rebase ONE candidate: a behind automerge PR still action=none whose ONLY
# blocker is "behind base branch" (mergeable-behind), least-behind, ties by lowest number.
# PRs with any other blocker (failing/pending check, awaiting review, changes requested)
# are NOT candidates — they keep rebasing on staleness like any PR but never prime the
# train. Whole-plan pass that buckets by base; plan order is preserved.
if [ "$REQUIRE_UP_TO_DATE_STRATEGY" = "automerge-optimized" ]; then
  jq '
    def parts: (.blockers // "") | if . == "" then [] else split("; ") end;
    def merge_progressing:
      .automerge == true and (
        .state == "queued"
        or (.action == "rebase" or .action == "pending")
        or (.behind_by == 0 and (parts == [] or parts == ["required check pending"]))
      );
    def is_candidate:
      .automerge == true and .state == "behind" and .action == "none"
      and (parts == ["behind base branch"]);
    # One PR number to prime per base whose train is stalled (no merge-progressing PR);
    # group_by only chooses, map below preserves original order.
    ([ group_by(.base)[]
       | if any(.[]; merge_progressing) then empty
         else (map(select(is_candidate)) | sort_by(.behind_by, .number))
              | if length == 0 then empty else .[0].number end
       end
     ]) as $primes
    | map(if (.number as $n | $primes | index($n)) != null
          then .action = "rebase"
             | .reason = "primed automerge merge-train (require-up-to-date-strategy=automerge-optimized): least-behind mergeable behind PR on this base so Renovate can merge it next scan"
          else . end)
  ' "$PLAN_FILE" > "${PLAN_FILE}.tmp" && mv "${PLAN_FILE}.tmp" "$PLAN_FILE"

  primed=$(jq -r '[.[] | select(.reason | startswith("primed automerge")) | (.number | tostring)] | join(", ")' "$PLAN_FILE" 2>/dev/null || echo "")
  if [ -n "$primed" ]; then
    echo "Automerge merge-train (optimized): primed PR(s) #${primed} (one per base; least-behind mergeable automerge PR)"
  else
    echo "Automerge merge-train (optimized): no prime needed (each base already has a merge-progressing automerge PR, or none are mergeable-behind)"
  fi
fi

# Expose the per-PR plan as a structured output so a caller can act on it (e.g.
# flag PRs stuck dirty/awaiting a rebase) without this action prescribing that
# policy. Mirrors the step-summary facts, minus internal fields (run_ids/reason).
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  processed_json=$(jq -c '
    [ .[] | {number, base, state, action, behind_by, age_hours, blockers, automerge} ]
  ' "$PLAN_FILE")
  processed_count=$(echo "$processed_json" | jq 'length')
  {
    echo "processed-prs<<EOF"
    echo "$processed_json"
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
  echo "Processed PRs surfaced via processed-prs output: ${processed_count}"
fi

# The human-readable step summary is rendered by apply.sh (the final step), which
# also knows each PR's applied/deferred outcome under the batch cap.
echo "Plan written to ${PLAN_FILE}"
