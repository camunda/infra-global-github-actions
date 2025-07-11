#!/bin/bash
#
# Copyright Camunda Services GmbH and/or licensed to Camunda Services GmbH under
# one or more contributor license agreements. See the NOTICE file distributed
# with this work for additional information regarding copyright ownership.
# Licensed under the Camunda License 1.0. You may not use this file
# except in compliance with the Camunda License 1.0.
#

# Given a current version identifies a previous version based on existing git tags
# Params:
#   1 - Current version. E.g. 8.8.0
#   2 - Verbose mode (true|false)
# Output:
#   "$TYPE $PREV_TAG"
#   E.g. "NORMAL 8.7.0"

PREV_TAG="not found"
VERSION="$1"
VERBOSE="$2"

if [[ ${VERBOSE} = "true" ]]; then
  set -x
fi

# Function to determine the previous tag using 'NORMAL' logic
determine_normal_prev_tag() {
  local candidate=""
  local candidateWithPatch0=""
  # Loop through all previous tags to find the appropriate previous tag
  for tag in $prev_tags; do
    if [[ $tag != "$current_tag" ]] && [[ $tag =~ $NORMAL_PATTERN ]]; then
      IFS='.' read -r tag_major tag_minor tag_patch <<< "$tag"
      IFS='.' read -r curr_major curr_minor curr_patch <<< "$current_tag"
      curr_patch=${curr_patch%%-*}
      if ((tag_major == curr_major)) && ((tag_minor == curr_minor)) && ((tag_patch == curr_patch)); then
        continue
      fi

      IFS='.' read -r candidate_major candidate_minor candidate_patch <<< "$candidate"

      # Compare each previous tag with the current tag to find the closest preceding version
      if ((tag_major == curr_major)); then
        if ((tag_minor == curr_minor)) && ((tag_patch <= curr_patch)) && ([[ -z "$candidate_patch" ]] || ((tag_patch > candidate_patch))); then
          candidate="$tag"
        elif ((tag_minor < curr_minor)) && ([[ -z "$candidate_minor" ]] || ((tag_minor > candidate_minor))); then
          candidate="$tag"
        fi
      elif ((tag_major < curr_major)) && ([[ -z "$candidate_major" ]] || ((tag_major > candidate_major))); then
        candidate="$tag"
      fi

      if ((tag_patch == 0)); then
        IFS='.' read -r candidateWithPatch0_major candidateWithPatch0_minor _ <<< "$candidateWithPatch0"
        if ((tag_major == curr_major)) && ((tag_minor <= curr_minor)) && ([[ -z "$candidateWithPatch0_minor" ]] || ((tag_minor > candidateWithPatch0_minor))); then
          candidateWithPatch0="$tag"
        elif ((tag_major < curr_major)) && ([[ -z "$candidateWithPatch0_major" ]] || ((tag_major > candidateWithPatch0_major))); then
          candidateWithPatch0="$tag"
        fi
      fi
    fi
  done

  # Decide the previous tag based on whether the current patch number is 0
  if [[ "$curr_patch" == "0" ]]; then
    if [[ -n "$candidateWithPatch0" ]]; then
      prev_tag="$candidateWithPatch0"
    else
      prev_tag="$candidate"
    fi
  else
    prev_tag="$candidate"
  fi

  echo "$prev_tag"
}


