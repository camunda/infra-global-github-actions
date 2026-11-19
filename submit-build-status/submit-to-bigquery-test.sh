#!/usr/bin/env bash
#
# Tests submit-to-bigquery.sh with a stubbed curl: no network, no credentials.
# Run: bash submit-build-status/submit-to-bigquery-test.sh

set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/submit-to-bigquery.sh"
FAILURES=0
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# The row every test job submits without tool_installs; report_time is masked as REPORT_TIME.
BASE_ROW='"report_time": "REPORT_TIME", "ci_url": "https://github.com/camunda/example", "workflow_name": "CI", "workflow_ref": ".github/workflows/ci.yml", "job_name": "build", "build_id": "100/1", "build_trigger": "pull_request", "build_status": "success", "build_ref": "refs/pull/1/merge", "runner_name": "gha-runner-1", "runner_arch": "x64", "runner_os": "linux", "job_id": "4242", "build_base_ref": "refs/heads/main", "build_duration_milliseconds": "1000"'
MONITOR_ROW_FIELDS=', "network_egress_bytes": 10, "network_ingress_bytes": 20'
# The insertAll payload of that row.
PAYLOAD_WITHOUT_TOOL_INSTALLS="{\"rows\": [{\"json\": {$BASE_ROW$MONITOR_ROW_FIELDS}}]}"
# Exported for the stub curl.
export SUCCESS_RESPONSE='{"kind": "bigquery#tableDataInsertAllResponse"}'
INSERT_ERRORS='{"kind": "bigquery#tableDataInsertAllResponse", "insertErrors": [{"index": 0, "errors": [{"reason": "invalid", "location": "tool_installs", "message": "Invalid JSON"}]}]}'

# Print the number of requests the stub curl received.
payload_count() {
  find "$SANDBOX" -maxdepth 1 -name 'payload-*' | wc -l | tr -d ' '
}

# Run the script in a fresh sandbox. Sets $SANDBOX, $OUTPUT and $STATUS.
# $TOOL_INSTALLS_CONTENT, when set, is written to the tool installs file, with mode $TOOL_INSTALLS_MODE if set.
# The stub curl saves the payload of call N, given as an argument or on stdin (@-), to $SANDBOX/payload-N and answers with
# $STUB_TOOL_INSTALLS_RESPONSE when that payload carries tool_installs, else with $SUCCESS_RESPONSE.
# $STUB_CURL_EXIT makes every call fail like curl -f on an HTTP error, and
# $STUB_TOOL_INSTALLS_CURL_EXIT only the calls whose payload carries tool_installs.
run_script() {
  SANDBOX=$(mktemp -d "$WORK_DIR/run.XXXXXX")
  mkdir -p "$SANDBOX/bin" "$SANDBOX/runner-temp"
  cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(payload_count) + 1 ))
while [ $# -gt 0 ]; do
  case "$1" in
    -d | --data-binary)
      if [ "$2" = @- ]; then cat > "$SANDBOX/payload-$n"; else printf '%s' "$2" > "$SANDBOX/payload-$n"; fi
      shift ;;
  esac
  shift
done
[ -z "${STUB_CURL_EXIT:-}" ] || exit "$STUB_CURL_EXIT"
if grep -q '"tool_installs"' "$SANDBOX/payload-$n"; then
  [ -z "${STUB_TOOL_INSTALLS_CURL_EXIT:-}" ] || exit "$STUB_TOOL_INSTALLS_CURL_EXIT"
  printf '%s' "$STUB_TOOL_INSTALLS_RESPONSE"
else
  printf '%s' "$SUCCESS_RESPONSE"
