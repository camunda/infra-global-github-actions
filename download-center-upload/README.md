# download-center-upload-action

## Intro

This action uploads files to [Camunda Download center]( https://downloads.camunda.cloud/). This is useful when you want
to upload artifacts from your workflow.

This action is owned by Infra team.

## Usage

### Inputs

Here is the list of the possible inputs and whether they are required or not:

| Input                | Description                                                                                                                | Required           | Default | Possible values        | Conditions                        |
|----------------------|----------------------------------------------------------------------------------------------------------------------------|--------------------|---------|------------------------|-----------------------------------|
| **gcp_credentials**  | The JSON key for accessing the bucket where to store the uploaded artifact. You need to approach Infra team to obtain it.  | :heavy_check_mark: |         |                        |                                   |
| **ee**               | Boolean value, if `true` means that it is an `enterprise` artifact.                                                        | :x:                | `false` | `true`  `false`        |                                   |
| **env**              | The DC environment to upload the artifact to.                                                                              | :x:                | `prod`  | `prod`  `stage`  `dev` |                                   |
| **version**          | Version of the artifact.                                                                                                   | :x:                |         |                        |                                   |
| **sub_version**      | Patch version of the artifact.                                                                                             | :x:                |         |                        |                                   |
| **artifact_subpath** | Sub-path of the artifact in Download center.                                                                               | :x:                |         |                        | should not start or end with `/`. |
| **artifact_file**    | The artifact(s). Can be a wildcard (*) or space separated list or single string                                                                                                              | :heavy_check_mark: |         |                        |                                   |


## Input usage

This action will help you upload artifacts to Camunda Download Center (dev, stage or prod):

- The default is `prod` and you can change it only in case of testing. To change that, you need to set the `env` input to either `stage` or `dev`.
  - Prod Download Center: [https://downloads.camunda.cloud/](https://downloads.camunda.cloud/).
  - Stage Download Center: [https://stage.downloads.camunda.cloud/](https://stage.downloads.camunda.cloud/).
  - Dev Download Center: [https://dev.downloads.camunda.cloud/](https://dev.downloads.camunda.cloud/).

The artifact could be an enterprise or community artifact:

- The community artifacts are publicly available while enterprise artifacts are password-protected to allow access only 
to Enterprise customers. Thus, we should be careful that nothing is accidentally published in the wrong place.
- The default is community. To change to enterprise you need to set the `ee` input to `true`.

The artifact itself will be passed to the action throw the `artifact_file` input.

The path to the uploaded artifact in DC will be created from the following inputs:

- artifact_subpath
- version
- sub_version

The path will be as following if all the mentioned inputs are set:

```bash
# Pattern
github_repository_name/artifact_subpath/version/sub_version/artifact_file
# e.g
camunda-bpm-rpa-bridge-ee/tomcat/0.1/0.1.1/artifact.zip
```

The path will be as following if none of the mentioned inputs are set:

```bash
# Pattern
github_repository_name/artifact_file
# e.g
camunda-bpm-rpa-bridge-ee/artifact.zip
```

## How to get the credentials

The only credential we need here is the `gcp_credentials` and you need to approach the Infra team 
to obtain it. The credential will not be directly shared with you, However, the Infra team will store it
in Vault and share the path to the credential with you. Thus, you can use it in your workflow to retrieve the credential.

If your repository is already onboarded to Vault, then you don't require additional help from Infra since the repository already has access.
The path to be used is the following and the secrets differ per chosen environment:
```
secret/data/common/jenkins/downloads-camunda-cloud_google_sa_key DOWNLOAD_CENTER_GCLOUD_KEY_BYTES
secret/data/common/jenkins/downloads-camunda-cloud_google_sa_key STAGE_DOWNLOAD_CENTER_GCLOUD_KEY_BYTES
secret/data/common/jenkins/downloads-camunda-cloud_google_sa_key DEV_DOWNLOAD_CENTER_GCLOUD_KEY_BYTES
```

Please check the `Import Secrets` Step in the example below on how you will get the credential.

## Example of using the action

```yaml
    steps:
      - name: Import Secrets
        id: secrets
        uses: hashicorp/vault-action@v2.5.0
        with:
          url: ${{ secrets.VAULT_ADDR }}
          method: approle
          roleId: ${{ secrets.VAULT_ROLE_ID }}
          secretId: ${{ secrets.VAULT_SECRET_ID }}
          secrets: |
              secret/data/common/jenkins/downloads-camunda-cloud_google_sa_key DEV_DOWNLOAD_CENTER_GCLOUD_KEY_BYTES | GCP_CREDENTIALS_NAME;
            
      - name: Upload artifact to Camunda Download Center
        uses: camunda/infra-global-github-actions/download-center-upload@main
        with:
          gcp_credentials: ${{ steps.secrets.outputs.GCP_CREDENTIALS_NAME }}
          ee: 'true'
          env: 'dev'
          version: 0.1
          sub_version: 0.1.1
          artifact_subpath: tomcat
          artifact_file: file.txt
```

Based on the previous example: you can find the
artifact under this path [https://dev.downloads.camunda.cloud/enterprise-release/camunda-bpm-rpa-bridge-ee/tomcat/0.1/v0.1.1/file.txt]().
