#!/usr/bin/env bash

INTERVAL=5  # seconds
# NOTE: these paths are shared with the monitor stop script(s) — if changed, update both
LOG_FILE=/tmp/_monitor-start.log
PID_FILE=/tmp/_monitor-start.pid

# CPU and memory cgroup controllers are independently enabled, so detect them separately.
# Cgroup-based metrics are scoped to this container — unaffected by other pods on the node.

# CPU source
if [ -f /sys/fs/cgroup/cpu.stat ]; then
  CPU_SOURCE="cgroupv2"
elif [ -f /sys/fs/cgroup/cpuacct/cpuacct.usage ]; then
  CPU_SOURCE="cgroupv1"
else
  CPU_SOURCE="proc"
fi

# Memory source
if [ -f /sys/fs/cgroup/memory.current ]; then
  MEM_SOURCE="cgroupv2"
elif [ -f /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
  MEM_SOURCE="cgroupv1"
else
  MEM_SOURCE="proc"
fi

# CPU limit in cores — used to express usage as % of the container's allocation.
CPU_LIMIT_CORES=$(nproc)
if [ "$CPU_SOURCE" = "cgroupv2" ] && [ -f /sys/fs/cgroup/cpu.max ]; then
  read -r _QUOTA _PERIOD < /sys/fs/cgroup/cpu.max
  if [ "${_QUOTA:-max}" != "max" ] && [ "${_PERIOD:-0}" -gt 0 ] 2>/dev/null; then
    CPU_LIMIT_CORES=$(awk "BEGIN {printf \"%.4f\", $_QUOTA / $_PERIOD}")
  fi
elif [ "$CPU_SOURCE" = "cgroupv1" ]; then
  _QUOTA=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo -1)
  _PERIOD=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo 100000)
  if [ "$_QUOTA" != "-1" ] && [ "$_QUOTA" -gt 0 ] 2>/dev/null; then
    CPU_LIMIT_CORES=$(awk "BEGIN {printf \"%.4f\", $_QUOTA / $_PERIOD}")
  fi
fi

# Memory total in kB — Cgroup limit gives the container's budget; /proc/meminfo fallback for bare VMs.
CGROUP_MEM_BYTES=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo "max")
if [ "$CGROUP_MEM_BYTES" != "max" ] && [ "$CGROUP_MEM_BYTES" -gt 0 ] 2>/dev/null; then
  MEM_TOTAL_KB=$(( CGROUP_MEM_BYTES / 1024 ))
else
  MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
fi

INTERVAL_US=$(( INTERVAL * 1000000 ))

(
  echo "# cpu_source=${CPU_SOURCE} mem_source=${MEM_SOURCE} cpu_limit_cores=${CPU_LIMIT_CORES} mem_total_kb=${MEM_TOTAL_KB} interval=${INTERVAL}"

  # Seed the initial CPU counter before the first sleep
  case "$CPU_SOURCE" in
    cgroupv2) PREV_CPU=$(awk '/^usage_usec/ {print $2}' /sys/fs/cgroup/cpu.stat) ;;
    cgroupv1) PREV_CPU=$(( $(cat /sys/fs/cgroup/cpuacct/cpuacct.usage) / 1000 )) ;;  # ns → us
    proc)     read -r PREV_IDLE PREV_TOTAL < <(awk '/^cpu / {idle=$5; tot=0; for(i=2;i<=NF;i++) tot+=$i; print idle, tot}' /proc/stat) ;;
  esac

  while true; do
    sleep "$INTERVAL"

    # CPU: delta of the cgroup cumulative counter, expressed as ratio of container allocation.
    # Bare-VM fallback uses /proc/stat jiffies (aggregate across all host cores).
    case "$CPU_SOURCE" in
      cgroupv2)
        CURR_CPU=$(awk '/^usage_usec/ {print $2}' /sys/fs/cgroup/cpu.stat)
        DELTA_US=$(( CURR_CPU - PREV_CPU ))
        CPU_RATIO=$(awk "BEGIN {r=$DELTA_US/($INTERVAL_US*$CPU_LIMIT_CORES); if(r>1)r=1; if(r<0)r=0; printf \"%.4f\",r}")
        PREV_CPU=$CURR_CPU
        ;;
      cgroupv1)
        CURR_CPU=$(( $(cat /sys/fs/cgroup/cpuacct/cpuacct.usage) / 1000 ))
        DELTA_US=$(( CURR_CPU - PREV_CPU ))
        CPU_RATIO=$(awk "BEGIN {r=$DELTA_US/($INTERVAL_US*$CPU_LIMIT_CORES); if(r>1)r=1; if(r<0)r=0; printf \"%.4f\",r}")
        PREV_CPU=$CURR_CPU
        ;;
      proc)
        read -r CURR_IDLE CURR_TOTAL < <(awk '/^cpu / {idle=$5; tot=0; for(i=2;i<=NF;i++) tot+=$i; print idle, tot}' /proc/stat)
        DELTA_IDLE=$(( CURR_IDLE - PREV_IDLE ))
        DELTA_TOTAL=$(( CURR_TOTAL - PREV_TOTAL ))
        CPU_RATIO=$(awk "BEGIN {r=($DELTA_TOTAL>0)?(1-$DELTA_IDLE/$DELTA_TOTAL):0; if(r>1)r=1; if(r<0)r=0; printf \"%.4f\",r}")
        PREV_IDLE=$CURR_IDLE
        PREV_TOTAL=$CURR_TOTAL
        ;;
    esac

    # Memory: current usage divided by total, expressed as ratio of container allocation.
    case "$MEM_SOURCE" in
      cgroupv2) MEM_USED_KB=$(( $(cat /sys/fs/cgroup/memory.current) / 1024 )) ;;
      cgroupv1) MEM_USED_KB=$(( $(cat /sys/fs/cgroup/memory/memory.usage_in_bytes) / 1024 )) ;;
      proc)     MEM_USED_KB=$(awk '/^MemTotal:/{t=$2}/^MemFree:/{f=$2}/^Cached:/{c=$2} END{print t-f-c}' /proc/meminfo) ;;
    esac
    MEM_RATIO=$(awk "BEGIN {r=$MEM_USED_KB/$MEM_TOTAL_KB; if(r>1)r=1; if(r<0)r=0; printf \"%.4f\",r}")

    # One data line per sample: cpu_ratio mem_ratio
    echo "$CPU_RATIO $MEM_RATIO"
  done
) >> "$LOG_FILE" 2>&1 &

echo $! > "$PID_FILE"
echo "Resource monitor started (PID=$(cat $PID_FILE), cpu=${CPU_SOURCE}(${CPU_LIMIT_CORES} cores) mem=${MEM_SOURCE}(${MEM_TOTAL_KB}KB), interval=${INTERVAL}s)"
