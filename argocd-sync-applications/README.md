# argocd-sync-applications

This composite Github Action (GHA) is aimed to be used by the Camunda Infrastructure team for synchronizing ArgoCD applications.

## Usage

This composite GHA can be used in any repository.

### Inputs
|       Input name        | Description                                                                                                                                                          |      Required      | Default |
| :---------------------: | :------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :----------------: | :-----: |
|        app-name         | ArgoCD application to be synced.                                                                                                                                     | :heavy_check_mark: |         |
|      argocd-token       | ArgoCD token with sufficient permissions to sync the ArgoCD application.                                                                                             | :heavy_check_mark: |         |
|      github-token       | A GitHub token to get a higher GitHub's API rate limit to avoid limitations when pulling the ArgoCD CLI from the ArgoCD repository.                                  | :heavy_check_mark: |         |
|       cli-version       | Version of the ArgoCD CLI to use.                                                                                                                                    |                    |         |
| max-waiting-time-health | The time (in seconds) to wait for the ArgoCD application to be healthy (does not wait if set to 0).                                                                  |                    |   600   |
|  max-waiting-time-sync  | The time (in seconds) to wait for the ArgoCD application to be synced (does not wait if set to 0).                                                                   |                    |   30    |
|         server          | URL of the ArgoCD server. | :heavy_check_mark: |         |


### Workflow Example
```yaml
---
name: example
on:
  push:
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
    - uses: camunda/infra-global-github-actions/argocd-sync-applications@main
      with:
        app-name: my-argocd-app-name
        argocd-token: my-argocd-token-***
        github-token: my-github-token-***
        server: dev
```