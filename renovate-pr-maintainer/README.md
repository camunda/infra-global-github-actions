# Renovate PR maintainer

Keeps open [Renovate](https://docs.renovatebot.com/) PRs **fresh** and **unstuck** on
repositories that adopt `rebaseWhen: "conflicted"`, without reintroducing the per-push
"rebase storm" of Renovate's default `rebaseWhen: "behind-base-branch"`.

Background and rationale: [camunda/team-infrastructure#1053](https://github.com/camunda/team-infrastructure/issues/1053).

## Why

With `rebaseWhen: "conflicted"`, Renovate stops rebasing PRs on every base-branch push — which
saves a large amount of CI — but two things can regress on busy repositories:

1. PRs drift far behind `main` and only get refreshed when they conflict.
2. PRs that hit a flaky required check never get retried, so they stop auto-merging.

This action runs on a schedule and, for each in-scope Renovate PR, takes the **minimum** action
needed: request a one-off Renovate rebase for stale PRs, or re-run failed jobs (within a budget)
for PRs whose required checks are red.

## Decision model

For every open, non-draft Renovate PR that does not carry an excluded label:

| `mergeable_state` | Condition | Action |
|:------------------|:----------|:-------|
| `dirty` | merge conflict | **skip** — Renovate rebases conflicts itself |
| `behind` | "require up to date" blocks merge | **rebase** |
| `blocked` / `unstable` | a **required** check is failing, run attempt ≤ `rerun-budget` | **rerun** the failed run(s) |
| `blocked` / `unstable` | no required rerun candidate, but PR is stale | **rebase** |
| `clean` (and others) | PR is stale | **rebase** |
| any | otherwise | **none** |

"Stale" is the OR of two stateless signals, both reset by a rebase:

```text
behind_by >= behind-threshold   OR   age_since_head >= stale-hours
```

- **rebase** = add the Renovate `rebase` label. Renovate performs the real rebase on its next
  run (re-running the package manager, regenerating lockfiles, pushing a fresh SHA). This action
  **never pushes commits itself**.
- **rerun** = re-run the failed workflow run(s) in place (increments
  `run_attempt`, no new SHA). Only runs that produced a **failing required check** are
  rerun: the action discovers required check contexts from the repository rulesets targeting
  the PR base branch, finds failing required check-runs on the head SHA, and maps them to
  their workflow runs via the shared check suite. Non-required (non-blocking) failures are
  never rerun. The budget is derived from `run_attempt`, so a new head SHA naturally
  refreshes it — no state is persisted.

## Usage

```yaml
# .github/workflows/renovate-pr-maintainer.yml
name: Renovate PR maintainer

on:
  schedule:
    - cron: "0 6 * * *" # daily, off-peak; scheduled runs are always dry-run
  workflow_dispatch:
    inputs:
      dry-run:
        description: "Run without modifying any PR"
        type: boolean
        default: true

permissions:
  issues: write        # apply the rebase label (Issues Labels API)
  pull-requests: read  # read PR metadata / mergeable_state
  actions: write       # re-run failed jobs
  checks: read         # read check/run state
  contents: read       # read compare/commit state

jobs:
  maintain:
    runs-on: ubuntu-latest
    steps:
      - uses: camunda/infra-global-github-actions/renovate-pr-maintainer@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          # Scheduled runs stay dry-run; manual runs honor the dispatch input.
          dry-run: ${{ github.event_name == 'schedule' || inputs.dry-run }}
```

Going live is a deliberate, auditable action: trigger the workflow manually
(`workflow_dispatch`) with `dry-run: false`. Scheduled runs never mutate PRs.

## Inputs

| Input | Default | Description |
|:------|:--------|:------------|
| `github-token` | — (required) | Token with `issues: write`, `pull-requests: read`, `actions: write`, `checks: read`, `contents: read`. |
| `repository` | `${{ github.repository }}` | Target repository (`owner/name`). |
| `renovate-author` | `renovate[bot]` | PR author login identifying Renovate PRs. |
| `exclude-labels` | `keep-updated,stop-updating` | Comma-separated labels that take a PR out of scope. |
| `behind-threshold` | `60` | Rebase when at least this many commits behind base (`B`). |
| `stale-hours` | `24` | Rebase when the PR head is at least this many hours old (`C`). |
| `rerun-budget` | `1` | Max workflow-run attempts per head SHA before reruns stop (`N`). |
| `batch-size` | `10` | Max PRs acted on per run (blast-radius cap). |
| `base-branch` | `""` | Optional exact base-branch filter; empty means all. |
| `rebase-label` | `rebase` | Renovate one-off rebase label to apply. |
| `dry-run` | `true` | When true, classify and log only; never modify any PR. |

## Scope and limitations (v1)

- **Rebases are requested via the Renovate `rebase` label, never `update-branch`.** This ensures
  lockfiles are regenerated against the new base and CI is re-triggered by Renovate.
- **Reruns are scoped to required checks discovered from rulesets.** Required contexts are read
  from repository **rulesets** targeting the PR base branch (classic branch protection is not
  inspected, mirroring the `wait-for-required-checks` action). On a repo with no matching
  rulesets, no required checks are found and the action will not rerun anything — only the
  staleness rebase path applies.
- **No persisted state.** Both staleness and rerun budget are derived from GitHub data, so the
  action is safe to run on any cadence and resets correctly on every new head SHA.
