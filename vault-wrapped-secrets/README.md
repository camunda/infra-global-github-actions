# vault-wrapped-secrets

## 📌 What

Two composite actions that hand Vault secrets to a job without giving that job any way to log in to Vault:

- `wrap` logs in with the job's GitHub OIDC token, reads the listed secrets and returns a single-use Vault response-wrapping token.
- `unwrap` redeems that token in another job and exposes the secrets there, masked.

## 🤔 Why

`id-token: write` applies to a whole job. Any process in a job with it can request an OIDC token and log in with the repository's Vault role, which can read far more than one secret. A job that runs an AI agent or other untrusted code therefore gets its secrets through `unwrap` and never holds `id-token: write`. See [Vault secrets in agentic workflows](https://github.com/camunda/infra-core/blob/stage/docs/vault/vault-secrets-in-agentic-workflows.md).

The wrapping token crosses the job boundary as a job output, which GitHub does not mask. Pass it into the consuming job as a reusable-workflow secret (below): GitHub then masks it everywhere in that job, including the inputs of `unwrap`. A token handed over as a plain job output is printed in clear text in the consuming job's log. The token is single-use and short-lived. `unwrap` fails when the token expired, was already redeemed, or was not created by `sys/wrapping/wrap`; it cannot tell apart two tokens that were both created there.

## 🔧 How

The job that runs the agent lives in its own workflow and receives the wrapping token as a secret:

```yaml
# .github/workflows/agent-caller.yml
jobs:
  secrets:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
    outputs:
      wrap-token: ${{ steps.wrap.outputs.wrap-token }}
    steps:
    - id: wrap
      uses: camunda/infra-global-github-actions/vault-wrapped-secrets/wrap@<sha> # vault-wrapped-secrets-<version>
      with:
        vault-url: ${{ secrets.VAULT_ADDR }}
        vault-auth-jwt-path: ${{ secrets.VAULT_JWT_PATH }}
        vault-auth-jwt-role: ${{ secrets.VAULT_JWT_ROLE }}
        vault-auth-jwt-audience: ${{ secrets.VAULT_JWT_AUDIENCE }}
        secrets: |
          secret/data/products/<team>/ci/common ANTHROPIC_API_KEY | ANTHROPIC_API_KEY;
        wrap-ttl: 5m

  agent:
    needs: secrets
    permissions:
      contents: read  # no id-token
    uses: ./.github/workflows/agent.yml
    secrets:
      VAULT_ADDR: ${{ secrets.VAULT_ADDR }}
      WRAP_TOKEN: ${{ needs.secrets.outputs.wrap-token }}
```

```yaml
# .github/workflows/agent.yml
on:
  workflow_call:
    secrets:
      VAULT_ADDR:
        required: true
      WRAP_TOKEN:
        required: true

jobs:
  agent:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
    - id: unwrap
      uses: camunda/infra-global-github-actions/vault-wrapped-secrets/unwrap@<sha> # vault-wrapped-secrets-<version>
      with:
        vault-url: ${{ secrets.VAULT_ADDR }}
        wrap-token: ${{ secrets.WRAP_TOKEN }}
    - run: ./run-agent.sh
      env:
        ANTHROPIC_API_KEY: ${{ fromJSON(steps.unwrap.outputs.secrets).ANTHROPIC_API_KEY }}
```

With a matrix, wrap one token per shard and select it in the caller: `WRAP_TOKEN: ${{ needs.secrets.outputs[format('wrap-token-{0}', matrix.shard)] }}`.

### `wrap` inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `vault-url` | yes | | Vault address |
| `vault-auth-jwt-path` | yes | | JWT auth mount (`VAULT_JWT_PATH`) |
| `vault-auth-jwt-role` | yes | | JWT role (`VAULT_JWT_ROLE`) |
| `vault-auth-jwt-audience` | yes | | OIDC audience (`VAULT_JWT_AUDIENCE`) |
| `secrets` | no | | One `<kv-v2 path> <key> \| <NAME>` per line |
| `values` | no | | JSON object of strings produced in this job, e.g. a GitHub App token minted with `skip-token-revoke: true` |
| `wrap-ttl` | no | `5m` | Lifetime of the wrapping token |

Output: `wrap-token`.

### `unwrap` inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `vault-url` | yes | | Vault address |
| `wrap-token` | yes | | `wrap-token` output of `wrap` |
| `export-env` | no | `false` | Also export each secret as an environment variable |

Output: `secrets`, a JSON object `{NAME: value}`.

Wrap only what the consuming job needs, make `unwrap` the first step of the consuming job, and keep `wrap-ttl` to a few minutes. Do not enable step debug logging on a run that wraps: the runner then prints the job output, and with it the unused wrapping token, in the wrap job's log. A wrapping token can be redeemed once, so a failed consumer job is retried with **Re-run all jobs**; **Re-run failed jobs** reuses the spent token and fails at `unwrap`. When `unwrap` reports a rejected token on the first run attempt, someone else may have redeemed it. To hand over a GitHub App token, generate it in the broker job with `generate-github-app-token-from-vault-secrets` and `skip-token-revoke: true` (the job would otherwise revoke it on exit) and pass it in `values`. The unwrapped values are in the job's memory and environment afterwards, so an agent can still read the secrets it was given, just nothing else.

## 📚 References

- [Vault response wrapping](https://developer.hashicorp.com/vault/docs/concepts/response-wrapping)
- [camunda/team-infrastructure#1076](https://github.com/camunda/team-infrastructure/issues/1076)
- First implementation: [camunda/pr-review-agent#5](https://github.com/camunda/pr-review-agent/pull/5)
