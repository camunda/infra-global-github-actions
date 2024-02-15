# rerun-failed-run

This reusable workflow is aimed to target runs which have failed due to a specific error message and retrigger them. To do so, the workflow utilizes the
id of a run as well as the error message which needs to be targeted.

## Usage

The workflow can be invoked with the aid of the github cli from another workflow. In case the calling workflow does not belong in the same repository a
Github App Token should be generated in order to allow the invokation. For that purpose, a github app is already set up and the necessary `app id` and
`app key` can be found in the following paths in Vault:

```
secret/data/products/infra/ci/retrigger-gha-workflow RETRIGGER_APP_KEY;
secret/data/products/infra/ci/retrigger-gha-workflow RETRIGGER_APP_ID;
```

Additionally, in order to allow the workflow to be applied in a number of repositories and error messages, it is necessary to provide in the inputs not only
the id of the run which needs to be retriggered, but also the repository name in which the workflow to be retriggered lives in the format `ORG/REPO_NAME`
(example would be `camunda/infra-global-github-action`). Moreover, the error message which needs to be targeted shall also be supplied in the inputs as string. As an example,
if you wish to rerun a workflow which has been erroring due to preemption the string `The runner has received a shutdown signal. This can happen when the runner service is stopped, or a manually started runner is canceled.`
shall be supplied on the `error_message`.

Lastly, you can customize how many times you want the workflow to retrigger your job by configuring the number of attempts in the job level. See th example provided
below for more information.

## Inputs

| Input name               | Description                                                                                   |
|--------------------------|-----------------------------------------------------------------------------------------------|
| run_id (required)        | The ID of the workflow run to retrigger.                                                      |
| error_message (required) | Custom error message to look for in the logs                                                  |
| repository (required)    | GitHub repository in the format ORG/REPO_NAME (example: `camunda/infra-global-github-action`) |

### Workflow Example
```yaml
---
 rerun-failed-jobs:
    needs:
      - job1
      - job2
      - job3
    if: failure() && fromJSON(github.run_attempt) < 3
    runs-on: ubuntu-latest
    steps:
      - name: Import secrets
        id: secrets
        uses: hashicorp/vault-action@v2.7.4
        with:
          url: ${{ secrets.VAULT_ADDR }}
          method: approle
          roleId: ${{ secrets.VAULT_ROLE_ID }}
          secretId: ${{ secrets.VAULT_SECRET_ID }}
          secrets: |
            secret/data/products/infra/ci/retrigger-gha-workflow RETRIGGER_APP_KEY;
            secret/data/products/infra/ci/retrigger-gha-workflow RETRIGGER_APP_ID;
      - name: Generate a GitHub token
        id: github-token
        uses: tibdex/github-app-token@v2
        with:
          app_id: ${{ steps.secrets.outputs.RETRIGGER_APP_ID }}
          private_key: ${{ steps.secrets.outputs.RETRIGGER_APP_KEY }}

      - name: Retrigger run
        env:
          GH_DEBUG: api
        shell: bash
        run: |
          echo ${{ steps.github-token.outputs.token }} | gh auth login --with-token
          gh workflow run rerun-failed-run.yml -R camunda/infra-global-github-actions --ref=main -F repository=${{ github.repository }} -F error_message="The runner has received a shutdown signal. This can happen when the runner service is stopped, or a manually started runner is canceled." -F run_id=${{ github.run_id }}
```
