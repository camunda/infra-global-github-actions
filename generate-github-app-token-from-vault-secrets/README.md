# generate-github-app-token-from-vault-secrets

This composite GitHub Action (GHA) is intended to be used by Camunda teams to generate a GitHub token from GitHub App secrets (ID & Private Key) stored in Vault.

## Usage

This composite GHA can be used in any repository.

### Inputs
| Input name                          | Description                                                            |
|-------------------------------------|------------------------------------------------------------------------|
| github-app-id-vault-key             | The key of the Vault secret storing the ID of the GitHub App            |
| github-app-id-vault-path            | The path of the Vault secret storing the ID of the GitHub App           |
| github-app-private-key-vault-key    | The key of the Vault secret storing the private key of the GitHub App   |
| github-app-private-key-vault-path   | The path of the Vault secret storing the private key of the GitHub App  |
| vault-auth-method                   | The method to use to authenticate with Vault: `approle` or `jwt` (*)    |
| vault-auth-role-id                  | The Role Id for (Vault) App Role authentication (required when `vault-auth-method=approle`) |
| vault-auth-secret-id                | The Secret Id for (Vault) App Role authentication (required when `vault-auth-method=approle`) |
| vault-auth-jwt-path                 | The auth backend path for (Vault) JWT authentication (required when `vault-auth-method=jwt`) |
| vault-auth-jwt-role                 | The role for (Vault) JWT authentication (required when `vault-auth-method=jwt`) |
| vault-auth-jwt-audience             | The GitHub OIDC audience for (Vault) JWT authentication (required when `vault-auth-method=jwt`) |
| vault-url                           | The URL for the Vault endpoint                                          |
| skip-token-revoke                   | If truthy, the token will not be revoked when the current job is complete (optional) |
| owner                               | The owner of the GitHub App installation (defaults to current repository owner, optional). |
| repositories                        | Comma or newline-separated list of repositories for which the GitHub app token will be valid for(defaults to current repository if owner is unset, optional). If you want to generate a token that has access to all repositories of the owner, set this to `!all` and explicitely set an `owner`. |
| permissions                         | JSON object narrowing what the token may do, e.g. `{"contents": "read"}` (optional, defaults to every permission the App holds). See [Permissions](#permissions). |

> (*) Supports both App Role (`vault-auth-method=approle`) and GitHub OIDC/JWT
> (`vault-auth-method=jwt`) authentication. When using `jwt`, the calling job
> must grant `id-token: write` permission so GitHub can mint the OIDC token.

### Outputs
| Output name      | Description                       |
|------------------|-----------------------------------|
| token            | The generated GitHub token        |
| installation-id  | GitHub App installation ID        |
| app-slug         | GitHub App slug                   |

### Permissions

`repositories` scopes **which repositories** the token reaches. `permissions` scopes
**what it may do** to them. Without the second, a token minted for one narrow purpose
still carries everything the App holds on those repositories.

```yaml
    - uses: camunda/infra-global-github-actions/generate-github-app-token-from-vault-secrets@main
      with:
        # ... vault inputs ...
        repositories: infraex-common-config
        permissions: '{"issues": "read", "actions": "write"}'
```

Keys are the scope names accepted by
[`actions/create-github-app-token`](https://github.com/actions/create-github-app-token)
with the `permission-` prefix removed, so `permission-pull-requests` is written
`pull-requests`.

Values are `read`, `write` or `admin`. Which of them a given scope accepts is narrower —
most take `read` or `write`, four also take `admin`, and a handful take only one of the
two — and that is enforced by the API rather than here, so an unsupported *level* for a
supported scope fails at token creation rather than at validation. Upstream's input
descriptions state the accepted values per scope.

An unrecognised key is an error rather than a silent no-op, because a dropped scope would
leave the caller believing the token was narrowed when it was not:

```
::error::unknown permission scope(s): contnets
```

Omitting the input entirely keeps the previous behaviour: the token inherits every
permission the App holds — and is also why `jq`, which the validation uses, is only
required of callers that actually pass `permissions`.

### Workflow Example
```yaml
---
name: example
on:
  pull_request:
jobs:
  configure-pr:
    runs-on: ubuntu-latest
    steps:
    - uses: camunda/infra-global-github-actions/generate-github-app-token-from-vault-secrets@main
      with:
        github-app-id-vault-key: THE_KEY_NAME_OF_THE_VAULT_SECRET_STORING_THE_APP_ID
        github-app-id-vault-path: the/path/of/the/vault/secret/storing/the/app/id
        github-app-private-key-vault-key: THE_KEY_NAME_OF_THE_VAULT_SECRET_STORING_THE_APP_PRIVATE_KEY
        github-app-private-key-vault-path: the/path/of/the/vault/secret/storing/the/app/private/key
        vault-auth-method: approle
        vault-auth-role-id: ${{ secrets.VAULT_ROLE_ID }}
        vault-auth-secret-id: ${{ secrets.VAULT_SECRET_ID }}
        vault-url: ${{ secrets.VAULT_ADDR }}
        skip-token-revoke: false  # Optional, defaults to false if omitted
        owner: ${{ github.repository_owner }}  # Optional, defaults to current repository owner
        repositories: ${{ github.repository }}  # Optional, defaults to current repository
```

#### Using GitHub OIDC/JWT authentication

```yaml
---
name: example
on:
  pull_request:
jobs:
  configure-pr:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write  # mint GitHub OIDC token for Vault JWT auth
    steps:
    - uses: camunda/infra-global-github-actions/generate-github-app-token-from-vault-secrets@main
      with:
        github-app-id-vault-key: THE_KEY_NAME_OF_THE_VAULT_SECRET_STORING_THE_APP_ID
        github-app-id-vault-path: the/path/of/the/vault/secret/storing/the/app/id
        github-app-private-key-vault-key: THE_KEY_NAME_OF_THE_VAULT_SECRET_STORING_THE_APP_PRIVATE_KEY
        github-app-private-key-vault-path: the/path/of/the/vault/secret/storing/the/app/private/key
        vault-auth-method: jwt
        vault-auth-jwt-path: ${{ secrets.VAULT_JWT_PATH }}
        vault-auth-jwt-role: ${{ secrets.VAULT_JWT_ROLE }}
        vault-auth-jwt-audience: ${{ secrets.VAULT_JWT_AUDIENCE }}
        vault-url: ${{ secrets.VAULT_ADDR }}
```

### Token Generation

The generated token is created using the [create-github-app-token](https://github.com/actions/create-github-app-token/) action. For more details on how the token is generated and its use, please refer to the documentation of the create-github-app-token action.
