# preview-env-create

This composite GitHub Action (GHA) is used to deploy preview environments.

After deploying the environment (or attempting to do so) the action updates the PR with the deployment results.
In order to gain more troubleshooting insights upon a deployment failure, an optional GitHub token can be passed to the action,
with `contents: read`, `deployments:write` and `id-token:write` permissions.
Information about defining GitHUb token permissions can be found [here](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/controlling-permissions-for-github_token#defining-access-for-the-github_token-permissions.)
If such GitHub token is not provided then the available troubleshooting information will be limited.

## Usage

### Inputs

| Field             | Description                                                                                                    | Required | Default                 |
|-------------------|----------------------------------------------------------------------------------------------------------------|----------|-------------------------|
| `revision`        | Revision or branch of the Helm chart. Typically the branch to be deployed, or `master`.                        | Yes      | -                       |
| `app_name`        | Argocd app name to be created                                                                                  | Yes      | -                       |
| `app_url`         | The URL to access the deployed app                                                                             | Yes      | -                       |
| `argocd_server`   | URL of the Argo CD instance to target                                                                          | No       | `argocd.int.camunda.com`|
| `argocd_token`    | An Argo CD token with sufficient permissions to create Applications                                            | Yes      | -                       |
| `argocd_version`  | Version tag of Argo CD CLI tool                                                                                | No       | `v2.13.4`               |
| `argocd_arguments`| List of arguments to pass to Argocd command for creating the new application                                   | Yes      | -                       |
| `argocd_wait_for_sync_timeout`| The time (in seconds) that the action waits for the app to become healthy                          | No       | `1800`                  |
| `github_token`    | GitHub token is used to authenticate with Teleport to gain additional troubleshooting insights from the cluster | No       | -                       |
