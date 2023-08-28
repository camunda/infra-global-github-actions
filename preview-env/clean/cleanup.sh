#!/bin/bash

## cleanup.sh
##
## A full cleanup cycle that:
## - Shutdown all preview environments whose lifetime (configurable threshold) has expired and leave a comment to inform users
## - Leave a comment to warn users of preview environments whose lifetime is about to expire (configurable threshold).
## - Delete any remaining inconsistant comments related to preview environments (a catch-all safety step)
##
## This script requires GNU's date binary

set -o errexit
set -o nounset
set -o pipefail

# Global variables
LABELS=${LABELS?}
RELATIVE_SCRIPT_PATH=$(dirname "$0")
SHUTDOWN_MESSAGE=${SHUTDOWN_MESSAGE?}
WARNING_MESSAGE=${WARNING_MESSAGE?}
WARNING_TTL=${WARNING_TTL?}

# shellcheck source=/dev/null
source "$RELATIVE_SCRIPT_PATH/common.sh"
# shellcheck source=/dev/null
source "$RELATIVE_SCRIPT_PATH/github.sh"

# Get pull requests that have at least one preview environment
function get_pull_requests_with_preview_envrionments {
  set -e # subshells do not inherit the -e option

  # Preview labels
  labels=$1

  # Results (pull requests) to be returned by current function
  results="[]"

  # Get candidate pull requests (OPEN and with one preview label attached)
  pull_requests=$(
    get_pull_requests_by_labels_and_state "$labels" OPEN
  )

  # For each pull request, check if at least one preview environment is running
  # A preview environment is considered running if:
  #  - at least one deployment is not inactive (i.e. not in DESTROYED state. Can be ACTIVE,FAILURE, etc ...)
  #  - all deployments are complete (no ongoing deployments)
  for pr in $pull_requests; do
    # Pull request information
    pr_id=$(echo "$pr" | jq -r .id)
    pr_ref=$(echo "$pr" | jq -r .headRefName)
    pr_number=$(echo "$pr" | jq -r .number)
    pr_author=$(echo "$pr" | jq -r .author.login)
    pr_labeled_event_timeline=$(echo "$pr" | jq -r .timelineItems.nodes)

    # Get deployments associated to head ref
    deployments=$(
      get_deployments_by_ref "$pr_ref"
    )
    # Check if all deployments are complete
    all_deployments_completed=$(
      echo "$deployments" |
        jq 'any(.[]; .state == "IN_PROGRESS" or .state == "PENDING" or .state == "QUEUED") | not'
    )
    # Check if at least one deployment is not inactive
    at_least_one_deployment_not_inactive=$(
      echo "$deployments" |
        jq 'any(.[]; .state != "DESTROYED")'
    )

    # If conditions are met, keep pull request
    if [ "$all_deployments_completed" = "true" ] && [ "$at_least_one_deployment_not_inactive" = "true" ]; then
      # Get last deployment id and update date
      last_updated_deployment=$(echo "$deployments" | jq '.[0]')
      updated_at=$(echo "$last_updated_deployment" | jq -r .updatedAt)
      deployment_id=$(echo "$last_updated_deployment" | jq -r .id)

      # Get actor logins (author + label author(s))
      # Limited to the last 100 labeled events (best effort)
      pr_actors=$(
        jq -n \
          --arg author "$pr_author" \
          --argjson labels "[\"${labels//,/\",\"}\"]" \
          --argjson timeline "$pr_labeled_event_timeline" \
          '
            (
              $labels | map(. as $l | $timeline | reverse | map(select(.label.name == $l))[0].actor.login)
            ) + [$author] | unique
          '
      )

      # Append pull request to results
      results=$(
        echo "$results" |
          jq \
            --argjson pr_actors "$pr_actors" \
            --arg pr_id "$pr_id" \
            --arg pr_number "$pr_number" \
            --arg updated_at "$updated_at" \
            --arg deployment_id "$deployment_id" \
            --indent 0 \
            '. += [{pullRequestId: $pr_id, pullRequestNumber: $pr_number, pullRequestActors: $pr_actors, lastDeployedAt: $updated_at, deploymentId: $deployment_id}]'
      )
    fi
  done

  echo "$results"
}

