#!/bin/bash
# Exercises validate-permissions.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/validate-permissions.sh}"
PASS=0
FAIL=0

check() { # check <label> <expected-rc> <permissions> [expected substring]
  local label="$1" want="$2" perms="$3" needle="${4:-}"
  local out rc
  out="$("$SCRIPT" "$perms" 2>&1)"
  rc=$?

  if [[ "$rc" != "$want" ]]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — expected rc=$want, got rc=$rc"
    echo "        output: $out"
    return
  fi

  if [[ -n "$needle" ]] && ! grep -qF "$needle" <<<"$out"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — expected output to contain: $needle"
    echo "        output: $out"
    return
  fi

  PASS=$((PASS + 1))
}

check_without_jq() { # check_without_jq <label> <expected-rc> <permissions> [substring]
  local label="$1" want="$2" perms="$3" needle="${4:-}"
  local out rc
  out="$(PATH="" "$SCRIPT" "$perms" 2>&1)"
  rc=$?

  if [[ "$rc" != "$want" ]]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — expected rc=$want, got rc=$rc"
    echo "        output: $out"
    return
  fi

  if [[ -n "$needle" ]] && ! grep -qF "$needle" <<<"$out"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — expected output to contain: $needle"
    echo "        output: $out"
    return
  fi

  PASS=$((PASS + 1))
}

echo "bash $BASH_VERSION"

# Omitted or empty: the token inherits the App's permissions, as before.
check "empty input"            0 ""
check "empty object"           0 '{}'

# Accepted.
check "one scope"              0 '{"contents": "read"}'
check "several scopes"         0 '{"contents": "read", "issues": "read", "pull-requests": "write"}'
check "a dashed scope"         0 '{"organization-secrets": "read"}'

# Every scope the wrapper forwards must be accepted, or the list in the script
# has drifted from the one in the action.
all="$(jq -n --args '$ARGS.positional | map({(.): "read"}) | add' \
  actions administration artifact-metadata attestations checks codespaces contents \
  custom-properties-for-organizations dependabot-secrets deployments discussions \
  email-addresses enterprise-custom-properties-for-organizations environments followers \
  git-ssh-keys gpg-keys interaction-limits issues members merge-queues metadata \
  organization-administration organization-announcement-banners \
  organization-copilot-seat-management organization-custom-org-roles \
  organization-custom-properties organization-custom-roles organization-events \
  organization-hooks organization-packages organization-personal-access-token-requests \
  organization-personal-access-tokens organization-plan organization-projects \
  organization-secrets organization-self-hosted-runners organization-user-blocking \
  packages pages profile pull-requests repository-custom-properties repository-hooks \
  repository-projects secret-scanning-alerts secrets security-events single-file \
  starring statuses team-discussions vulnerability-alerts workflows)"
check "all 54 scopes"          0 "$all"

# Rejected. The typo case is the reason this validation exists: the wrapper
# cannot forward a scope it does not know, so without this it would be dropped
# and the caller would think the token was narrowed.
check "a misspelled scope"     1 '{"contnets": "read"}'          "unknown permission scope(s): contnets"
check "underscores not dashes" 1 '{"pull_requests": "write"}'    "unknown permission scope(s): pull_requests"
check "one good one bad"       1 '{"contents": "read", "nope": "read"}' "unknown permission scope(s): nope"
check "not JSON at all"        1 'contents=read'                 "not valid JSON"
check "a JSON array"           1 '["contents"]'                  "must be a JSON object"
check "a JSON string"          1 '"contents"'                    "must be a JSON object"

# jq is only reached once the input is non-empty, so a caller that does not use
# `permissions` needs nothing new. One that does, on a runner without jq, must
# be told that rather than that its JSON is malformed.
check_without_jq "no jq, input given"   1 '{"contents": "read"}' "needs jq"
check_without_jq "no jq, input omitted" 0 ''                     ""

echo
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" == "0" ]]
