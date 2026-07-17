#!/usr/bin/env bash

set -euo pipefail

# Authentication modes:
# - GH_APP_ID + GH_APP_PRIVATE_KEY set: the script mints GitHub App installation
#   tokens itself and re-mints them before they hit the 1-hour expiry, so runs
#   longer than an hour keep working.
# - GH_TOKEN set (pre-minted installation token): used as-is; such tokens expire
#   after 1 hour, so timeouts beyond ~50 minutes are unreliable in this mode.
if [ -n "${GH_APP_ID:-}" ] || [ -n "${GH_APP_PRIVATE_KEY:-}" ]; then
  if [ -z "${GH_APP_ID:-}" ] || [ -z "${GH_APP_PRIVATE_KEY:-}" ]; then
    echo "Both app-id and private-key must be provided to enable self-minted tokens."
    exit 1
  fi
elif [ -z "${GH_TOKEN:-}" ]; then
  echo "Either app-token or the app-id + private-key pair must be provided."
  exit 1
fi

if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY RUN] Monitoring merge queue status (read-only) for PR #${PR_NUMBER}"
else
  echo "Monitoring merge queue status for PR #${PR_NUMBER}"
fi

MAX_ATTEMPTS=$(((TIMEOUT_MINUTES + 1) / 2)) # Check every 2 minutes (ceiling division)
ATTEMPT=0
EVICTION_COUNT=0
PREVIOUS_QUEUE_STATE=""
API_FAILURE_COUNT=0
MAX_CONSECUTIVE_API_FAILURES=5 # 5 failures x 2 minutes = 10 minutes
REPOSITORY="${REPO_OWNER}/${REPO_NAME}"
API_URL="${GITHUB_API_URL:-https://api.github.com}"
TOKEN_MINTED_AT=0
TOKEN_REFRESH_SECONDS=3000 # Installation tokens expire after 60 minutes; re-mint at 50.
LAST_QUEUE_STATE=""
LAST_QUEUE_POSITION=""
LAST_MERGE_STATUS=""
MERGE_ARGS=(--auto)

case "$MERGE_METHOD" in
  squash)
    MERGE_ARGS+=(--squash)
    ;;
  merge)
    MERGE_ARGS+=(--merge)
    ;;
  rebase)
    MERGE_ARGS+=(--rebase)
    ;;
  default)
    ;;
  *)
    echo "Invalid merge method: '$MERGE_METHOD'. Allowed values: squash, merge, rebase, default."
    exit 1
    ;;
esac

base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

mint_installation_token() {
  local now header payload signature jwt installation_id token
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | base64url) || return 1
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$GH_APP_ID" | base64url) || return 1
  signature=$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -sign <(printf '%s' "$GH_APP_PRIVATE_KEY") -binary | base64url) || return 1
  jwt="${header}.${payload}.${signature}"
  echo "::add-mask::${jwt}"

  installation_id=$(curl -sSf \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "${API_URL}/repos/${REPOSITORY}/installation" | jq -r '.id // empty') || return 1
  if [ -z "$installation_id" ]; then
    echo "Could not resolve the GitHub App installation for ${REPOSITORY}."
    return 1
  fi

  token=$(curl -sSf -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "${API_URL}/app/installations/${installation_id}/access_tokens" | jq -r '.token // empty') || return 1
  if [ -z "$token" ]; then
    echo "Could not mint an installation token for installation ${installation_id}."
    return 1
  fi

  echo "::add-mask::${token}"
  export GH_TOKEN="$token"
  TOKEN_MINTED_AT=$now
  echo "Minted a fresh GitHub App installation token (installation ${installation_id})"
}

ensure_fresh_token() {
  [ -n "${GH_APP_ID:-}" ] || return 0
  local age
  age=$(($(date +%s) - TOKEN_MINTED_AT))
  if [ "$age" -ge "$TOKEN_REFRESH_SECONDS" ]; then
    mint_installation_token || echo "Token mint failed; continuing with the current token."
  fi
}

write_outputs() {
  {
    echo "result=$1"
    echo "queue-state=${LAST_QUEUE_STATE:-UNKNOWN}"
    echo "queue-position=${LAST_QUEUE_POSITION:-N/A}"
    echo "merge-state-status=${LAST_MERGE_STATUS:-UNKNOWN}"
  } >> "$GITHUB_OUTPUT"
}

