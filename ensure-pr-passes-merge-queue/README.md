# Ensure PR passes merge queue

This composite GitHub Action (GHA) is intended for Camunda engineers to monitor a pull request in merge queue and automatically recover from queue evictions by re-enabling auto-merge.

## What it does

- Polls PR and merge queue state every 2 minutes.
- Succeeds when the PR is merged.
- Fails when the PR is closed, evicted too many times, or timeout is reached.
- Re-enables auto-merge after eviction (unless `dry-run` is `true`).

## Usage

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `pr-number` | Yes | - | Pull request number to monitor. |
| `app-token` | Yes | - | GitHub App installation token used for GraphQL queries and re-enabling auto-merge. |
| `repository-owner` | Yes | - | Repository owner, for example `camunda`. |
| `repository-name` | Yes | - | Repository name, for example `infra-core`. |
| `timeout-minutes` | No | `180` | Maximum minutes to wait for merge completion. |
| `max-evictions` | No | `3` | Maximum merge queue evictions before failing. |
| `dry-run` | No | `false` | If `true`, does not re-enable auto-merge, only observes. |

### Outputs

| Output | Description |
|---|---|
| `result` | Final outcome: `merged`, `closed`, `evicted`, or `timeout`. |

### Workflow example

```yaml
name: Ensure PR Passes Merge Queue

on:
  workflow_dispatch:

jobs:
  monitor:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - name: Ensure PR passes merge queue
        id: monitor_mq
        uses: camunda/infra-global-github-actions/ensure-pr-passes-merge-queue@main
        with:
          pr-number: ${{ github.event.pull_request.number }}
          app-token: ${{ secrets.MERGE_QUEUE_APP_TOKEN }}
          repository-owner: ${{ github.repository_owner }}
          repository-name: ${{ github.event.repository.name }}
          timeout-minutes: "180"
          max-evictions: "3"

      - name: Print result
        run: echo "Merge queue result: ${{ steps.monitor_mq.outputs.result }}"
```

## Notes

- Use a GitHub App installation token with at least `Pull requests: Write` permission.
- The GitHub App must be installed on the target repository.
