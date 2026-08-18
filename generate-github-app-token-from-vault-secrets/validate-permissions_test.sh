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

# The scopes the action forwards and the scopes the script accepts are two lists
# that must stay equal. Both are read from the files themselves: a fixture typed
# out here would only ever compare itself against one of them, and would go
# green while action.yml forwarded a scope the validator rejects.
ACTION_YML="${ACTION_YML:-$HERE/action.yml}"

forwarded="$(grep -oE '^      permission-[a-z-]+:' "$ACTION_YML" | sed 's/ *permission-//; s/://' | sort)"
accepted="$(sed -n '/^KNOWN_SCOPES=(/,/^)/p' "$SCRIPT" | grep -oE '^  [a-z-]+$' | tr -d ' ' | sort)"

if [[ -z "$forwarded" || -z "$accepted" ]]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: scope lists — could not read them (action.yml: $(wc -w <<<"$forwarded"), script: $(wc -w <<<"$accepted"))"
elif [[ "$forwarded" != "$accepted" ]]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: scope lists — action.yml and the validator disagree:"
  diff <(echo "$forwarded") <(echo "$accepted") | sed 's/^/        /'
else
  PASS=$((PASS + 1))
fi

# Every scope the action forwards must be accepted, built from that same list so
# it cannot drift from it.
all="$(jq -Rn '[inputs] | map({(.): "read"}) | add' <<<"$forwarded")"
all_count="$(jq -r 'length' <<<"${all:-null}" 2>/dev/null || echo 0)"

if [[ "$all_count" != "$(wc -l <<<"$forwarded" | tr -d ' ')" || "$all_count" == "0" ]]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: all-scopes fixture — built $all_count keys from $(wc -l <<<"$forwarded" | tr -d ' ') scopes (is jq working?)"
else
  check "every forwarded scope" 0 "$all"
fi

# Rejected. The typo case is the reason this validation exists: the wrapper
# cannot forward a scope it does not know, so without this it would be dropped
# and the caller would think the token was narrowed.
check "a misspelled scope"     1 '{"contnets": "read"}'          "unknown permission scope(s): contnets"
check "underscores not dashes" 1 '{"pull_requests": "write"}'    "unknown permission scope(s): pull_requests"
check "one good one bad"       1 '{"contents": "read", "nope": "read"}' "unknown permission scope(s): nope"
check "not JSON at all"        1 'contents=read'                 "not valid JSON"
check "a JSON array"           1 '["contents"]'                  "must be a JSON object"
check "a JSON string"          1 '"contents"'                    "must be a JSON object"

# Values. Which levels a scope accepts is upstream's business; that they are one
# of the three, and a string, is checkable here instead of after Vault has been
# read and a token requested.
check "write and admin"        0 '{"contents": "write", "organization-administration": "admin"}'
check "uppercase value"        0 '{"contents": "READ"}'
check "a misspelled value"     1 '{"contents": "raed"}'          "must be read, write or admin: contents=raed"
check "a numeric value"        1 '{"contents": 1}'               "contents=1"
check "a null value"           1 '{"contents": null}'            "contents=null"
check "a nested object"        1 '{"contents": {"level": "read"}}'

# jq is only reached once the input is non-empty, so a caller that does not use
# `permissions` needs nothing new. One that does, on a runner without jq, must
# be told that rather than that its JSON is malformed.
check_without_jq "no jq, input given"   1 '{"contents": "read"}' "needs jq"
check_without_jq "no jq, input omitted" 0 ''                     ""

# The runner reads workflow commands line by line, so anything echoed into a
# `::error::` line must not be able to open a second one.
check_single_annotation() { # check_single_annotation <label> <permissions>
  local label="$1" perms="$2"
  local out n
  out="$("$SCRIPT" "$perms" 2>&1)"
  n="$(grep -c '^::' <<<"$out")"

  if [[ "$n" != "1" ]]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — expected 1 workflow command, got $n"
    echo "        output: $out"
    return
  fi

  PASS=$((PASS + 1))
}

check_single_annotation "a newline in a malformed input" '{"a": 1}
::error::INJECTED'
check_single_annotation "a newline in an unknown scope key" '{"nope\ntwo::three": "read"}'

echo
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" == "0" ]]
