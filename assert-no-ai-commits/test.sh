#!/bin/bash

# Comprehensive test script for assert-no-ai-commits action
# This script tests various AI patterns to ensure they are correctly detected

set -e

echo "🧪 Running comprehensive tests for assert-no-ai-commits action..."

# Test cases to verify
test_cases=(
    "Co-authored-by: GitHub Copilot <noreply@github.com>"
    "Co-authored-by: Copilot <copilot@github.com>"
    "Co-authored-by: ChatGPT <chatgpt@openai.com>"
    "Co-authored-by: Claude AI <claude@anthropic.com>"
    "Co-authored-by: AI Assistant <ai@example.com>"
)

# Test author/committer patterns
ai_author_tests=(
    "GitHub Copilot:copilot@github.com"
    "ChatGPT Bot:gpt@openai.com"
    "Claude AI:claude@anthropic.com"
    "AI Assistant:ai@example.com"
)

# Function to run a single test
run_test() {
    local test_name="$1"
    local commit_message="$2"
    local author_name="$3"
    local author_email="$4"

    echo "📋 Testing: $test_name"

    # Create temporary test repository
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"

    git init -q
    git config user.email "${author_email:-test@camunda.com}"
    git config user.name "${author_name:-Test User}"

    # Create initial commit
    echo "test" > test.txt
    git add test.txt
    git commit -q -m "Initial commit"

    # Create commit with AI pattern
    echo "content" >> test.txt
    git add test.txt
    git commit -q -m "$commit_message"

    # Test the action
    export GIT_RANGE="HEAD~1..HEAD"
    SCRIPT_PATH="/Users/maxim.danilov/repos/camunda/infra-global-github-actions/assert-no-ai-commits/check.sh"

    if $SCRIPT_PATH > /tmp/test_output.log 2>&1; then
        echo "❌ FAILED: Should have detected AI pattern but didn't"
        echo "Output was:"
        cat /tmp/test_output.log
        rm -rf "$TEST_DIR"
        return 1
    else
        echo "✅ PASSED: Correctly detected AI pattern"
        rm -rf "$TEST_DIR"
        return 0
    fi
}

# Function to run positive test (should pass)
run_positive_test() {
    local test_name="$1"

    echo "📋 Testing: $test_name"

    # Create temporary test repository
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"

    git init -q
    git config user.email "test@camunda.com"
    git config user.name "Test User"

    # Create normal commit
    echo "test" > test.txt
    git add test.txt
    git commit -q -m "feat: add new feature

This is a normal human commit with proper attribution."

    # Test the action
    export GIT_RANGE="HEAD~1..HEAD"
    SCRIPT_PATH="/Users/maxim.danilov/repos/camunda/infra-global-github-actions/assert-no-ai-commits/check.sh"

    if $SCRIPT_PATH > /dev/null 2>&1; then
        echo "✅ PASSED: Correctly allowed human commit"
        rm -rf "$TEST_DIR"
        return 0
    else
        echo "❌ FAILED: Should have allowed human commit but didn't"
        rm -rf "$TEST_DIR"
        return 1
    fi
}

# Test co-authored-by patterns
echo "🔍 Testing Co-authored-by patterns..."
for test_case in "${test_cases[@]}"; do
    commit_msg="feat: add new feature

$test_case"
    run_test "Co-authored-by pattern" "$commit_msg"
done

# Test author/committer patterns
echo "🔍 Testing author/committer patterns..."
for test_case in "${ai_author_tests[@]}"; do
    IFS=':' read -r name email <<< "$test_case"
    run_test "AI Author: $name <$email>" "feat: add new feature" "$name" "$email"
done

# Test normal human commits (should pass)
echo "🔍 Testing normal human commits..."
run_positive_test "Normal human commit"

echo "🎉 All tests completed!"
echo "If all tests show ✅ PASSED, the action is working correctly."
