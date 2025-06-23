# Validate PR Title GitHub Action

This GitHub Action validates pull request titles against conventional commit format. It's specifically designed for side projects that use the release-please action to ensure PR titles comply with conventional commit standards when using "Squash & Merge".

## Problem Statement

When using "Squash & Merge" on GitHub, the PR title becomes the commit message. If the PR title doesn't follow conventional commit format, it can break the release-please workflow, preventing new release PRs from being created.

## Features

- Validates PR titles against conventional commit format
- Configurable commit types (feat, fix, docs, etc.)
- Subject pattern validation (e.g., no uppercase first letter)
- Support for ignoring specific labels (like release PRs)
- Validates single commit PRs when using squash merge

## Usage

### Basic Usage

Add this to your workflow file (e.g., `.github/workflows/validate-pr-title.yml`):

```yaml
---
name: Validate PR Title

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

jobs:
  validate-title:
    runs-on: ubuntu-latest
    steps:
      - name: Validate PR title
        uses: camunda/infra-global-github-actions/teams/infra/pull-request/validate-title@main
```

## Inputs

| Input Name | Required | Default | Description |
|------------|----------|---------|-------------|
| `github-token` | No | `${{ github.token }}` | GitHub token with read access to pull requests |
| `types` | No | Standard types | List of allowed conventional commit types |
| `subject-pattern` | No | `^(?![A-Z]).+$` | Regex pattern for subject validation |

## Examples of Valid PR Titles

- `feat: add new user authentication`
- `fix: resolve memory leak in data processing`
- `docs: update installation instructions`
- `chore: upgrade dependencies to latest versions`
- `refactor: simplify error handling logic`

## Examples of Invalid PR Titles

- `Add new feature` (missing type)
- `feat: Add new feature` (subject starts with uppercase)
- `Feature: add authentication` (invalid type)
- `fix` (missing subject)