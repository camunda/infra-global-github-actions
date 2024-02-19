# rerun-failed-run

This reusable workflow can be used in GitHub Actions workflows to automatically retrigger them if they failed and contain a specific error message in their build logs.

## Usage

The workflow can be invoked with the aid of the GitHub CLI from another workflow. In case the calling workflow is not in the same repository, the designated GitHub App Token should be generated to allow the invocation. For that purpose, a GitHub app is already set up, and its credentials can be found in the following Vault secret paths:

```
secret/data/products/infra/ci/retrigger-gha-workflow RETRIGGER_APP_KEY;
secret/data/products/infra/ci/retrigger-gha-workflow RETRIGGER_APP_ID;
```

It is crucial to always specify the retry limit to avoid the risk of running in a loop. You can specify how many times you want the workflow to retrigger your job by configuring the number of attempts at the job level.
See the example provided below for more information.

## Inputs

| Input name                | Description                                                                                                                                              |
|---------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| run_id (required)         | The ID of the workflow run to retrigger.                                                                                                                 |
| error_messages (required) | A string representing the error messages to look for in the logs in the format of an array (example: `"["First error message", "Second error message"]"` |
| repository (required)     | GitHub repository calling this reusable workflow, in the format ORG/REPO_NAME (example: `camunda/infra-global-github-action`)                            |

### Workflow Example
```yaml
---
jobs:
 job1:
  runs-on: gcp-core-2-default
  steps:
    - name: Echo dummy text
      run: echo "dummy text"

 rerun-failed-jobs:
    needs:
      - job1
    if: failure() && fromJSON(github.run_attempt) < 3 #This limits the job to only be retried two times
    runs-on: ubuntu-latest
    steps:
      - name: Import secrets
        id: secrets
        uses: hashicorp/vault-action@v2.8.0
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
          error_messages="[\"First error message\", \"Second error message\"]"
          gh workflow run rerun-failed-run.yml -R camunda/infra-global-github-actions --ref=main -F repository=${{ github.repository }} -F error_messages="The runner has received a shutdown signal. This can happen when the runner service is stopped, or a manually started runner is canceled." -F run_id=${{ github.run_id }}
```
