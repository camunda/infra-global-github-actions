# preview-env-comment

This composite Github Action (GHA) can be used to collect and summarize deployment results as a comment at the end of your PR.

This comment is of sticky nature and will be upserted every time a deployment has been executed and this action has been called. The comment will always be placed on the last position in the PR.

The action depends on the outcome of the action `preview-env-create`. If there was no call to said action, no result summary will be created. Otherwise results of each call to  `preview-env-create` in the same workflow run attempt will be summarized.

## Possible Deployment Results
All of the following deployment results will be collected in a comment with a heading like this:

> # :rocket: Deployment Results :rocket:

### Success
A success text contains the `app_name` and `app_url` handed to `preview-env-create` and looks like this:

> :full_moon_with_face: [app_name](https://argo-cd.readthedocs.io): success

### Failure
A failure text contains the `app_name` and a link to the `argocd_server` (defaults to: `argocd.int.camunda.com`) with prefiltered results (status: degraded, search: `revision`)

> :boom: `app_name`: failure :arrow_right: see [ArgoCD Dummy URL](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/)

## Usage

> [!NOTE]
> To take effect, this action needs to be run after at least one call to `preview-env-create`. Otherwise you won't receive any results and no comment will be upserted.

### Simple Job
In a job which isn't part of any matrix the summary can be appended like this:
```yaml
...
jobs:
  deploy-preview:
    ...
    #########################################################################
    # Sample Deployment Call
    - name: Deploy Preview Environment
      uses: camunda/infra-global-github-actions/preview-env/create@main
      id: deploy
      with:
        revision: ${{ env.BRANCH_NAME }}
        argocd_token: ${{ steps.secrets.outputs.ARGOCD_TOKEN }}
        app_name: app-name
        app_url: https://app-name.camunda.cloud
        argocd_arguments: ${{ env.argocd_arguments }}

    #########################################################################
    # Summarize Deployment results
    - name: Summarize Deployment Results
      uses: camunda/infra-global-github-actions/preview-env/comment@main
    ...
```

### Matrix Job
For a matrix job it's slightly different. You have to call the action in a subsequent job like this:
```yaml
...
jobs:
  deploy-preview:
    strategy:
      fail-fast: false # Don't disrupt other deployments because of failure
      matrix:
        product_context:
          - permutation1
          - permuation2
    ...
    #########################################################################
    # Sample Deployment Call - Matrix
    - name: Deploy Preview Environment for ${{ matrix.product_context }}
        uses: camunda/infra-global-github-actions/preview-env/create@main
        id: deploy
        with:
        revision: ${{ env.BRANCH_NAME }}
        argocd_token: ${{ steps.secrets.outputs.ARGOCD_TOKEN }}
        app_name: app-name-${{ matrix.product_context }}
        app_url: https://${{ matrix.product_context }}.app-name.camunda.cloud
        argocd_arguments: ${{ env.argocd_arguments }}
  #########################################################################
  # Summarize Deployment Results
  summarize:
    name: summarize-deployment-results
    runs-on: ubuntu-22.04
    if: always()
    needs:
    - deploy-preview
    steps:
      - uses: camunda/infra-global-github-actions/preview-env/comment@main
```
