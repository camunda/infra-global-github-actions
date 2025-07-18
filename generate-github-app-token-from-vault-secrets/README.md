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
| vault-auth-method                   | The method to use to authenticate with Vault (*)                        |
| vault-auth-role-id                  | The Role Id for (Vault) App Role authentication                         |
| vault-auth-secret-id                | The Secret Id for (Vault) App Role authentication                       |
| vault-url                           | The URL for the Vault endpoint                                          |
| skip-token-revoke                   | If truthy, the token will not be revoked when the current job is complete (optional) |
| owner                               | The owner of the GitHub App installation (defaults to current repository owner, optional). |
| repositories                        | Comma or newline-separated list of repositories for which the GitHub app token will be valid for(defaults to current repository if owner is unset, optional). If you want to generate a token that has access to all repositories of the owner, set this to `!all` and explicitely set an `owner`. |

> (*) The above Vault properties only support App Role authentication (`vault-auth-method=approle`) for now. New inputs may be added in the future to support other authentication methods.

### Outputs
| Output name      | Description                       |
|------------------|-----------------------------------|
| token            | The generated GitHub token        |
| installation-id  | GitHub App installation ID        |
| app-slug         | GitHub App slug                   |

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

### Token Generation

The generated token is created using the [create-github-app-token](https://github.com/actions/create-github-app-token/) action. For more details on how the token is generated and its use, please refer to the documentation of the create-github-app-token action.
