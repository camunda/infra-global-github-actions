#!/bin/bash

set -eu

# this function is derived from its groovy equivalent
# https://github.com/camunda/jenkins-global-shared-library/blob/master/src/org/camunda/helper/GitUtilities.groovy#L4-L10

# $1 = branch name
# $2 = max length

BRANCH=$(echo "$1" | tr '[:upper:]' '[:lower:]') # make the branch input lowercase
BRANCH="${BRANCH//dependabot\//}" # removes all dependabot/ in a string
BRANCH="${BRANCH//renovate\//}" # removes all renovate/ in a string
BRANCH="${BRANCH/-deploy/}" # removes all -deploy in a string
BRANCH="${BRANCH//[^a-z0-9]/-}" # replaces anything not a-z0-9 with -
MAX_LENGTH="$2"

if [[ $MAX_LENGTH -eq 0 ]]; then
    RESULT="${BRANCH}"
else
    RESULT="${BRANCH:0:MAX_LENGTH}"
    # Replace trailing hyphens with next alphanumeric to maintain max length
    # (Helm release names must end with alphanumeric: ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$)
    p=${#RESULT}
    while [[ $RESULT == *- && $p -lt ${#BRANCH} ]]; do
        if [[ ${BRANCH:$p:1} != - ]]; then
            RESULT="${RESULT%-}${BRANCH:$p:1}"
        fi
        ((p++))
    done
    # Fallback: strip remaining trailing hyphens if source exhausted
    while [[ $RESULT == *- ]]; do RESULT="${RESULT%-}"; done
fi

echo "${RESULT}"
