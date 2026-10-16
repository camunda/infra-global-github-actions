# submit-build-status

This composite Github Action (GHA) is intended to be used by Camunda teams for submitting the build status of a GHA workflow job to [CI Analytics](https://confluence.camunda.com/display/HAN/CI+Analytics). This allows later analysis across many CI builds to identify trends.

## Usage

This composite GHA can be used in any repository set up to access the central Google Big Query (BQ) database through Workload Identity Federation (WIF) or service account JSON credentials.

### Inputs

| Input name           | Description                                        |
|----------------------|----------------------------------------------------|
| build_status         | String representing the build status that should be submitted to CI Analytics, e.g. `"success"`, `"failed"`, `"cancelled"` |
| build_duration_millis | Optional non-negative build duration in milliseconds. Overrides the automatic duration from `start-build-monitor`. |
| user_reason          | Optional string (200 chars max) the user can submit to indicate the reason why a build has ended with a certain build status , e.g. `"flaky-tests"` |
| user_description     | Optional string (1000 chars max) the user can submit to provide details on the user_reason, e.g. a list of flaky tests |
| gcp_credentials_json | Optional service account JSON credentials allowed to publish to Big Query. When non-empty, takes precedence over WIF. |
| gcp_workload_identity_provider | Optional full Workload Identity Provider resource name. Defaults to the shared Camunda CI provider; ignored when JSON credentials are supplied. |
| gcp_service_account | Optional service account email to impersonate for WIF. Defaults to the production CI Analytics writer; ignored when JSON credentials are supplied. |
| job_name_override    | Optional string being used for the `job_name` field instead of the default `$GITHUB_JOB`, useful e.g. for matrix builds |
| big_query_table_name | Optional destination in `project:dataset.table` format for infrastructure testing. Defaults to `ci-30-162810:prod_ci_analytics.build_status_v2`. |

### Authentication

Authentication is selected by whether `gcp_credentials_json` is non-empty:

- **JSON credentials:** pass `gcp_credentials_json`. Both WIF inputs are ignored, including defaults and caller overrides. Existing callers require no changes and do not need `id-token: write` for Google authentication. See Camunda's [Github Actions Recipes](https://github.com/camunda/github-actions-recipes#secrets=) for retrieving credentials from Vault.
- **Workload Identity Federation (default):** omit `gcp_credentials_json` and grant the calling job `id-token: write`. The defaults use the shared Camunda CI provider and production CI Analytics writer account. Override `gcp_workload_identity_provider` and `gcp_service_account` for custom WIF configuration. The provider must trust the calling GitHub repository, and its federated identity must have `roles/iam.workloadIdentityUser` on the service account. The service account also needs permission to insert rows into the target BigQuery table.

The default WIF configuration is for Camunda repositories. WIF uses service account impersonation to generate the access token for the BigQuery request. Authentication failures do not trigger a fallback to the other method.

### Behavior

When invoking this action with a `build_status` input, it will submit it together with additional data like the repository URL, GHA workflow name & job name, the current time and run ID (for uniqueness) to a central Google Big Query database maintained by the Infra team.

All data submitted by this action is stored as one record in the Big Query table `build_status_v2` which retains records for 90 days and has the following fields in BQ:

| Field Name       | Field Type | Field Mode | Description/Purpose |
|------------------|------------|------------|---------------------|
| report_time      | TIMESTAMP  | REQUIRED   | Time of record submission, in UTC |
| ci_url           | STRING     | REQUIRED   | Github repository URL from `"$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"` |
| workflow_name    | STRING     | NULLABLE   | GHA workflow name from `"$GITHUB_WORKFLOW"` |
| workflow_ref     | STRING     | NULLABLE   | GHA workflow file path extracted from `"$GITHUB_WORKFLOW_REF"`, e.g. `.github/workflows/ci.yml` |
| job_name         | STRING     | REQUIRED   | GHA workflow job ID from `"$GITHUB_JOB"` |
| build_id         | STRING     | REQUIRED   | GHA workflow run ID from `"$GITHUB_RUN_ID/$GITHUB_RUN_ATTEMPT"` |
| build_trigger    | STRING     | NULLABLE   | Github event name from `"$GITHUB_EVENT_NAME"` |
| build_status     | STRING     | REQUIRED   | Based on user input |
| build_ref        | STRING     | NULLABLE   | Git object reference from `"$GITHUB_REF"` |
| build_base_ref   | STRING     | NULLABLE   | Git object reference of target branch for PRs or GH merge queue |
| build_head_ref   | STRING     | NULLABLE   | Git object reference of the branch PR was built against |
| build_duration_milliseconds | INTEGER | NULLABLE | Explicit input or automatic monitor-derived job duration |
| runner_name      | STRING     | NULLABLE   | Lowercase name of the runner executing the GHA workflow job |
| runner_arch      | STRING     | NULLABLE   | Lowercase name of the runner's CPU architecture executing the GHA workflow job |
| runner_os        | STRING     | NULLABLE   | Lowercase name of the runner's operating system executing the GHA workflow job |
| network_egress_bytes  | INTEGER | NULLABLE | Cumulative bytes transmitted across non-loopback interfaces at job end; per-job on ephemeral runners, cumulative since interface-up on long-lived ones (Linux only) |
| network_ingress_bytes | INTEGER | NULLABLE | Cumulative bytes received across non-loopback interfaces at job end (Linux only) |
| user_reason      | STRING     | NULLABLE   | Based on user input |
| user_description | STRING     | NULLABLE   | Based on user input |

#### Build duration

When [`start-build-monitor`](../start-build-monitor/) is the first step in a job, this action automatically submits the elapsed time with whole-second precision, converted to milliseconds. The duration starts when the monitor action runs and ends when this action collects its metrics, after Google authentication but before the BigQuery request. Resource sampling also continues through authentication, preserving the existing measurement window.

An explicit `build_duration_millis` input takes precedence over the automatic duration. Explicit values must be non-negative integers no greater than 72 hours (`259200000` milliseconds); invalid values emit a warning and omit the duration field without failing submission or falling back to the monitor-derived duration. Automatic duration is used only when no explicit value is supplied. If the monitor did not run, its timestamp is invalid, or the calculated duration is outside that range, the duration field is omitted without failing submission.


### Integration

The scope of the `submit-build-status` action is to persist a *user-provided* build status information (whether a GHA workflow job run is considered successful or failed) into the central [CI Analytics](https://confluence.camunda.com/display/HAN/CI+Analytics) database for later analysis.

It is _out of scope_ for this action to extract that build status information from a GHA workflow run itself as this depends on the structure of the GHA workflow.

It is the task of the user to integrate this action into their GHA workflows by invoking it at all suitable places and providing the desired inputs. See the next section for one possible simple integration.

### Workflow Example

Since there are multiple ways of integrating and using the `submit-build-status` into your workflows depending on your requirements, the below is just a simple example:

#### JSON credentials

```yaml
---
name: ci

on: [pull_request]

jobs:
  successful-job:
    runs-on: ubuntu-22.04
    steps:
    # Must remain first to collect the automatic duration and resource metrics.
    - uses: camunda/infra-global-github-actions/start-build-monitor@main

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

#### Workload Identity Federation

Use the default WIF configuration without supplying Google credentials:

```yaml
---
name: ci

on: [pull_request]

jobs:
  successful-job:
    runs-on: ubuntu-22.04
    permissions:
      contents: read
      id-token: write
    steps:
    - uses: camunda/infra-global-github-actions/start-build-monitor@main
    - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

    - name: Testing
      run: echo Hello World

    - uses: camunda/infra-global-github-actions/submit-build-status@main
      if: always()
      continue-on-error: true
      with:
        build_status: "${{ job.status }}"
```

For custom WIF configuration, override the inputs in the submission step. For testing, also override `big_query_table_name`: changing the identity alone does not change the destination.

```yaml
with:
  build_status: "${{ job.status }}"
  gcp_workload_identity_provider: "${{ vars.TEST_WIF_PROVIDER }}"
  gcp_service_account: "${{ vars.TEST_SERVICE_ACCOUNT }}"
  big_query_table_name: 'test-project:test_dataset.build_status_v2'
```
