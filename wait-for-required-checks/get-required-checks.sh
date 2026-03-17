#!/usr/bin/env bash

set -euo pipefail

REPOSITORY="${REPO_OWNER}/${REPO_NAME}"

REQUIRED_CHECKS=""

# Get all rulesets (returns empty array [] if none exist).
RULESETS_RESPONSE=$(gh api "repos/${REPOSITORY}/rulesets" 2>&1) || {
  echo "Failed to fetch rulesets: $RULESETS_RESPONSE"
  echo "Proceeding without required checks validation"
  echo "checks_pattern=" >> "$GITHUB_OUTPUT"
  exit 0
}

# Check if rulesets array is empty.
RULESET_COUNT=$(echo "$RULESETS_RESPONSE" | jq '. | length' 2>/dev/null || echo "0")

if [ "$RULESET_COUNT" -eq 0 ]; then
  echo "No rulesets configured for repository"
  echo "Note: This does NOT check traditional branch protection rules; only rulesets are queried"
  echo "If branch protection rules exist, they may still be enforced by GitHub during merge"
  echo "Proceeding without required checks validation"
  echo "checks_pattern=" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Iterate through all rulesets.
for id in $(echo "$RULESETS_RESPONSE" | jq -r '.[].id'); do
  RULESET=$(gh api "repos/${REPOSITORY}/rulesets/${id}")

  # Check if this ruleset targets the base branch.
  INCLUDES=$(echo "$RULESET" | jq -r '.conditions.ref_name.include[]? // empty' || echo "")

  # Match exact branch or wildcard pattern (e.g., refs/heads/stable/8.7 or refs/heads/stable/*).
  if echo "$INCLUDES" | grep -qE "refs/heads/${BASE_BRANCH}\$|refs/heads/${BASE_BRANCH%%/*}/\*" || false; then
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
