#!/bin/bash

set -eu

# Set default range if not provided (for testing)
if [[ -z "${GIT_RANGE:-}" ]]; then
    GIT_RANGE="HEAD~10..HEAD"
    echo "No GIT_RANGE provided, using default: ${GIT_RANGE}"
fi

echo "Checking for AI-authored commits in range: ${GIT_RANGE}"
echo "As per Camunda AI Policy, commits created by AI should be attributed to people and not be merged."
echo ""

# Get all commits in the range
commits=$(git rev-list "${GIT_RANGE}" 2>/dev/null || true)

if [[ -z "${commits}" ]]; then
    echo "No commits found in range ${GIT_RANGE}"
    exit 0
fi

echo "Commits to check:"
git log --oneline "${GIT_RANGE}" || true
echo ""

ai_violations=0

# Check each commit for AI patterns
for commit in ${commits}; do
    echo "Checking commit: ${commit}"

    # Get commit metadata only (not diff content)
    commit_metadata=$(git show --format=fuller --no-patch "${commit}" 2>/dev/null)

    # Skip if commit metadata couldn't be retrieved
    if [[ -z "${commit_metadata}" ]]; then
        echo "⚠️  Could not retrieve commit metadata for ${commit}, skipping"
        continue
    fi

    # Check for GitHub Copilot patterns in the commit metadata
    # Pattern detects: Copilot in author/committer fields, copilot[bot] usernames, and GitHub Copilot email addresses
    # To add more AI tools in the future, extend this regex with additional patterns like: |Pattern1|Pattern2
    if echo "${commit_metadata}" | grep -i -E "(Co-authored-by:.*[Cc]opilot|Author:.*[Cc]opilot|Committer:.*[Cc]opilot|.*copilot.*\[bot\]|.*[0-9]+\+[Cc]opilot@users\.noreply\.github\.com)" > /dev/null; then
        echo "❌ AI-authored commit detected!"
        echo "Commit: ${commit}"

        # Get commit subject safely
        commit_subject=$(git show --format="%s" -s "${commit}" 2>/dev/null || true)
        echo "Subject: ${commit_subject:-N/A}"
        echo ""
        ai_violations=$((ai_violations + 1))
    else
        echo "✓ Commit ${commit} appears to be human-authored"
    fi
done

echo ""

if [[ "${ai_violations}" -eq 0 ]]; then
    echo "✅ Success! No AI-authored commits found."
    echo "All commits appear to be properly attributed to human authors."
    exit 0
else
    echo "❌ Failure! Found ${ai_violations} AI-authored commit(s)."
    echo ""
    echo "According to Camunda's AI Policy, commits created by AI should be attributed to people and not be merged."
    echo "Please ensure that:"
    echo "1. AI-generated code is properly reviewed and attributed to human authors"
    echo "2. Commits are authored by humans, not AI tools"
    echo "3. If AI was used to assist, the human should be the commit author"
    echo ""
    echo "If you believe this is a false positive, please contact the Infrastructure team."
    exit 1
fi
