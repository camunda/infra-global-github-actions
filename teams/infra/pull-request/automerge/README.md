# Automerge GitHub Action

This GitHub Action automatically merges pull requests based on a label filter.

> [!NOTE]
> We introduced this wrapper action to be able to easily change what's under the hood.
> At the moment that's `pascalgn/automerge-action`, but this may change in the future.
> And if that's happens we only have to do the adaption here.

## Usage

To use this action, create a workflow file in your repository (e.g., `.github/workflows/automerge.yml`):

```yaml
name: Automerge Release PRs

on:
  schedule:
  - cron: '0 9 * * 6'
  workflow_dispatch:

jobs:
  automerge:
    runs-on: ubuntu-latest
    steps:
    - name: Create Release
      uses: camunda/infra-global-github-actions/pull-request/automerge@main
      with:
        label: <yourCustomLabel> # optional, defaults to 'autorelease: pending'
        vault-addr: ${{ secrets.VAULT_ADDR }}
        vault-role-id: ${{ secrets.VAULT_ROLE_ID }}
        vault-secret-id: ${{ secrets.VAULT_SECRET_ID}}
```
