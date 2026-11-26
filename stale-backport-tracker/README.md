# stale-backport-tracker

Finds backport PRs that stayed open longer than a threshold and nags about them:

- a **pinned Slack report**, created with the first run of the day and updated in place by every later run;
- a **comment** on each stale backport PR, mentioning its assignee (or the original PR's author or approvers), plus the `stale-backport` label.

One implementation serves every repository that backports with the same mechanics. A caller is a thin workflow with a schedule and its own values.

| Path | What it is |
|---|---|
| [`.github/workflows/stale-backport-tracker.yml`](../.github/workflows/stale-backport-tracker.yml) | The reusable workflow callers use |
| `collect`, `notify-github`, `format-slack` | Composite actions the workflow is built from |
| `scripts/` | The Bash behind the actions, shipped here so callers need no copy |

## Adding a repository

Create `.github/workflows/stale-backport-tracker.yml` in the repository:

```yaml
---
name: Stale Backport Tracker

on:
  schedule:
  - cron: '0 6-18 * * 1-5'   # hourly on weekdays; the first run of the day posts, the others update
  workflow_dispatch:
    inputs:
      dry_run:
        type: boolean
        default: true

permissions: {}

jobs:
  stale-backports:
    permissions:
      id-token: write  # Vault JWT login in the called workflow
    uses: camunda/infra-global-github-actions/.github/workflows/stale-backport-tracker.yml@main
    secrets: inherit
    with:
      repositories: camunda/camunda-hub
      target_branch_prefix: self-managed/
      slack_channel_id: C0XXXXXXXXX   # the only value a new repository must provide
      notify_slack: true
      notify_github: true
      dry_run: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run }}
```

The caller needs the `VAULT_ADDR`, `VAULT_JWT_ROLE`, `VAULT_JWT_PATH` and `VAULT_JWT_AUDIENCE` secrets, and `id-token: write`.

camunda/camunda keeps today's behavior with its own values:

```yaml
    with:
      repositories: camunda/camunda,camunda/zeebe-process-test
      slack_channel_id_vault_key: SLACK_TOPMONOREPOCI_CHANNEL_ID
      notify_github: true
      dry_run: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run }}
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `repositories` | required | Comma-separated `owner/repo` to scan. Same organization as the caller. |
| `slack_channel_id` | | Channel the report is posted to. Required with `notify_slack`, unless `slack_channel_id_vault_key` is set. |
| `slack_channel_id_vault_key` | | Key under `slack_vault_path` holding the channel ID, used when `slack_channel_id` is empty. |
| `stale_hours_threshold` | `24` | Hours after which an open backport PR is stale. |
| `report_title` | `Stale Backport PRs` | Title of the report. It is also how the existing message is found and updated, so keep it stable. |
| `notify_slack` | `true` | Post the report to Slack. |
| `notify_github` | `false` | Comment on and label the stale backport PRs. |
| `dry_run` | `false` | Collect and format only. No Slack message, comment, label or reviewer request. The Slack blocks go to the job summary. |
| `target_branch_prefix` | `stable/` | Prefix of the branches backport PRs target, e.g. `self-managed/`. |
| `target_branch` | | Restrict the report to one exact branch. |
| `target_backport_pr` | | TEST ONLY: restrict GitHub notifications to one backport PR number. |
| `backport_authors` | `backport-action,monorepo-devops-automation[bot]` | Logins that open backport PRs. |
| `slack_cc` | engineering-operations subteam | Mention added to the "user map not available" warning. Empty for none. |
| `github_app_vault_path`, `github_app_id_vault_key`, `github_app_private_key_vault_key` | camunda monorepo app (`MONOREPO_RELEASE_APP_*`) | The GitHub App that reads and notifies the PRs. It must be installed on every repository in `repositories`. |
| `user_map_repository`, `user_map_app_id_vault_key`, `user_map_app_private_key_vault_key` | `camunda/monorepo-ci-data`, `MONOREPO_DEVOPS_AUTOMATION_APP_*` | Where the weekly `github-slack-user-map` artifact is downloaded from. |
| `slack_vault_path`, `slack_bot_token_vault_key` | `secret/data/products/camunda/ci/github-actions`, `SLACK_C8_MONOREPO_NOTIFICATIONS_BOT_TOKEN` | The Slack bot. It must be a member of the channel and able to pin there. |

## Notes

- The workflow calls its composite actions at `@main`, as the rest of this repository does for its own actions. A caller pinning the workflow to a SHA still gets the actions of `main`.
- Backport PRs are found by author (`backport_authors`), by a `Backport of #N` line in their body, and by their base branch starting with `target_branch_prefix`.
- A comment is renewed after two days (deleted and recreated, so the mention notifies again). Between two renewals the PR is skipped.
- `observe-build-status`, which camunda/camunda ran inside its own copy, is not part of the shared workflow. A caller that wants it adds a job with `needs:` on the tracker job.