fi
EOF
  chmod +x "$SANDBOX/bin/curl"
  OUTPUT=$(
    export -f payload_count
    export SANDBOX STUB_CURL_EXIT="${STUB_CURL_EXIT:-}" STUB_TOOL_INSTALLS_CURL_EXIT="${STUB_TOOL_INSTALLS_CURL_EXIT:-}"
    export STUB_TOOL_INSTALLS_RESPONSE="${STUB_TOOL_INSTALLS_RESPONSE:-$SUCCESS_RESPONSE}"
    export PATH="$SANDBOX/bin:$PATH"
    export RUNNER_TEMP="$SANDBOX/runner-temp"
    export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=camunda/example
    export GITHUB_WORKFLOW=CI GITHUB_WORKFLOW_REF=camunda/example/.github/workflows/ci.yml@refs/pull/1/merge
    export GITHUB_JOB=build GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_EVENT_NAME=pull_request
    export GITHUB_REF=refs/pull/1/merge RUNNER_NAME=GHA-Runner-1 RUNNER_ARCH=X64 RUNNER_OS=Linux
    export BUILD_STATUS=success JOB_NAME_OVERRIDE='' USER_REASON='' USER_DESCRIPTION=''
    export BIG_QUERY_TABLE_NAME='test-project:test_dataset.build_status_v2'
    export BUILD_BASE_REF=refs/heads/main BUILD_HEAD_REF='' BUILD_DURATION_MILLIS=1000
    export MONITOR_FIELDS="$MONITOR_ROW_FIELDS" ACCESS_TOKEN=token JOB_ID=4242
    export RUNNER_INFO_RUNS_ON_FILE="$SANDBOX/no-runs-on-file"
    if [ -n "${TOOL_INSTALLS_CONTENT+set}" ]; then
      mkdir -p "$RUNNER_TEMP/ci-analytics"
      printf '%s' "$TOOL_INSTALLS_CONTENT" > "$RUNNER_TEMP/ci-analytics/tool-installs.jsonl"
      [ -z "${TOOL_INSTALLS_MODE:-}" ] || chmod "$TOOL_INSTALLS_MODE" "$RUNNER_TEMP/ci-analytics/tool-installs.jsonl"
    fi
    # $BASH: running this test with an older Bash also runs the script with it.
    "$BASH" "$SCRIPT" 2>&1
  )
  STATUS=$?
}

# Print payload N with its report_time masked.
payload() {
  sed -E 's/"report_time": "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}"/"report_time": "REPORT_TIME"/' "$SANDBOX/payload-$1"
}

assert_eq() {
  if [ "$2" != "$3" ]; then
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains() {
  case "$3" in
    *"$2"*) ;;
    *) printf 'FAIL: %s\n  expected to contain: %s\n  actual: %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)) ;;
  esac
}

assert_not_contains() {
  case "$3" in
    *"$2"*) printf 'FAIL: %s\n  expected not to contain: %s\n  actual: %s\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)) ;;
  esac
}

test_without_file_the_row_is_unchanged() {
  unset TOOL_INSTALLS_CONTENT
  run_script
  assert_eq "no file: exit status" 0 "$STATUS"
  assert_eq "no file: one request" 1 "$(payload_count)"
  assert_eq "no file: row" "$PAYLOAD_WITHOUT_TOOL_INSTALLS" "$(payload 1)"
  assert_not_contains "no file: no warning" "::warning::" "$OUTPUT"
}

test_valid_file_adds_its_lines_as_a_json_array() {
  # Two runs of infra-tools in one job, a blank line between them, and a value with JSON escapes.
  TOOL_INSTALLS_CONTENT='{"tool":"java","version":"21.0.12+101.0.LTS","size_bytes":201326592}

{"tool":"maven","note":"a \"quoted\" back\\slash"}
'
  run_script
  assert_eq "valid file: exit status" 0 "$STATUS"
  assert_eq "valid file: one request" 1 "$(payload_count)"
  # A JSON column takes a JSON-encoded string in insertAll, so the array is escaped once more.
  local tool_installs='"[{\"tool\":\"java\",\"version\":\"21.0.12+101.0.LTS\",\"size_bytes\":201326592},{\"tool\":\"maven\",\"note\":\"a \\\"quoted\\\" back\\\\slash\"}]"'
  assert_eq "valid file: row" "{\"rows\": [{\"json\": {$BASE_ROW, \"tool_installs\": $tool_installs$MONITOR_ROW_FIELDS}}]}" "$(payload 1)"
  assert_not_contains "valid file: no warning" "::warning::" "$OUTPUT"
}

test_rejected_tool_installs_resend_the_row_without_them() {
  TOOL_INSTALLS_CONTENT='{"tool":"java","version":
'
  STUB_TOOL_INSTALLS_RESPONSE="$INSERT_ERRORS"
  run_script
  unset STUB_TOOL_INSTALLS_RESPONSE
  assert_eq "malformed line: exit status" 0 "$STATUS"
  assert_eq "malformed line: two requests" 2 "$(payload_count)"
  assert_contains "malformed line: first request carries tool_installs" '"tool_installs": "[{\"tool\":\"java\",\"version\":]"' "$(payload 1)"
  assert_eq "malformed line: second request is the row without tool_installs" "$PAYLOAD_WITHOUT_TOOL_INSTALLS" "$(payload 2)"
  assert_contains "malformed line: warning" "::warning::" "$OUTPUT"
}