query_pr_state() {
  # shellcheck disable=SC2016
  gh api graphql -f query='
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
    }' -f owner="$REPO_OWNER" -f repo="$REPO_NAME" -F number="$PR_NUMBER"
}

# Emits a non-merged result unless a final fresh-token recheck finds the PR
# merged (the merge can land between the last poll and the conclusion).
conclude_not_merged() {
  local result=$1 final_state
  ensure_fresh_token
  final_state=$(query_pr_state 2>/dev/null | jq -r '.data.repository.pullRequest.state' 2>/dev/null) || final_state=""
  if [ "$final_state" = "MERGED" ]; then
    echo "Final recheck: PR was merged after all"
    write_outputs "merged"
    exit 0
  fi
  write_outputs "$result"
  exit 1
}

echo "Timeout configured: ${TIMEOUT_MINUTES} minutes (${MAX_ATTEMPTS} attempts)"

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  ensure_fresh_token

  # Query PR and merge queue status via GraphQL.
  set +e
  PR_DATA=$(query_pr_state 2>&1)
  GH_STATUS=$?
  set -e

  if [ $GH_STATUS -ne 0 ] || ! PR_STATE=$(echo "$PR_DATA" | jq -e -r '.data.repository.pullRequest.state' 2>/dev/null); then
    API_FAILURE_COUNT=$((API_FAILURE_COUNT + 1))
    echo "API call failed (${API_FAILURE_COUNT}/${MAX_CONSECUTIVE_API_FAILURES}): $PR_DATA"

    # A 401 means the installation token expired or was revoked; re-mint right
    # away when app credentials are available (retried next attempt on failure).
    if [ -n "${GH_APP_ID:-}" ] && echo "$PR_DATA" | grep -q "HTTP 401"; then
      echo "Token looks expired - re-minting"
      TOKEN_MINTED_AT=0
      mint_installation_token || echo "Token mint failed; will retry on the next attempt."
    fi

    if [ $API_FAILURE_COUNT -ge $MAX_CONSECUTIVE_API_FAILURES ]; then
      echo "API calls failed ${MAX_CONSECUTIVE_API_FAILURES} times consecutively (10 minutes) - aborting"
      conclude_not_merged "api_failure"
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
  LAST_QUEUE_STATE="$QUEUE_STATE"
  LAST_QUEUE_POSITION="$QUEUE_POSITION"
  LAST_MERGE_STATUS="$MERGE_STATUS"

  AUTO_MERGE_STATUS="disabled"
  if [ "$AUTO_MERGE" != "null" ]; then
    AUTO_MERGE_STATUS="enabled"
  fi
  echo "Attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS - State: $PR_STATE, Queue: $QUEUE_STATE (pos: $QUEUE_POSITION), Merge Status: $MERGE_STATUS, Auto-merge: $AUTO_MERGE_STATUS"

  if [ "$PR_STATE" = "MERGED" ]; then
    echo "PR merged successfully via merge queue"
    write_outputs "merged"
    exit 0
  fi

  if [ "$PR_STATE" = "CLOSED" ]; then
    echo "PR was closed without merging"
    conclude_not_merged "closed"
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

    if [ $EVICTION_COUNT -ge "$MAX_EVICTIONS" ]; then
      echo "PR evicted $MAX_EVICTIONS times - giving up"
      conclude_not_merged "evicted"
    fi

    if [ "$DRY_RUN" = "true" ]; then
      echo "[DRY RUN] Would re-enable auto-merge after eviction"
    else
      echo "Re-enabling auto-merge (method: ${MERGE_METHOD})..."
      # Use the GitHub App token for auto-merge re-enable.
      if ! gh pr merge "$PR_NUMBER" -R "$REPOSITORY" "${MERGE_ARGS[@]}"; then
        echo "Failed to enable auto-merge for PR #${PR_NUMBER} in ${REPOSITORY}"
        echo "Check that the GitHub App is installed on ${REPOSITORY} and has Pull requests: Write permission."
        conclude_not_merged "api_failure"
      fi
      echo "Auto-merge re-enabled - PR sent back to merge queue"
    fi
  fi

  PREVIOUS_QUEUE_STATE="$QUEUE_STATE"
  ATTEMPT=$((ATTEMPT + 1))
  sleep 120
done

echo "Timeout waiting for merge (${TIMEOUT_MINUTES} minutes) - manual intervention required"
conclude_not_merged "timeout"
