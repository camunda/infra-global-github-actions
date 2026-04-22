#!/bin/bash

set -eu

# This variable has to contain regex expression for the grep tool
HARDCODED_ALLOWED_EMAILS_REGEX="@camunda.com\|@users.noreply.github.com\|noreply@github.com\|github-actions@github.com\|bot@renovateapp.com\|snyk-bot@snyk.io"

if [ "$ADDITIONAL_ALLOWED_EMAILS_REGEX" = "" ]; then
  ALLOWED_EMAILS_REGEX="$HARDCODED_ALLOWED_EMAILS_REGEX"
else
  ALLOWED_EMAILS_REGEX="$HARDCODED_ALLOWED_EMAILS_REGEX\|$ADDITIONAL_ALLOWED_EMAILS_REGEX"
fi

echo "Looking at Git commits in range $GIT_RANGE"

echo "All found email addresses:"
git log --pretty=tformat:"%ae%n%ce" "$GIT_RANGE" | sort | uniq

# shellcheck disable=SC2126
NUM_VIOLATIONS=$(git log --pretty=tformat:"%ae%n%ce" "$GIT_RANGE" | \
  grep -v "$ALLOWED_EMAILS_REGEX" | \
  sort | \
  uniq | \
  wc -l)

if [ "$NUM_VIOLATIONS" -eq 0 ]; then
  echo "Success! No violating email addresses found."

  exit 0
else
  echo "Failure! Found $NUM_VIOLATIONS violating email addresses:"
  git log --pretty=tformat:"%ae%n%ce" "$GIT_RANGE" | \
    grep -v "$ALLOWED_EMAILS_REGEX" | \
    sort | uniq

  NUM_COMMITS=$(git rev-list --count "$GIT_RANGE")

  echo ""
  if [ "$NUM_COMMITS" -le 30 ]; then
    echo "Detailed commit list (author email vs. committer email):"
    git log --pretty=tformat:"%h | Author: %ae | Committer: %ce | %s" "$GIT_RANGE"
  else
    echo "Too many commits ($NUM_COMMITS) to display individually. Use the command below to investigate locally."
  fi

  echo ""
  echo "To investigate locally, run:"
  echo "  git log --pretty=tformat:\"%h | Author: %ae | Committer: %ce | %s\" \"$GIT_RANGE\""
  echo ""
  echo "Note: The author email (%ae) is set by the person who wrote the code."
  echo "The committer email (%ce) is set by the person who applied the commit (e.g. during rebase or merge)."
  echo "To fix the author email, use: git commit --amend --author=\"Your Name <your.name@camunda.com>\""
  echo "To fix the committer email, configure your git email: git config user.email \"your.name@camunda.com\" and rebase."

  exit 1
fi
