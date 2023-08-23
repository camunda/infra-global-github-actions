# preview-env-clean

This composite GitHub Action (GHA) is aimed to clean up preview environments whose defined lifetime has expired.

Lifetime of a preview environment corresponds to the time since the last deployment activity.

Users are notified by comments on the associated PR, informing them of an upcoming or completed shutdown. A great care is given to keep these comments consistent with the preview environment state, and gave the right information with possible actions.

## Usage

This composite GHA can be used with other preview environment GHAs (deploy/teradown) to enable automatic cleanup.

Two modes are availble:
- **Full**: Cleans all preview environments whose defined lifetime has expired and post comments.
- **Minimal**: Cleans comments (preview-related) of a PR that may be inconsistent with the preview environment state. Can be used after any operation on preview environments, while waiting for the full mode to be executed. This mode is very efficient and avoids the need to systematically perform a full cleanup after each deployment activity to ensure comment consistency.

Two configurable thresholds:
- `ttl`: lifetime (duration) of a preview environment since last deployment, before it becomes a candidate for shutdown.
- `ttl-warning`: duration since last deployment after which users are warned of the upcoming shutdown of preview environment(s) (must be lower than `ttl`)

Comment templates can be cutomized.

A private GitHub token with following permissions is needed:
- `Deployments` (read) to get last deployment activities
- `Pull requests` (read & write) to remove preview environment label(s) and manage comments

> ![!IMPORTANT]
> Don't use `$GITHUB_TOKEN` otherwise no event will be tiggered when removing labels from a PR.

### Inputs
| Input name | Description                                                                                                       |      Required      |   Default   |
| :--------: | :---------------------------------------------------------------------------------------------------------------- | :----------------: | :---------: |
|  dry-run   | Disable side effects for testing purposes |  |  `false`           |
|  labels    | Comma-speparated list of labels used to deploy preview environment   |   :heavy_check_mark:  | `deploy-preview` |
| pull-request | Limit cleanup to a single pull request (number) and a minimal mode. Only inconsistent comments related to preview environment(s) are removed. | | |
| repository | Target GitHub repository with preview environments to clean (in `owner/name` format) | | Current repository |
| shutdown-message | A message template to inform users of the complete shutdown of a preview environment | :heavy_check_mark: | See [actions.yaml](./action.yml) |
| ttl | Lifetime before a preview environment is candidate for shutdown (e.g. 2d, 15h, 35m, 5s) | :heavy_check_mark: | `21d` |
| token | GitHub token with necessary permissions (Deployments & Pull request). Default $GITHUB_TOKEN cannot be used | :heavy_check_mark: | |
| warning-message | A message template to warn users of the upcoming shutdown of a preview environment | | See [actions.yaml](./action.yml) |
| warning-ttl | Duration since last deployment after which users are warned of the upcoming shutdown of the preview environment(s) (e.g. 2d, 15h, 35m, 5s). Skipped if set to 0. Must be lower than `ttl` |  | `0s` |

### Workflow Example
```yaml
---
name: preview-env-clean

on:
  schedule:
  - cron: 0 6,22 * * *
  workflow_call:
    inputs:
      pull-request:
        description: |
          Limit cleanup to a single pull request (number) and a minimal mode.
          Useful for quickly eliminating inconsistencies while waiting for the full cleanup cycle to run.
        required: false
        type: number
    secrets:
      PRIVATE_TOKEN:
        required: true
  workflow_dispatch:

jobs:
  preview-env-clean:
    concurrency:
      group: ${{ github.workflow }}-${{ inputs.pull-request }}
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    - uses: camunda/infra-global-github-actions/preview-env/clean@main
      with:
        labels: deploy-preview
        pull-request: ${{ inputs.pull-request }}
        token: ${{ secrets.PRIVATE_TOKEN }}
        ttl: 21d
        warning-ttl: 14d

```
