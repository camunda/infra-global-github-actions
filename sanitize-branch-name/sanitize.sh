#!/bin/bash

set -eu

# this function is derived from its groovy equivalent
# https://github.com/camunda/jenkins-global-shared-library/blob/master/src/org/camunda/helper/GitUtilities.groovy#L4-L10

# $1 = branch name
# $2 = max length

BRANCH=$(echo $1 | tr '[:upper:]' '[:lower:]') # make the branch input lowercase
BRANCH=$(echo ${BRANCH//dependabot\//}) # removes all dependabot/ in a string
BRANCH=$(echo ${BRANCH//renovate\//}) # removes all renovate/ in a string
BRANCH=$(echo ${BRANCH//[^a-z0-9]/-}) # replaces anything not a-z0-9 with -
MAX_LENGTH=$2

if [[ $MAX_LENGTH -eq 0 ]];
then
    echo ${BRANCH}
else
    echo ${BRANCH:0:MAX_LENGTH}
fi
