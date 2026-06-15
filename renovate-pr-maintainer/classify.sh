#!/usr/bin/env bash
# Classify in-scope Renovate PRs into maintenance actions.
#
# This script is READ-ONLY: it never mutates any PR. It inspects each in-scope
# Renovate PR and decides one of: skip / rerun / rebase / none, then writes a
# JSON plan to $PLAN_FILE which apply.sh consumes.
#
# Decision model (see camunda/team-infrastructure#1053):
#   - dirty (merge conflict)                  -> skip   (Renovate rebases conflicts itself)
#   - behind (blocked by "require up to date") -> rebase (apply the rebase label)
#   - blocked/unstable (required checks red)   -> rerun  if a failed run still has budget,
#                                                 else rebase if stale, else none
#   - clean/has_hooks                          -> rebase if stale, else none
#   - unknown (mergeability not yet computed)  -> none   (defer; never act on a guess)
#
# Staleness is OR of two stateless signals, both reset by a rebase:
#   behind_by >= BEHIND_THRESHOLD   OR   age_since_head >= STALE_HOURS
set -euo pipefail

: "${REPOSITORY:?REPOSITORY is required (owner/name)}"
: "${PLAN_FILE:?PLAN_FILE is required}"
RENOVATE_AUTHOR="${RENOVATE_AUTHOR:-renovate[bot]}"
EXCLUDE_LABELS="${EXCLUDE_LABELS:-keep-updated,stop-updating}"
BEHIND_THRESHOLD="${BEHIND_THRESHOLD:-60}"
STALE_HOURS="${STALE_HOURS:-24}"
RERUN_BUDGET="${RERUN_BUDGET:-1}"
BASE_BRANCH="${BASE_BRANCH:-}"
# Polling for GitHub's asynchronously-computed mergeable_state. Every push to
# the base branch resets it to "unknown", so a single retry is often not enough
# on busy repos; poll a few times with backoff before giving up.
MERGEABLE_MAX_POLLS="${MERGEABLE_MAX_POLLS:-5}"
MERGEABLE_POLL_DELAY="${MERGEABLE_POLL_DELAY:-3}"

MAX_API_RETRIES=3
API_RETRY_DELAY=5
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

# Resolve a PR's mergeable_state. GitHub computes it asynchronously and resets
# it to null/"unknown" whenever the base branch moves, which on busy repos
# happens constantly. Poll with linear backoff and return the first definitive
# value. A residual "unknown" is returned as-is so the caller can defer instead
# of guessing (acting on a guess can force a needless rebase or skip a cheaper
# rerun). Returns non-zero only when the PR GET itself fails.
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

# Required status check contexts for a base branch, discovered from repository
# rulesets targeting that branch. Newline-separated, cached per base branch.
# NOTE: only rulesets are inspected (not classic branch protection), mirroring
# the wait-for-required-checks action.
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
    # `~ALL` (every branch) and `~DEFAULT_BRANCH`, plus glob includes like
    # `refs/heads/stable/**`. Glob match avoids regex injection.
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
echo "Thresholds: behind_by>=${BEHIND_THRESHOLD}, age>=${STALE_HOURS}h, rerun-budget=${RERUN_BUDGET}"
[ -n "$BASE_BRANCH" ] && echo "Base-branch filter: ${BASE_BRANCH}"

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

# Pre-warm the required-checks cache once per distinct base branch, in THIS
# shell. The per-PR call below uses command substitution ($(...)), which runs
# in a subshell; a subshell inherits a copy of REQUIRED_CACHE but cannot write
# back to it, so warming the cache here is what makes the in-loop calls cache
# hits instead of re-discovering rulesets (many gh api calls) for every PR.
while IFS= read -r warm_base; do
  [ -z "$warm_base" ] && continue
  required_checks_for_base "$warm_base" >/dev/null
done < <(echo "$candidates" | jq -r '.[].base' | sort -u)

# Compute staleness for one PR: sets behind_by, age_hours, stale (globals).
# Cost: 1 compare + 1 commit GET. Called only for states whose decision can
# depend on staleness (blocked/unstable/clean/has_hooks).
compute_staleness() {
  local base="$1" head_sha="$2" base_enc head_date head_epoch
  # URL-encode '/' in the base ref so base branches like `stable/8.7` don't break the path.
  base_enc="${base//\//%2F}"
  behind_by=$(gh_api "repos/${REPOSITORY}/compare/${base_enc}...${head_sha}" --jq '.behind_by' 2>/dev/null || echo 0)
  [ -z "$behind_by" ] && behind_by=0
  head_date=$(gh_api "repos/${REPOSITORY}/commits/${head_sha}" --jq '.commit.committer.date' 2>/dev/null || echo "")
  if [ -n "$head_date" ]; then
    head_epoch=$(date -u -d "$head_date" +%s 2>/dev/null || echo "$NOW_EPOCH")
  else
    head_epoch=$NOW_EPOCH
  fi
  age_hours=$(( (NOW_EPOCH - head_epoch) / 3600 ))
  if [ "$behind_by" -ge "$BEHIND_THRESHOLD" ] || [ "$age_hours" -ge "$STALE_HOURS" ]; then
    stale=true
  fi
}

