# Testing

## What

Which actions have a CI test, which usage paths it covers, and which risks are accepted.

## Why

Other repositories consume these actions directly from `main`. A broken action breaks their CI, and Renovate bumps tools inside the actions without anyone running them.

## How

### Argo CD CLI (`quay.io/argoproj/argocd`)

Test: [`.github/workflows/test-preview-env.yml`](.github/workflows/test-preview-env.yml), against the real Argo CD at `argocd.int.camunda.com`. It deploys a small chart (`preview-env/test/chart`: a Namespace and a ConfigMap, so destroying the app removes its namespace) into the `infra-actions-previews` project, asserts `Synced/Healthy`, syncs it, destroys it and asserts it is gone. It prints `argocd version` (client and server), so a client/server skew shows up in the run.

| Usage path | Consumers | Covered by |
|---|---|---|
| `preview-env/create`: CLI download and cache, `app create --upsert`, `app get`, `app sync --async --force`, health polling | camunda, connectors, cawemo, identity, camunda-hub | `test-preview-env.yml`, step "Deploy the test app" |
| `preview-env/destroy`: `app delete --yes` | same | `test-preview-env.yml`, steps "Destroy the test app" and "Assert the app is gone" |
| `argocd-sync-applications`: `app sync`, `app wait --sync`, `app wait --health` | none found | `test-preview-env.yml`, step "Sync the app through argocd-sync-applications" |

Not covered: Teleport and Kubernetes events on failure, the GitHub environment deletion (needs `administration:write`), and `argocd-delete-applications` (not in the Renovate bump).

The `infra-actions-previews` Argo CD project and its token are defined in `camunda/infra-core`. The token lives in Vault at `secret/products/infra/ci/infra-actions-previews` (key `ARGOCD_TOKEN`).

### Stale backport tracker (`stale-backport-tracker`)

Test: [`.github/workflows/test-stale-backport-tracker.yml`](.github/workflows/test-stale-backport-tracker.yml), offline, against a stub `gh` (`stale-backport-tracker/test/bin/gh`) that serves generated fixtures. The `scripts` job runs `stale-backport-tracker/test/run-tests.sh` over the collect, format and notify scripts. The `actions` job runs the three composite actions through the stub and asserts their outputs.

| Usage path | Consumers | Covered by |
|---|---|---|
| `collect`: `stable/` and `self-managed/` prefixes, exact `target-branch`, threshold, backport authors, grouping and enrichment | camunda, camunda-hub | `run-tests.sh` "collect" checks, job `actions` |
| `format-slack`: default and custom title, cc footer, clean report | same | `run-tests.sh` "format" checks, job `actions` |
| `notify-github`: dry run (comment body, mentions) | same | `run-tests.sh` "notify" checks, job `actions` |

Not covered, and an accepted risk pending sign-off by the maintainers:

- The reusable workflow `.github/workflows/stale-backport-tracker.yml`: Vault and GitHub App token steps, the Slack find, update, pin and unpin calls, and the real `gh` and Slack API behaviour (including whether the `base:` search qualifier matches a `self-managed/` prefix before the post-filter). The workflow calls its composite actions at `@main`, so a pull request cannot exercise its own version of them. It is verified by a `dry_run: true` run from each caller, which prints the Slack blocks to the job summary and writes nothing.
- The real Slack API.
