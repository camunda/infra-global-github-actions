#!/usr/bin/env sh
set -e

CUSTOM_CONFIG_FILE="$1"
DEFAULT_CONFIG_FILE="$2"

yq -r '.self-hosted-runner.labels' "$CUSTOM_CONFIG_FILE" | sort -u >/tmp/custom_runner_labels
yq -r '.self-hosted-runner.labels' "$DEFAULT_CONFIG_FILE" | sort -u >/tmp/supported_runner_labels
UNSUPPORTED_RUNNERS=$(comm -13 /tmp/supported_runner_labels /tmp/custom_runner_labels) # extract invalid labels from custom_runners
if [ -n "$UNSUPPORTED_RUNNERS" ]; then
  # Print warning messages on stderr
  >&2 echo "These self-hosted labels are not supported and will be removed from actionlint configuration"
  >&2 echo "$UNSUPPORTED_RUNNERS"
fi
VALID_RUNNERS="$(comm -12 /tmp/supported_runner_labels /tmp/custom_runner_labels)"
if [ -z "$VALID_RUNNERS" ]; then
  >&2 echo "No valid self-hosted labels found in your actionlint configuration"
  >&2 echo "Fallback to default runners"
  VALID_RUNNERS=$(cat /tmp/supported_runner_labels)
fi
valid_runners="$VALID_RUNNERS" yq '.self-hosted-runner.labels = env(valid_runners)' "$CUSTOM_CONFIG_FILE"
