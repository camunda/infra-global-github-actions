# preview-env-comment

This composite Github Action (GHA) can be used to collect and summarize deployment results as a comment at the end of your PR.

This comment is of sticky nature and will be upserted every time a deployment has been executed and this action has been called. The comment will always be placed on the last position in the PR.

The action depends on the outcome of the action `preview-env-create`. If there was no call to said action, no result summary will be created. Otherwise results of each call to  `preview-env-create` in the same workflow run attempt will be summarized.

## Possible Deployment Results
All of the following deployment results will be collected in a comment with a heading like this:

> # :rocket: Deployment Results :rocket:

For `preview-env-create` we have 3 different deployment result templates:

### Success
Please see [this template](../create/templates/comment-success.md).

### Failure
Please see [this template](../create/templates/comment-failure.md).

### Cancelled
Please see [this template](../create/templates/comment-cancelled.md).

## Usage

> [!NOTE]
> To take effect, this action needs to be run after at least one call to `preview-env-create`. Otherwise you won't receive any results and the comment even gets deleted!

### Simple Job
In a simple workflow the summary can be appended like this:
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
      if: always() && needs.deploy-preview.result != 'skipped'
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
    if: always() && needs.deploy-preview.result != 'skipped'
    needs:
    - deploy-preview
    steps:
      - uses: camunda/infra-global-github-actions/preview-env/comment@main
```

### Delete Summary
If you want to delete the summary comment you can simply call it (like outlined above) in a different context where no matching workflow artifacts have been uploaded (e.g. your `teardown` workflow).
Again, 2 examples:

```yaml
#################
# Simple Workflow

...
jobs:
  teardown:
    ...
    - name: Delete Deployment Results
      if: always() && needs.deploy-preview.result != 'skipped'
      uses: camunda/infra-global-github-actions/preview-env/comment@main
    ...

#################
# Matrix Workflow
...
jobs:
  ...
  teardown-stuff: ...
  ...
  comment:
    name: delete-deployment-results
    runs-on: ubuntu-22.04
    if: always() && needs.teardown.result != 'skipped'
    needs:
    - teardown
    steps:
      - uses: camunda/infra-global-github-actions/preview-env/comment@gha-459-preview-env-ux
  ...
```

### Artifact Production
The usage scenarios above only apply, when your workflow has produced artifacts beforehands which follow this naming convention:
```
# Artifact naming convention
deployment-status-${{ github.run_id }}-${{ github.run_attempt }}-*
```

See steps `Create deployment status artifact` and `Upload deployment status as artifact` in the [`create` action](../create/action.yml) on how to upload artifacts properly.

> [!TIP]
> The content of each markdown doesn't matter to the `comment` action, since it's blindly accumulating all artifacts it can find for the same run attempt into a single markdown file.
