# preview-env-destroy

This composite GitHub Action (GHA) can be used to deactivate deployments and (optional) destroy them and the associated environment.

In order to delete the environment, a personal access token (PAT) with `deployments:write` and `administration:write` permissions is required.
If such PAT is not provided, the environment will be maintained and the deployments will only be deactivated.

By default, a set of environments are 'protected' from deletion:

- main
- master
- production
- stage

## Usage

### Inputs

| Field         | Description                                                                                                                                      | Required | Default                        |
|---------------|--------------------------------------------------------------------------------------------------------------------------------------------------|----------|--------------------------------|
| `app_name`    | Argocd app name to be deleted.                                                                                                                   | Yes      | -                              |
| `revision`    | Revision or branch of the Helm chart. Typically the branch to be deployed, or `master`.                                                          | Yes      | -                              |
| `argocd_server` | URL of the Argo CD instance to target.                                                                                                          | No       | `argocd.int.camunda.com`       |
| `argocd_token` | An Argo CD token with sufficient permissions to create Applications.                                                                             | Yes      | -                              |
| `argocd_version`| Version tag of Argo CD CLI tool                                                                                                                | No       | `v2.13.3`                      |
| `github_token`  | Personal access token used to delete the deployment and the environment; If present, the deployment environment also gets deleted. Token must include `deployments:write` and `administration:write` permissions for environment to be deleted. | No       | -                              |
