#!/bin/bash
# Validates the `permissions` input of the composite action.
#
# Kept in a file rather than inline so it can be exercised directly. Through the
# action, a rejection and a later Vault failure both surface as "the step
# failed", so an end-to-end assertion cannot tell them apart and would go green
# even if this stopped rejecting anything.
#
# Usage: validate-permissions.sh '<json>'
set -euo pipefail

PERMISSIONS="${1:-}"

# Nothing to check: the token inherits every permission the App holds, which is
# what callers got before this input existed. Kept above the jq dependency
# below, so a caller that does not use `permissions` needs nothing new.
[[ -z "${PERMISSIONS}" ]] && exit 0

# Without this, a missing jq surfaces as "not valid JSON" — the check below runs
# `jq` and reads its non-zero exit as a verdict on the input rather than as the
# command being absent.
if ! command -v jq >/dev/null 2>&1; then
  echo "::error::the 'permissions' input needs jq, which is not installed on this runner"
  exit 1
fi

KNOWN_SCOPES=(
  actions
  administration
  artifact-metadata
  attestations
  checks
  codespaces
  contents
  custom-properties-for-organizations
  dependabot-secrets
  deployments
  discussions
  email-addresses
  enterprise-custom-properties-for-organizations
  environments
  followers
  git-ssh-keys
  gpg-keys
  interaction-limits
  issues
  members
  merge-queues
  metadata
  organization-administration
  organization-announcement-banners
  organization-copilot-seat-management
  organization-custom-org-roles
  organization-custom-properties
  organization-custom-roles
  organization-events
  organization-hooks
  organization-packages
  organization-personal-access-token-requests
  organization-personal-access-tokens
  organization-plan
  organization-projects
  organization-secrets
  organization-self-hosted-runners
  organization-user-blocking
  packages
  pages
  profile
  pull-requests
  repository-custom-properties
  repository-hooks
  repository-projects
  secret-scanning-alerts
  secrets
  security-events
  single-file
  starring
  statuses
  team-discussions
  vulnerability-alerts
  workflows
)

# The runner reads workflow commands line by line, so a value echoed into a
# `::error::` line can open a second command of the caller's choosing. Flatten
# newlines and defuse the `::` marker before interpolating anything derived from
# the input.
sanitize() {
  printf '%s' "${1}" | tr '\n\r\t' '   ' | sed 's/::/;;/g' | cut -c1-200
}

if ! jq -e . >/dev/null 2>&1 <<<"${PERMISSIONS}"; then
  echo "::error::the 'permissions' input is not valid JSON: $(sanitize "${PERMISSIONS}")"
  exit 1
fi

if [[ "$(jq -r 'type' <<<"${PERMISSIONS}")" != "object" ]]; then
  echo "::error::the 'permissions' input must be a JSON object, for example {\"contents\": \"read\"}"
  exit 1
fi

known_json="$(printf '%s\n' "${KNOWN_SCOPES[@]}" | jq -Rn '[inputs]')"

# A scope this action does not forward would otherwise be dropped in silence,
# and the caller would believe the token was narrowed when it was not.
#
# Counted rather than tested for emptiness: an unknown key that is itself the
# empty string joins to "", which would read as "nothing unknown" and let the
# one case this check exists for through.
unknown_count="$(jq --argjson known "${known_json}" \
  '[keys[] | select(. as $k | $known | index($k) | not)] | length' <<<"${PERMISSIONS}")"

if [[ "${unknown_count}" != "0" ]]; then
  unknown="$(jq -r --argjson known "${known_json}" \
    '[keys[] | select(. as $k | $known | index($k) | not) | if . == "" then "(empty)" else . end] | join(", ")' <<<"${PERMISSIONS}")"
  echo "::error::unknown permission scope(s): $(sanitize "${unknown}")"
  printf 'Accepted scopes: %s\n' "${KNOWN_SCOPES[*]}" >&2
  exit 1
fi

# Values are checked here rather than left to the API, which would reject them
# only after Vault has been read and a token requested, with an error that does
# not name the input. Which levels a given scope accepts is upstream's business;
# that they are one of the three, and a string, is checkable locally.
bad_values="$(jq -r '
  [to_entries[]
   | select((.value | type) != "string" or ((.value | ascii_downcase) | IN("read", "write", "admin") | not))
   | "\(.key)=\(.value | tostring)"]
  | join(", ")' <<<"${PERMISSIONS}")"

if [[ -n "${bad_values}" ]]; then
  echo "::error::permission values must be read, write or admin: $(sanitize "${bad_values}")"
  exit 1
fi
