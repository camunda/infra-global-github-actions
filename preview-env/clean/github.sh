#!/bin/bash

## Functions for accessing GitHub API

# Global variables
RELATIVE_SCRIPT_PATH=$(dirname "$0")

# Create a new comment on pull request
function create_pull_request_comment {
  set -e # subshells do not inherit the -e option

  pr_number=$1
  body=$2

  gh pr comment "$pr_number" --body "$body"
}

# Delete pull request comment
function delete_pull_request_comment {
  set -e # subshells do not inherit the -e option

  id=$1
  exit_code=0

  result=$(
    gh api \
      --method DELETE \
      "/repos/{owner}/{repo}/issues/comments/$id"
  ) || exit_code=$?

  if [ "$exit_code" != 0 ]; then
    not_found=$(
      echo "$result" | jq '.message == "Not Found"'
    )
    if [ "$not_found" = true ]; then
      return 44
    else
      return $exit_code
    fi
  fi
}

# Deletes all comments from a pull request containing a tag (in the body)
function delete_comments_by_pull_request_and_tag {
  set -e # subshells do not inherit the -e option

  pr_number=$1
  comment_tag=$2

  # Get existing comment IDs if any (should be only one)
  comment_ids=$(
    get_comments_by_pull_request_and_tag \
      "$pr_number" \
      "$comment_tag" |
        jq -r \
          '.[].id | select(. != null)'
  )

  if [ -z "$comment_ids" ]; then
    echo "No comments matching tag '$comment_tag' found on PR #$pr_number"
  fi


  # delete comments
  for id in $comment_ids; do
    echo -ne "🗑️\tDeleting comment (id: $id) on pr #$pr_number ... "
    delete_pull_request_comment "$id" || [ $? = 44 ] # 44 -> Comment not found
    echo -e "✔️"
  done
}

# Remove label(s) from a pull request
function delete_pull_request_labels {
  set -e # subshells do not inherit the -e option

  pr_id=$1
  label_ids=$2

  # Generate gh --field argument for each label ID
  label_id_fields=$(
    # shellcheck disable=SC2016
    echo "$label_ids" | xargs -n 1 \
      bash -c 'echo -n "--field labelIds[]=$0 "'
  )
  IFS=" " read -r -a label_id_fields <<<"$label_id_fields"

  gh api graphql \
    --field pullRequestId="$pr_id" \
    "${label_id_fields[@]}" \
    --field "query=@$RELATIVE_SCRIPT_PATH/graphql/mutation_remove_labels.gql" \
    --silent
}

# Get comments from a pull request containing a tag (in the body)
function get_comments_by_pull_request_and_tag {
  set -e # subshells do not inherit the -e option

  pr_number=$1
  tag=$2

  comments=$(
    gh api \
      --paginate \
      "/repos/{owner}/{repo}/issues/$pr_number/comments" |
      jq \
        --arg tag "$tag" \
        '[.[] | select(.body | contains($tag))]'
  )

  echo "$comments"
}

# Upserts a comment identified by pr_id and tag in body
#
# To have a sticky comment (at the very end)
# AND to get a cleanup of eventually multipliple comments with the same ID
# all comments with the given `comment_tag` will be deleted before a new one is created.
# So an update is actually a "delete & create"
# args:
#   $1: pr_number
#   $2: comment_tag (to identify comment in pr)
#   $3: comment_body (actual readable payload)
function upsert_comment {
  set -e # subshells do not inherit the -e option

  pr_number=$1
  comment_tag=$2
  comment_body="$2
  $3" # composite body of tag and actual comment body

  # Delete existing comments
  delete_comments_by_pull_request_and_tag \
      "$pr_number" \
      "$comment_tag"

  # Create a new comment
  echo -ne "💬\tCreating a new comment on PR #$pr_number ... "
  create_pull_request_comment "$pr_number" "$comment_body" > /dev/null
  echo -e " ✔️"
}

