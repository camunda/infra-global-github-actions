# kubernetes-image-replace

This composite Github Action (GHA) can be used to replace the image of a specified container within a deployment or statefulset. Alternatively, if the image is already present, it will just restart the pod.

## Usage

For the credentials, please reach out to the Infrastructure team.
Requirements for the usage of this action is to have kubectl installed and authenticated already.

```yaml
---
name: Deploy new Image to Cluster

on:
    push:

jobs:
  replace-kubernetes-image:
    runs-on: ubuntu-latest
    steps:
    - name: Import Secrets
      id: secrets
      uses: hashicorp/vault-action@v2.5.0
      with:
        url: ${{ secrets.VAULT_ADDR }}
        method: approle
        roleId: ${{ secrets.VAULT_ROLE_ID }}
        secretId: ${{ secrets.VAULT_SECRET_ID }}
        exportEnv: false
        secrets: |
          secret/data/SOME_PATH GCP_AUTH_CREDS | GCP_CREDENTIALS;
    - uses: azure/setup-kubectl@v3
    - name: GCloud Auth
      id: auth
      uses: google-github-actions/auth@v1
      with:
        credentials_json: '${{ steps.secrets.outputs.GCP_CREDENTIALS }}'
    - id: get-credentials
      uses: 'google-github-actions/get-gke-credentials@v1'
      with:
        cluster_name: camunda-ci
        location: europe-west1-b
    - uses: camunda/infra-global-github-actions/kubernetes-image-replace@main
      with:
        app_name: alert-int-camunda-com
        app_type: statefulset
        container_name: alertmanager
        image: prom/alertmanager:v0.25.0
        namespace: monitoring
```