test_file_larger_than_one_argument_is_submitted() {
  # Linux caps one command-line argument at 128 KiB (MAX_ARG_STRLEN), so the payload must not be one.
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    # Bash 3's ${s//...} takes minutes on this much text. infra-tools writes the file only on Linux runners.
    echo "SKIP: large file: Bash $BASH_VERSION is too slow for it"
    return
  fi
  local i
  TOOL_INSTALLS_CONTENT=$(for i in $(seq 1 2000); do printf '{"tool":"tool-%s","selector":"tool-%s@1","outcome":"installed"}\n' "$i" "$i"; done)
  run_script
  assert_eq "large file: exit status" 0 "$STATUS"
  assert_eq "large file: one request" 1 "$(payload_count)"
  assert_contains "large file: row carries the last line" '{\"tool\":\"tool-2000\",\"selector\":\"tool-2000@1\",\"outcome\":\"installed\"}]"' "$(payload 1)"
  assert_not_contains "large file: no warning" "::warning::" "$OUTPUT"
}

test_unreadable_file_sends_the_row_without_tool_installs() {
  local probe="$WORK_DIR/unreadable-probe"
  : > "$probe" && chmod 000 "$probe"
  if [ -r "$probe" ]; then
    echo "SKIP: unreadable file: this user (root?) reads files with mode 000"
    return
  fi
  TOOL_INSTALLS_CONTENT='{"tool":"java"}
'
  TOOL_INSTALLS_MODE=000
  run_script
  unset TOOL_INSTALLS_MODE
  assert_eq "unreadable file: exit status" 0 "$STATUS"
  assert_eq "unreadable file: one request" 1 "$(payload_count)"
  assert_eq "unreadable file: row" "$PAYLOAD_WITHOUT_TOOL_INSTALLS" "$(payload 1)"
  assert_contains "unreadable file: warning" "::warning::" "$OUTPUT"
}

test_empty_file_leaves_the_row_unchanged() {
  for content in '' '

'; do
    TOOL_INSTALLS_CONTENT="$content"
    run_script
    assert_eq "empty file: exit status" 0 "$STATUS"
    assert_eq "empty file: one request" 1 "$(payload_count)"
    assert_eq "empty file: row" "$PAYLOAD_WITHOUT_TOOL_INSTALLS" "$(payload 1)"
    assert_not_contains "empty file: no warning" "::warning::" "$OUTPUT"
  done
}

test_http_error_without_tool_installs_fails_the_step() {
  unset TOOL_INSTALLS_CONTENT
  STUB_CURL_EXIT=22
  run_script
  unset STUB_CURL_EXIT
  assert_eq "HTTP error without tool_installs: exit status" 22 "$STATUS"
  assert_eq "HTTP error without tool_installs: one request" 1 "$(payload_count)"
}

test_http_error_with_tool_installs_resends_the_row_without_them() {
  TOOL_INSTALLS_CONTENT='{"tool":"java"}
'
  STUB_TOOL_INSTALLS_CURL_EXIT=22
  run_script
  unset STUB_TOOL_INSTALLS_CURL_EXIT
  assert_eq "HTTP error with tool_installs: exit status" 0 "$STATUS"
  assert_eq "HTTP error with tool_installs: two requests" 2 "$(payload_count)"
  assert_contains "HTTP error with tool_installs: first request carries tool_installs" '"tool_installs"' "$(payload 1)"
  assert_eq "HTTP error with tool_installs: second request is the row without tool_installs" "$PAYLOAD_WITHOUT_TOOL_INSTALLS" "$(payload 2)"
  assert_contains "HTTP error with tool_installs: warning" "::warning::" "$OUTPUT"
}

test_http_error_on_the_resend_fails_the_step() {
  TOOL_INSTALLS_CONTENT='{"tool":"java"}
'
  STUB_CURL_EXIT=22
  run_script
  unset STUB_CURL_EXIT
  assert_eq "HTTP error on the resend: exit status" 22 "$STATUS"
  assert_eq "HTTP error on the resend: two requests" 2 "$(payload_count)"
  assert_contains "HTTP error on the resend: warning" "::warning::" "$OUTPUT"
}

test_without_file_the_row_is_unchanged
test_valid_file_adds_its_lines_as_a_json_array
test_rejected_tool_installs_resend_the_row_without_them
test_file_larger_than_one_argument_is_submitted
test_unreadable_file_sends_the_row_without_tool_installs
test_empty_file_leaves_the_row_unchanged
test_http_error_without_tool_installs_fails_the_step
test_http_error_with_tool_installs_resends_the_row_without_them
test_http_error_on_the_resend_fails_the_step

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES assertion(s) failed"
  exit 1
fi
echo "All tests passed"
