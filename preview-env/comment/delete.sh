#!/bin/bash

## delete.sh
##
## Deletes the PRs summary comment
## Background:
## There's currently no well-maintained working github action out there, which we could use.
## Thus we decided to reuse functions of `preview-env/clean/github.sh`

set -o errexit
set -o nounset
set -o pipefail

RELATIVE_SCRIPT_PATH=$(dirname "$0")
TAG_IN_COMMENT_BODY=${TAG_IN_COMMENT_BODY?}
PULL_REQUEST=${PULL_REQUEST?}

# shellcheck source=/dev/null
source "$RELATIVE_SCRIPT_PATH/../clean/github.sh"

comment_ids_to_delete=$(
get_comments_by_pull_request_and_tag \
    "$PULL_REQUEST" \
    "$TAG_IN_COMMENT_BODY" |
    jq -r \
    '.[].id'
)

if [ -z "$comment_ids_to_delete" ]; then
    echo "No comments found to delete."
    exit 0
fi

# There should be only one comment with the same id.
# But to be thorough we handle all of the Ids here
# If the comment cannot be deleted, we log it but don't fail.
for id in $comment_ids_to_delete; do
    if delete_pull_request_comment "$id"; then
        echo "Deleted comment with id ${id}"
    else
        if [ $? -ne 44 ]; then
            echo "Failed to delete comment with id ${id}."
        else
            echo "Comment with id ${id} not found (exit code 44)."
        fi
    fi
done
