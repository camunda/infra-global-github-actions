#!/usr/bin/env bash

set -euo pipefail

REPOSITORY="${REPO_OWNER}/${REPO_NAME}"

REQUIRED_CHECKS=""
MAX_API_RETRIES=3
API_RETRY_DELAY=5

# Get all ruleset IDs with pagination.
RULESET_IDS=""
API_ATTEMPT=1
API_SUCCESS=false
while [ $API_ATTEMPT -le $MAX_API_RETRIES ]; do
  set +e
  RULESET_IDS=$(gh api "repos/${REPOSITORY}/rulesets?per_page=100" --paginate --jq '.[].id' 2>&1)
  GH_STATUS=$?
  set -e

  if [ $GH_STATUS -eq 0 ]; then
    API_SUCCESS=true
    break
  fi

  echo "Failed to fetch rulesets (attempt $API_ATTEMPT/$MAX_API_RETRIES, exit $GH_STATUS): $RULESET_IDS"
  API_ATTEMPT=$((API_ATTEMPT + 1))
  [ $API_ATTEMPT -le $MAX_API_RETRIES ] && sleep "$API_RETRY_DELAY"
done

if [ "$API_SUCCESS" != "true" ]; then
  echo "Failed to fetch rulesets after $MAX_API_RETRIES attempts"
  echo "Proceeding without required checks validation"
  echo "checks_pattern=" >> "$GITHUB_OUTPUT"
  exit 0
fi

if [ -z "$RULESET_IDS" ]; then
  echo "No rulesets configured for repository"
  echo "Note: This does NOT check traditional branch protection rules; only rulesets are queried"
  echo "If branch protection rules exist, they may still be enforced by GitHub during merge"
  echo "Proceeding without required checks validation"
  echo "checks_pattern=" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Iterate through all rulesets.
for id in $RULESET_IDS; do
  RULESET=""
  API_ATTEMPT=1
  API_SUCCESS=false
  while [ $API_ATTEMPT -le $MAX_API_RETRIES ]; do
    set +e
    RULESET=$(gh api "repos/${REPOSITORY}/rulesets/${id}" 2>&1)
    GH_STATUS=$?
    set -e

    if [ $GH_STATUS -eq 0 ]; then
      API_SUCCESS=true
      break
    fi

    echo "Failed to fetch ruleset ${id} (attempt $API_ATTEMPT/$MAX_API_RETRIES, exit $GH_STATUS): $RULESET"
    API_ATTEMPT=$((API_ATTEMPT + 1))
    [ $API_ATTEMPT -le $MAX_API_RETRIES ] && sleep "$API_RETRY_DELAY"
  done

  if [ "$API_SUCCESS" != "true" ]; then
    echo "Skipping ruleset ${id} after $MAX_API_RETRIES failed attempts"
    continue
  fi

  # Check if this ruleset targets the base branch.
  INCLUDES=$(echo "$RULESET" | jq -r '.conditions.ref_name.include[]? // empty' || echo "")
  TARGET_REF="refs/heads/${BASE_BRANCH}"
  MATCHES_BASE_BRANCH=false

  # Use glob-style matching to avoid regex injection and support wildcard patterns
  # such as refs/heads/*.
  while IFS= read -r include; do
    [ -z "$include" ] && continue
    # shellcheck disable=SC2254
    case "$TARGET_REF" in
      $include)
        MATCHES_BASE_BRANCH=true
        break
        ;;
    esac
  done <<< "$INCLUDES"

  if [ "$MATCHES_BASE_BRANCH" = true ]; then
    # Extract required status checks from this ruleset, preserving full check names.
    while IFS= read -r check; do
      [ -n "$check" ] && REQUIRED_CHECKS="${REQUIRED_CHECKS}${check}"$'\n'
    done < <(echo "$RULESET" | jq -r '.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' || echo "")
  fi
done

# Remove duplicates and format as pipe-delimited pattern.
CHECKS_PATTERN=$(echo "$REQUIRED_CHECKS" | sort -u | grep -v '^$' | paste -sd '|' - || true)

if [ -z "$CHECKS_PATTERN" ]; then
  echo "No required checks found in rulesets for branch: $BASE_BRANCH"
  echo "checks_pattern=" >> "$GITHUB_OUTPUT"
else
  echo "Required checks for $BASE_BRANCH: $CHECKS_PATTERN"
  echo "checks_pattern=$CHECKS_PATTERN" >> "$GITHUB_OUTPUT"
fi
