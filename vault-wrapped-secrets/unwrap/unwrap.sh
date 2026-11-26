#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${WRAP_TOKEN}" ]]; then
  echo "::error::No wrapping token given"
  exit 1
fi
echo "::add-mask::${WRAP_TOKEN}"

body=$(mktemp)
trap 'rm -f "${body}"' EXIT

# vault_post <path> <json body> [token]: response body in ${body}, HTTP status in ${status}.
vault_post() {
  local args=(-sS --max-time 10 -o "${body}" -w '%{http_code}' -X POST --data-binary @-)
  [[ -n "${3:-}" ]] && args+=(-H "X-Vault-Token: ${3}")
  status=$(curl "${args[@]}" "${VAULT_ADDR}/v1/${1}" <<< "${2}") || {
    echo "::error::Could not reach Vault at ${1}. The wrapping token was not redeemed and stays valid until it expires; retry with 'Re-run all jobs'."
    exit 1
  }
}

# Vault answers 400 for a token that is unknown, expired or already redeemed.
rejected() {
  if [[ "${GITHUB_RUN_ATTEMPT:-1}" == "1" ]]; then
    echo "::error::Vault rejected the wrapping token on the first run attempt. Unless the wrap job finished longer ago than its wrap-ttl, someone else redeemed it: treat this as a possible interception and report the run to InfoSec."
  else
    echo "::error::Vault rejected the wrapping token. Wrapping tokens are single-use: retry with 'Re-run all jobs' so the job that wraps runs again."
  fi
  exit 1
}

# A substituted token that wraps some other response has a different creation path.
vault_post sys/wrapping/lookup "$(jq -n --arg t "${WRAP_TOKEN}" '{token: $t}')"
[[ "${status}" == 4* ]] && rejected
[[ "${status}" == 200 ]] || { echo "::error::Wrapping token lookup returned HTTP ${status}"; exit 1; }
creation_path=$(jq -r '.data.creation_path' "${body}")
if [[ "${creation_path}" != "sys/wrapping/wrap" ]]; then
  echo "::error::Wrapping token was created by '${creation_path}', expected 'sys/wrapping/wrap'"
  exit 1
fi

vault_post sys/wrapping/unwrap '{}' "${WRAP_TOKEN}"
[[ "${status}" == 4* ]] && rejected
[[ "${status}" == 200 ]] || { echo "::error::Unwrapping returned HTTP ${status}"; exit 1; }
data=$(jq -c '.data' "${body}")

mask() {
  local part="$1"
  part="${part//'%'/'%25'}"
  part="${part//$'\r'/'%0D'}"
  echo "::add-mask::${part}"
}

while IFS= read -r name; do
  # The sentinel keeps trailing newlines that command substitution would strip.
  value=$(jq -j --arg n "${name}" '.[$n]' <<< "${data}"; printf x)
  value="${value%x}"
  while IFS= read -r part || [[ -n "${part}" ]]; do
    [[ -n "${part//$'\r'/}" ]] && mask "${part}"
  done <<< "${value}"
  if [[ "${EXPORT_ENV}" == "true" ]]; then
    delim="EOF_$(openssl rand -hex 16)"
    printf '%s<<%s\n%s\n%s\n' "${name}" "${delim}" "${value}" "${delim}" >> "${GITHUB_ENV}"
  fi
done < <(jq -r 'keys[]' <<< "${data}")

delim="EOF_$(openssl rand -hex 16)"
printf 'secrets<<%s\n%s\n%s\n' "${delim}" "${data}" "${delim}" >> "${GITHUB_OUTPUT}"
echo "Unwrapped $(jq 'length' <<< "${data}") secret(s)"
