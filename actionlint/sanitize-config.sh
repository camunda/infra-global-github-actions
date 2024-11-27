#!/usr/bin/env sh
set -e

CUSTOM_CONFIG_FILE="$1"
DEFAULT_CONFIG_FILE="$2"
# TODO: Implement error logging
# ERROR_OUTPUT_FILE="${3:-/tmp/actionlint-sanitize-error.log}"

error() {
  # echo "$@" >>"$ERROR_OUTPUT_FILE"
  >&2 echo "$@"
}

yq -r '.self-hosted-runner.labels' "$CUSTOM_CONFIG_FILE" | sort -u >/tmp/custom_runner_labels
yq -r '.self-hosted-runner.labels' "$DEFAULT_CONFIG_FILE" | sort -u >/tmp/supported_runner_labels
UNSUPPORTED_RUNNERS=$(comm -13 /tmp/supported_runner_labels /tmp/custom_runner_labels) # extract invalid labels from custom_runners
if [ -n "$UNSUPPORTED_RUNNERS" ]; then
  # Print warning messages on stderr
  error "These self-hosted labels are not supported and will be removed from actionlint configuration"
  error "$UNSUPPORTED_RUNNERS"
  error
fi
VALID_RUNNERS="$(comm -12 /tmp/supported_runner_labels /tmp/custom_runner_labels)"
if [ -z "$VALID_RUNNERS" ]; then
  error "No valid self-hosted labels found in your actionlint configuration"
  error "Fallback to default runners"
  error
  VALID_RUNNERS=$(cat /tmp/supported_runner_labels)
fi
valid_runners="$VALID_RUNNERS" yq '.self-hosted-runner.labels = env(valid_runners)' "$CUSTOM_CONFIG_FILE"
