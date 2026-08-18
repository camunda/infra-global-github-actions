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
# what callers got before this input existed.
[[ -z "${PERMISSIONS}" ]] && exit 0

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

if ! jq -e . >/dev/null 2>&1 <<<"${PERMISSIONS}"; then
  echo "::error::the 'permissions' input is not valid JSON: ${PERMISSIONS}"
  exit 1
fi

if [[ "$(jq -r 'type' <<<"${PERMISSIONS}")" != "object" ]]; then
  echo "::error::the 'permissions' input must be a JSON object, for example {\"contents\": \"read\"}"
  exit 1
fi

known_json="$(printf '%s\n' "${KNOWN_SCOPES[@]}" | jq -Rn '[inputs]')"

# A scope this action does not forward would otherwise be dropped in silence,
# and the caller would believe the token was narrowed when it was not.
unknown="$(jq -r --argjson known "${known_json}" \
  '[keys[] | select(. as $k | $known | index($k) | not)] | join(", ")' <<<"${PERMISSIONS}")"

if [[ -n "${unknown}" ]]; then
  echo "::error::unknown permission scope(s): ${unknown}"
  printf 'Accepted scopes: %s\n' "${KNOWN_SCOPES[*]}" >&2
  exit 1
fi
