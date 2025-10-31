# Check Copilot Commits

Checks for commits co-authored by GitHub Copilot and fails if found.

## Usage

```yaml
- uses: camunda/infra-global-github-actions/check-copilot-commits@main
  with:
    repository: 'owner/repo'
    branch: 'feature-branch'
    base-branch: 'main'
```

## Inputs

| Input | Required | Default |
|-------|----------|---------|
| `repository` | Yes | - |
| `branch` | Yes | - |
| `base-branch` | Yes | `main` |
| `fail-on-copilot-commits` | No | `true` |
