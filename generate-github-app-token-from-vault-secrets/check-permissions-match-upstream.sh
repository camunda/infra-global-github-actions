#!/bin/bash
# Checks that the `permission-*` block in action.yml matches the inputs of the
# actions/create-github-app-token revision it is pinned to.
#
# That block is the list of scopes a caller can ask for: validate-permissions.sh
# reads it, and anything absent from it cannot reach the upstream action. So it
# has to follow upstream, and the moment it silently stops doing so is a bump of
# the pinned SHA — which is exactly when this runs.
#
# The SHA is read from action.yml rather than configured here, and content at a
# SHA never changes, so this check is deterministic: it can only start failing
# because someone moved the pin.
#
# Usage: check-permissions-match-upstream.sh [path/to/action.yml]
set -euo pipefail

ACTION_YML="${1:-${BASH_SOURCE[0]%/*}/action.yml}"

if [[ ! -r "${ACTION_YML}" ]]; then
  echo "cannot read ${ACTION_YML}" >&2
  exit 1
fi

pinned="$(grep -oE 'actions/create-github-app-token@[0-9a-f]{40}' "${ACTION_YML}" | head -1 | cut -d@ -f2)"
if [[ -z "${pinned}" ]]; then
  echo "no SHA-pinned actions/create-github-app-token reference found in ${ACTION_YML}" >&2
  exit 1
fi

upstream_yml="$(mktemp)"
trap 'rm -f "${upstream_yml}"' EXIT

curl --fail --silent --show-error --location \
     --proto '=https' --proto-redir '=https' --retry 3 \
     --output "${upstream_yml}" \
     "https://raw.githubusercontent.com/actions/create-github-app-token/${pinned}/action.yml"

# Upstream declares them as inputs; this action forwards them in a `with:` block.
upstream="$(grep -oE '^  permission-[a-z-]+:' "${upstream_yml}" | sed 's/^  permission-//; s/://' | sort)"
forwarded="$(grep -oE '^ +permission-[a-z-]+: \$\{\{' "${ACTION_YML}" | sed 's/.*permission-//; s/:.*//' | sort)"

if [[ -z "${upstream}" ]]; then
  echo "found no permission-* inputs in upstream action.yml at ${pinned}; its shape has changed" >&2
  exit 1
fi

missing="$(comm -23 <(echo "${upstream}") <(echo "${forwarded}"))"
extra="$(comm -13 <(echo "${upstream}") <(echo "${forwarded}"))"

if [[ -z "${missing}" && -z "${extra}" ]]; then
  echo "action.yml forwards all $(echo "${upstream}" | grep -c .) permission scopes of create-github-app-token@${pinned:0:7}"
  exit 0
fi

echo "action.yml is out of step with create-github-app-token@${pinned:0:7}" >&2

if [[ -n "${missing}" ]]; then
  echo >&2
  echo "Not forwarded, so a caller cannot ask for them. Add to the \`with:\` block:" >&2
  while IFS= read -r scope; do
    [[ -z "${scope}" ]] && continue
    # shellcheck disable=SC2016
    printf '      permission-%s: ${{ fromJSON(inputs.permissions || '"'"'{}'"'"')['"'"'%s'"'"'] }}\n' "${scope}" "${scope}" >&2
  done <<<"${missing}"
fi

if [[ -n "${extra}" ]]; then
  echo >&2
  echo "Forwarded but no longer accepted upstream. Remove from the \`with:\` block:" >&2
  while IFS= read -r scope; do
    [[ -z "${scope}" ]] && continue
    printf '      permission-%s\n' "${scope}" >&2
  done <<<"${extra}"
fi

exit 1
