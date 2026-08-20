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

# The scopes come from the forwarding block in action.yml, so there is no second
# list to keep in step — but the parsing of that block is now load-bearing, and
# these cover it.
ACTION_YML="${ACTION_YML:-$HERE/action.yml}"

forwarded="$(grep -oE '^ +permission-[a-z-]+: \$\{\{' "$ACTION_YML" | sed 's/.*permission-//; s/:.*//' | sort)"
forwarded_count="$(printf '%s\n' "$forwarded" | grep -c .)"

if [[ "$forwarded_count" -lt 10 ]]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: forwarding block — found $forwarded_count scopes in $ACTION_YML"
else
  PASS=$((PASS + 1))
fi

# Every scope the action forwards must be accepted, built from that same block
# so the fixture cannot drift from it.
all="$(jq -Rn '[inputs] | map({(.): "read"}) | add' <<<"$forwarded")"
all_count="$(jq -r 'length' <<<"${all:-null}" 2>/dev/null || echo 0)"

if [[ "$all_count" != "$forwarded_count" || "$all_count" == "0" ]]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: all-scopes fixture — built $all_count keys from $forwarded_count scopes (is jq working?)"
else
  check "every forwarded scope" 0 "$all"
fi

# A scope added to action.yml is accepted without touching this script, which is
# the point of reading the block rather than restating it.
added="$(mktemp)"
cp "$ACTION_YML" "$added"
printf "      permission-brand-new: \${{ fromJSON(inputs.permissions || '{}')['brand-new'] }}\n" >>"$added"
out="$(ACTION_YML="$added" "$SCRIPT" '{"brand-new": "read"}' 2>&1)"; rc=$?
if [[ "$rc" != "0" ]]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: a scope added to action.yml — expected it to be accepted, got rc=$rc: $out"
else
  PASS=$((PASS + 1))
fi
out="$("$SCRIPT" '{"brand-new": "read"}' 2>&1)"; rc=$?
if [[ "$rc" != "1" ]]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: that same scope against the real action.yml — expected rejection, got rc=$rc"
else
  PASS=$((PASS + 1))
fi
rm -f "$added"

# The block moving or changing shape must be an error about this repository, not
# a rejection blamed on the caller.
empty="$(mktemp)"
printf 'name: nothing here\n' >"$empty"
out="$(ACTION_YML="$empty" "$SCRIPT" '{"contents": "read"}' 2>&1)"; rc=$?
if [[ "$rc" != "1" ]] || ! grep -qF "the forwarding block has moved or changed shape" <<<"$out"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: a shapeless action.yml — expected a shape error, got rc=$rc: $out"
else
  PASS=$((PASS + 1))
fi
out="$(ACTION_YML="$empty/nope" "$SCRIPT" '{"contents": "read"}' 2>&1)"; rc=$?
if [[ "$rc" != "1" ]] || ! grep -qF "cannot read" <<<"$out"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: an unreadable action.yml — expected a read error, got rc=$rc: $out"
else
  PASS=$((PASS + 1))
fi
rm -f "$empty"

# Rejected. The typo case is the reason this validation exists: the wrapper
# cannot forward a scope it does not know, so without this it would be dropped
# and the caller would think the token was narrowed.
check "a misspelled scope"     1 '{"contnets": "read"}'          "unknown permission scope(s): contnets"
check "underscores not dashes" 1 '{"pull_requests": "write"}'    "unknown permission scope(s): pull_requests"
check "one good one bad"       1 '{"contents": "read", "nope": "read"}' "unknown permission scope(s): nope"
# An unknown key that is the empty string joins to "", which reads as "nothing
# unknown" if the check tests the joined string instead of counting.
check "an empty key"           1 '{"": "read"}'                  "unknown permission scope(s): (empty)"
check "an empty key among good ones" 1 '{"contents": "read", "": "read"}' "(empty)"
check "not JSON at all"        1 'contents=read'                 "not valid JSON"
check "a JSON array"           1 '["contents"]'                  "must be a JSON object"
check "a JSON string"          1 '"contents"'                    "must be a JSON object"

# Values. This checks the level set, not what each individual scope accepts:
# upstream documents finer limits per scope — 45 take read or write, 4 also take
# admin, 3 take only write, 2 only read — and encoding that here would mean
# parsing English out of upstream's action.yml on every run.
check "write and admin"        0 '{"contents": "write", "repository-projects": "admin"}'
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