# Compute rerun eligibility for one PR, scoped to REQUIRED checks only:
#   failing required check-run -> its check suite -> the workflow run that produced it.
# Sets required_count, eligible_ids, eligible_count (globals). This avoids
# rerunning non-required (non-blocking) workflows.
# Cost: 1 check-runs + 1 actions/runs GET (both paginated — the most expensive
# pair). Called only for blocked/unstable, the only states with a rerun path.
compute_rerun_eligibility() {
  local base="$1" head_sha="$2" required_checks required_json checkruns_ndjson failing_suites runs_ndjson
  required_checks=$(required_checks_for_base "$base")
  required_json=$(printf '%s\n' "$required_checks" | jq -R . | jq -s 'map(select(length > 0))')
  required_count=$(echo "$required_json" | jq 'length')

  # Check suites on the head SHA that contain a failing REQUIRED check-run.
  checkruns_ndjson=$(gh_api "repos/${REPOSITORY}/commits/${head_sha}/check-runs?per_page=100" --paginate \
    --jq '.check_runs[] | {name, conclusion, suite: .check_suite.id}' 2>/dev/null || echo "")
  failing_suites=$(printf '%s\n' "$checkruns_ndjson" | jq -s --argjson req "$required_json" \
    '[.[] | select(.conclusion == "failure" and ((.name as $n | $req | index($n)) != null)) | .suite] | unique' 2>/dev/null || echo "[]")

  # Workflow runs whose suite has a failing required check, still within rerun budget.
  runs_ndjson=$(gh_api "repos/${REPOSITORY}/actions/runs?head_sha=${head_sha}&per_page=100" --paginate \
    --jq '.workflow_runs[] | {id, run_attempt, suite: .check_suite_id}' 2>/dev/null || echo "")
  eligible_ids=$(printf '%s\n' "$runs_ndjson" | jq -s --argjson n "$RERUN_BUDGET" --argjson suites "$failing_suites" \
    '[.[] | select(((.suite as $s | $suites | index($s)) != null) and .run_attempt <= $n) | .id] | unique' 2>/dev/null || echo "[]")
  eligible_count=$(echo "$eligible_ids" | jq 'length' 2>/dev/null || echo 0)
}

entries=()

while read -r cand; do
  [ -z "$cand" ] && continue
  num=$(echo "$cand" | jq -r '.number')
  base=$(echo "$cand" | jq -r '.base')
  head_sha=$(echo "$cand" | jq -r '.head_sha')

  # mergeable_state is computed asynchronously and reset by base pushes; poll
  # with backoff. A residual "unknown" is handled conservatively in the case
  # statement below (deferred, never acted on).
  ms=$(mergeable_state_for_pr "$num") || { echo "::warning::skip PR #${num}: GET failed"; continue; }

  # Per-PR diagnostic/plan fields. Defaulted here, then filled lazily by the
  # case below — we only fetch what each state's decision actually needs:
  #   - rerun eligibility (check-runs + actions/runs, the costliest pair) only
  #     matters for blocked/unstable.
  #   - staleness (compare + commit date) only matters for states that can
  #     rebase-on-stale (blocked/unstable/clean/has_hooks).
  # dirty/behind/unknown have a fixed action and fetch nothing further.
  # apply.sh consumes only number/action/run_ids, so the defaulted diagnostic
  # fields (behind_by/age_hours) on fixed-action states are cosmetic, not load-bearing.
  behind_by=0
  age_hours=0
  required_count=0
  eligible_ids="[]"
  eligible_count=0
  stale=false

  action="none"
  reason=""
  case "$ms" in
    dirty)
      action="skip"; reason="merge conflict; Renovate owns the rebase" ;;
    behind)
      action="rebase"; reason="behind base (require-up-to-date blocks merge)" ;;
    blocked|unstable)
      # Needs rerun eligibility; staleness is the rebase fallback and also
      # populates behind_by/age diagnostics for these (the actionable) PRs.
      compute_rerun_eligibility "$base" "$head_sha"
      compute_staleness "$base" "$head_sha"
      if [ "$eligible_count" -gt 0 ]; then
        action="rerun"; reason="failing required checks; rerun ${eligible_count} run(s) (budget left)"
      elif [ "$stale" = "true" ]; then
        action="rebase"; reason="checks failing, no required rerun left, stale -> fresh SHA"
      else
        action="none"; reason="checks failing, no required rerun candidate, not stale"
      fi ;;
    clean|has_hooks)
      compute_staleness "$base" "$head_sha"
      if [ "$stale" = "true" ]; then
        action="rebase"; reason="stale (behind_by>=${BEHIND_THRESHOLD} or age>=${STALE_HOURS}h)"
      else
        action="none"; reason="fresh & green"
      fi ;;
    *)
      # unknown / indeterminate: GitHub had not finished (re)computing
      # mergeability, typically because the base moved during the run. Acting
      # here would be a guess that can force a needless rebase or skip a cheaper
      # rerun, so defer to the next run instead.
      action="none"; reason="indeterminate mergeable_state ('${ms}'); deferring to next run" ;;
  esac

  echo "PR #${num} [${ms}] behind_by=${behind_by} age=${age_hours}h required=${required_count} -> ${action} (${reason})"

  entry=$(jq -nc \
    --argjson num "$num" \
    --arg state "$ms" \
    --arg action "$action" \
    --arg reason "$reason" \
    --argjson rids "$eligible_ids" \
    --argjson behind "$behind_by" \
    --argjson age "$age_hours" \
    '{number: $num, state: $state, action: $action, reason: $reason, run_ids: $rids, behind_by: $behind, age_hours: $age}')
  entries+=("$entry")
done < <(echo "$candidates" | jq -c '.[]')

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
