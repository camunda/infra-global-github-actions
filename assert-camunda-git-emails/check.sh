#!/bin/bash

set -eu

echo "Looking at Git commits in range $GIT_RANGE"

echo "All found email addresses:"
git log --pretty=tformat:"%ae%n%ce" "$GIT_RANGE" | sort | uniq

# shellcheck disable=SC2126
NUM_VIOLATIONS=$(git log --pretty=tformat:"%ae%n%ce" "$GIT_RANGE" | \
  grep -v "@camunda.com\|@users.noreply.github.com\|noreply@github.com" | \
  wc -l)

if [ "$NUM_VIOLATIONS" -ne 0 ]; then
  echo "Failure! Found $NUM_VIOLATIONS violating email addresses:"
  git log --pretty=tformat:"%ae%n%ce" "$GIT_RANGE" | \
    grep -v "@camunda.com\|@users.noreply.github.com\|noreply@github.com" | \
    sort | uniq

  exit 1
fi

exit 0
