# Testing

## What

Which actions have a CI test, which usage paths it covers, and which risks are accepted.

## Why

Other repositories consume these actions directly from `main`. A broken action breaks their CI, and Renovate bumps tools inside the actions without anyone running them.

## How

### Argo CD CLI (`quay.io/argoproj/argocd`)

Test: [`.github/workflows/test-preview-env.yml`](.github/workflows/test-preview-env.yml), against the real Argo CD at `argocd.int.camunda.com`. It deploys a ConfigMap-only app (`preview-env/test/`) into the `infra-actions-previews` project, asserts `Synced/Healthy`, syncs it, destroys it and asserts it is gone. It prints `argocd version` (client and server), so a client/server skew shows up in the run.

| Usage path | Consumers | Covered by |
|---|---|---|
| `preview-env/create`: CLI download and cache, `app create --upsert`, `app get`, `app sync --async --force`, health polling | camunda, connectors, cawemo, identity, camunda-hub | `test-preview-env.yml`, step "Deploy the test app" |
| `preview-env/destroy`: `app delete --yes` | same | `test-preview-env.yml`, steps "Destroy the test app" and "Assert the app is gone" |
| `argocd-sync-applications`: `app sync`, `app wait --sync`, `app wait --health` | none found | `test-preview-env.yml`, step "Sync the app through argocd-sync-applications" |

Not covered: Teleport and Kubernetes events on failure, the GitHub environment deletion (needs `administration:write`), and `argocd-delete-applications` (not in the Renovate bump).

The `infra-actions-previews` Argo CD project and its token are defined in `camunda/infra-core`. The token lives in Vault at `secret/products/infra/ci/infra-actions-previews` (key `ARGOCD_TOKEN`).
