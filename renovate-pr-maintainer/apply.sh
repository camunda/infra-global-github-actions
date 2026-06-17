#!/usr/bin/env bash
# Apply the maintenance plan produced by classify.sh.
#
# This is the ONLY script that mutates PRs. When DRY_RUN=true it performs no
# writes and only logs what it would do. Actionable items (rebase/rerun) are
# capped at BATCH_SIZE per invocation as a blast-radius limiter.
#
# - rebase: add the Renovate rebase label; Renovate performs the actual rebase
#           on its next run (regenerating lockfiles and pushing a fresh SHA).
#           We never push commits ourselves.
# - rerun:  re-run failed jobs of the failing workflow run(s) in place
#           (increments run_attempt; no new SHA).
# - none/skip/pending: no-op (pending = a rebase is already queued on the PR and
#           awaiting Renovate, so the maintainer deliberately does nothing).
set -euo pipefail

: "${REPOSITORY:?REPOSITORY is required (owner/name)}"
: "${PLAN_FILE:?PLAN_FILE is required}"
BATCH_SIZE="${BATCH_SIZE:-10}"
DRY_RUN="${DRY_RUN:-true}"
REBASE_LABEL="${REBASE_LABEL:-rebase}"
MAX_API_RETRIES="${MAX_API_RETRIES:-3}"
API_RETRY_DELAY="${API_RETRY_DELAY:-5}"
# Thresholds/knobs surfaced in the step-summary footnote only (classify.sh owns
# the actual decisions); defaults mirror classify.sh and action.yml.
BEHIND_THRESHOLD="${BEHIND_THRESHOLD:-60}"
STALE_HOURS="${STALE_HOURS:-24}"
RERUN_BUDGET="${RERUN_BUDGET:-0}"
REQUIRE_UP_TO_DATE="${REQUIRE_UP_TO_DATE:-false}"

# gh api write (POST) with bounded retries, mirroring classify.sh's gh_api.
# Retrying is safe: re-adding the rebase label is a no-op, and a rerun whose POST
# already took effect just 4xxs on retry, so writes never double-act. Returns 0
# and prints nothing on success; on final failure prints the last gh error body
# to stdout (per-attempt warnings go to stderr) so the caller can surface it.
gh_api_write() {
  local attempt=1 out rc
  while [ "$attempt" -le "$MAX_API_RETRIES" ]; do
    set +e
    out=$(gh api "$@" 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 0 ] && return 0
    echo "::warning::gh api $* failed (attempt ${attempt}/${MAX_API_RETRIES}, exit ${rc})" >&2
    attempt=$((attempt + 1))
    [ "$attempt" -le "$MAX_API_RETRIES" ] && sleep "$API_RETRY_DELAY"
  done
  printf '%s' "$out"
  return 1
}

if [ ! -f "$PLAN_FILE" ]; then
  echo "No plan file at ${PLAN_FILE}; nothing to do."
  exit 0
fi

if [ "$DRY_RUN" = "true" ]; then
  echo "DRY-RUN enabled: no PR will be modified."
fi
echo "Batch size: ${BATCH_SIZE}"

declare -A OUTCOME
outcomes_seen=false  # set -u-safe guard: avoids expanding an empty OUTCOME on bash < 4.4
applied=0
deferred=0
while read -r item; do
  [ -z "$item" ] && continue
  action=$(echo "$item" | jq -r '.action')
  num=$(echo "$item" | jq -r '.number')

  # Non-actionable states never count against the batch and need no write; they
  # render as "—" (no action) in the summary.
  case "$action" in
    none|skip|pending) continue ;;
  esac

  # Blast-radius cap: once BATCH_SIZE actionable PRs have been processed, defer
  # the rest to the next run. We keep iterating (no break) solely to record their
  # deferred outcome for the summary — no API calls are made for these.
  if [ "$applied" -ge "$BATCH_SIZE" ]; then
    echo "Batch cap (${BATCH_SIZE}) reached; deferring PR #${num} (${action}) to the next run."
    OUTCOME[$num]="deferred"
    outcomes_seen=true
    deferred=$((deferred + 1))
    continue
  fi

  # Every item reaching here is actionable and records an OUTCOME below.
  outcomes_seen=true
  case "$action" in
    rebase)
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] PR #${num}: would add '${REBASE_LABEL}' label"
        OUTCOME[$num]="dry-run"
      else
        if err=$(gh_api_write -X POST "repos/${REPOSITORY}/issues/${num}/labels" \
          -f "labels[]=${REBASE_LABEL}"); then
          echo "PR #${num}: added '${REBASE_LABEL}' label"
          OUTCOME[$num]="applied"
        else
          echo "::warning::PR #${num}: failed to add '${REBASE_LABEL}' label: ${err}"
          OUTCOME[$num]="failed"
        fi
      fi
      applied=$((applied + 1))
      ;;
    rerun)
      mapfile -t rids < <(echo "$item" | jq -r '.run_ids[]')
      rerun_failed=false
      for rid in "${rids[@]}"; do
        [ -z "$rid" ] && continue
        if [ "$DRY_RUN" = "true" ]; then
          echo "[dry-run] PR #${num}: would rerun failed jobs of run ${rid}"
        else
          if err=$(gh_api_write -X POST "repos/${REPOSITORY}/actions/runs/${rid}/rerun-failed-jobs"); then
            echo "PR #${num}: reran failed jobs of run ${rid}"
          else
            echo "::warning::PR #${num}: failed to rerun run ${rid}: ${err}"
            rerun_failed=true
          fi
        fi
      done
      if [ "$DRY_RUN" = "true" ]; then
        OUTCOME[$num]="dry-run"
      elif [ "$rerun_failed" = "true" ]; then
        OUTCOME[$num]="failed"
      else
        OUTCOME[$num]="applied"
      fi
      applied=$((applied + 1))
      ;;
    *)
      # Defensive: classify.sh only emits none/skip/pending/rebase/rerun, so this
      # is unreachable in practice. Report it as `failed` (we could not act on it)
      # to keep the summary's applied? values within the documented set; the
      # warning above carries the detail.
      echo "::warning::PR #${num}: unknown action '${action}', skipping"
      OUTCOME[$num]="failed"
      ;;
  esac
