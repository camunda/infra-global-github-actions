#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COLLECTOR="$SCRIPT_DIR/stop-and-collect-build-monitor.sh"
VALIDATOR="$SCRIPT_DIR/validate-build-duration.sh"
RESOLVER="$SCRIPT_DIR/resolve-build-duration.sh"
TEST_DIR="$(mktemp -d)"
PID_FILE="$TEST_DIR/monitor.pid"
LOG_FILE="$TEST_DIR/monitor.log"
START_TIME_FILE="$TEST_DIR/monitor.epoch-millis"
NET_DEV_FILE="$TEST_DIR/net-dev"

cleanup() {
  if [ -n "${MONITOR_PID:-}" ]; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_line() {
  local expected_line="$1"
  local file="$2"

  grep -Fqx -- "$expected_line" "$file" || fail "Expected '$expected_line' in $file"
}

run_collection_case() {
  local name="$1"
  local start_time="$2"
  local end_time="$3"
  local expected_duration="$4"
  local output_file="$TEST_DIR/$name.output"

  cat > "$LOG_FILE" <<'EOF'
# monitor header
0.0100 0.4000
0.0200 0.3900
0.0300 0.3800
0.0400 0.3700
0.0500 0.3600
0.0600 0.3500
0.0700 0.3400
0.0800 0.3300
0.0900 0.3200
0.1000 0.3100
0.1100 0.3000
0.1200 0.2900
0.1300 0.2800
0.1400 0.2700
0.1500 0.2600
0.1600 0.2500
0.1700 0.2400
0.1800 0.2300
0.1900 0.2200
0.2000 0.2100
EOF
  sleep 60 &
  MONITOR_PID=$!
  printf '%s\n' "$MONITOR_PID" > "$PID_FILE"
  if [ "$start_time" != "missing" ]; then
    printf '%s\n' "$start_time" > "$START_TIME_FILE"
  fi

  BUILD_MONITOR_PID_FILE="$PID_FILE" \
    BUILD_MONITOR_LOG_FILE="$LOG_FILE" \
    BUILD_MONITOR_START_TIME_FILE="$START_TIME_FILE" \
  BUILD_MONITOR_NET_DEV_FILE="$NET_DEV_FILE" \
  MOCK_DATE_VALUE="$end_time" \
    PATH="$TEST_DIR:$PATH" \
    bash "$COLLECTOR" "$output_file"

  wait "$MONITOR_PID" 2>/dev/null || true
  unset MONITOR_PID

  assert_file_line "build_duration_millis=$expected_duration" "$output_file"
  assert_file_line 'monitor_fields=, "cpu_usage_ratio_avg": 0.1050, "cpu_usage_ratio_p95": 0.1900, "memory_usage_ratio_avg": 0.3050, "memory_usage_ratio_p95": 0.3900, "network_egress_bytes": 6000, "network_ingress_bytes": 4000' "$output_file"
  for monitor_file in "$PID_FILE" "$LOG_FILE" "$START_TIME_FILE"; do
    [ ! -e "$monitor_file" ] || fail "$monitor_file was not cleaned up"
  done
}

# The mock must resolve MOCK_DATE_VALUE only when the collector invokes it.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$MOCK_DATE_VALUE"' > "$TEST_DIR/date"
chmod +x "$TEST_DIR/date"

cat > "$NET_DEV_FILE" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0
  eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0
  eth1: 3000 0 0 0 0 0 0 0 4000 0 0 0 0 0 0 0
EOF

run_collection_case "valid" "199000" "200000" "1000"
run_collection_case "missing" "missing" "200000" ""
run_collection_case "non-numeric" "not-a-timestamp" "200000" ""
run_collection_case "future" "200001" "200000" ""
run_collection_case "too-long" "0" "259200001" ""

assert_validator_output() {
  local input="$1"
  local expected_output="$2"
  local output

  output=$(bash "$VALIDATOR" "$input")
  [ "$output" = "$expected_output" ] || fail "Expected '$expected_output' for '$input', got '$output'"
}

assert_validator_output "" ""
assert_validator_output "0001000" "1000"
assert_validator_output "259200000" "259200000"
for invalid_input in "-1" "invalid" "259200001"; do
  if bash "$VALIDATOR" "$invalid_input" >/dev/null 2>&1; then
    fail "Expected '$invalid_input' to fail validation"
  fi
done

assert_resolved_duration() {
  local explicit_duration="$1"
  local monitor_duration="$2"
  local expected_duration="$3"
  local resolved_duration

  resolved_duration=$(bash "$RESOLVER" "$explicit_duration" "$monitor_duration")
  [ "$resolved_duration" = "$expected_duration" ] ||
    fail "Expected resolved duration '$expected_duration', got '$resolved_duration'"
}

assert_resolved_duration "1500" "1000" "1500"
assert_resolved_duration "" "1000" "1000"

echo "All build duration tests passed"
