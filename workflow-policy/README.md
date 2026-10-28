# 🔎 Workflow policy check

Checks direct action presence in the calling repository's workflow jobs.

## ⚙️ Configuration

Create `.github/workflow-policy.yml`:

```yaml
required-actions:
  - actions/checkout
  - camunda/infra-global-github-actions/submit-build-status

exceptions:
  - workflow: .github/workflows/workflow-policy.yml
    jobs: [check]
    reason: Policy validation only
```

Configure action paths without `@ref`. Remote composites and local paths such as `./.github/actions/observe-build-status` are supported.

The example excludes the checker job below. Use exact workflow paths and job IDs, or `"*"` for all workflows or jobs. Each exception needs a reason and must match at least one job.

Reusable-workflow call jobs require explicit exceptions because their steps are uninspectable.

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

Checkout must populate the workspace root. The action checks every `.yml` and `.yaml` file directly in that checkout's `.github/workflows/`. `config-path` is relative to the checkout. Missing required actions or invalid configuration fail the step.

Pin the action to a released commit SHA following the [repository's usage convention](../README.md).

Use a dedicated checker job on Linux or macOS (x86-64 or ARM64) to isolate the action's Python 3.13 setup and dependency installation.

## 📊 Results

The GitHub job summary lists each job's result, missing actions, and exclusion reasons, including on policy failure.

| Output | Contents |
| --- | --- |
| `report-path` | JSON with aggregate counts, per-job results, missing actions, and errors |
| `summary-path` | Markdown summary and job table |

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