done < <(jq -c '.[]' "$PLAN_FILE")

echo "Actionable PRs processed this run: ${applied} (deferred by batch cap: ${deferred})"

# Human-readable step summary: the classify plan plus what THIS run actually did.
# Rendered here (not in classify.sh) because each PR's applied/deferred outcome is
# only known after the batch-capped loop above.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # Build links from the runner's GitHub context (with sensible fallbacks) so they
  # are correct on GitHub Enterprise Server and the README link points at the
  # action version actually running, not always main. These are default runner
  # env vars; the fallbacks cover local-path usage where they may be unset.
  server_url="${GITHUB_SERVER_URL:-https://github.com}"
  action_repo="${GITHUB_ACTION_REPOSITORY:-camunda/infra-global-github-actions}"
  action_ref="${GITHUB_ACTION_REF:-main}"
  readme_url="${server_url}/${action_repo}/blob/${action_ref}/renovate-pr-maintainer/README.md#decision-model"

  # Fold the per-PR OUTCOME map into a JSON object so jq can join it onto the plan.
  outcomes_json='{}'
  if [ "$outcomes_seen" = "true" ]; then
    outcomes_json=$(
      for k in "${!OUTCOME[@]}"; do
        jq -nc --arg k "$k" --arg v "${OUTCOME[$k]}" '{($k): $v}'
      done | jq -sc 'add'
    )
  fi

  {
    echo "### Renovate PR maintainer — plan"
    echo ""
    echo "| PR | state | behind_by | head age (h) | action | applied?\\* | reason |"
    echo "|---:|:------|----------:|-------------:|:-------|:----------|:-------|"
    jq -r --arg server "$server_url" --arg repo "$REPOSITORY" --argjson outcomes "$outcomes_json" '
      .[]
      | ($outcomes[(.number | tostring)] // "—") as $applied
      | "| [#\(.number)](\($server)/\($repo)/pull/\(.number)) | \(.state) | \(.behind_by) | \(.age_hours) | \(.action) | \($applied) | \(.reason) |"
    ' "$PLAN_FILE"
    echo ""
    # Backticks here are literal Markdown code spans, so the single-quoted format
    # is intentional (values are injected via the %s positional args).
    # shellcheck disable=SC2016
    printf '\\* **applied?** = this run'"'"'s outcome: `applied`, `dry-run`, `failed`, `deferred` (over the `batch-size`=%s cap, retried next run), or `—` (no action needed).\n\n**state** = GitHub'"'"'s `mergeable_state`: `clean`/`has_hooks` green · `blocked` a **required** check failing/pending · `unstable` only **non-required** failing · `dirty` merge conflict · `behind` head behind base · `unknown` not yet computed · `rebase-labeled` rebase already queued.\n\n**Decision:** **rebase** when stale — ≥ %s commits behind base or head ≥ %sh old — or immediately if behind base and `require-up-to-date`=true (currently %s); otherwise **re-run** failing required checks within `rerun-budget`=%s. Full [decision model](%s).\n' \
      "$BATCH_SIZE" "$BEHIND_THRESHOLD" "$STALE_HOURS" "$REQUIRE_UP_TO_DATE" "$RERUN_BUDGET" "$readme_url"
  } >> "$GITHUB_STEP_SUMMARY"
fi
