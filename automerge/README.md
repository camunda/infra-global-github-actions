# Automerge GitHub Action

This GitHub Action automatically merges pull requests based on a label filter.

## Usage

To use this action, create a workflow file in your repository (e.g., `.github/workflows/automerge.yml`):

```yaml
name: Automerge on the Weekend

on:
  schedule:
    - cron: '0 9 * * 6'
  workflow_dispatch:

jobs:
  automerge:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4
      # you can skip the create-github-app-token step, if using a PAT instead of a Github App
      - name: Create Github Token
        uses: actions/create-github-app-token@v1
        id: app-token
        with:
          app-id: 1234567 # make sure the app can modify PRs, contents and actions
          private-key: ${{ secrets.APP_PRIVATE_KEY }} # needs to be set on repo or orga level
      - name: Create Release
        uses: camunda/infra-global-github-actions/automerge@main
        with:
          github-token: ${{ steps.app-token.outputs.token }}
          label: <yourCustomLabel> # optional, defaults to 'autorelease: pending'
```
