# Check Copilot Commits

Checks for commits authored by GitHub Copilot and optionally co-authored commits. Reports findings with commit hashes and GitHub URLs.

## Usage

```yaml
- uses: camunda/infra-global-github-actions/check-copilot-commits@main
  with:
    repository: 'owner/repo'
    branch: 'feature-branch'
    base-branch: 'main'
    check-co-author: true  # Optional: also check co-authored commits
```

## What it checks

1. **Author field** (always checked): Commits where Copilot is listed as the author in git metadata
2. **Co-authored statements** (optional): Commits containing `Co-authored-by: Copilot` lines in the commit message body

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `repository` | Yes | - | Repository to check (format: owner/repo) |
| `branch` | Yes | - | Branch to check for copilot commits |
| `base-branch` | Yes | `main` | Base branch to compare against |
| `check-co-author` | No | `false` | Whether to also check for co-authored commits in message body |

## Outputs

| Output | Description |
|--------|-------------|
| `copilot-commits-found` | Whether Copilot commits were found (true/false) |
| `copilot-commits-hashes` | Commit hashes of found commits |

## Example with conditional failure

```yaml
- name: Check for Copilot commits
  id: copilot-check
  uses: camunda/infra-global-github-actions/check-copilot-commits@main
  with:
    repository: ${{ github.repository }}
    branch: ${{ github.head_ref }}
    base-branch: ${{ github.base_ref }}

- name: Fail if Copilot commits found
  if: steps.copilot-check.outputs.copilot-commits-found == 'true'
  run: |
    echo "ERROR: Copilot commits are not allowed"
    exit 1
```
