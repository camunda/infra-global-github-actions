#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
  echo "::error::No GitHub OIDC token available: grant 'id-token: write' to this job"
  exit 1
fi

audience=$(jq -rn --arg a "${JWT_AUDIENCE}" '$a | @uri')
oidc=$(curl -sS --fail --max-time 10 -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience}" | jq -r '.value')
echo "::add-mask::${oidc}"

token=$(jq -n --arg role "${JWT_ROLE}" --arg jwt "${oidc}" '{role: $role, jwt: $jwt}' \
  | curl -sS --fail --max-time 10 -X POST -d @- "${VAULT_ADDR}/v1/auth/${JWT_PATH}/login" \
  | jq -r '.auth.client_token')
echo "::add-mask::${token}"

payload='{}'
while IFS= read -r line; do
  line="${line%%;*}"
  [[ -z "${line//[[:space:]]/}" ]] && continue
  if [[ ! "${line}" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]+([^[:space:]|]+)[[:space:]]*\|[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$ ]]; then
    echo "::error::Cannot parse secrets line '${line}', expected '<path> <key> | <NAME>'"
    exit 1
  fi
  path="${BASH_REMATCH[1]}" key="${BASH_REMATCH[2]}" name="${BASH_REMATCH[3]}"
  # Keep the value JSON-encoded so trailing newlines survive.
  value_json=$(curl -sS --fail --max-time 10 -H "X-Vault-Token: ${token}" "${VAULT_ADDR}/v1/${path}" \
    | jq -ec --arg k "${key}" 'if (.data.data | has($k)) then .data.data[$k] else error("missing") end') || {
    echo "::error::Key '${key}' not found at '${path}'"
    exit 1
  }
  payload=$(jq -c --arg n "${name}" --argjson v "${value_json}" '. + {($n): $v}' <<< "${payload}")
done <<< "${SECRETS}"

if [[ -n "${VALUES:-}" ]]; then
  if ! jq -e 'type == "object" and all(.[]; type == "string")' <<< "${VALUES}" > /dev/null; then
    echo "::error::'values' must be a JSON object of strings"
    exit 1
  fi
  payload=$(jq -c --argjson extra "${VALUES}" '. + $extra' <<< "${payload}")
fi

if [[ "${payload}" == '{}' ]]; then
  echo "::error::No secrets to wrap"
  exit 1
fi

wrap_token=$(curl -sS --fail --max-time 10 -X POST -H "X-Vault-Token: ${token}" -H "X-Vault-Wrap-TTL: ${WRAP_TTL}" \
  -d "${payload}" "${VAULT_ADDR}/v1/sys/wrapping/wrap" | jq -r '.wrap_info.token')
if [[ -z "${wrap_token}" || "${wrap_token}" == "null" ]]; then
  echo "::error::Vault returned no wrapping token"
  exit 1
fi
echo "wrap-token=${wrap_token}" >> "${GITHUB_OUTPUT}"
echo "Wrapped $(jq 'length' <<< "${payload}") secret(s), TTL ${WRAP_TTL}"
