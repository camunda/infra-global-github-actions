#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${WRAP_TOKEN}" ]]; then
  echo "::error::No wrapping token given"
  exit 1
fi

# A substituted token that wraps some other response has a different creation path.
creation_path=$(jq -n --arg t "${WRAP_TOKEN}" '{token: $t}' \
  | curl -sS --fail --max-time 10 -X POST -d @- "${VAULT_ADDR}/v1/sys/wrapping/lookup" \
  | jq -r '.data.creation_path') || {
  echo "::error::Wrapping token is unknown, expired or already used"
  exit 1
}
if [[ "${creation_path}" != "sys/wrapping/wrap" ]]; then
  echo "::error::Wrapping token was created by '${creation_path}', expected 'sys/wrapping/wrap'"
  exit 1
fi

data=$(curl -sS --fail --max-time 10 -X POST -H "X-Vault-Token: ${WRAP_TOKEN}" \
  "${VAULT_ADDR}/v1/sys/wrapping/unwrap" | jq -c '.data') || {
  echo "::error::Unwrapping failed: the token was already used or has expired"
  exit 1
}

while IFS= read -r name; do
  value=$(jq -r --arg n "${name}" '.[$n]' <<< "${data}")
  while IFS= read -r part; do
    [[ -n "${part}" ]] && echo "::add-mask::${part}"
  done <<< "${value}"
  if [[ "${EXPORT_ENV}" == "true" ]]; then
    delim="EOF_$(openssl rand -hex 16)"
    printf '%s<<%s\n%s\n%s\n' "${name}" "${delim}" "${value}" "${delim}" >> "${GITHUB_ENV}"
  fi
done < <(jq -r 'keys[]' <<< "${data}")

delim="EOF_$(openssl rand -hex 16)"
printf 'secrets<<%s\n%s\n%s\n' "${delim}" "${data}" "${delim}" >> "${GITHUB_OUTPUT}"
echo "Unwrapped $(jq 'length' <<< "${data}") secret(s)"
