#!/bin/bash

set -euo pipefail

# Check for Copilot authored commits (always checked)
COPILOT_AUTHOR_COMMITS=$(git log --author=".*[Cc]opilot.*" --pretty=format:"%H" "origin/$BASE_BRANCH..origin/$BRANCH" || true)

# Check for co-authored commits only if requested
if [ "$CHECK_CO_AUTHOR" = "true" ]; then
    COPILOT_COAUTHOR_COMMITS=$(git log --grep="Co-authored-by:.*[Cc]opilot" --pretty=format:"%H" "origin/$BASE_BRANCH..origin/$BRANCH" || true)
    # Combine and deduplicate
    COPILOT_COMMITS=$(echo -e "$COPILOT_AUTHOR_COMMITS\n$COPILOT_COAUTHOR_COMMITS" | grep -v '^$' | sort | uniq || true)
else
    COPILOT_COMMITS="$COPILOT_AUTHOR_COMMITS"
fi

if [ -n "$COPILOT_COMMITS" ]; then
    echo "Found Copilot (co-)authored commits:"
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
else
    echo "No Copilot commits found"
    echo "copilot_commits_found=false" >> "$GITHUB_OUTPUT"
    echo "copilot_commits_hashes=" >> "$GITHUB_OUTPUT"
fi
