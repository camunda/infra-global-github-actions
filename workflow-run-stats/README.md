# Workflow Run Statistics Action

A GitHub Action that collects workflow run statistics over a specified time window.

## Usage

```yaml
# Workflow Run Statistics Action

A GitHub Action that collects workflow run statistics over a specified time window and provides URLs for easy navigation.

## Usage

```yaml
- name: Collect workflow statistics
  uses: ./workflow-run-stats
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    repository: owner/repo
    workflows: |
      CI:main
      Release:stable/8.6
      build.yml:main
      67890:develop
    lookback-minutes: '360'
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `github-token` | Yes | - | GitHub token with access to workflow runs |
| `repository` | No | Current repository | Repository in format `owner/repo` |
| `workflows` | Yes | - | List of workflows in format `workflow-identifier:branch` (one per line) |
| `lookback-minutes` | Yes | - | Number of minutes to look back from current time (e.g., '360' for 6 hours) |

## Outputs

| Output | Description |
|--------|-------------|
| `stats` | JSON array with statistics for each workflow/branch combination |

### Output Format

```json
[
  {
    "workflow": "CI",
    "branch": "main",
    "url": "https://github.com/owner/repo/actions/workflows/ci.yml?query=branch%3Amain",
    "html_url": "https://github.com/owner/repo/actions/workflows/ci.yml",
    "total": 25,
    "success": 20,
    "failure": 3,
    "cancelled": 2,
    "skipped": 0,
    "in_progress": 0,
    "queued": 0
  }
]
```

## Workflow Identifier Formats

The action supports multiple formats for workflow identification in the `workflow-identifier:branch` format:

- **Workflow name**: `CI:main`
- **Workflow ID**: `12345:main`
- **Workflow filename**: `ci.yml:main`

## Example with Slack Notifications

```yaml
name: Monitor Workflow Statistics

on:
  schedule:
    - cron: '0 */6 * * *'  # Every 6 hours
  workflow_dispatch:

jobs:
  monitor:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Collect workflow statistics
        id: stats
        uses: ./workflow-run-stats
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          repository: ${{ github.repository }}
          workflows: |
            CI:main
            Release:main
          lookback-minutes: '360'

      - name: Alert on failures
        if: fromJson(steps.stats.outputs.stats)[0].failure > 0
        run: |
          # Send Slack notification
          curl -X POST "${{ secrets.SLACK_WEBHOOK_URL }}" \
            -H 'Content-Type: application/json' \
            -d '{"text": "Workflow failures detected in ${{ github.repository }}"}'
```
