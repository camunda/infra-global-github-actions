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

# shellcheck disable=SC2086
logs=$(
  gh run view "$RUN_ID" \
    ${ATTEMPT_GH_CLI_FLAG} \
    --exit-status --log-failed || true
)

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
