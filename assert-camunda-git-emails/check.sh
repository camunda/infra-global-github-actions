#!/bin/bash

set -eu

# This variable has to contain regex expression for the grep tool
HARDCODED_ALLOWED_EMAILS_REGEX="@camunda.com\|@users.noreply.github.com\|noreply@github.com\|bot@renovateapp.com"

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
  wc -l)

if [ "$NUM_VIOLATIONS" -eq 0 ]; then
  echo "Success! No violating email addresses found."

  exit 0
else
  echo "Failure! Found $NUM_VIOLATIONS violating email addresses:"
  git log --pretty=tformat:"%ae%n%ce" "$GIT_RANGE" | \
    grep -v "$ALLOWED_EMAILS_REGEX" | \
    sort | uniq

  exit 1
fi