# Preview environment cleanup
function preview_environment_cleanup {
  set -e # subshells do not inherit the -e option

  # Target pull requests
  pull_requests=$1
  # Preview labels
  labels=$2
  # Lifetime threshold after which a preview environment is shutdown
  ttl=$3
  # Threshold after which preview environment users are warned
  warning_ttl=$4
  # Comment templates
  shutdown_message=$5
  warning_message=$6
  # Comment tags
  comment_tag=${7:-<!-- preview-env -->}
  comment_tag_shutdown=${8:-<!-- preview-env:type:shutdown -->}
  comment_tag_warning=${9:-<!-- preview-env:type:warning -->}

  # Get current date (UTC) in seconds
  now=$(date --utc '+%s')

  # Get IDs of preview environment labels
  label_ids=$(get_label_ids "$labels")

  # Count the number of preview environments that will be cleaned during this cycle.
  nb_preview_environments_cleaned=0

  # Check each candidate pull request
  for pr in $(echo "$pull_requests" | jq -c '.[]'); do
    # Pull request information
    deployment_id=$(echo "$pr" | jq -r .deploymentId)
    pr_id=$(echo "$pr" | jq -r .pullRequestId)
    pr_last_deployed_at=$(date --date="$(echo "$pr" | jq -r .lastDeployedAt)" +%s)
    pr_number=$(echo "$pr" | jq -r .pullRequestNumber)
    pr_actors=$(echo "$pr" | jq -r .pullRequestActors)

    # Compute lifetime since last deployment activity
    lifetime=$((now - pr_last_deployed_at))

    # Get existing comment ID if any (should be only one)
    comment_id=$(
      get_comments_by_pull_request_and_tag \
        "$pr_number" \
        "$comment_tag" |
        jq -r \
          '.[0].id | select(. != null)'
    )

    # Comment content to be created or updated if applicable
    comment_body=""

    log "Checking PR #$pr_number (lifetime=${lifetime}s,ttl=${ttl}s,warning-ttl=${warning_ttl}s)"

    # If lifetime has been reached, shutdown preview environment(s)
    if [ $lifetime -gt "$ttl" ]; then
      log "Preview environement lifetime expired!"
      log "Unlabeling PR #$pr_number ..."
      if [ "$DRY_RUN" != "true" ]; then
        delete_pull_request_labels "$pr_id" "$label_ids"
      fi
      nb_preview_environments_cleaned=$((nb_preview_environments_cleaned + 1))

      # Generate shutdown message
      actors=$(echo "$pr_actors" | jq -r 'map("@" + .) | join(" ")')
      preview_labels=$labels
      tag="$comment_tag $comment_tag_shutdown"
      ttl_days=$((ttl / (24 * 3600)))
      comment_body=$(
        render_template \
          "{tag}\n$shutdown_message" \
          "actors:$actors" \
          "preview-labels:$preview_labels" \
          "tag:$comment_tag" \
          "ttl-days:$ttl_days"
      )
    # If lifetime is about to be reached, warn users
    elif [ "$warning_ttl" -gt 0 ] && [ "$lifetime" -gt "$warning_ttl" ]; then
      log "Preview environement lifetime expires soon!"

      # Generate warning message
      actors=$(echo "$pr_actors" | jq -r 'map("@" + .) | join(" ")')
      checks_url=$(get_pull_request_checks_url "$pr_number")
      days_to_shutdown=$(((ttl - lifetime) / (24 * 3600)))
      preview_labels=$labels
      shutdown_date=$(date -d@$((pr_last_deployed_at + ttl)) +'%b %d %Y at %I %p %Z')
      tag="$comment_tag $comment_tag_warning"
      ttl_days=$((ttl / (24 * 3600)))
      comment_body=$(
        render_template \
          "{tag}\n$warning_message" \
          "actors:$actors" \
          "checks-url:$checks_url" \
          "days-to-shutdown:$days_to_shutdown" \
          "preview-labels:$preview_labels" \
          "tag:$tag" \
          "shutdown-date:$shutdown_date" \
          "ttl-days:$ttl_days"
      )
    else
      log "Preview environement lifetime has not expired!"
    fi

    # Upsert comment or delete an existing one
    if [ -n "$comment_body" ]; then
      if [ -z "$comment_id" ]; then
        # Create a new comment
        log "Creating a new comment on PR #$pr_number ..."
        if [ "$DRY_RUN" != "true" ]; then
          create_pull_request_comment "$pr_number" "$comment_body"
        fi
      else
        # Update existing comment
        log "Updating existing comment on PR #$pr_number ..."
        if [ "$DRY_RUN" != "true" ]; then
          # There is a possible race condition if cleanup.sh and limited-cleanup.sh run at the same time.
          # Unlikely to happen, but if it does, ignore it and let the next cleaning cycles update the comment.
          patch_pull_request_comment "$comment_id" "$comment_body" || [ $? = 44 ] # 44 -> Comment not found
        fi
      fi
    else
      # Delete existing comment if any
      if [ -n "$comment_id" ]; then
        log "Deleting existing comment on PR #$pr_number ..."
        if [ "$DRY_RUN" != "true" ]; then
          # There is a possible race condition if cleanup.sh and limited-cleanup.sh run at the same time.
          # Unlikely to happen, but if it does, ignore it. Comment has been deleted.
          delete_pull_request_comment "$comment_id" || [ $? = 44 ] # 44 -> Comment not found
        fi
      fi
    fi
  done

  log "$nb_preview_environments_cleaned preview environment(s) cleaned!"
}

