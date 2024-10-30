# Automerge GitHub Action

This GitHub Action automatically merges pull requests based on a label filter.

> [!NOTE]
> We introduced this wrapper action to be able to easily change what's under the hood.
> At the moment that's `pascalgn/automerge-action`, but this may change in the future.
> And if that's happens we only have to do the adaption here.

## Usage

To use this action, create a workflow file in your repository (e.g., `.github/workflows/automerge.yml`):

```yaml
name: Automerge Release-Please PRs

on:
  schedule:
  - cron: '35 4 * * 1' # runs every Monday at 04:35 UTC

jobs:
  auto-merge:
    runs-on: ubuntu-latest
    steps:
    - name: Import Secrets
      id: vault-secrets
      uses: hashicorp/vault-action@v3.0.0
      with:
        url: ${{ secrets.VAULT_ADDR }}
        method: approle
        roleId: ${{ secrets.VAULT_ROLE_ID }}
        secretId: ${{ secrets.VAULT_SECRET_ID}}
        secrets: |
          secret/data/products/infra/ci/infra-releases RELEASES_APP_ID;
          secret/data/products/infra/ci/infra-releases RELEASES_APP_KEY;
    - name: Generate a GitHub token for infra-rerun camunda/infra-global-github-actions
      id: app-token
      uses: actions/create-github-app-token@v1
      with:
        app-id: ${{ steps.vault-secrets.outputs.RELEASES_APP_ID }}
        private-key: ${{ steps.vault-secrets.outputs.RELEASES_APP_KEY }}
    - name: Automerge Release-Please PR
      uses: camunda/infra-global-github-actions/teams/infra/pull-request/automerge@main
      with:
        github-token: ${{ steps.app-token.outputs.token }}
```
