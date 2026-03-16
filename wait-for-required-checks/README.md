# Wait for Required Checks

This composite GitHub Action (GHA) is intended for Camunda engineers to wait until all required checks are green before continuing a pipeline.

The action discovers required checks from repository rulesets that apply to the PR base branch, then polls check-runs for the target commit SHA.

## What it does

- Reads required status checks from GitHub repository rulesets.
- Targets checks relevant for the provided base branch.
- Polls check-runs until all required checks pass.
- Fails fast if a required check completes with a non-success conclusion.
- Returns `skipped` when no required checks are discovered.

## Usage

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `repository` | Yes | - | Repository in `owner/repo` format (for example `camunda/infra-core`). |
| `base_branch` | Yes | - | PR base branch name (for example `main`, `stage`, `stable/8.7`). |
| `head_sha` | Yes | - | Commit SHA to monitor. |
| `timeout_minutes` | No | `50` | Maximum minutes to wait for required checks. |
| `poll_interval` | No | `30` | Polling interval in seconds. |

### Outputs

| Output | Description |
|---|---|
| `result` | `success` when all checks passed, `skipped` when no checks were found. |

### Workflow example

```yaml
name: Wait For Required Checks

on:
  pull_request:

jobs:
  wait-required-checks:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      checks: read
    steps:
      - name: Wait for required checks to pass
        id: wait_checks
        uses: camunda/infra-global-github-actions/wait-for-required-checks@main
        with:
          repository: ${{ github.repository }}
          base_branch: ${{ github.base_ref }}
          head_sha: ${{ github.event.pull_request.head.sha }}
          timeout_minutes: "50"
          poll_interval: "30"

      - name: Print result
        run: echo "Required checks result: ${{ steps.wait_checks.outputs.result }}"
```

## Notes

- Discovery is based on repository rulesets. Traditional branch protection checks are not queried by this action.
- Ensure `gh` and `jq` are available in the runner environment.
