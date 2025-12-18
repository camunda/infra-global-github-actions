# argocd-delete-applications

Delete ArgoCD applications by name or label selector, with optional age filtering.

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `argocd-token` | ArgoCD token with delete permissions | Yes | - |
| `github-token` | GitHub token to avoid rate limiting | Yes | - |
| `server` | ArgoCD server URL | No | `argocd.int.camunda.com` |
| `app-name` | Specific app name to delete | No* | - |
| `label-selector` | Label selector to filter apps | No* | - |
| `min-age` | Minimum age before deletion (e.g. `12h`, `2d`) | No | `0` (immediate) |
| `cascade` | Delete app resources (not just the app) | No | `true` |
| `cli-version` | ArgoCD CLI version | No | `3.2.1` |

> *Either `app-name` or `label-selector` must be provided.

## Usage Examples

### Delete a single application

```yaml
- uses: camunda/infra-global-github-actions/argocd-delete-applications@main
  with:
    argocd-token: ${{ steps.secrets.outputs.ARGOCD_TOKEN }}
    github-token: ${{ secrets.GITHUB_TOKEN }}
    app-name: my-preview-app
```

### Delete all apps with labels

```yaml
- uses: camunda/infra-global-github-actions/argocd-delete-applications@main
  with:
    argocd-token: ${{ steps.secrets.outputs.ARGOCD_TOKEN }}
    github-token: ${{ secrets.GITHUB_TOKEN }}
    label-selector: preview-env=smoke-test,repo=camunda/camunda
    # Newline-separated also supported:
    # label-selector: |
    #   preview-env=smoke-test
    #   repo=camunda/camunda
```

### Delete apps older than 12 hours

```yaml
- uses: camunda/infra-global-github-actions/argocd-delete-applications@main
  with:
    argocd-token: ${{ steps.secrets.outputs.ARGOCD_TOKEN }}
    github-token: ${{ secrets.GITHUB_TOKEN }}
    label-selector: preview-env=smoke-test
    min-age: 12h
```

### Delete app without removing managed resources

```yaml
- uses: camunda/infra-global-github-actions/argocd-delete-applications@main
  with:
    argocd-token: ${{ steps.secrets.outputs.ARGOCD_TOKEN }}
    github-token: ${{ secrets.GITHUB_TOKEN }}
    app-name: my-preview-app
    cascade: "false"  # Only delete app, keep Kubernetes resources
```
