#!/bin/bash

set -eu

# Common AI-related patterns to detect in commit messages, author names, and co-authored-by trailers
# These patterns are designed to catch various AI tools including GitHub Copilot, ChatGPT, and others
AI_PATTERNS=(
    "Co-authored-by:.*GitHub Copilot"
    "Co-authored-by:.*Copilot"
    "Co-authored-by:.*ChatGPT"
    "Co-authored-by:.*OpenAI"
    "Co-authored-by:.*Claude"
    "Co-authored-by:.*GPT"
    "Co-authored-by:.*AI Assistant"
    "Co-authored-by:.*artificial intelligence"
    "Co-authored-by:.*bot@"
    "Co-authored-by:.*ai@"
    "Co-authored-by:.*copilot@"
    "Co-authored-by:.*gpt@"
    "Author:.*GitHub Copilot"
    "Author:.*Copilot"
    "Author:.*ChatGPT"
    "Author:.*OpenAI"
    "Author:.*Claude"
    "Author:.*GPT"
    "Author:.*AI Assistant"
    "Committer:.*GitHub Copilot"
    "Committer:.*Copilot"
    "Committer:.*ChatGPT"
    "Committer:.*OpenAI"
    "Committer:.*Claude"
    "Committer:.*GPT"
    "Committer:.*AI Assistant"
)

# Function to check if a commit contains AI patterns
check_commit_for_ai() {
    local commit_hash="$1"
    local commit_info
    
    # Get full commit information including author, committer, and full message
    commit_info=$(git show --format=fuller "$commit_hash" 2>/dev/null || return 0)
    
    # Check against each AI pattern
    for pattern in "${AI_PATTERNS[@]}"; do
        if echo "$commit_info" | grep -i -q "$pattern"; then
            echo "AI pattern detected: $pattern"
            echo "Commit: $commit_hash"
            echo "Commit message:"
            git show --format="%s%n%b" -s "$commit_hash" | head -10
            echo ""
            return 1
        fi
    done
    
    return 0
}

# Function to check author and committer names/emails for AI patterns
check_author_committer_for_ai() {
    local commit_hash="$1"
    local author_name author_email committer_name committer_email
    
    author_name=$(git show --format="%an" -s "$commit_hash" 2>/dev/null || echo "")
    author_email=$(git show --format="%ae" -s "$commit_hash" 2>/dev/null || echo "")
    committer_name=$(git show --format="%cn" -s "$commit_hash" 2>/dev/null || echo "")
    committer_email=$(git show --format="%ce" -s "$commit_hash" 2>/dev/null || echo "")
    
    # Check for AI-related patterns in names and emails
    local ai_name_patterns=("copilot" "gpt" "chatgpt" "openai" "claude" "ai.assistant" "github.copilot" "artificial.intelligence" "ai-assistant")
    local ai_email_patterns=("copilot@" "gpt@" "ai@" "chatgpt@" "openai@" "claude@" "bot@.*ai" "noreply@.*copilot" "assistant@")
    
    # Check author name
    for pattern in "${ai_name_patterns[@]}"; do
        if echo "$author_name" | grep -i -q "$pattern"; then
            echo "AI author name detected: $author_name (pattern: $pattern)"
            echo "Commit: $commit_hash"
            echo "Subject: $(git show --format="%s" -s "$commit_hash" 2>/dev/null || echo "N/A")"
            return 1
        fi
    done
    
    # Check author email
    for pattern in "${ai_email_patterns[@]}"; do
        if echo "$author_email" | grep -i -q "$pattern"; then
            echo "AI author email detected: $author_email (pattern: $pattern)"
            echo "Commit: $commit_hash"
            echo "Subject: $(git show --format="%s" -s "$commit_hash" 2>/dev/null || echo "N/A")"
            return 1
        fi
    done
    
    # Check committer name
    for pattern in "${ai_name_patterns[@]}"; do
        if echo "$committer_name" | grep -i -q "$pattern"; then
            echo "AI committer name detected: $committer_name (pattern: $pattern)"
            echo "Commit: $commit_hash"
            echo "Subject: $(git show --format="%s" -s "$commit_hash" 2>/dev/null || echo "N/A")"
            return 1
        fi
    done
    
    # Check committer email
    for pattern in "${ai_email_patterns[@]}"; do
        if echo "$committer_email" | grep -i -q "$pattern"; then
            echo "AI committer email detected: $committer_email (pattern: $pattern)"
            echo "Commit: $commit_hash"
            echo "Subject: $(git show --format="%s" -s "$commit_hash" 2>/dev/null || echo "N/A")"
            return 1
        fi
    done
    
    return 0
}

# Set default range if not provided (for testing)
if [ -z "${GIT_RANGE:-}" ]; then
    GIT_RANGE="HEAD~10..HEAD"
    echo "No GIT_RANGE provided, using default: $GIT_RANGE"
fi

echo "Checking for AI-authored commits in range: $GIT_RANGE"
echo "As per Camunda AI Policy, commits created by AI should be attributed to people and not be merged."
echo ""

# Get all commits in the range
commits=$(git rev-list "$GIT_RANGE" 2>/dev/null || true)

if [ -z "$commits" ]; then
    echo "No commits found in range $GIT_RANGE"
    exit 0
fi

echo "Commits to check:"
git log --oneline "$GIT_RANGE" || true
echo ""

ai_violations=0

# Check each commit
for commit in $commits; do
    echo "Checking commit: $commit"
    
    # Check commit message and metadata for AI patterns
    if ! check_commit_for_ai "$commit"; then
        ai_violations=$((ai_violations + 1))
        continue
    fi
    
    # Check author and committer for AI patterns
    if ! check_author_committer_for_ai "$commit"; then
        ai_violations=$((ai_violations + 1))
        continue
    fi
    
    echo "✓ Commit $commit appears to be human-authored"
done

echo ""

if [ "$ai_violations" -eq 0 ]; then
    echo "✅ Success! No AI-authored commits found."
    echo "All commits appear to be properly attributed to human authors."
    exit 0
else
    echo "❌ Failure! Found $ai_violations AI-authored commit(s)."
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
