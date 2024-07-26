#!/bin/bash

## limited-cleanup.sh
##
## A script that performs a minimal cleanup.
## It removes any comments from a pull request that might be inconsistent with the deployment status of its associated preview environment(s).
## This is very useful for quickly updating a pull request and eliminating any potential inconsistencies just after
## an operation on associated preview environment(s) (deploy or teardown), while waiting for the full cleanup script to be executed.
##
## If pull request is in MERGED or CLOSED state, any warning or shutdown comments can be safely removed.
## If pull request is in OPEN state and NO preview label is attached, warning comments can be safely removed.
## If pull request is in OPEN state and a preview label is attached, warning and shutdown comments can be safely removed.

set -o errexit
set -o nounset
set -o pipefail

# Global variables
LABELS=${LABELS?}
PULL_REQUEST=${PULL_REQUEST?}
RELATIVE_SCRIPT_PATH=$(dirname "$0")

# shellcheck source=/dev/null
source "$RELATIVE_SCRIPT_PATH/common.sh"
# shellcheck source=/dev/null
source "$RELATIVE_SCRIPT_PATH/github.sh"

function clean_pull_request_comments {
  set -e

  # Target pull request
  pr_number=$1
  # Preview labels
  labels=$2
  # Comment tags
  comment_tag=${3:-<!-- preview-env -->}
  comment_tag_warning=${4:-<!-- preview-env:type:warning -->}

  # Get pull request
  pr=$(
    get_pull_request_by_number "$pr_number"
  )

  # Get pull request state
  pr_state=$(
    echo "$pr" | jq -r '.state | ascii_upcase'
  )
  # Check if pull request has a preview label attached
  pr_has_preview_label=$(
    echo "$pr" |
      jq -c \
        --argjson labels "[\"${labels//,/\",\"}\"]" \
        'any(.labels[]; .name | IN($labels[]))'
  )

  # Tag to use for filtering comments
  target_tag=$comment_tag
  if [ "$pr_state" = "OPEN" ] && [ "$pr_has_preview_label" != "true" ]; then
    target_tag=$comment_tag_warning
  fi

  # Get comment IDs to delete
  comment_ids_to_delete=$(
    get_comments_by_pull_request_and_tag \
      "$pr_number" \
      "$target_tag" |
      jq -r \
        '.[].id'
  )

  # Delete comments
  if [ "$DRY_RUN" != "true" ]; then
    for id in $comment_ids_to_delete; do
      # There is a possible race condition if cleanup.sh and limited-cleanup.sh run at the same time.
      # Unlikely to happen, but if it does, ignore it. Comment has been deleted.
      delete_pull_request_comment "$id" || [ $? = 44 ] # 44 -> Comment not found
    done
  fi

  nb_comments_cleaned=$(
    echo "$comment_ids_to_delete" | wc -w | sed 's/ //g'
  )
  log "$nb_comments_cleaned comment(s) cleaned!"

}

log "Cleaning comments of PR #$PULL_REQUEST ..." false
clean_pull_request_comments \
  "$PULL_REQUEST" \
  "$LABELS"
