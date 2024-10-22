# Automerge GitHub Action

This GitHub Action automatically merges pull requests based on a label filter.

> [!NOTE]
> We introduced this wrapper action to be able to easily change what's under the hood.
> At the moment that's `pascalgn/automerge-action`, but this may change in the future.
> And if that's happens we only have to do the adaption here.

## Usage

To use this action, create a workflow file in your repository (e.g., `.github/workflows/automerge.yml`):

```yaml
name: Automerge on the Weekend

on:
  schedule:
  - cron: '0 9 * * 6'
  workflow_dispatch:

permissions:            # Additional permissions for standard GITHUB_TOKEN
  contents: write       # so we can modify the changelog
  pull-requests: write  # so release-please can create/update PRs
  actions: write        # so subsequent actions can run

jobs:
  automerge:
    runs-on: ubuntu-latest
    steps:
    - name: Create Release
      uses: camunda/infra-global-github-actions/pull-request/automerge@main
      with:
        github-token: ${{ secrets.GITHUB_TOKEN }}
        label: <yourCustomLabel> # optional, defaults to 'autorelease: pending'
```
