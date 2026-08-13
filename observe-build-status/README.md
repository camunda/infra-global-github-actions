# observe-build-status

This composite Github Action (GHA) reports a job's outcome, duration and runner resource usage to [CI Analytics](https://confluence.camunda.com/display/HAN/CI+Analytics).

It wraps [`start-build-monitor`](../start-build-monitor) and [`submit-build-status`](../submit-build-status) together with the Vault plumbing that fetches the CI Analytics credentials, so a repository needs two workflow steps rather than a vendored copy of that plumbing.

## Why this exists

At the time of writing, eleven repositories in the organisation carry their own copy of this wrapper under `.github/actions/observe-build-status/`. They are all descended from the same original, and they have drifted:

- seven of them anchor the build duration on `$GITHUB_ACTION_PATH` instead of the `start-build-monitor` timestamp file, so every duration they report excludes job setup, tool installation and image pulls — silently, with no warning
- four reference `hashicorp/vault-action` by mutable tag, which is refused outright in repositories that enforce GitHub's *Require actions to be pinned to a full-length commit SHA* setting
- `user_description` is documented as 200 characters in six copies and 1000 in the rest; [`submit-build-status`](../submit-build-status) accepts 1000
- most fail the job they are supposed to observe if Vault or BigQuery has a bad day, unless the caller remembers `continue-on-error: true`

Only the Vault secret path genuinely differs between them, so it is an input here.

## Usage

`start-build-monitor` must be the **first** step of the job, and this action the **last**:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write # only for JWT authentication
    steps:
    - uses: camunda/infra-global-github-actions/start-build-monitor@main

    # ... the job's real steps ...

    - name: Observe build status
      if: always()
      uses: camunda/infra-global-github-actions/observe-build-status@main
      with:
        ci_analytics_secret_path: secret/data/products/<product>/ci/ci-analytics
        job_name: ${{ github.job }}
        build_status: ${{ job.status }}
        secret_vault_address: ${{ secrets.VAULT_ADDR }}
        secret_vault_jwt_path: ${{ secrets.VAULT_JWT_PATH }}
        secret_vault_jwt_role: ${{ secrets.VAULT_JWT_ROLE }}
        secret_vault_jwt_audience: ${{ secrets.VAULT_JWT_AUDIENCE }}
```

`if: always()` is required so failed and cancelled jobs are reported. `continue-on-error: true` is **not** required: every step in this action is best-effort, so it cannot fail the job it measures.

For a repository still on AppRole, swap the last three inputs:

```yaml
        secret_vault_roleId: ${{ secrets.VAULT_ROLE_ID }}
        secret_vault_secretId: ${{ secrets.VAULT_SECRET_ID }}
```

### Matrix jobs

`job_name` defaults to `$GITHUB_JOB`, which collapses every leg of a matrix into one row. Pass the matrix values explicitly, separated by `/` — matrix values routinely contain `-`, which makes the column unsplittable otherwise:

```yaml
        job_name: ${{ github.job }}/${{ matrix.runner }}/${{ matrix.version }}
```

### Inputs

| Input name | Description |
|---|---|
| `build_status` | Outcome of the job, normally `${{ job.status }}`: one of `success`, `failure`, `cancelled` |
| `job_name` | Optional. Value recorded in the `job_name` column; defaults to `$GITHUB_JOB` |
| `user_reason` | Optional string (200 chars max) categorising why the job ended this way, e.g. `flaky-tests` |
| `user_description` | Optional string (1000 chars max) detailing `user_reason`, e.g. the list of flaky tests |
| `ci_analytics_secret_path` | Vault path holding the CI Analytics service-account key under `gcloud_sa_key`. By convention `secret/data/products/<product>/ci/ci-analytics` |
| `secret_vault_address` | Vault server URL. The opt-in switch: leave empty to disable reporting entirely |
| `secret_vault_jwt_path` | Vault JWT auth mount path |
| `secret_vault_jwt_role` | Vault JWT auth role. Setting it selects JWT authentication |
| `secret_vault_jwt_audience` | Vault JWT GitHub audience |
| `secret_vault_roleId` | Vault AppRole role ID. Used only when `secret_vault_jwt_role` is empty |
| `secret_vault_secretId` | Vault AppRole secret ID |

### Behaviour

The action is a no-op when `secret_vault_address` is empty, so forks, local runs and repositories that have not opted in are unaffected — no annotations, no failed steps.

When `secret_vault_address` **is** set, the configuration must be complete: `ci_analytics_secret_path`, plus either `secret_vault_jwt_role` or both AppRole inputs. An incomplete set is a configuration mistake rather than an opt-out, and produces a warning naming what is missing. Treating it as "no credentials" instead would leave a repository believing it reports metrics when it does not.

The build duration is derived from the mtime of `/tmp/_monitor-start.pid`, written by `start-build-monitor`. If that file is absent the action warns and omits `build_duration_millis` rather than falling back to a later anchor: an under-reported duration is worse than a missing one in a duration dashboard. Durations outside 0–72h are dropped the same way.

Resource metrics (CPU, memory, network) are collected by `start-build-monitor` and picked up automatically by `submit-build-status`; this action passes nothing for them.

### Authentication

JWT/OIDC is preferred: it stores no long-lived credential as a repository secret. It requires `permissions: id-token: write` on the calling job. AppRole is supported so a repository can adopt this action before migrating, and is skipped as soon as `secret_vault_jwt_role` is set — both sets of inputs can coexist during a migration.

Both AppRole inputs are required together. Authenticating with only one of them cannot succeed, and the resulting failure would be reported as "could not read the secret", pointing at the Vault policy — the one place the problem is not.

## Migrating from a vendored copy

Delete `.github/actions/observe-build-status/` and point the workflow at this action. Input names match the majority of existing copies; two changes are usually needed:

- add `ci_analytics_secret_path`, carrying over the path that was hardcoded in the vendored copy
- drop `continue-on-error: true` from the call site, now redundant

Expect reported durations to **increase** after migrating if the vendored copy anchored on `$GITHUB_ACTION_PATH`: the previous numbers excluded everything before the checkout.
