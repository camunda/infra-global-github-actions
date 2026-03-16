#!/usr/bin/env bash

set -euo pipefail

MAX_WAIT=$((TIMEOUT_MINUTES * 60))
ELAPSED=0
MAX_API_RETRIES=3
API_RETRY_DELAY=5

IFS='|' read -ra REQUIRED_CHECKS <<< "$CHECKS_PATTERN"
echo "Waiting for required checks: ${REQUIRED_CHECKS[*]}"
echo "Timeout: ${TIMEOUT_MINUTES}m, poll interval: ${POLL_INTERVAL}s"
echo ""

while [ $ELAPSED -lt $MAX_WAIT ]; do
  # Fetch check runs with retry logic for transient API/parse failures.
  API_ATTEMPT=1
  API_SUCCESS=false
  while [ $API_ATTEMPT -le $MAX_API_RETRIES ]; do
    set +e
    RUNS_RAW=$(gh api "repos/${REPOSITORY}/commits/${SHA}/check-runs?filter=all&per_page=100" \
      --paginate --jq '.check_runs[] | {name: .name, id: .id, status: .status, conclusion: .conclusion}' 2>&1)
    GH_STATUS=$?
    set -e
    if [ $GH_STATUS -ne 0 ]; then
      echo "gh api failed (attempt $API_ATTEMPT/$MAX_API_RETRIES, exit $GH_STATUS)"
      API_ATTEMPT=$((API_ATTEMPT + 1))
      sleep "$API_RETRY_DELAY"
      continue
    fi

    set +e
    RUNS_JSON=$(printf '%s\n' "$RUNS_RAW" | jq -s '.' 2>&1)
    JQ_STATUS=$?
    set -e
    if [ $JQ_STATUS -ne 0 ]; then
      echo "jq parse failed (attempt $API_ATTEMPT/$MAX_API_RETRIES, exit $JQ_STATUS)"
      API_ATTEMPT=$((API_ATTEMPT + 1))
      sleep "$API_RETRY_DELAY"
      continue
    fi

    API_SUCCESS=true
    break
  done

  if [ "$API_SUCCESS" != "true" ]; then
    echo "Failed to fetch check runs after $MAX_API_RETRIES attempts, will retry next poll"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
    if [ $ELAPSED -ge $MAX_WAIT ]; then
      echo ""
      echo "Timed out waiting for checks after ${TIMEOUT_MINUTES} minutes"
      exit 1
    fi
    echo "--- Waiting ${POLL_INTERVAL}s (${ELAPSED}s/${MAX_WAIT}s) ---"
    sleep "$POLL_INTERVAL"
    continue
  fi

  ALL_PASSED=true
  for CHECK in "${REQUIRED_CHECKS[@]}"; do
    # Pick the latest run for this check name.
    LATEST=$(echo "$RUNS_JSON" | jq -r --arg name "$CHECK" \
      '[.[] | select(.name == $name)] | sort_by(.id) | last // empty')

    if [ -z "$LATEST" ] || [ "$LATEST" = "null" ]; then
      echo "[$CHECK] not yet registered"
      ALL_PASSED=false
      continue
    fi

    STATUS=$(echo "$LATEST" | jq -r '.status')
    CONCLUSION=$(echo "$LATEST" | jq -r '.conclusion // "pending"')

    if [ "$STATUS" != "completed" ]; then
      echo "[$CHECK] $STATUS"
      ALL_PASSED=false
    elif [ "$CONCLUSION" = "success" ]; then
      echo "[$CHECK] passed"
    else
      echo "[$CHECK] failed (conclusion: $CONCLUSION)"
      exit 1
    fi
  done

  if [ "$ALL_PASSED" = true ]; then
    echo ""
    echo "All required checks passed"
    echo "result=success" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  ELAPSED=$((ELAPSED + POLL_INTERVAL))
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo ""
    echo "Timed out waiting for checks after ${TIMEOUT_MINUTES} minutes"
    exit 1
  fi
  echo "--- Waiting ${POLL_INTERVAL}s (${ELAPSED}s/${MAX_WAIT}s) ---"
  sleep "$POLL_INTERVAL"
done
