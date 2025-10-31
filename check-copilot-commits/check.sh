#!/bin/bash

set -euo pipefail

# Check for Copilot commits in range
COPILOT_COMMITS=$(git log --grep="Co-authored-by:.*[Cc]opilot" --pretty=format:"%H" "origin/$BASE_BRANCH..origin/$BRANCH" || true)

if [ -n "$COPILOT_COMMITS" ]; then
    echo "Found Copilot co-authored commits:"
    while IFS= read -r hash; do
        echo "Hash: $hash"
        echo "URL: https://github.com/$REPOSITORY/commit/$hash"
        echo
    done <<< "$COPILOT_COMMITS"

    echo "copilot_commits_found=true" >> "$GITHUB_OUTPUT"
    {
        echo "copilot_commits_hashes<<EOF"
        echo "$COPILOT_COMMITS"
        echo "EOF"
    } >> "$GITHUB_OUTPUT"

    if [ "$FAIL_ON_COPILOT_COMMITS" = "true" ]; then
        echo "ERROR: Copilot commits not allowed"
        exit 1
    fi
else
    echo "No Copilot commits found"
    echo "copilot_commits_found=false" >> "$GITHUB_OUTPUT"
    echo "copilot_commits_hashes=" >> "$GITHUB_OUTPUT"
fi
