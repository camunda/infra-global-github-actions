# submit-aborted-gha-status

This composite Github Action (GHA) is intended to be used by Camunda teams for submitting status of aborted GHA workflow jobs to [CI Analytics](https://confluence.camunda.com/display/HAN/CI+Analytics). This allows to identify problems with the underlying (self-hosted) runners at scale.

## Usage

This composite GHA can be used in any repository that was set up to provide credentials for accessing the central Google Big Query (BQ) database (credentials via Vault).

### Inputs

| Input name           | Description                                        |
|----------------------|----------------------------------------------------|
| gcp_credentials_json | Credentials for a Google Cloud ServiceAccount allowed to publish to Big Query formatted as contents of credentials.json file |

Please check out Camunda's [Github Actions Recipes](https://github.com/camunda/github-actions-recipes#secrets=) for how to retrieve secrets from Vault.

### Behavior

This action should be invoked by a GHA job which runs (via `needs`) after all other jobs in a GHA workflow. It will check all failed GHA jobs of this workflow run for problems with the underlying runner (via GHA workflow annotations). In case a job got aborted due to such problems it will not have been able to send CI Analytics data itself, so this action does it on behalf of the aborted job.

All data submitted by this action is stored as one record in the Big Query table `build_status_v2` which retains records for 90 days and has the following fields in BQ:

| Field Name       | Field Type | Field Mode | Description/Purpose |
|------------------|------------|------------|---------------------|
| report_time      | TIMESTAMP  | REQUIRED   | Time of record submission |
| ci_url           | STRING     | REQUIRED   | Github repository URL from `"$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"` |
| workflow_name    | STRING     | NULLABLE   | GHA workflow name from `"$GITHUB_WORKFLOW"` |
| job_name         | STRING     | REQUIRED   | GHA workflow job ID of the aborted job |
| build_id         | STRING     | REQUIRED   | GHA workflow run ID from `"$GITHUB_RUN_ID/$GITHUB_RUN_ATTEMPT"` |
| build_trigger    | STRING     | NULLABLE   | Github event name from `"$GITHUB_EVENT_NAME"` |
| build_status     | STRING     | REQUIRED   | `"aborted"` |
| build_ref        | STRING     | NULLABLE   | Git object reference from `"$GITHUB_REF"` |
| build_base_ref   | STRING     | NULLABLE   | Git object reference of target branch for PRs or GH merge queue |
| build_head_ref   | STRING     | NULLABLE   | Git object reference of the branch PR was built against |
| build_duration_milliseconds | INTEGER | NULLABLE | `null` (not implemented yet) |
| runner_name      | STRING     | NULLABLE   | Lowercase name of the runner executing the GHA workflow job |
| runner_arch      | STRING     | NULLABLE   | `null` (cannot be determined afterwards) |
| runner_os        | STRING     | NULLABLE   | `null` (cannot be determined afterwards) |
| user_reason      | STRING     | NULLABLE   | `"agent-disconnected"` |
| user_description | STRING     | NULLABLE   | `null` (cannot be determined afterwards) |


### Integration

It is the task of the user to integrate this action into their GHA workflows by invoking it at all suitable places and providing the desired inputs. See the next section for one possible simple integration.

### Workflow Example

This action should be used together with [submit-build-status](https://github.com/camunda/infra-global-github-actions/tree/main/submit-build-status) to retrieve information about jobs aborted due to runner problems. The below is a simple example:

```yaml
---
name: ci

on: [pull_request]

jobs:
  job-that-might-get-aborted:
    runs-on: ubuntu-22.04
    steps:
    # Needed to create a workspace so submit-build-status can store files!
    - uses: actions/checkout@v4

    # This step is user-defined and does the actual testing/linting.
    - name: Testing
      run: |
        echo Hello World

    # Always submit build status to CI Analytics
    - uses: camunda/infra-global-github-actions/submit-build-status@main
      if: always()  # run even in case of failures
      continue-on-error: true  # prevent failure here of marking the job as failed
      with:
        build_status: "${{ job.status }}"
        gcp_credentials_json: "${{ secrets.YOUR_GCP_CREDENTIALS }}"

  job-that-checks-for-aborts:
    # List all other jobs here so this job runs last!
    needs: [job-that-might-get-aborted]
    runs-on: ubuntu-22.04
    steps:
    - name: Check for aborted jobs
      if: always()  # run even in case of failures
      continue-on-error: true  # prevent failure here of marking the job as failed
      uses: camunda/infra-global-github-actions/submit-aborted-gha-status@main
      with:
        gcp_credentials_json: "${{ secrets.YOUR_GCP_CREDENTIALS }}"
```
