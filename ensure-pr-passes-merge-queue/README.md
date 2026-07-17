# Ensure PR passes merge queue

This composite GitHub Action (GHA) is intended for Camunda engineers to monitor a pull request in merge queue and automatically recover from queue evictions by re-enabling auto-merge.

## What it does

- Polls PR and merge queue state every 2 minutes.
- Succeeds when the PR is merged.
- Fails when the PR is closed, evicted too many times, the timeout is reached, or the API keeps failing.
- Re-enables auto-merge after eviction (unless `dry-run` is `true`).
- Before reporting any non-merged outcome, rechecks the PR once with a fresh token and reports `merged` if the merge landed in the meantime.
- When given `app-id` + `private-key`, mints GitHub App installation tokens itself and refreshes them before the 1-hour expiry, so long monitoring windows keep working.

## Usage

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `pr-number` | Yes | - | Pull request number to monitor. |
| `app-id` | No | - | GitHub App ID. Together with `private-key`, enables self-minted, auto-refreshed installation tokens. |
| `private-key` | No | - | GitHub App private key (PEM). Together with `app-id`, enables self-minted, auto-refreshed installation tokens. |
| `app-token` | No | - | Pre-minted GitHub App installation token. Expires after 1 hour, so prefer `app-id` + `private-key` for timeouts beyond ~50 minutes. |
| `repository-owner` | Yes | - | Repository owner, for example `camunda`. |
| `repository-name` | Yes | - | Repository name, for example `infra-core`. |
| `timeout-minutes` | No | `180` | Maximum minutes to wait for merge completion. |
| `max-evictions` | No | `3` | Maximum merge queue evictions before failing. |
| `merge-method` | No | `squash` | Merge method used when re-enabling auto-merge: `squash`, `merge`, `rebase`, or `default` (omit method flag). |
| `dry-run` | No | `false` | If `true`, does not re-enable auto-merge, only observes. |

Either `app-id` + `private-key` or `app-token` must be provided.

### Outputs

| Output | Description |
|---|---|
| `result` | Final outcome: `merged`, `closed`, `evicted`, `timeout`, or `api_failure`. Empty when input validation fails before monitoring starts. |
| `queue-state` | Last observed merge queue entry state (e.g. `AWAITING_CHECKS`, `MERGEABLE`, `NOT_IN_QUEUE`, `UNKNOWN`). |
| `queue-position` | Last observed merge queue position, or `N/A`. |
| `merge-state-status` | Last observed PR `mergeStateStatus` (e.g. `CLEAN`, `BLOCKED`, `UNKNOWN`). |

`timeout` means the time budget ran out while the PR was still open (check `queue-state` to see whether it was still progressing); `api_failure` means the GitHub API kept failing (or auto-merge could not be re-enabled) and the monitor lost visibility — the PR itself may still merge.

### Workflow example

```yaml
name: Ensure PR Passes Merge Queue

on:
  workflow_dispatch:

jobs:
  monitor:
    runs-on: ubuntu-slim
    permissions:
      contents: read
      pull-requests: write
    steps:
      - name: Ensure PR passes merge queue
        id: monitor_mq
        uses: camunda/infra-global-github-actions/ensure-pr-passes-merge-queue@main
        with:
          pr-number: ${{ github.event.pull_request.number }}
          app-id: ${{ secrets.MERGE_QUEUE_APP_ID }}
          private-key: ${{ secrets.MERGE_QUEUE_APP_PRIVATE_KEY }}
          repository-owner: ${{ github.repository_owner }}
          repository-name: ${{ github.event.repository.name }}
          timeout-minutes: "180"
          max-evictions: "3"
          merge-method: "default"

      - name: Print result
        run: |
          echo "Merge queue result: ${{ steps.monitor_mq.outputs.result }}"
          echo "Last queue state: ${{ steps.monitor_mq.outputs.queue-state }} (pos: ${{ steps.monitor_mq.outputs.queue-position }})"
```

## Notes

- Use a GitHub App with at least `Pull requests: Write` permission. GitHub exposes a
  separate `Merge queues` permission and does not document which one gates the GraphQL
  `mergeQueueEntry` field this action polls — grant `Merge queues: Read` as well if
  queue state comes back empty.
- The GitHub App must be installed on the target repository.
- With `app-id` + `private-key` there is no need for a separate token-minting step (for example `tibdex/github-app-token` or `actions/create-github-app-token`) in the calling job, and no risk of the 1-hour installation-token expiry killing long monitoring windows.
