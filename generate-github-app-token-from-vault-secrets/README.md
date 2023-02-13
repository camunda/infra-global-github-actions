# generate-github-app-token-from-vault-secrets

This composite Github Action (GHA) is aimed to be used by Camunda teams to generate a GitHub token from Github App secrets (ID & Private Key) stored in Vault.

## Usage

This composite GHA can be used in any repository.

### Inputs
| Input name                          | Description                                                            |
|-------------------------------------|------------------------------------------------------------------------|
| github-app-id-vault-key             | The key of the Vault secret storing the ID of the GitHub App  |
| github-app-id-vault-path            | The path of the Vault secret storing the ID of the GitHub App |
| github-app-private-key-vault-key    | The key of the Vault secret storing the private key of the GitHub App |
| github-app-private-key-vault-path   | The path of the Vault secret storing the private key of the GitHub App |
| vault-auth-method                   | The method to use to authenticate with Vault (*) |
| vault-auth-role-id                  | The Role Id for (Vault) App Role authentication |
| vault-auth-secret-id                | The Secret Id for (Vault) App Role authentication |
| vault-url                           | The URL for the Vault endpoint |

> (*) The above Vault properties only support App Role authentication (`vault-auth-method=approle`) for now. New inputs may be added in the future to support other authentication methods.

### Outputs
| Output name      | Description                 |
|------------------|-----------------------------|
| token            | The generated GitHub token  |

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
        vault-auth-secret-id: ${{ secrets.VAULT_SECRET_ID}}
        vault-url: ${{ secrets.VAULT_ADDR }}
```
