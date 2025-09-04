# build-docker-image

This composite Github Action (GHA) is intended to be used by Camunda teams for building and pushing a Docker image to any Docker registry.

## Usage

This composite GHA can be used in any non-public repository with a `Dockerfile` in the top-level project folder. It should be run on pushes to Git branches, Git tags and/or Github Pull Requests (PR) and will build the `Dockerfile`.

### Inputs

| Input name                 | Description                                        |
|----------------------------|----------------------------------------------------|
| registry_host              | Host name of target Docker registry, e.g. `gcr.io` |
| registry_username          | Username used for authenticating to registry host. Required if `use_workload_identity_auth` is `false`. |
| registry_password          | Password used for authenticating to registry host. Required if `use_workload_identity_auth` is `false`. |
| use_workload_identity_auth | Use Google Workload Identity for authenticating to registry host (takes precedence over credentials if `true`) |
| image_name                 | Docker image name (*without* registry and Docker tag), e.g. `example/image` |
| build_args                 | Allows defining extra build-args, supply as list with \| (pipe bar) |
| extra_tags                 | Allows defining extra tags according to the [metadata action](https://github.com/docker/metadata-action), supply as list with \| (pipe bar) |
| force_push                 | Allows overwriting the image push behaviour, by setting to 'true' as input |
| build_context              | Docker build context location                      |
| build_docker_file          | Path to the Dockerfile relative to the build context (e.g., `{context}/Dockerfile`). If empty, defaults to "Dockerfile" in the build context |
| build_allow                | Extra privilege entitlements to give builder       |
| build_platforms            | List of [target platforms](https://docs.docker.com/engine/reference/commandline/buildx_build/#platform) for build        |
| buildx_driver              | Driver to use for buildx builder                   |
| buildx_version             | Which release version of a buildx action to use    |
| docker_load                | Whether or not to load docker image builds into the local Docker Images |
| qemu_image                 | QEMU static binaries Docker image                  |
| qemu_platforms             | Platforms to install (e.g., `arm64,riscv64,arm`)   |

For the above example inputs the resulting Docker image would be named `gcr.io/example/image`.

Please check out Camunda's [Github Actions Recipes](https://github.com/camunda/github-actions-recipes#secrets=) for how to retrieve secrets from Vault.

### Outputs
| Output name        | Description                                        |
|--------------------|----------------------------------------------------|
| image_digest       | The image digest (sha256) of the pushed image      |
| image_metadata     | The json metadata object of the pushed image, according to the [docker-push action](https://github.com/docker/build-push-action). This can often not be set as additional output for other jobs within a workflow      |
| images             | The "images.name" value from metadata. This is a comma separated string of image:tag |
| pushed             | The decission whether the image was pushed or not, can be "true" or "false |

### Behavior

| Branch name                       | Tag name | PR number | will be built? | will be pushed? | will be pushed as                                       |
|-----------------------------------|----------|-----------|----------------|-----------------|---------------------------------------------------------|
| —                                 | —        | 42        | ✅             | ❌              | —                                                       |
| normal-branch                     | —        | —         | ✅             | ❌              | —                                                       |
| normal-branch-push                | —        | —         | ✅             | ✅              | gcr.io/example/image:normal-branch-push                 |
| *repo default branch* (e.g. main) | —        | —         | ✅             | ✅              | gcr.io/example/image:latest + gcr.io/example/image:main |
| —                                 | 1.2.3    | —         | ✅             | ✅              | gcr.io/example/image:1.2.3                              |


In general, the Docker tag is then derived from the Git reference (Git branch/tag name or Github PR number) and sanitized to not include special characters. [Repository's default Git branch](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/changing-the-default-branch) also gets the `latest` Docker tag.

The resulting image will only be pushed to the registry in those cases:

1. When it was built for a Git tag.
1. When it was built on the [repository's default Git branch](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/changing-the-default-branch) (e.g. `main`).
1. When it was built for a Git branch whose name ends with `-push`.

### Workflow Examples

**🔒 Standard Authentication**

As an example you can use the below Github Action workflow in your repository:

```yaml
---
name: ci

on:
  push:
    branches:
    - '**'
    tags:
    - 'v*.*.*'

# Alternative event triggers for PRs:
#
# on:
#   push:
#     branches:
#     - 'main'
#     - '**-push'
#     tags:
#     - 'v*.*.*'
#   pull_request:
#     branches:
#     - '**'

jobs:
  docker:
    runs-on: ubuntu-24.04

    steps:
    # Needed to fetch the Dockerfile
    - uses: actions/checkout@v3

    - uses: camunda/infra-global-github-actions/build-docker-image@main
      with:
        registry_host: registry.example.com
        registry_username: ${{ secrets.YOUR_REGISTRY_USERNAME }}
        registry_password: ${{ secrets.YOUR_REGISTRY_PASSWORD }}

        image_name: my-cool/image-name
```

**🔑 Authentication using Workload Identity**

*A modified example taken from [camunda/nginx-ldap-auth](https://github.com/camunda/nginx-ldap-auth/blob/master/.github/workflows/build.yml)*

```yaml
---
name: ci

...

permissions:
  id-token: write # required for workload identity authentication
  contents: read # required for checking out the repository

jobs:
  docker:
    runs-on: ubuntu-24.04

    steps:
    - uses: actions/checkout@v4

    - name: Import Secrets
      id: secrets # important to refer to it in later steps
      uses: hashicorp/vault-action@v3.4.0
      with:
        url: ${{ secrets.VAULT_ADDR }}
        method: approle
        roleId: ${{ secrets.VAULT_ROLE_ID }}
        secretId: ${{ secrets.VAULT_SECRET_ID }}
        exportEnv: false # we rely on step outputs, no need for environment variables
        secrets: |
          ...
          secret/data/products/infra/benchmark/workload-identity/nginx-ldap-auth WORKLOAD_IDENTITY_PROVIDER;
          secret/data/products/infra/benchmark/workload-identity/nginx-ldap-auth SERVICE_ACCOUNT;

    - name: Authenticate GCP using workload identity
      id: gcp_auth
      uses: google-github-actions/auth@v2
      with:
        workload_identity_provider: ${{ steps.secrets.outputs.WORKLOAD_IDENTITY_PROVIDER}}
        service_account: ${{ steps.secrets.outputs.SERVICE_ACCOUNT }}
    - name: Install GCP CLI
      id: setup_gcloud
      uses: google-github-actions/setup-gcloud@v2
      with:
        project_id: camunda-benchmark
    - name: Configure GAR
      run: |-
        gcloud auth configure-docker europe-west1-docker.pkg.dev
    - id: build
      uses: camunda/infra-global-github-actions/build-docker-image@refactor-docker-build
      with:
        registry_host: europe-west1-docker.pkg.dev
        use_workload_identity_auth: true
        image_name: camunda-benchmark/main/camunda_nginx-ldap-auth
    ...
```
