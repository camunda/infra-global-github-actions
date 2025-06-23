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

### Advanced Usage with Custom Configuration

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
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          types: |
            feat
            fix
            docs
            style
            refactor
            test
            build
            ci
            chore
            revert
            perf
          subject-pattern: '^(?![A-Z]).+$'
          ignore-labels: |
            release/pr
            autorelease: pending
            skip-validation
          validate-single-commit: true
```

## Inputs

| Input Name | Required | Default | Description |
|------------|----------|---------|-------------|
| `github-token` | No | `${{ github.token }}` | GitHub token with read access to pull requests |
| `types` | No | Standard types | List of allowed conventional commit types |
| `subject-pattern` | No | `^(?![A-Z]).+$` | Regex pattern for subject validation |
| `ignore-labels` | No | release/pr, autorelease: pending | Labels to skip validation for |
| `validate-single-commit` | No | `true` | Validate commit message for single commit PRs |

## Default Conventional Commit Types

The action supports these conventional commit types by default:

- `feat` - A new feature
- `fix` - A bug fix
- `docs` - Documentation only changes
- `style` - Changes that do not affect the meaning of the code
- `refactor` - A code change that neither fixes a bug nor adds a feature
- `test` - Adding missing tests or correcting existing tests
- `build` - Changes that affect the build system or external dependencies
- `ci` - Changes to CI configuration files and scripts
- `chore` - Other changes that don't modify src or test files
- `revert` - Reverts a previous commit

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

## Integration with Release-Please

This action is particularly useful for repositories that use:

1. `camunda/infra-global-github-actions/teams/infra/pull-request/release@main` for automated releases
2. "Squash & Merge" as the merge strategy
3. Conventional commits for version bumping and changelog generation

## Side Projects Integration

Side projects that use the release action should add this validation to prevent broken releases:

```yaml
# .github/workflows/validate-pr-title.yml
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

## Error Messages

When validation fails, the action provides clear error messages:

- Type validation: "The PR title doesn't match the conventional commit format"
- Subject validation: "The subject line doesn't match the expected pattern"
- Missing type: "No release type found in pull request title"

## Skip Validation

You can skip validation for specific PRs by adding labels:

- `release/pr` - For automated release PRs
- `autorelease: pending` - For pending release PRs
- Custom labels can be configured via the `ignore-labels` input

## Related Actions

- [Release Action](../release/README.md) - Automated release management
- [Automerge Action](../automerge/README.md) - Automated PR merging