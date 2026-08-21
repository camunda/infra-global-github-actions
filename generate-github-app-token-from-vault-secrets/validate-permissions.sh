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

# The scopes are read from the forwarding block in action.yml rather than listed
# again here. That block is what decides which scopes can reach
# actions/create-github-app-token — a scope missing from it cannot be forwarded
# whatever this script believes — so a second copy could only ever disagree with
# it, and would do so silently on the next upstream bump.
ACTION_YML="${ACTION_YML:-${BASH_SOURCE[0]%/*}/action.yml}"

if [[ ! -r "${ACTION_YML}" ]]; then
  echo "::error::cannot read ${ACTION_YML}, which lists the scopes this action forwards"
  exit 1
fi

KNOWN_SCOPES=()
while IFS= read -r scope; do
  [[ -n "${scope}" ]] && KNOWN_SCOPES+=("${scope}")
done < <(grep -oE '^ +permission-[a-z-]+: \$\{\{' "${ACTION_YML}" | sed 's/.*permission-//; s/:.*//')

# A parse that returns nothing would make every scope unknown and reject every
# input, which is at least safe, but the message would blame the caller for a
# change of shape in this repository.
if [[ ${#KNOWN_SCOPES[@]} -lt 10 ]]; then
  echo "::error::found ${#KNOWN_SCOPES[@]} permission scope(s) in ${ACTION_YML}; the forwarding block has moved or changed shape"
  exit 1
fi


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
# not name the input.
#
# This checks the level set, not what each individual scope accepts. Upstream
# documents finer limits — 45 scopes take read or write, 4 also take admin, 3
# take only write, 2 only read — but they exist as prose in its action.yml, and
# reproducing them here would mean a second copy going stale against it.
#
# Plain comparisons rather than IN(), which is not in every jq old enough to
# still be on a self-hosted runner. A jq failure here would abort under `set -e`
# with a compile error and no annotation.
bad_values="$(jq -r '
  [to_entries[]
   | select((.value | type) != "string"
            or ((.value | ascii_downcase) as $v
                | $v != "read" and $v != "write" and $v != "admin"))
   | "\(.key)=\(.value | tostring)"]
  | join(", ")' <<<"${PERMISSIONS}")"

if [[ -n "${bad_values}" ]]; then
  echo "::error::permission values must be read, write or admin: $(sanitize "${bad_values}")"
  exit 1
fi
