#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# Global variables
ERROR_MESSAGES=${ERROR_MESSAGES?}
GH_REPO=${GH_REPO?}
GH_TOKEN=${GH_TOKEN?}
RELATIVE_SCRIPT_PATH=$(dirname "$0")
RUN_ID=${RUN_ID?}
ATTEMPT_GH_API_PATH="${ATTEMPT:+/attempts/$ATTEMPT}"
ATTEMPT_GH_CLI_FLAG="${ATTEMPT:+--attempt $ATTEMPT}"


# Fetch failed logs of the workflow run, i.e. with an exit status != 0

# `--exit-status` makes gh exit non-zero for any failed run, so the exit code cannot tell a
# download error apart. Retry on gh's own download error instead: swallowing it leaves the
# logs empty and silently skips the retry (e.g. "stream error: ... CANCEL" on large logs).
log_errors=$(mktemp)
trap 'rm -f "$log_errors"' EXIT
for log_attempt in 1 2 3; do
  # shellcheck disable=SC2086
  logs=$(
    gh run view "$RUN_ID" \
      ${ATTEMPT_GH_CLI_FLAG} \
      --exit-status --log-failed 2>"$log_errors" || true
  )
  cat "$log_errors" >&2
  grep -q "failed to get run log" "$log_errors" || break
  echo "Failed to download the logs (attempt ${log_attempt}/3), retrying..." >&2
  sleep $((log_attempt * 5))
done

# Fetch annotations of the workflow run (related jobs)
# Id of the WorkflowRun object is needed to fetch annotations from GitHub GraphQL API
node_id=$(
  gh api \
    "/repos/{owner}/{repo}/actions/runs/${RUN_ID}${ATTEMPT_GH_API_PATH}" \
    --jq '.node_id'
)
annotations=$(
  gh api graphql \
    --paginate \
    --field nodeId="${node_id}" \
    --field query="@$RELATIVE_SCRIPT_PATH/graphql/query_get_annotations_by_workflow_run.graphql" \
    --jq '.data.node.checkSuite.checkRuns.edges[].node.annotations.edges[] | select(.node.annotationLevel == "FAILURE").node.message'
)

# Check for error messages in logs and annotations
found=$(
  echo "$logs" "$annotations" | \
  jq -c -n -R \
    --argjson errors "${ERROR_MESSAGES}" '[inputs] | any(test($errors | join("|")))'
)

echo "${found}"
