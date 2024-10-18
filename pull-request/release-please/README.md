# Release Please GitHub Action

This repository contains a GitHub Action for automating releases using [release-please](https://github.com/googleapis/release-please).

## Features

- Automated release PR creation & updates
- Version bumping based on conventional commits
- Changelog generation

## Usage

To use this action, add the following to your workflow YAML file:

```yaml
name: Release Please

on:
  push:
    branches:
      - main

# Assign required permissions to the default github token
permissions:
  contents: write
  pull-requests: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - name: Run Release Please
        uses: camunda/infra-global-github-actions/pull-request/release-please@main
        with:
          token: ${{ secrets.GITHUB_TOKEN }}

```

## Inputs
* `github-token` (required): GitHub token with permissions to modify pull requests and contents.
* `config-filename` (optional): Filename of a custom release-please configuration file. Default is release-please-config.json from the action repository.
* `manifest-filename` (optional): Filename of a custom release-please manifest file. Defaults to the root of the caller's repository (.release-please-manifest.json).

## How it works

This action performs two main tasks depending on the commit on your target branch:

1. Updates a release PR based on all conventional commits since the last release.
2. Creates a new release and tags it if the release PR gets merged.

> [!NOTE]
> The PR will grow with each commit until it gets merged.
> You can also automate the merging of these kind of PRs by using the [automerge action](../automerge/README.md) in this repository.
