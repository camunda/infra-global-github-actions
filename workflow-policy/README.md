# 🔎 Workflow policy check

Checks the calling repository's workflow jobs against rules: required actions and presets bundled with this action.

## ⚙️ Configuration

Create `.github/workflow-policy.yml`:

```yaml
extends:
  - build-monitoring

required-actions:
  - actions/checkout

exceptions:
  - workflow: .github/workflows/workflow-policy.yml
    jobs: [check]
    reason: Policy validation only
  - workflow: "*"
    jobs: [lint]
    rule: build-monitoring
    reason: Too short to monitor
```

Set `required-actions`, `extends`, or both. Each becomes a rule: `required-actions` checks that every job uses each listed action, and each [preset](#-presets) adds its own rule.

Configure action paths without `@ref`. Remote composites and local paths such as `./.github/actions/observe-build-status` are supported.

The first exception excludes the checker job below from every rule; the second excludes `lint` from `build-monitoring` only. Use exact workflow paths and job IDs, or `"*"` for all workflows or jobs. Each exception needs a reason and must match at least one job; `rule` is optional and must name a configured rule.

Reusable-workflow call jobs require explicit exceptions, in the configuration or inline, because their steps are uninspectable.

## 🧩 Presets

A preset is a rule maintained in this action, enabled by name with `extends`. Pinning the action's commit SHA pins its presets too.

| Preset | Checks |
| --- | --- |
| `build-monitoring` | The first step uses `camunda/infra-global-github-actions/start-build-monitor`, and the last step uses `camunda/infra-global-github-actions/submit-build-status` or `./.github/actions/observe-build-status` with `if: always()` and `continue-on-error: true`. Jobs named `notify`, `notify-on-failure`, or `notify-on-success` are excluded. |

A preset's own exceptions apply only to its rule and may match no job. Each preset lives in `presets/<name>/`: `preset.yml` holds its parameters and exceptions, and its Rego package `workflow_policy.<name>` returns findings with `rule`, `job`, and `msg`. The checker applies exceptions to those findings afterwards. Run its tests with `conftest verify --policy presets/<name>`.

### Inline exceptions

A workflow can also exclude a job with a comment next to that job:

```yaml
jobs:
  # workflow-policy: skip notification-only job
  notify:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Notify"

  cleanup: # workflow-policy: skip housekeeping only
    runs-on: ubuntu-latest
    steps:
      - run: echo "Clean up"

  lint: # workflow-policy: skip rule=build-monitoring too short to monitor
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
```

Write `# workflow-policy: skip [rule=<rule>] <reason>` on the job ID line, or in the comment lines directly above the job ID at the same indentation, with no blank line in between. Inline and configured exceptions share the same two fields: `reason` is required, and the optional `rule` names one configured rule; without it, the directive excludes the job from every rule. A malformed directive, an unconfigured rule, a directive not attached to exactly one job, or a second directive for the same job fails the check. `#` inside `run:` scripts and quoted strings is ignored.

Inline, configured, and preset exceptions combine. The report lists every exception that matches a job, inline first, each with its source and location, prefixed by its rule when it excludes only one: `Slack only (inline, .github/workflows/ci.yml:6)` or `build-monitoring: Too short to monitor (config, .github/workflow-policy.yml:11)`.

## 🔧 Caller workflow

Create `.github/workflows/workflow-policy.yml`:

```yaml
name: Workflow policy
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - id: policy
        uses: camunda/infra-global-github-actions/workflow-policy@main
        with:
          config-path: .github/workflow-policy.yml
```

Checkout must populate the workspace root. The action checks every `.yml` and `.yaml` file directly in that checkout's `.github/workflows/`. `config-path` is relative to the checkout. Rule failures or invalid configuration fail the step.

Pin the action to a released commit SHA following the [repository's usage convention](../README.md).

Use a dedicated checker job on Linux or macOS (x86-64 or ARM64) to isolate the action's Python 3.13 setup and dependency installation.

## 📊 Results

The GitHub job summary lists each job's result, rule findings, and exclusion reasons, including on policy failure. A rule check is one rule evaluated on one job.

| Output | Contents |
| --- | --- |
| `report-path` | JSON with aggregate counts, per-job results, findings, exclusions, and errors |
| `summary-path` | Markdown summary and job table |

Each job lists the `rules` it was checked against and its `findings` (`rule`, `message`, and `action` for `required-actions`). Its `exclusions` list holds `source` (`inline`, `config`, or `preset`), `file`, `line`, `reason`, and `rule` (`null` for every rule) for each matching exception, so excluded jobs can be traced to their declaration.

Outputs are runner-local file paths available after validation, including policy failures. Configuration and Conftest errors appear in the report and fail the check. Upload the JSON as an artifact to retain it after the job.

For custom summary placement, set `write-summary: 'false'` on the action and add:

```yaml
- name: Append policy table
  if: ${{ always() && steps.policy.outputs.summary-path != '' }}
  env:
    POLICY_SUMMARY: ${{ steps.policy.outputs.summary-path }}
  run: cat "${POLICY_SUMMARY}" >> "${GITHUB_STEP_SUMMARY}"
```

For local reports, run `python workflow-policy/check.py --config <path> --report-dir <directory>`.
