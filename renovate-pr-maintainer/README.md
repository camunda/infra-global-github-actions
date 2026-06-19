# Renovate PR maintainer

Keeps open [Renovate](https://docs.renovatebot.com/) PRs fresh and unstuck on repositories using `rebaseWhen: "conflicted"` by taking the **minimum** action per PR — rebase stale PRs (via the Renovate `rebase` label) or re-run failed required jobs (within a budget). On `rebaseWhen: "conflicted"`, PRs silently drift behind base until their checks rot, yet eager rebasing triggers a CI-burning rebase storm — this nudges only the PRs that are actually stale or stuck. Background: [camunda/team-infrastructure#1053](https://github.com/camunda/team-infrastructure/issues/1053).

## Usage

Run it on a schedule so it periodically nudges open Renovate PRs. With the defaults it only **rebases stale PRs** (reruns are off until you set a `rerun-budget`):

```yaml
name: Renovate PR maintainer

on:
  schedule:
    - cron: "0 */4 * * *" # every 4 hours
  workflow_dispatch: {}

permissions:
  contents: read
  checks: read
  actions: write
  pull-requests: write

jobs:
  maintain:
    runs-on: ubuntu-latest
    steps:
      - uses: camunda/infra-global-github-actions/renovate-pr-maintainer@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

### Common tweaks

Try it safely first — classify and log only, change nothing:

```yaml
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          dry-run: true
```

Also re-run failed required checks (up to 2 attempts per commit):

```yaml
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          rerun-budget: 2
```

Keep the automerge merge-train moving on a repo that requires up-to-date branches (rebases every behind auto-merging PR immediately so Renovate can merge them next scan):

```yaml
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          require-up-to-date-strategy: automerge
```

On a busy repo where Renovate merges only a couple of PRs per run, keep it moving with **minimal rebases** — per base branch, rebase just the one least-behind *mergeable* auto-merging PR (blocked ones are skipped so they can'́t stall the train):

```yaml
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          require-up-to-date-strategy: automerge-optimized
```

## What it does

A few common situations and the action it takes (with the defaults: rebase once a PR is **behind base** and either ≥ 60 commits behind **or** ≥ 24h since its head was pushed — a PR level with base is never rebased):

| Renovate PR situation | What the maintainer does |
|:----------------------|:-------------------------|
| 70 commits behind base, or behind base with a 30h-old head | Adds the `rebase` label → Renovate rebases it (fresh SHA) |
| Up to date with base, even with an old head | Nothing — not behind, so no rebase (its checks are re-run if they fail) |
| Green and fresh (few commits behind, recent head) | Nothing — leaves it alone |
| Has a merge conflict | Nothing — Renovate rebases conflicts itself |
| Failing required check, fresh head¹ | Re-runs the failed jobs in place (no new SHA) |
| Already carries the `rebase` label | Nothing — a rebase is already queued |
| Branch has human-pushed commits | Nothing — leaves it for the human |
| Behind base & auto-merging² | Rebases it immediately so Renovate can merge it next scan |

¹ Only when `rerun-budget` ≥ 1 (reruns are off by default).

² With `require-up-to-date-strategy: automerge`, every behind auto-merging PR is rebased; with `automerge-optimized`, only one least-behind **mergeable** auto-merging PR per base branch is (blocked ones excluded).

See the [decision model](#decision-model) below for the exact rules.

## Decision model

```mermaid
stateDiagram-v2
    state "head-ownership check" as owned
    state "blocked / unstable" as red
    state "clean / has_hooks" as green

    [*] --> classify: in-scope Renovate PR

    classify --> pending: carries rebase label
    classify --> skip: dirty (merge conflict)
    classify --> none: unknown (mergeability undecided)
    classify --> owned: behind / blocked / unstable / clean

    owned --> skip: head edited by a human
    owned --> behind: behind
    owned --> red: blocked / unstable
    owned --> green: clean / has_hooks

    behind --> rebase: require-up-to-date-strategy = all
    behind --> rebase: require-up-to-date-strategy = automerge & PR auto-merges
    behind --> red: otherwise (none, automerge-optimized, or non-automerge PR)

    red --> rebase: stale
    red --> rerun: else, required check failing & attempt ≤ rerun-budget
    red --> none: otherwise

    green --> rebase: stale
    green --> none: fresh

    note right of green
        rebase only when behind base, then
        stale = behind_by ≥ behind-threshold
                OR head age ≥ stale-hours.
                Level with base is never rebased.
    end note

    note left of behind
        require-up-to-date-strategy = automerge-optimized: a per-base post-pass
        rebases just one least-behind mergeable behind auto-merging PR,
        unless that base already has one merge-ready or being rebased.
        Blocked auto-merging PRs are excluded (left to staleness) so
        they can't stall the train.
    end note
```

- **rebase** — add the Renovate `rebase` label; Renovate does the real rebase (regenerates lockfiles, pushes a fresh SHA). This action never pushes commits. With `require-up-to-date-strategy: all` every behind PR is rebased immediately; with `automerge`, every behind auto-merging PR is; with `automerge-optimized`, just one least-behind mergeable auto-merging PR per base branch is (see the note above).
- **rerun** — re-run the failed required workflow run(s) in place, no new SHA; budget derives from `run_attempt`.
- **no action** — the PR is left untouched this run; three states share that outcome but differ by reason and what comes next:
  - **`skip`** — merge conflict (Renovate rebases it itself) or a human-edited head (a rebase would discard manual commits); stays skipped until that changes.
  - **`pending`** — already carries the `rebase` label, so a rebase is queued; clears once Renovate acts on it.
  - **`none`** — fresh & green, or mergeability not yet known; re-evaluated next run.

Every PR in the step-summary plan also shows its **blockers** — why GitHub won't merge it right now (failing/pending required check, awaiting required review, changes requested, merge conflict, behind base). Because `mergeable_state: blocked` hides whether the gate is a check or a missing approval, `blocked` PRs are disambiguated with the check-runs API plus GitHub's GraphQL `reviewDecision`. Blockers are independent of the action: a PR `awaiting required review` shows action `—`, since the maintainer can't approve it — only a human can.

## Inputs

| Input | Default | Description |
|:------|:--------|:------------|
| `github-token` | — (required) | Token with `pull-requests: write`, `actions: write`, `checks: read`, `contents: read`. Labeling a PR via the Issues Labels API is authorized by the `pull-requests` scope, not `issues`. |
| `repository` | `${{ github.repository }}` | Target repository (`owner/name`). |
| `exclude-labels` | `keep-updated,stop-updating` | Comma-separated labels that take a PR out of scope. |
| `behind-threshold` | `60` | Rebase when at least this many commits behind base (`B`). |
| `stale-hours` | `24` | Rebase a **behind** PR when its head is at least this many hours old (`C`); a PR level with base is never rebased on age. |
| `rerun-budget` | `0` | Max workflow-run attempts per head SHA before reruns stop (`N`). `0` (default) disables reruns; set to `1`+ to enable. |
| `batch-size` | `10` | Max PRs acted on per run (blast-radius cap). |
| `base-branch` | `""` | Optional exact base-branch filter; empty means all. |
| `extra-trusted-logins` | `""` | Comma- or newline-separated extra logins (author/committer) treated as Renovate-owned, so trusted bots like `github-actions[bot]` don't mark a branch as human-edited. |
| `extra-rerun-checks` | `""` | Comma- or newline-separated check-run names to also treat as required for the rerun decision (unioned with ruleset-discovered checks). Use to retry a non-required/flaky check or one enforced via classic branch protection. |
| `require-up-to-date-strategy` | `none` | How to handle the `behind` state ("require branches up to date"). `none`: ignored, decided by staleness. `automerge`: every behind auto-merging PR is rebased immediately (non-automerge PRs still staleness-driven). `automerge-optimized`: per base branch, only one least-behind **mergeable** auto-merging PR is rebased (blocked ones excluded so they can't stall the train), and only when no auto-merging PR is already merge-ready or being rebased. `all`: every behind PR is rebased immediately. |
| `automerge-labels` | `automerge` | Comma- or newline-separated labels marking a Renovate PR as auto-merging (used only by `require-up-to-date-strategy: automerge`). GitHub native auto-merge is detected too; set empty to rely on that only. |
| `dry-run` | `false` | When true, classify and log only; never modify any PR. |
