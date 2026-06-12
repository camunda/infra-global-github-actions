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
set -euo pipefail

: "${REPOSITORY:?REPOSITORY is required (owner/name)}"
: "${PLAN_FILE:?PLAN_FILE is required}"
BATCH_SIZE="${BATCH_SIZE:-10}"
DRY_RUN="${DRY_RUN:-true}"
REBASE_LABEL="${REBASE_LABEL:-rebase}"

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
    none|skip) continue ;;
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
        if gh api -X POST "repos/${REPOSITORY}/issues/${num}/labels" \
          -f "labels[]=${REBASE_LABEL}" >/dev/null 2>&1; then
          echo "PR #${num}: added '${REBASE_LABEL}' label"
        else
          echo "::warning::PR #${num}: failed to add '${REBASE_LABEL}' label"
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
          if gh api -X POST "repos/${REPOSITORY}/actions/runs/${rid}/rerun-failed-jobs" >/dev/null 2>&1; then
            echo "PR #${num}: reran failed jobs of run ${rid}"
          else
            echo "::warning::PR #${num}: failed to rerun run ${rid}"
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
