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
    permissions:
      id-token: write
    steps:
    - name: Import Secrets
      id: vault-secrets
      uses: hashicorp/vault-action@892a26828f195e65540a40b4768ae4571f51ebfc # v4.0.0
      with:
        url: ${{ secrets.VAULT_ADDR }}
        method: jwt
        role: ${{ secrets.VAULT_JWT_ROLE }}
        path: ${{ secrets.VAULT_JWT_PATH }}
        jwtGithubAudience: ${{ secrets.VAULT_JWT_AUDIENCE }}
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
        author: infra-releases[bot]
```

## Inputs

| Input          | Default     | Description                                                                                    |
| -------------- | ----------- | ------------------------------------------------------------------------------------------------ |
| `github-token` |             | Token with permissions to modify pull requests, contents and actions.                          |
| `label`        | `automerge` | Label a pull request must carry to be merged.                                                  |
| `author`       | (none)      | Restricts merging to pull requests raised by this author (e.g. `infra-releases[bot]`). Any user with write access can still add the `automerge` label to a PR, so set `author` whenever this workflow is meant for release-please PRs only, otherwise it merges any labeled PR regardless of origin. |
