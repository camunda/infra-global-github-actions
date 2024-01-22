### Retrigger Failed Run Action

This GitHub Actions workflow is aimed to be used by Camunda teams in order to retrigger github action runs which have failed.

### Usage

This workflow can be triggered from another workflow existing in any repository in Camunda org using the "workflow_dispatch" 
event and it will attempt to retrigger any run for two additional times. The usage of the Github App 

### Inputs

| Input name                  | Description                                         |
|-----------------------------|-----------------------------------------------------|
| run_id (required)           | The ID of the run that you want to retrigger.       |
| error_message (required)    | Custom error message to look for in the logs.       |
| app_access_token (required) | The GitHub App access token.                        |
| repository (required)       | The repository in which the workflow resides.       |


### Workflow Example
jobs:
  build:
    runs-on: gcp-core-2-default
    outputs:
      output1: ${{ steps.step1.outputs.test }}

    steps:
      - name: Fail
        run: exit 1

 # rerun the failed job
  rerun-failed-jobs:
    needs: build
    if: failure() && fromJSON(github.run_attempt) < 3
    runs-on: ubuntu-latest
    steps:
      - name: Import Secrets
        id: secrets
        uses: hashicorp/vault-action@affa6f04da5c2d55e6e115b7d1b044a6b1af8c74 # v2.7.4
        with:
          url: ${{ secrets.VAULT_ADDR }}
          method: approle
          roleId: ${{ secrets.VAULT_ROLE_ID }}
          secretId: ${{ secrets.VAULT_SECRET_ID }}
          secrets: |
            secret/data/products/optimize/ci/common RETRIGER_APP_ID;
            secret/data/products/optimize/ci/common RETRIGGER_APP_KEY;      

      - name: Generate a GitHub token
        id: github-token
        uses: tibdex/github-app-token@v2
        with:
          app_id: ${{ steps.secrets.outputs.RETRIGER_APP_ID }}
          private_key: ${{ steps.secrets.outputs.RETRIGGER_APP_KEY }}

      - env:
          GH_DEBUG: api
        run: |
          echo ${{ steps.github-token.outputs.token }} | gh auth login --with-token
          gh workflow run rerunfailedjob.yml -R camunda/infra-test-retrying-failed-actions --ref=main -F run_id=${{ github.run_id }} -F app_access_token="dummy" -F repository="dummy" -F error_message="Process completed with exit code 1."

