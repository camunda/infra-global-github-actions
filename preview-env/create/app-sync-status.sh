#!/bin/bash

## app-sync-status.sh
##
## The script waits for an ArgoCD app to be synced and reports the results back

set -o errexit
set -o nounset
set -o pipefail

# ensure TIMEOUT is set and not empty
: "${TIMEOUT:?argocd_wait_for_sync_timeout variable is required but not set}"

# ensure TIMEOUT is a valid positive integer
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "Error: argocd_wait_for_sync_timeout must be a non-negative integer. Got: '$TIMEOUT'"
  exit 1
fi

INTERVAL=30   # interval between retries in seconds
ELAPSED=0

echo "::group::wait for sync"

while [ "$ELAPSED" -le "$TIMEOUT" ]; do
    ARGOCD_APP_STATUS=$(argocd app get "$APP_NAME" -o json | jq -r '.status.health.status')
    echo "Current status: $ARGOCD_APP_STATUS"

    if [ "$ARGOCD_APP_STATUS" == "Healthy" ]; then
        echo "App is healthy."
        break
    fi

    echo "App is not healthy yet. Retrying in $INTERVAL seconds..."
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    echo "Elapsed time is $ELAPSED seconds."
done

echo "::endgroup::"

if [ "$ARGOCD_APP_STATUS" == "Healthy" ]; then
    echo "Application reached healthy state."
    exit 0
else
    echo "Timeout reached. The application did not become healthy. Collecting troubleshooting information."
    ARGOCD_APP_DETAILS=$(cat <<EOF
ArgoCD App details
------------------
App health: $(argocd app get "$APP_NAME" -o json | jq -r '.status.health.status')
App sync: $(argocd app get "$APP_NAME" -o json | jq -r '.status.sync.status')
App conditions: $(argocd app get "$APP_NAME" -o json | jq -r '.status.conditions')
State of the latest operation phase: $(argocd app get "$APP_NAME" -o json | jq -r '.status.operationState.phase')
Message from the latest operation phase: $(argocd app get "$APP_NAME" -o json | jq -r '.status.operationState.message')
Sync results:
$(argocd app get "$APP_NAME" -o json | jq '.status.operationState.syncResult[]')
EOF
    )
    # shellcheck disable=SC2129
    echo "argocd_app_details<<EOF" >> "$GITHUB_OUTPUT"
    echo "$ARGOCD_APP_DETAILS" >> "$GITHUB_OUTPUT"
    echo "EOF" >> "$GITHUB_OUTPUT"
    exit 1
fi
