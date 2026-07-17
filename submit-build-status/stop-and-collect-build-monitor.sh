#!/usr/bin/env bash

OUTPUT_FILE="$1"
if [ -z "$OUTPUT_FILE" ]; then
  echo "Usage: $0 <output-file>" >&2
  exit 1
fi

MONITOR_FIELDS=""
# NOTE: these paths are shared with start-build-monitor.sh -- if changed, update both
PID_FILE="${BUILD_MONITOR_PID_FILE:-/tmp/_monitor-start.pid}"
LOG_FILE="${BUILD_MONITOR_LOG_FILE:-/tmp/_monitor-start.log}"
START_TIME_FILE="${BUILD_MONITOR_START_TIME_FILE:-/tmp/_monitor-start.epoch-millis}"
NET_DEV_FILE="${BUILD_MONITOR_NET_DEV_FILE:-/proc/net/dev}"
MAX_BUILD_DURATION_MILLIS=259200000  # 72 hours
BUILD_DURATION_MILLIS=""

is_valid_timestamp() {
  [[ "$1" =~ ^[0-9]{1,18}$ ]]
}

if [ -f "$START_TIME_FILE" ]; then
  START_TIME_MILLIS=$(cat "$START_TIME_FILE")
  END_TIME_MILLIS=$(date +%s%3N)
  if is_valid_timestamp "$START_TIME_MILLIS" && is_valid_timestamp "$END_TIME_MILLIS"; then
    BUILD_DURATION_MILLIS=$((10#$END_TIME_MILLIS - 10#$START_TIME_MILLIS))
    if [ "$BUILD_DURATION_MILLIS" -ge 0 ] && [ "$BUILD_DURATION_MILLIS" -le "$MAX_BUILD_DURATION_MILLIS" ]; then
      echo "Build duration: ${BUILD_DURATION_MILLIS}ms"
    else
      echo "Build duration is outside the supported range (0-${MAX_BUILD_DURATION_MILLIS}ms); duration omitted" >&2
      BUILD_DURATION_MILLIS=""
    fi
  else
    echo "Build start or end timestamp is invalid; duration omitted" >&2
  fi
else
  echo "Build start timestamp not found; duration omitted" >&2
fi

if [ -f "$PID_FILE" ]; then
  MONITOR_PID=$(cat "$PID_FILE")
  kill "$MONITOR_PID" 2>/dev/null || true
  echo "Resource monitor stopped (PID=$MONITOR_PID)"

  if [ -f "$LOG_FILE" ]; then
    echo "Raw monitor log values (CPU, memory usage ratio) per interval:"
    echo "::group::Resource monitor raw log"
    cat "$LOG_FILE"
    echo "::endgroup::"

    # Parse monitor log: header lines start with '#', data lines are "cpu_ratio mem_ratio".
    # Both are already 0-1 ratios computed in start-build-monitor.
    read -r AVG_CPU CPU_MAX P90_CPU P95_CPU AVG_MEM MEM_MAX P90_MEM P95_MEM COUNT < <(
      awk '
        function ceil(x) { return (x == int(x)) ? x : int(x) + 1 }
        function sort_num(a, n,   i,j,tmp) {
          for (i = 1; i <= n; i++)
            for (j = i + 1; j <= n; j++)
              if (a[i] > a[j]) { tmp = a[i]; a[i] = a[j]; a[j] = tmp }
        }
        function pctile(sorted, n, p,   idx) {
          idx = ceil(p * n)
          if (idx < 1) idx = 1
          if (idx > n) idx = n
          return sorted[idx]
        }
        /^#/   { next }
        NF < 2 { next }
        {
          cv = $1 + 0; mv = $2 + 0
          if (cv < 0) cv = 0; if (cv > 1) cv = 1
          if (mv < 0) mv = 0; if (mv > 1) mv = 1
          cpu_sum += cv; mem_sum += mv; count++
          cpu[count] = cv; mem[count] = mv
          if (count == 1 || cv > cpu_max) cpu_max = cv
          if (count == 1 || mv > mem_max) mem_max = mv
        }
        END {
          if (count > 0) {
            sort_num(cpu, count); sort_num(mem, count)
            printf "%.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %d\n",
              cpu_sum/count, cpu_max, pctile(cpu,count,0.90), pctile(cpu,count,0.95),
              mem_sum/count, mem_max, pctile(mem,count,0.90), pctile(mem,count,0.95),
              count
          }
        }
      ' "$LOG_FILE"
    ) || true  # read returns 1 when awk produces no output (empty log); || true prevents set -e from killing the step

    if [ -n "$COUNT" ] && [ "$COUNT" -gt 0 ]; then
      read -r _ac _cm _p90c _p95c _am _mm _p90m _p95m < <(awk "BEGIN {printf \"%.1f %.1f %.1f %.1f %.1f %.1f %.1f %.1f\\n\", $AVG_CPU*100,$CPU_MAX*100,$P90_CPU*100,$P95_CPU*100,$AVG_MEM*100,$MEM_MAX*100,$P90_MEM*100,$P95_MEM*100}") || true
      echo "CPU: avg=${_ac}%, p90=${_p90c}%, p95=${_p95c}%, max=${_cm}%  |  Mem: avg=${_am}%, p90=${_p90m}%, p95=${_p95m}%, max=${_mm}%  (${COUNT} samples)"
      MONITOR_FIELDS=$(printf ', "cpu_usage_ratio_avg": %s, "cpu_usage_ratio_p95": %s, "memory_usage_ratio_avg": %s, "memory_usage_ratio_p95": %s' \
        "$AVG_CPU" "$P95_CPU" "$AVG_MEM" "$P95_MEM")
    else
      echo "Resource monitor log had no data rows -- metrics omitted"
    fi
  else
    echo "Resource monitor log not found -- metrics omitted" >&2
  fi
fi

# Remove monitor state only after the log and start timestamp have been collected.
rm -f "$PID_FILE" "$LOG_FILE" "$START_TIME_FILE"

# ── Network bytes: cumulative tx/rx summed across non-loopback interfaces. ──
# Runner pods are ephemeral (one job per pod), so the counters span the job;
# on long-lived runners they are cumulative since interface-up.
TX_BYTES=""; RX_BYTES=""
if [ -r "$NET_DEV_FILE" ]; then
  read -r TX_BYTES RX_BYTES < <(
    awk -F'[: ]+' '
      NR > 2 && $2 != "lo" { rx += $3 + 0; tx += $11 + 0 }
      END { printf "%.0f %.0f\n", tx, rx }
    ' "$NET_DEV_FILE"
  ) || true
  if [ -n "$TX_BYTES" ]; then
    echo "Network: egress=${TX_BYTES}B, ingress=${RX_BYTES}B"
    MONITOR_FIELDS=$(printf '%s, "network_egress_bytes": %s, "network_ingress_bytes": %s' \
      "$MONITOR_FIELDS" "$TX_BYTES" "$RX_BYTES")
  fi
fi

printf 'monitor_fields=%s\n' "$MONITOR_FIELDS" >> "$OUTPUT_FILE"
printf 'build_duration_millis=%s\n' "$BUILD_DURATION_MILLIS" >> "$OUTPUT_FILE"