# Function to determine the previous tag based on the type and version
determine_prev_tag() {
  local current_tag="$1"
  local type="$2"
  local prev_tag=""
  local -r prev_tags=$(git --no-pager tag --sort=-v:refname)

  if [[ $type == "RC" ]]; then
    # Extract the base version and RC version from the current tag
    local base_version="${current_tag%-rc*}"
    local -r current_rc_version=$(echo "$current_tag" | grep -oE "rc[0-9]+" | sed 's/rc//')

    # Get the previous RC tag within the same minor version and with a lower RC number
    prev_tag=$(get_previous_rc_tag "$base_version" "$current_rc_version" "$prev_tags")
  fi

  if [[ $type == "ALPHA" ]] || { [[ -z $prev_tag ]] && [[ $current_tag =~ -alpha[0-9]+(\.[0-9]+)?-rc[0-9]+$ ]]; }; then
    # Extract the alpha base version
    local base_version="${current_tag%-alpha*}"
    local -r current_alpha_version=$(echo "$current_tag" | grep -oE "alpha[0-9]+(\.[0-9]+)?" | sed 's/alpha//')
    prev_tag=$(get_previous_alpha_tag "$base_version" "$current_alpha_version" "$prev_tags")
  fi

  # Fallback to 'NORMAL' logic if no previous tag found
  if [[ -z $prev_tag ]]; then
    prev_tag=$(determine_normal_prev_tag)
  fi

  PREV_TAG="$prev_tag"
}


# Function to get the previous RC tag
get_previous_rc_tag() {
  local base_version=$1
  local current_rc_version=$2
  local prev_tags=$3
  local candidate_tag=""
  local candidate_rc_version=0
  local tag_rc_version

  for tag in $prev_tags; do
    if [[ $tag == $base_version-rc* ]]; then
      tag_rc_version=$(echo "$tag" | grep -oE "rc[0-9]+" | sed 's/rc//')
      if (( tag_rc_version < current_rc_version )) && (( tag_rc_version > candidate_rc_version )); then
        candidate_tag="$tag"
        candidate_rc_version=$tag_rc_version
      fi
    fi
  done

  echo "$candidate_tag"
}


# Function to get the previous alpha tag
get_previous_alpha_tag() {
  local base_version=$1
  local current_alpha_version=$2
  local prev_tags=$3
  local candidate_tag=""
  local candidate_alpha_version=0
  local tag_alpha_version
  local tag_alpha_lt_current_alpha
  local tag_alpha_gt_candidate_alpha

  for tag in $prev_tags; do
    if [[ $tag == $base_version-alpha* ]] && [[ $tag =~ $ALPHA_PATTERN ]]; then
      tag_alpha_version=$(echo "$tag" | grep -oE "alpha[0-9]+(\.[0-9]+)?" | sed 's/alpha//')
      tag_alpha_lt_current_alpha=$(echo "$tag_alpha_version < $current_alpha_version" | bc)
      tag_alpha_gt_candidate_alpha=$(echo "$tag_alpha_version > $candidate_alpha_version" | bc)
      if [[ "$tag_alpha_lt_current_alpha" -eq 1 && "$tag_alpha_gt_candidate_alpha" -eq 1 ]]; then
        candidate_tag="$tag"
        candidate_alpha_version=$tag_alpha_version
      fi
    fi
  done

  echo "$candidate_tag"
}

# validation for tag format
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+(-alpha[0-9]+(\.[0-9]+)?)?(-rc[0-9]+)?$ ]]; then
  echo "Release tag is invalid"
  exit 1
fi
# Determine the tag type
NORMAL_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
ALPHA_PATTERN='-alpha[0-9]+(\.[0-9]+)?$'
RC_PATTERN='-rc[0-9]+$'

TYPE=""
if [[ $VERSION =~ $NORMAL_PATTERN ]]; then
  TYPE="NORMAL"
elif [[ $VERSION =~ $ALPHA_PATTERN ]]; then
  TYPE="ALPHA"
elif [[ $VERSION =~ $RC_PATTERN ]]; then
  TYPE="RC"
fi

if [[ -z $TYPE ]]; then
  echo "Invalid tag format"
  exit 1
fi


# Determine the previous tag
determine_prev_tag "$VERSION" "$TYPE"
if [[ -z $PREV_TAG ]]; then
  echo "No previous tag found for the given rules"
  exit 1
fi

# Output the previous tag with its type
echo "$TYPE $PREV_TAG"
