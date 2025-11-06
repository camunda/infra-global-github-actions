### Retrigger Failed Run Action

This composite GitHub Action can be used to retrigger runs which have failed.

### Usage

> [!IMPORTANT]
> This action must be called only once per workflow run (preferably in a separate job as shown in the examples below). Calling it multiple times within the same workflow run will trigger simultaneous retry attempts, which will lead to issues.

To call this action, you need to provide:
- the ID of a failed GitHub Action workflow run to rerun
- an error message that needs to be present in the workflow run logs
This targeted approach helps retrigger only those runs that failed due to the specified error.
You also need to ensure that the repository from which you invoke this composite action has the following secrets configured: `VAULT_ADDR`, `VAULT_ROLE_ID`, and `VAULT_SECRET_ID`.
If these secrets are not present, please contact the infrastructure team to set them up for you.

### Inputs

| Input name                 | Description                                                                                                                                  |
|----------------------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| run-id (required)          | The ID of the failed workflow run to be retried.                                                                                             |
| error-messages  |       The error messages to check for in the workflow run logs. The workflow will be rerun only if at least one of the given messages is found in the logs of a failed job If not provided, the workflow will retry directly without checking the logs.                                                                                             |
| repository (required)      | The name of the repository containing the workflow to be retried in the format ORG/REPO_NAME (example: `camunda/infra-global-github-action`) |
| vault-addr (required)      | The Vault URL.                                                                                                                               |
| vault-role-id (required)   | The Vault Role ID.                                                                                                                           |
| vault-secret-id (required) | The Vault Secret ID.                                                                                                                         |
| notify-back-on-error       | When the error message does not match with the expected one, re-trigger the workflow with the parameter `notify_back_error_message`. Your calling workflow must implement the `notify_back_error_message` parameter and forward the error. This allows you to capture failures that are not related to a specific error. Default is `"false"`. |
| rerun-whole-workflow       | If set to true, the workflow will be re-triggered in its entirety. This is useful when you want to retry the entire workflow instead of just failed jobs. Default is `"false"`. |

### Workflow Example without error propagation

This example shows how you can call this GitHub Action (GHA) from your CI without handling cases where a non-captured error is not propagated.

```yaml
jobs:
  build:
    runs-on: gcp-core-2-default
    ...

  # rerun the failed job
  rerun-failed-jobs:
    needs: build
    if: failure() && fromJSON(github.run_attempt) < 3 # This limits the job to only be retried two times
    runs-on: ubuntu-latest
    steps:
      - name: Retrigger job
        uses: camunda/infra-global-github-actions/rerun-failed-run@main
        with:
          error-messages: |
            Process completed with exit code 1.
            Process completed with exit code 99
          run-id: ${{ github.run_id }}
          repository: ${{ github.repository }}
          vault-addr: ${{ secrets.VAULT_ADDR }}
          vault-role-id: ${{ secrets.VAULT_ROLE_ID }}
          vault-secret-id: ${{ secrets.VAULT_SECRET_ID }}
```


### Workflow Example with error propagation

This example shows you how to propagate an error that is not supposed to be captured by the retry action.

It requires you to implement a `workflow_dispatch` event with a `notify_back_error_message` input and a `triage` step that displays the error.

```yaml
  workflow_dispatch:
    inputs:
      notify_back_error_message:
        description: |-
          Error message if retry was not successful.
          This parameter is used for internal call back actions.
        required: false
        default: ''

jobs:
  triage:
    runs-on: ubuntu-22.04
    steps:
      - name: Display notify_back_error_message if present
        if: ${{ inputs.notify_back_error_message != '' }}
        run: |
          echo "A previous workflow failed but has attempted to retry: ${{ inputs.notify_back_error_message }}"
          exit 1

  build:
    runs-on: gcp-core-2-default
    ...

  # rerun the failed job
  rerun-failed-jobs:
    needs: build
    if: failure() && fromJSON(github.run_attempt) < 3 # This limits the job to only be retried two times
    runs-on: ubuntu-latest
    steps:
      - name: Retrigger job
        uses: camunda/infra-global-github-actions/rerun-failed-run@main
        with:
          error-messages: |
            Process completed with exit code 1.
            Process completed with exit code 99
          run-id: ${{ github.run_id }}
          repository: ${{ github.repository }}
          vault-addr: ${{ secrets.VAULT_ADDR }}
          vault-role-id: ${{ secrets.VAULT_ROLE_ID }}
          vault-secret-id: ${{ secrets.VAULT_SECRET_ID }}

          notify-back-on-error: "true" # <--- In case of an error not captured by the GHA, the same workflow will be called again, and the triage step will show the error.
```
