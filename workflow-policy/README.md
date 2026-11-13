# 🔎 Workflow policy check

Checks the calling repository's workflow jobs against rule presets bundled with this action.

## ⚙️ Configuration

Create `.github/workflow-policy.yml`:

```yaml
extends:
  - build-monitoring

exceptions:
  - workflow: .github/workflows/workflow-policy.yml
    jobs: [check]
    reason: Policy validation only
  - workflow: "*"
    jobs: [lint]
    rule: build-monitoring
    reason: Too short to monitor
```

Each [preset](#-presets) listed in `extends` is a rule, written as its name or as a mapping with `name` and optional [`params`](#preset-parameters). The `exceptions` list is described under [Exceptions](#-exceptions).

## 🧩 Presets

A preset is a rule maintained in this action. Pinning the action's commit SHA pins its presets too.

| Preset | Checks |
| --- | --- |
| `build-monitoring` | The first step uses `camunda/infra-global-github-actions/start-build-monitor`, and the last step uses `camunda/infra-global-github-actions/submit-build-status` or the local `observe-build-status` wrapper at any checkout path with `if: always()` and `continue-on-error: true`. |

`build-monitoring` has no built-in exceptions: a job that only sends notifications, such as `notify-on-failure`, has no build to monitor and needs an exception.

Each preset lives in `presets/<name>/`: `preset.yml` holds its parameters and the ones a repository may override, and its Rego package `workflow_policy.<name>` returns findings with `rule`, `job`, and `msg`.

The checker applies exceptions to those findings afterwards. Run its tests with `conftest verify --policy presets/<name>`.

### Preset parameters

A repository sets the parameters a preset lists as `overridable` under `params`:

```yaml
extends:
  - name: build-monitoring
    params:
      last-step-any-of:
        - camunda/infra-global-github-actions/submit-build-status
        - ./.github/actions/report-build
```

| Preset | Parameter | Default | Overridable |
| --- | --- | --- | --- |
| `build-monitoring` | `first-step` | `camunda/infra-global-github-actions/start-build-monitor` | No |
| `build-monitoring` | `last-step-any-of` | `camunda/infra-global-github-actions/submit-build-status`, `./**/.github/actions/observe-build-status` | Yes |

A value replaces its default, so repeat the defaults you still want, as above: a string, or a non-empty list when the default is a list. Each value is an action path without `@ref`, such as `actions/checkout`, or a pattern: `*` matches one path segment and `**` any number of segments, including none, so `./**/.github/actions/observe-build-status` matches `./.github/actions/observe-build-status` and `./tool/.github/actions/observe-build-status`. An unknown or fixed parameter, a value of the wrong shape, a value with `?`, `[`, `{`, or `\`, or an empty `params` fails the check. The `if: always()` and `continue-on-error: true` requirement on the last step of `build-monitoring` is fixed.

The report and the job summary list every override with its value and configuration line, such as `build-monitoring: last-step-any-of = camunda/infra-global-github-actions/submit-build-status, ./.github/actions/report-build (.github/workflow-policy.yml:4)`, and the rule's findings name the effective values.

## 🚫 Exceptions

An exception excludes a job from one rule or from every rule. Two kinds exist, and the inline kind has two forms:

| Kind | Declared in | Excludes | `rule` |
| --- | --- | --- | --- |
| [Configured](#configured-exceptions) | `exceptions` in `.github/workflow-policy.yml`, written by the repository | The jobs matching `workflow` and `jobs` | Optional; without it, every rule |
| [Inline `skip-job`](#skip-a-job) | `# workflow-policy:` comment on or above a job ID | That job | Optional `rule=<rule>`; without it, every rule |
| [Inline `skip-workflow`](#skip-a-workflow) | `# workflow-policy:` comment before the workflow's first key | Every job of that workflow | Optional `rule=<rule>`; without it, every rule |

Exceptions are only additive, and there is no precedence between the kinds. A job is skipped for a rule as soon as any exception covers it, whatever its kind, and nothing can bring it back. An exception without a rule skips every rule. Overlapping exceptions are allowed: they are redundant, not conflicting.

A job that calls a reusable workflow is never checked: a called workflow in `.github/workflows/` is checked as its own file, and one from another repository is outside this check. The report lists such jobs as `reusable`, with the workflow they call. A configured exception or inline directive that matches only such jobs fails the check.

The report lists every exception that matches a job, so removing one shows what remains: inline first (`skip-workflow`, then `skip-job`), then configured. Each shows its source and location, prefixed by its rule when it excludes only one: `Slack only (inline, .github/workflows/ci.yml:6)` or `build-monitoring: Too short to monitor (config, .github/workflow-policy.yml:12)`.

### Configured exceptions

A repository lists them under `exceptions` in `.github/workflow-policy.yml`:

```yaml
exceptions:
  - workflow: .github/workflows/workflow-policy.yml
    jobs: [check]
    reason: Policy validation only
  - workflow: "*"
    jobs: [lint]
    rule: build-monitoring
    reason: Too short to monitor
```

The first exception excludes the checker job from every rule; the second excludes every job named `lint` from `build-monitoring` only.

| Field | Meaning |
| --- | --- |
| `workflow` | Required. An exact workflow path in `.github/workflows/`, or `"*"` for all workflows. |
| `jobs` | Required. A non-empty list of exact job IDs; `"*"` in the list means every job. Other patterns are not supported. |
| `reason` | Required and not empty. Shown in the report. |
| `rule` | Optional. Names a configured rule, one listed in `extends`. Without it, the job is excluded from every rule. |

Each configured exception must match at least one job, so a typo fails the check instead of silently hiding nothing.

### Inline exceptions

A workflow excludes jobs with `# workflow-policy:` comments. Two directives exist: `skip-job` excludes one job, and `skip-workflow` excludes every job of the workflow. Both are followed by an optional `rule=<rule>` and a reason.

#### Skip a job

A `skip-job` comment next to a job excludes that job:

```yaml
jobs:
  # workflow-policy: skip-job notification-only job
  notify:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Notify"

  cleanup: # workflow-policy: skip-job housekeeping only
    runs-on: ubuntu-latest
    steps:
      - run: echo "Clean up"

  lint: # workflow-policy: skip-job rule=build-monitoring too short to monitor
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
```

Write `# workflow-policy: skip-job [rule=<rule>] <reason>` on the job ID line, or in the comment lines directly above the job ID at the same indentation, with no blank line in between.

#### Skip a workflow

To exclude every job of a workflow, write `# workflow-policy: skip-workflow [rule=<rule>] <reason>` in the comment lines before the workflow's first key:

```yaml
# Manual cluster maintenance.
# workflow-policy: skip-workflow rule=build-monitoring manual maintenance only
name: Maintenance
on: workflow_dispatch
```

A `skip-workflow` comment after the first key is misplaced and fails the check. It combines with `skip-job` directives in the same workflow: a job is skipped for every rule that either one covers.

#### Fields shared by both directives

Both directives share the fields of configured exceptions: `reason` is required, and the optional `rule` names one configured rule; without it, the directive excludes from every rule.

A malformed directive, an unconfigured rule, a misplaced directive, two directives for the same rule, or a directive without `rule` next to another one on the same job or workflow fails the check. Every line is searched for `# workflow-policy:`, so one inside a `run:` script or a quoted string is read as a directive too.

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
| `report-path` | JSON with aggregate counts, parameter overrides, per-job results, findings, exclusions, and errors |
| `summary-path` | Markdown summary and job table |

Each job has a `status`: `passed`, `failed`, `excluded`, `reusable`, or `error`; a `reusable` job names the workflow it calls in `calls`. Each job lists the `rules` it was checked against and its `findings` (`rule` and `message`). Its `exclusions` list holds `source` (`inline` or `config`), `file`, `line`, `reason`, and `rule` (`null` for every rule) for each matching exception, so excluded jobs can be traced to their declaration. The top-level `overrides` list holds `rule`, `param`, `value`, `file`, and `line` for each parameter override.

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
