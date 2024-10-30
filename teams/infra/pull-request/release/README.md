# Release Please GitHub Action

This repository contains a GitHub Action for automating releases using [release-please](https://github.com/googleapis/release-please).

## Features

- Automated release PR creation & updates
- Version bumping based on conventional commits
- Changelog generation

## Usage

To use this action, add the following to your workflow YAML file:

```yaml
name: Handle Release PRs

on:
  push:
    branches:
    - main # the mainline branch may differ for the individual repository

jobs:
  release-please:
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
    - name: Handle Release Creation
      uses: camunda/infra-global-github-actions/teams/infra/pull-request/release@main
      with:
        github-token: ${{ steps.app-token.outputs.token }}
```

## Inputs
* `github-token` (required): GitHub token with permissions to modify pull requests and contents.
* `config-filename` (optional): Filename of a custom release-please configuration file. Default is `.github/config/release-please-config.json` from the action repository.
* `manifest-filename` (optional): Filename of a custom release-please manifest file. Default is `.github/config/release-please-manifest.json`.

## How it works

This action performs two main tasks depending on the commit on your target branch:

1. Updates a release PR based on all conventional commits since the last release.
2. Creates a new release and tags it if the release PR gets merged.

> [!NOTE]
> The PR will grow with each commit until it gets merged.
> You can also automate the merging of these kind of PRs by using the [automerge action](../automerge/README.md) in this repository.
