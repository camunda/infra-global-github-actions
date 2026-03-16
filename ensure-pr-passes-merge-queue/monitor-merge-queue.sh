#!/usr/bin/env bash

set -euo pipefail

if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY RUN] Monitoring merge queue status (read-only) for PR #${PR_NUMBER}"
else
  echo "Monitoring merge queue status..."
fi

MAX_ATTEMPTS=$((TIMEOUT_MINUTES / 2)) # Check every 2 minutes
ATTEMPT=0
EVICTION_COUNT=0
PREVIOUS_QUEUE_STATE=""
API_FAILURE_COUNT=0
MAX_CONSECUTIVE_API_FAILURES=5 # 5 failures x 2 minutes = 10 minutes

echo "Timeout configured: ${TIMEOUT_MINUTES} minutes (${MAX_ATTEMPTS} attempts)"

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  # Query PR and merge queue status via GraphQL.
  # shellcheck disable=SC2016
  PR_DATA=$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          state
          autoMergeRequest { enabledAt }
          mergeStateStatus
          mergeQueueEntry {
            state
            position
          }
        }
      }
    }' -f owner="$REPO_OWNER" -f repo="$REPO_NAME" -F number="$PR_NUMBER")

  # Validate API response and parse PR state.
  if ! PR_STATE=$(echo "$PR_DATA" | jq -e -r '.data.repository.pullRequest.state' 2>/dev/null); then
    API_FAILURE_COUNT=$((API_FAILURE_COUNT + 1))
    echo "API call failed (${API_FAILURE_COUNT}/${MAX_CONSECUTIVE_API_FAILURES})"

    if [ $API_FAILURE_COUNT -ge $MAX_CONSECUTIVE_API_FAILURES ]; then
      echo "API calls failed ${MAX_CONSECUTIVE_API_FAILURES} times consecutively (10 minutes) - aborting"
      echo "result=timeout" >> "$GITHUB_OUTPUT"
      exit 1
    fi

    ATTEMPT=$((ATTEMPT + 1))
    sleep 120
    continue
  fi

  # API call succeeded - reset failure counter.
  API_FAILURE_COUNT=0

  AUTO_MERGE=$(echo "$PR_DATA" | jq -r '.data.repository.pullRequest.autoMergeRequest')
  MERGE_STATUS=$(echo "$PR_DATA" | jq -r '.data.repository.pullRequest.mergeStateStatus')
  QUEUE_STATE=$(echo "$PR_DATA" | jq -r '.data.repository.pullRequest.mergeQueueEntry.state // "NOT_IN_QUEUE"')
  QUEUE_POSITION=$(echo "$PR_DATA" | jq -r '.data.repository.pullRequest.mergeQueueEntry.position // "N/A"')

  AUTO_MERGE_STATUS="disabled"
  if [ "$AUTO_MERGE" != "null" ]; then
    AUTO_MERGE_STATUS="enabled"
  fi
  echo "Attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS - State: $PR_STATE, Queue: $QUEUE_STATE (pos: $QUEUE_POSITION), Merge Status: $MERGE_STATUS, Auto-merge: $AUTO_MERGE_STATUS"

  if [ "$PR_STATE" = "MERGED" ]; then
    echo "PR merged successfully via merge queue"
    echo "result=merged" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  if [ "$PR_STATE" = "CLOSED" ]; then
    echo "PR was closed without merging"
    echo "result=closed" >> "$GITHUB_OUTPUT"
    exit 1
  fi

  if [ "$QUEUE_STATE" = "AWAITING_CHECKS" ] || [ "$QUEUE_STATE" = "QUEUED" ]; then
    echo "Waiting for checks to complete..."
    PREVIOUS_QUEUE_STATE="$QUEUE_STATE"
    ATTEMPT=$((ATTEMPT + 1))
    sleep 120
    continue
  fi

  # Detect eviction: was in queue, now NOT_IN_QUEUE (and PR still open).
  if [ "$QUEUE_STATE" = "NOT_IN_QUEUE" ] && [ "$PR_STATE" = "OPEN" ] && [ -n "$PREVIOUS_QUEUE_STATE" ] && [ "$PREVIOUS_QUEUE_STATE" != "NOT_IN_QUEUE" ]; then
    EVICTION_COUNT=$((EVICTION_COUNT + 1))
    echo "PR evicted from merge queue (attempt $EVICTION_COUNT/$MAX_EVICTIONS)"

    if [ $EVICTION_COUNT -ge $MAX_EVICTIONS ]; then
      echo "PR evicted $MAX_EVICTIONS times - giving up"
      echo "result=evicted" >> "$GITHUB_OUTPUT"
      exit 1
    fi

    if [ "$DRY_RUN" = "true" ]; then
      echo "[DRY RUN] Would re-enable auto-merge after eviction"
    else
      echo "Re-enabling auto-merge..."
      # Use the GitHub App token for auto-merge re-enable.
      gh pr merge "$PR_NUMBER" --auto --squash
      echo "Auto-merge re-enabled - PR sent back to merge queue"
    fi
  fi

  PREVIOUS_QUEUE_STATE="$QUEUE_STATE"
  ATTEMPT=$((ATTEMPT + 1))
  sleep 120
done

echo "Timeout waiting for merge (${TIMEOUT_MINUTES} minutes) - manual intervention required"
echo "result=timeout" >> "$GITHUB_OUTPUT"
exit 1