# Get deployments associated to a Git ref.
function get_deployments_by_ref {
  set -e # subshells do not inherit the -e option

  ref=$1

  environments=$(
    gh api \
      --paginate \
      "/repos/{owner}/{repo}/deployments?ref=$ref" \
      --jq '.[].environment' |
      sort | uniq
  )

  # Generate gh --field argument for each environment
  environment_fields=$(
    # shellcheck disable=SC2016
    echo "$environments" | xargs -n 1 \
      bash -c 'echo -n "--field environments[]=$0 "'
  )
  IFS=" " read -r -a environment_fields <<<"$environment_fields"

  deployments=$(
    gh api graphql \
      --paginate \
      --field owner="{owner}" \
      --field repo="{repo}" \
      "${environment_fields[@]}" \
      --field "query=@$RELATIVE_SCRIPT_PATH/graphql/query_get_deployments_by_environments.gql" |
      jq -s '[.[].data.repository.deployments.nodes[]] | sort_by(.updatedAt) | reverse'
  )

  echo "$deployments"
}

# Get label IDs from a comma-separated list of label name
function get_label_ids {
  set -e # subshells do not inherit the -e option

  labels=$1

  # Get label IDs
  results=""
  for label in ${labels//,/ }; do
    results="$results "$(
      gh api graphql \
        --paginate \
        --field owner="{owner}" \
        --field repo="{repo}" \
        --field label="$label" \
        --field "query=@$RELATIVE_SCRIPT_PATH/graphql/query_get_label_by_name.gql" \
        --jq '.data.repository.label.id'
    )
  done

  echo "$results"
}

# Get URL to pull request checks
function get_pull_request_checks_url {
  set -e # subshells do not inherit the -e option

  pr_number=$1

  checks_url=$(
    gh pr view "$pr_number" \
      --json url \
      --jq '.url + "/checks"'
  )

  echo "$checks_url"
}

# Get pull requests filtered by labels and state
function get_pull_requests_by_labels_and_state {
  set -e # subshells do not inherit the -e option

  labels=$1
  state=$2

  # Generate gh --field argument for each label
  label_fields=$(
    # shellcheck disable=SC2016
    echo "${labels//,/ } " | xargs -n 1 \
      bash -c 'echo -n "--field labels[]=$0 "'
  )
  IFS=" " read -r -a label_fields <<<"$label_fields"

  pull_requests=$(
    gh api graphql \
      --paginate \
      --field owner="{owner}" \
      --field repo="{repo}" \
      "${label_fields[@]}" \
      --field states="$state" \
      --field "query=@$RELATIVE_SCRIPT_PATH/graphql/query_get_pull_requests_by_labels_and_state.gql" \
      --jq '.data.repository.pullRequests.nodes | unique | .[]'
  )

  echo "$pull_requests"
}

# Get pull requests filtered by labels and state
function get_pull_request_by_number {
  set -e # subshells do not inherit the -e option

  pr_number=$1

  pull_request=$(
    gh api \
      "repos/{owner}/{repo}/pulls/$pr_number"
  )

  echo "$pull_request"
}

# Get pull requests filtered by states with the last 100 comments
function get_pull_requests_by_states_with_last_100_comments {
  set -e # subshells do not inherit the -e option

  states=$1
  paginate=${2:-true}

  params=""
  if [ "$paginate" = "true" ]; then
    params=--paginate
  fi

  # Generate gh --field argument for each state to filter
  state_fields=$(
    # shellcheck disable=SC2016
    echo "${states//,/ }" | xargs -n 1 \
      bash -c 'echo -n "--field states[]=$0 "'
  )
  IFS=" " read -r -a state_fields <<<"$state_fields"

  results=$(
    gh api graphql \
      $params \
      --field owner="{owner}" \
      --field repo="{repo}" \
      "${state_fields[@]}" \
      --field "query=@$RELATIVE_SCRIPT_PATH/graphql/query_get_pull_requests_by_states_with_last_100_comments.gql" |
      jq -s \
        '[.[].data.repository.pullRequests.nodes[]] |
         (.[].comments.nodes[] | select(.body | length > 1000)).body |= .[0:980] + " ... (truncated)"'
  )

  echo "$results"
}

# Update pull request comment
function patch_pull_request_comment {
  set -e # subshells do not inherit the -e option

  id=$1
  body=$2

  result=$(
    gh api \
      --method PATCH \
      "/repos/{owner}/{repo}/issues/comments/$id" \
      --field body="$body"
  ) || exit_code=$?

  if [ "${exit_code:-0}" != 0 ]; then
    not_found=$(
      echo "$result" | jq '.message == "Not Found"'
    )
    if [ "$not_found" = true ]; then
      return 44
    else
      return "$exit_code"
    fi
  fi
}
