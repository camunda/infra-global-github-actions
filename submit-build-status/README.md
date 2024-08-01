# submit-build-status

This composite Github Action (GHA) is aimed to be used by Camunda teams for submitting the build status of a GHA workflow job to [CI Analytics](https://confluence.camunda.com/display/HAN/CI+Analytics). This allows later analysis across many CI builds to identify trends.

## Usage

This composite GHA can be used in any repository that was set up to provide credentials for accessing the central Google Big Query (BQ) database (credentials via Vault).

### Inputs

| Input name           | Description                                        |
|----------------------|----------------------------------------------------|
| build_status         | String representing the build status that should be submitted to CI Analytics, e.g. `"success"`, `"failed"`, `"cancelled"` |
| build_duration_millis | Optional number (positive) that indicates the duration of the build in milliseconds |
| user_reason          | Optional string (200 chars max) the user can submit to indicate the reason why a build has ended with a certain build status , e.g. `"flaky-tests"` |
| user_description     | Optional string (1000 chars max) the user can submit to provide details on the user_reason, e.g. a list of flaky tests |
| gcp_credentials_json | Credentials for a Google Cloud ServiceAccount allowed to publish to Big Query formatted as contents of credentials.json file |
| job_name_override    | Optional string being used for the `job_name` field instead of the default `$GITHUB_JOB`, useful e.g. for matrix builds |

Please check out Camunda's [Github Actions Recipes](https://github.com/camunda/github-actions-recipes#secrets=) for how to retrieve secrets from Vault.

### Behavior

When invoking this action with a `build_status` input, it will submit it together with additional data like the repository URL, GHA workflow name & job name, the current time and run ID (for uniqueness) to a central Google Big Query database maintained by the Infra team.

All data submitted by this action is stored as one record in the Big Query table `build_status_v2` which retains records for 90 days and has the following fields in BQ:

| Field Name       | Field Type | Field Mode | Description/Purpose |
|------------------|------------|------------|---------------------|
| report_time      | TIMESTAMP  | REQUIRED   | Time of record submission |
| ci_url           | STRING     | REQUIRED   | Github repository URL from `"$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"` |
| workflow_name    | STRING     | NULLABLE   | GHA workflow name from `"$GITHUB_WORKFLOW"` |
| job_name         | STRING     | REQUIRED   | GHA workflow job ID from `"$GITHUB_JOB"` |
| build_id         | STRING     | REQUIRED   | GHA workflow run ID from `"$GITHUB_RUN_ID/$GITHUB_RUN_ATTEMPT"` |
| build_trigger    | STRING     | NULLABLE   | Github event name from `"$GITHUB_EVENT_NAME"` |
| build_status     | STRING     | REQUIRED   | Based on user input |
| build_ref        | STRING     | NULLABLE   | Git object reference from `"$GITHUB_REF"` |
| build_base_ref   | STRING     | NULLABLE   | Git object reference of target branch for PRs or GH merge queue |
| build_duration_milliseconds | INTEGER | NULLABLE | Based on user input (time a job needed from start to finish) |
| runner_name      | STRING     | NULLABLE   | Lowercase name of the runner executing the GHA workflow job |
| runner_arch      | STRING     | NULLABLE   | Lowercase name of the runner's CPU architecture executing the GHA workflow job |
| runner_os        | STRING     | NULLABLE   | Lowercase name of the runner's operating system executing the GHA workflow job |
| user_reason      | STRING     | NULLABLE   | Based on user input |
| user_description | STRING     | NULLABLE   | Based on user input |


### Integration

The scope of the `submit-build-status` action is to persist a *user-provided* build status information (whether a GHA workflow job run is considered successful or failed) into the central [CI Analytics](https://confluence.camunda.com/display/HAN/CI+Analytics) database for later analysis.

It is _out of scope_ for this action to extract that build status information from a GHA workflow run itself as this depends on the structure of the GHA workflow.

It is task of the user to integrate this action into their GHA workflows by invoking it at all suitable places and providing the desired inputs. See the next section for one possible simple integration.

### Workflow Example

Since there are multiple ways of integrating and using the `submit-build-status` into your workflows depending on your requirements, the below is just a simple example:

```yaml
---
name: ci

on: [pull_request]

jobs:
  successful-job:
    runs-on: ubuntu-22.04
    steps:
    # Needed to create a workspace so submit-build-status can store files!
    - uses: actions/checkout@v4

    # This step is user-defined and does the actual testing/linting.
    - name: Testing
      run: |
        echo Hello World
        exit 0  # <- experiment with setting this to 1

    # Always submit build status to CI Analytics
    - uses: camunda/infra-global-github-actions/submit-build-status@main
      if: always()  # run even in case of failures
      continue-on-error: true  # prevent failure here of marking the job as failed
      with:
        build_status: "${{ job.status }}"
        gcp_credentials_json: "${{ secrets.YOUR_GCP_CREDENTIALS }}"
        # user_reason: "maybe-flaky-tests"
        # user_description: "test1,test2,test23,test42"
```
