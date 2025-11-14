# Rerun Failed Run Action

Retriggers failed GitHub Actions workflows, with optional error message filtering.

## Features

- **Unconditional Retry**: Retry immediately when `error-messages` is empty
- **Conditional Retry**: Only retry if specific error messages are found in logs
- **Error Propagation**: Notify back when errors don't match specified patterns
- **Scope Control**: Retry failed jobs only or entire workflow

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `run-id` | Yes | - | Workflow run ID to retry |
| `repository` | Yes | - | Repository in `owner/repo` format |
| `vault-addr` | Yes | - | Vault URL |
| `vault-role-id` | Yes | - | Vault role ID |
| `vault-secret-id` | Yes | - | Vault secret ID |
| `error-messages` | No | `''` | Error messages to check for (one per line). Empty = retry immediately |
| `notify-back-on-error` | No | `false` | Notify when errors don't match |
| `rerun-whole-workflow` | No | `false` | Retry entire workflow vs failed jobs only |

## Examples

### Immediate Retry
```yaml
- uses: camunda/infra-global-github-actions/rerun-failed-run@main
  with:
    run-id: ${{ github.run_id }}
    repository: ${{ github.repository }}
    vault-addr: ${{ secrets.VAULT_ADDR }}
    vault-role-id: ${{ secrets.VAULT_ROLE_ID }}
    vault-secret-id: ${{ secrets.VAULT_SECRET_ID }}
```

### Conditional Retry
```yaml
- uses: camunda/infra-global-github-actions/rerun-failed-run@main
  with:
    error-messages: |
      Process completed with exit code 1
      Connection timeout
    run-id: ${{ github.run_id }}
    repository: ${{ github.repository }}
    vault-addr: ${{ secrets.VAULT_ADDR }}
    vault-role-id: ${{ secrets.VAULT_ROLE_ID }}
    vault-secret-id: ${{ secrets.VAULT_SECRET_ID }}
```

## How It Works

The action first analyzes job logs for specified error patterns (if provided), then decides whether to retry. If target errors are found or no filtering is specified, it triggers the retry workflow via GitHub API. When enabled, it can also notify back about non-matching errors via workflow dispatch.

## Best Practices

Limit retry attempts with conditions like `github.run_attempt < 3` to prevent infinite loops. Place retry logic in a separate job with proper dependencies. Use specific error patterns to avoid unnecessary retries.
