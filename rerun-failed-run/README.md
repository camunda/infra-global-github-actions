### Retrigger Failed Run Action

This composite Github Action can be used to retrigger runs which have failed.

### Usage

To call this action, you need to provide:
- the ID of a failed GitHub Action workflow run to rerun
- an error message that needs to be present in the workflow run logs
This targeted approach helps retrigger only those runs that failed due to the specified error.
You also need ensure that the repository from which you invoke this composite action has the following secrets configured: `VAULT_ADDR`, `VAULT_ROLE_ID`, and `VAULT_SECRET_ID`.
If these secrets are not present, please contact the infrastructure team to set them up for you.

### Inputs

| Input name                 | Description                                                                                                                                  |
|----------------------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| run-id (required)          | The ID of the failed workflow run to be retried.                                                                                             |
| error-message (required)   | Custom error message to search for in the logs.                                                                                              |
| repository (required)      | The name of the repository containing the workflow to be retried in the format ORG/REPO_NAME (example: `camunda/infra-global-github-action`) |
| vault-addr (required)      | The Vault URL.                                                                                                                               |
| vault-role-id (required)   | The Vault Role ID.                                                                                                                           |
| vault-secret-id (required) | The Vault Secret ID.                                                                                                                         |

### Workflow Example
```yaml
jobs:
  build:
    runs-on: gcp-core-2-default
    ...

  # rerun the failed job
  rerun-failed-jobs:
    needs: build
    if: failure() && fromJSON(github.run_attempt) < 3 #This limits the job to only be retried two times
    runs-on: ubuntu-latest
    steps:
      - name: Retrigger job
        uses: camunda/infra-global-github-actions/rerun-failed-run
        with:
          error-message: "Process completed with exit code 1."
          run-id: ${{ github.run_id }}
          repository: ${{ github.repository }}
          vault-addr: ${{ secrets.VAULT_ADDR }}
          vault-role-id: ${{ secrets.VAULT_ROLE_ID }}
          vault-secret-id: ${{ secrets.VAULT_SECRET_ID }}
```