# Clean up inconsistent comments
function cleanup_inconsistent_comments {
  set -e # subshells do not inherit the -e option

  # Preview labels
  labels=$1
  # Comment tags
  comment_tag=${2:-<!-- preview-env -->}
  comment_tag_warning=${3:-<!-- preview-env:type:warning -->}

  # Get OPEN pull requests (with their comments)
  open_pull_requests=$(
    get_pull_requests_by_states_with_last_100_comments OPEN
  )

  # Get CLOSED or MERGED pull requests (with their comments)
  # Limit to the last 100 pull requests as there is no need to scan and process the entire history at each iteration.
  # Considering the pull request closing frequency and the cleanup job execution frequency, each pull request should be processed at least once.
  # Given the frequency with which pull requests are closed and the frequency with which cleanup jobs are executed, each pull request should be processed at least once.
  closed_merged_pull_requests=$(
    get_pull_requests_by_states_with_last_100_comments CLOSED,MERGED false
  )

  # If pull request is in MERGED or CLOSED state, any warning or shutdown comments can be safely removed.
  # If pull request is in OPEN state and NO preview label is attached, warning comments can be safely removed.
  comment_ids_to_delete=$(
    jq -n -r \
      --arg comment_tag "$comment_tag" \
      --arg comment_tag_warning "$comment_tag_warning" \
      --argjson open_pull_requests "$open_pull_requests" \
      --argjson closed_merged_pull_requests "$closed_merged_pull_requests" \
      --argjson labels "[\"${labels//,/\",\"}\"]" \
      '
        (
          $closed_merged_pull_requests |
          [
            .[].comments.nodes[] | select (.body | contains($comment_tag)).databaseId
          ]
        )
        +
        (
          $open_pull_requests |
          [
            .[] |
            select (.labels | any(.nodes[]; .name | IN($labels[])) | not) |
            .comments.nodes[] | select (.body | contains($comment_tag_warning)).databaseId
          ]
        ) | .[]
      '
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

# Get OPEN Pull Requests that have at least one preview envrionment
pull_requests=$(
  get_pull_requests_with_preview_envrionments "$LABELS"
)

log "Cleaning preview environments ..." false
log "pull_requests=$(echo "$pull_requests" | jq -c 'map(.pullRequestNumber)')" false
preview_environment_cleanup \
  "$pull_requests" \
  "$LABELS" \
  "$TTL" \
  "$WARNING_TTL" \
  "$SHUTDOWN_MESSAGE" \
  "$WARNING_MESSAGE"

log "\nCleaning inconsistent comments (catch-all step) ..." false
cleanup_inconsistent_comments \
  "$LABELS"
