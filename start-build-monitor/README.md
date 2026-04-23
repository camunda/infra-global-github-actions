# start-build-monitor

This composite GitHub Action starts a lightweight background CPU and memory monitor at the beginning of a job. When used together with [`submit-build-status`](../submit-build-status/), resource utilization metrics are automatically included at the end in the [CI Analytics](https://confluence.camunda.com/display/HAN/CI+Analytics) record for that job.

## Usage

Add `start-build-monitor` as the **first step** of any job that already uses `submit-build-status` (or the `observe-build-status` wrapper). No inputs are required.

```yaml
jobs:
  my-job:
    runs-on: ubuntu-latest
    steps:
      - uses: camunda/infra-global-github-actions/start-build-monitor@main

      - uses: actions/checkout@v4
      # ... all other job steps unchanged ...

      # Always submit build status to CI Analytics as usual, unchanged
      - uses: camunda/infra-global-github-actions/submit-build-status@main
        if: always()  # run even in case of failures
        continue-on-error: true  # prevent failure here of marking the job as failed
        with:
          build_status: "${{ job.status }}"
          gcp_credentials_json: "${{ secrets.YOUR_GCP_CREDENTIALS }}"
```

Jobs that do **not** include `start-build-monitor` are unaffected — `submit-build-status` simply omits the resource fields, which appear as `NULL` in BigQuery like any other optional field.

## Behavior

Starts a polling loop in the background (interval: 5s) that samples CPU and memory usage once per interval until `submit-build-status` stops it at job end.

### Metric sources

Metrics are sourced from cgroup interfaces where available, so they reflect the build job container's usage rather than the shared host node. This is correct for self-hosted Kubernetes runners with a fallback for GitHub-hosted runners.

| Source | CPU | Memory |
|--------|-----|--------|
| cgroup v2 (default on Ubuntu 22.04+) | `cpu.stat usage_usec` delta | `memory.current` |
| cgroup v1 | `cpuacct.usage` delta | `memory.usage_in_bytes` |
| Fallback (bare VM, no cgroup) | `/proc/stat` jiffies delta | `/proc/meminfo` |

CPU usage is normalized to the container's CPU limit (from `cpu.max` / `cfs_quota_us`), so 1.0 means the full CPU allocation is saturated. The same scaling applies to memory usage, so CI Analytics contains relative informations only - useful for right-sizing containers.

### Fields added to CI Analytics

The following fields are added to the `build_status_v2` BigQuery table (`FLOAT64`, `NULLABLE`, range 0.0–1.0):

| Field | Description |
|-------|-------------|
| `cpu_usage_ratio_avg` | Average CPU utilization over the job |
| `cpu_usage_ratio_p95` | 95th percentile of CPU utilization (robust against short spikes) |
| `memory_usage_ratio_avg` | Average RAM memory utilization over the job |
| `memory_usage_ratio_p95` | 95th percentile of RAM memory utilization |
