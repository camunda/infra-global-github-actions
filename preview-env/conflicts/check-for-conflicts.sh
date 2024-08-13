#!/bin/bash

# This script checks the current repository for merge conflicts on open PRs labeled with `deploy-preview`
# A sticky comment will be upserted on all conflicted PRs.
# The script can also be called with `PR_ID` set to a single id to limit the scope.
# If `PR_ID` is set, there will be no check for the `deploy-preview` label to allow more freedom in usage.
# `GH_REPO` must be set like `<orga>/<repo>`.
# `LABEL_FILTERS` is an optional comma-separated list of labels to filter for and defaults to "deploy-preview".
# `COMMENT_BODY_TEMPLATE_PATH` is required, since paths will be determined during runtime.
#   When script's being called via Github Action, please set to `${{ github.action_path }}/templates/comment-body.md`
# All comments matching the `COMMENT_TAG` on non-conflicting PRs will be idempotently removed.
#
# Local Testing (Example Call):
# gh auth login # receive github token for authentication.
# GH_REPO=camunda/infra-global-github-actions COMMENT_BODY_TEMPLATE_PATH=templates/comment-body.md ./check-for-conflicts.sh

set -eo pipefail

RELATIVE_SCRIPT_PATH=$(dirname "$0")
COMMENT_TAG="<!-- MERGE CONFLICT DETECTED -->" # used for sticky comments

# shellcheck source=/dev/null
source "$RELATIVE_SCRIPT_PATH/../clean/github.sh" # importing reusable function to act upon PR comments (CRUD)

# assemble label filter string
LABEL_FILTERS=${LABEL_FILTERS:=deploy-preview}
DEFAULT_IFS=$IFS
IFS=','
FILTER_STRING=""
echo -ne "🏗️\tAssembling label filter..."
for label in $LABEL_FILTERS; do
  FILTER_STRING="${FILTER_STRING} --label ${label}"
done
echo -e " ✔️"
IFS=$DEFAULT_IFS

# Determine PRs to check (filtered by given label filters and state: open)
if [ -z "$PR_ID" ]; then
  # scan all PRs in repository
  echo -e "🌐\tChecking all PRs with label filter '${FILTER_STRING}' for merge conflicts..."
  PR_IDS=$(eval gh pr list -R "${GH_REPO}" --state open "${FILTER_STRING}" --json number --jq '.[].number')
else
  # use only input to limit scope
  echo -e "📍\tChecking PR #${PR_ID} for merge conflicts..."
  PR_IDS=$PR_ID
fi

if [ -z "$PR_IDS" ]; then
  echo -e "☀️\tno conflicted PRs found. Awesome, BYE 👋"
  exit 0
fi

set -o nounset # at this point all variables are set


# Check for Merge Conflicts
conflicted_prs=""
mergeable_prs=""
for id in $PR_IDS; do
  echo -ne "\t🔍\tChecking PR #$id ... "
  if gh pr view "$id" -R "$GH_REPO" --json mergeable --jq '.mergeable' | grep -q CONFLICTING; then
    echo " 💥 CONFLICTED!"
    conflicted_prs="$conflicted_prs $id"
  else
    echo " ✅ MERGEABLE"
    mergeable_prs="$mergeable_prs $id"
  fi
done
echo

# upsert comments on conflicted prs
if [ -n "$conflicted_prs" ]; then
  echo "Found conflicted PRs. Will post comment on: #${conflicted_prs}"
  for pr in $conflicted_prs; do
    echo "Upserting comment in PR #$pr ..."
    comment_body=$(envsubst < "$COMMENT_BODY_TEMPLATE_PATH")
    upsert_comment "$pr" "$COMMENT_TAG" "$comment_body"
  done
fi

echo

# cleanup on mergeable prs
if [ -n "$mergeable_prs" ]; then
  echo "Found mergeable PRs. Will delete comment on: #${mergeable_prs} if applicable."
  for pr in $mergeable_prs; do
    echo "Looking for deletable comments on PR #$pr"
    delete_comments_by_pull_request_and_tag "$pr" "$COMMENT_TAG"
  done
fi
