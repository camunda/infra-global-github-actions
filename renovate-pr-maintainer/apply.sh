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

# gh api write (POST ...) with bounded retries on transient failures, mirroring
# classify.sh's gh_api. Retrying a write here is safe: re-adding the rebase label
# is a no-op, and a rerun whose first POST already took effect just gets a 4xx on
# retry (the run is no longer "completed"), so retries never double-act. On
# success returns 0 and prints nothing; on final failure prints the last gh error
# body to stdout and returns 1 so the caller can surface the reason. Per-attempt
# failures are logged to stderr.
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

applied=0
while read -r item; do
  [ -z "$item" ] && continue
  action=$(echo "$item" | jq -r '.action')
  num=$(echo "$item" | jq -r '.number')

  case "$action" in
    none|skip|pending) continue ;;
  esac

  if [ "$applied" -ge "$BATCH_SIZE" ]; then
    echo "Batch cap (${BATCH_SIZE}) reached; deferring remaining actions to the next run."
    break
  fi

  case "$action" in
    rebase)
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] PR #${num}: would add '${REBASE_LABEL}' label"
      else
        if err=$(gh_api_write -X POST "repos/${REPOSITORY}/issues/${num}/labels" \
          -f "labels[]=${REBASE_LABEL}"); then
          echo "PR #${num}: added '${REBASE_LABEL}' label"
        else
          echo "::warning::PR #${num}: failed to add '${REBASE_LABEL}' label: ${err}"
        fi
      fi
      applied=$((applied + 1))
      ;;
    rerun)
      mapfile -t rids < <(echo "$item" | jq -r '.run_ids[]')
      for rid in "${rids[@]}"; do
        [ -z "$rid" ] && continue
        if [ "$DRY_RUN" = "true" ]; then
          echo "[dry-run] PR #${num}: would rerun failed jobs of run ${rid}"
        else
          if err=$(gh_api_write -X POST "repos/${REPOSITORY}/actions/runs/${rid}/rerun-failed-jobs"); then
            echo "PR #${num}: reran failed jobs of run ${rid}"
          else
            echo "::warning::PR #${num}: failed to rerun run ${rid}: ${err}"
          fi
        fi
      done
      applied=$((applied + 1))
      ;;
    *)
      echo "::warning::PR #${num}: unknown action '${action}', skipping"
      ;;
  esac
done < <(jq -c '.[]' "$PLAN_FILE")

echo "Actionable PRs processed this run: ${applied}"
