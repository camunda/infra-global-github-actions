#!/bin/bash

set -eu

# Set default range if not provided (for testing)
if [[ -z "${GIT_RANGE:-}" ]]; then
    echo "No GIT_RANGE provided"
    exit 1
fi

echo "Checking for AI-authored commits in range: ${GIT_RANGE}"
echo "As per Camunda AI Policy, commits created by AI should be attributed to people first."
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
    # Using multiple simple checks instead of one complex regex for better readability
    ai_detected=false

    # Check 1: Co-authored-by fields containing "copilot"
    if echo "${commit_metadata}" | grep -i -q "Co-authored-by:.*copilot"; then
        ai_detected=true
    fi

    # Check 2: Author fields containing "copilot"
    if echo "${commit_metadata}" | grep -i -q "Author:.*copilot"; then
        ai_detected=true
    fi

    # Check 3: Committer fields containing "copilot"
    if echo "${commit_metadata}" | grep -i -q "Committer:.*copilot"; then
        ai_detected=true
    fi

    # Check 4: Any field with "copilot" and "[bot]" (e.g., copilot-swe-agent[bot])
    if echo "${commit_metadata}" | grep -i -q "copilot.*\[bot\]"; then
        ai_detected=true
    fi

    # Check 5: GitHub Copilot specific email pattern (e.g., 198982749+Copilot@users.noreply.github.com)
    if echo "${commit_metadata}" | grep -i -E -q "[0-9]+\+copilot@users\.noreply\.github\.com"; then
        ai_detected=true
    fi

    # To add more AI tools in the future, add similar checks here:
    # if echo "${commit_metadata}" | grep -i -q "pattern-for-other-ai-tool"; then
    #     ai_detected=true
    # fi

    if [[ "${ai_detected}" == "true" ]]; then
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
    echo "According to Camunda's AI Policy, commits created by AI should be attributed to people first."
    echo "Please ensure that:"
    echo "1. AI-generated code is properly reviewed and attributed to human authors"
    echo "2. All commits are authored by humans, not AI tools, even if they are created by AI"
    exit 1
fi
