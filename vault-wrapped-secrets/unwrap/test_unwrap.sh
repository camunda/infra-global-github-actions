#!/usr/bin/env bash
# Unit tests for unwrap.sh error handling, with curl stubbed per Vault endpoint.
# Each stub answer is "<http status>" or "fail" (curl transport error).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"

cat > "${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-X|-H|--max-time|--data-binary) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
cat > /dev/null
case "${url}" in
  */sys/wrapping/lookup) answer="${STUB_LOOKUP}"; body='{"data":{"creation_path":"sys/wrapping/wrap"}}' ;;
  */sys/wrapping/unwrap) answer="${STUB_UNWRAP}"; body='{"data":{"NAME":"value"}}' ;;
  *) echo "unexpected URL ${url}" >&2; exit 2 ;;
esac
if [[ "${answer}" == fail ]]; then
  echo "curl: (28) Operation timed out" >&2
  exit 28
fi
[[ "${answer}" == 200 ]] && printf '%s' "${body}" > "${out}" || printf '{"errors":["stub"]}' > "${out}"
printf '%s' "${answer}"
STUB
chmod +x "${work}/bin/curl"

failures=0

# check <name> <lookup answer> <unwrap answer> <run attempt> <expected exit> <expected message part>
check() {
  local name="$1" lookup="$2" unwrap="$3" attempt="$4" want_exit="$5" want_msg="$6" out rc
  : > "${work}/output"; : > "${work}/env"
  out=$(PATH="${work}/bin:${PATH}" STUB_LOOKUP="${lookup}" STUB_UNWRAP="${unwrap}" \
    GITHUB_RUN_ATTEMPT="${attempt}" GITHUB_OUTPUT="${work}/output" GITHUB_ENV="${work}/env" \
    VAULT_ADDR="https://vault.invalid" WRAP_TOKEN="hvs.test" EXPORT_ENV="false" \
    bash "${here}/unwrap.sh" 2>&1)
  rc=$?
  if [[ "${rc}" != "${want_exit}" || "${out}" != *"${want_msg}"* ]]; then
    echo "FAIL ${name}: exit ${rc} (want ${want_exit}), output:"
    printf '    %s\n' "${out//$'\n'/$'\n'    }"
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
  if [[ "${out}" != *"::add-mask::hvs.test"* ]]; then
    echo "FAIL ${name}: wrapping token not masked"
    failures=$((failures + 1))
  fi
}

check "success"                       200  200  1 0 "Unwrapped 1 secret(s)"
check "lookup transport failure"      fail 200  1 1 "The wrapping token was not redeemed"
check "unwrap transport failure"      200  fail 1 1 "it is unknown whether the wrapping token was redeemed"
check "lookup 400, first attempt"     400  200  1 1 "possible interception"
check "lookup 400, rerun"             400  200  2 1 "Wrapping tokens are single-use"
check "unwrap 400, first attempt"     200  400  1 1 "possible interception"
check "unwrap 400, rerun"             200  400  2 1 "Wrapping tokens are single-use"
check "lookup 404 is not a rejection" 404  200  1 1 "Wrapping token lookup returned HTTP 404"
check "unwrap 429 is not a rejection" 200  429  1 1 "Unwrapping returned HTTP 429"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} check(s) failed"
  exit 1
fi
