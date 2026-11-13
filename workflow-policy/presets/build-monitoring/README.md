# 📈 build-monitoring preset

Makes sure every workflow job sends a complete record to CI Analytics (`build_status_v2`): its status, duration, and CPU and memory usage. Without the first step, a job's record has no duration or resource usage. Without the last step, the job sends no record at all.

## ✅ Checks

The preset checks each job's first and last steps:

| Check | Why |
| --- | --- |
| The first step uses [`start-build-monitor`](../../../start-build-monitor/) | It records the start time and starts CPU and memory sampling. It has to come first so the measurement covers the whole job. |
| The last step uses [`submit-build-status`](../../../submit-build-status/) or a local `observe-build-status` wrapper | It stops the monitor and submits the record. It has to come last so the record covers every earlier step. |
| The last step sets `if: always()` | Failed and cancelled jobs get reported as well. |
| The last step sets `continue-on-error: true` | A failed submission doesn't fail the job. |

A job that passes:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: camunda/infra-global-github-actions/start-build-monitor@main
      - uses: actions/checkout@v5
      - run: make
      - uses: camunda/infra-global-github-actions/submit-build-status@main
        if: always()
        continue-on-error: true
        with:
          build_status: ${{ job.status }}
```

## ⚙️ Parameters

| Parameter | Default | Overridable | Why |
| --- | --- | --- | --- |
| `first-step` | `camunda/infra-global-github-actions/start-build-monitor` | No | The duration and resource fields depend on this action. |
| `last-step-any-of` | `camunda/infra-global-github-actions/submit-build-status`, `./**/.github/actions/observe-build-status` | Yes | A repository can submit through its own wrapper. By default, `observe-build-status` is accepted under any checkout path. |

The `if: always()` and `continue-on-error: true` requirement can't be changed. See [Preset parameters](../../README.md#preset-parameters) for how to override `last-step-any-of`.

## 🚫 Exceptions

The preset comes with no exceptions. A job that only sends notifications, such as `notify-on-failure`, has no build to monitor and needs an [exception](../../README.md#-exceptions) in the repository's configuration.
