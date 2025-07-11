# submit-test-status

This composite Github Action (GHA) is intended to be used by Camunda teams for submitting the test status(es) from a GHA workflow job to [CI Analytics](https://confluence.camunda.com/display/HAN/CI+Analytics). This allows teams to generate statistics about flakiness, runtime, etc. per test case across all branches and prioritize the worst offenders.
The GHA uses [Google Big Query batch loading](https://cloud.google.com/bigquery/docs/batch-loading-data#bq) mechanism to load data into CI Analytics. It can handle a single test event, or multiple events at once. The only limitation is that the data source cannot exceed 100MB.

## Usage

This composite GHA can be used in any repository that was set up to provide credentials for accessing the central Google Big Query (BQ) database (credentials via Vault).

### Inputs

| Input name           | Description                                        |
|----------------------|----------------------------------------------------|
| test_event_record    | Multi-line string that contains the details of the test events in [JSONL format](https://jsonlines.org). One test event per line. |
| job_name_override    | Optional string being used for the `job_name` field instead of the default `$GITHUB_JOB`, useful e.g. for matrix builds |
| gcp_credentials_json | Credentials for a Google Cloud ServiceAccount allowed to publish to Big Query formatted as contents of credentials.json file |

Please check out Camunda's [Github Actions Recipes](https://github.com/camunda/github-actions-recipes#secrets=) for how to retrieve secrets from Vault.

Input details for `test_event_record`

| Field Name                       | Field Type | Field Mode | Description/Purpose |
|----------------------------------|------------|------------|---------------------|
| test_class_name                  | STRING     | NULLABLE   | Individual (unit) test cases are usually grouped together in a container/class. This field holds the name of the container. |
| test_class_duration_milliseconds | INTEGER    | NULLABLE   | Based on user input (time a test class needed from start to finish) |
| test_name                        | STRING     | REQUIRED   | Name of the individual test case, can include parameters for uniqueness |
| test_status                      | STRING     | REQUIRED   | String representing the test status, either `"success"`, `"failed"`, `"skipped"`, `"flaky"` |
| test_duration_milliseconds       | INTEGER    | NULLABLE   | Based on user input (time an individual test needed from start to finish) |

Example `test_event_record`
```json
{"test_name":"test 99","test_status":"success"}
{"test_name":"test 999","test_status":"failed"}
{"test_name":"test 9999","test_duration_milliseconds":1234,"test_class_name":"9","test_status":"flaky"}
```

### Behavior

When invoking this action, it will submit the test record together with additional data like the repository URL, the current time and build ID (for uniqueness) to a central Google Big Query database maintained by the Infra team.

All data submitted by this action is stored as one record per JSONL input line in the Big Query table `test_status_v1` which retains records for 90 days and has the following fields in BQ:

| Field Name                       | Field Type | Field Mode | Description/Purpose |
|----------------------------------|------------|------------|---------------------|
| report_time                      | TIMESTAMP  | REQUIRED   | Time of record submission |
| ci_url                           | STRING     | REQUIRED   | Github repository URL from `"$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"` |
| build_id                         | STRING     | REQUIRED   | GHA workflow run ID from `"$GITHUB_RUN_ID/$GITHUB_RUN_ATTEMPT"` |
| job_name                         | STRING     | REQUIRED   | GHA workflow job ID from `"$GITHUB_JOB"` |
| test_class_name                  | STRING     | NULLABLE   | Individual (unit) test cases are usually grouped together in a container/class. This field holds the name of the container. |
| test_class_duration_milliseconds | INTEGER    | NULLABLE   | Based on user input (time a test class needed from start to finish) |
| test_name                        | STRING     | REQUIRED   | Name of the individual test case, can include parameters for uniqueness |
| test_status                      | STRING     | REQUIRED   | String representing the test status, either `"success"`, `"failed"`, `"skipped"`, `"flaky"` |
| test_duration_milliseconds       | INTEGER    | NULLABLE   | Based on user input (time an individual test needed from start to finish) |


### Integration

The scope of the `submit-test-status` action is to load the  *user-provided* test status information into the central [CI Analytics](https://confluence.camunda.com/display/HAN/CI+Analytics) database for later analysis.

It is the task of the user to integrate this action into their GHA workflows by invoking it at all suitable places and providing the desired inputs.

### A sample workflow

```yaml
name: sample workflow to upload test data to CI Analytics
on:
  workflow_dispatch: {}

jobs:
  upload-test-records:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - name: upload test results to CI Analytics
      uses: camunda/infra-global-github-actions/submit-test-status@main
      with:
        gcp_credentials_json: ${{ secrets.YOUR_GCP_CREDENTIALS }}
        test_event_record: |
          {"test_name":"test 99","test_status":"success"}
          {"test_name":"test 999","test_status":"failed"}
          {"test_name":"test 9999","test_duration_milliseconds":1234,"test_class_name":"9","test_status":"flaky"}
```
