#!/bin/bash

# This script checks the current repository for merge conflicts on open PRs labeled with `deploy-preview`
# A sticky comment will be upserted on all conflicted PRs.
# The script can also be called with `PR_ID` set to a single id to limit the scope.
# If `PR_ID` is set, there will be no check for the `deploy-preview` label to allow more freedom in usage.
# All comments matching the `COMMENT_TAG` on non-conflicting PRs will be idempotently removed.


set -o pipefail
set -o errexit

# FIXME put these into the env section of the action itself
COMMENT_BODY_TEMPLATE_PATH=templates/comment-body.md
export REPOSITORY=camunda/infra-global-github-actions

RELATIVE_SCRIPT_PATH=$(dirname "$0")
COMMENT_TAG="<!-- MERGE CONFLICT DETECTED -->" # used for sticky comments

# shellcheck source=/dev/null
source "$RELATIVE_SCRIPT_PATH/../preview-env/clean/github.sh"

# Determine PRs to check (filtered by label: deploy-preview and state: open)
if [ -z "$PR_ID" ]; then
  # scan all PRs in repository
  echo "🌐  Checking all PRs with label 'deploy-preview' for merge conflicts..."
  PR_IDS=$(gh pr list -R $REPOSITORY --state open --label deploy-preview --json number --jq '.[].number')
else
  # use only input to limit scope
  echo "📍  Checking PR #$PR_ID for merge conflicts..."
  PR_IDS=$PR_ID
fi

set -o nounset # at this point all variables are set


# Check for Merge Conflicts
conflicted_prs=
mergeable_prs=
for id in $PR_IDS; do
  echo -n "  Checking PR #$id ... "
  if gh pr view "$id" -R "$REPOSITORY" --json mergeable --jq '.mergeable' | grep -q CONFLICTING; then
    echo " 💥 CONFLICTED!"
    conflicted_prs="$conflicted_prs $id"
  else
    echo " ✅ MERGEABLE"
    mergeable_prs="$mergeable_prs $id"
  fi
done
echo ""

# upsert comments on conflicted prs
if [ -n "$conflicted_prs" ]; then
  echo "Found conflicted PRs. Will post comment on:${conflicted_prs}"
  for pr in $conflicted_prs; do
    export pr
    echo "Upserting comment in PR #$pr ..."
    comment_body=$(envsubst < $COMMENT_BODY_TEMPLATE_PATH)
    upsert_comment "$pr" "$COMMENT_TAG" "$comment_body"
  done
fi

echo ""

# cleanup on mergeable prs
if [ -n "$mergeable_prs" ]; then
  echo "Found mergeable PRs. Will delete comment on:${mergeable_prs} if applicable."
  for pr in $mergeable_prs; do
    export pr
    echo "Looking for deletable comments on PR #$pr"
    delete_comments_by_pull_request_and_tag "$pr" "$COMMENT_TAG"
  done
fi
