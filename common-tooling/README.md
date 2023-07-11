# common-tooling

This composite Github Action (GHA) is aimed to be used by Camunda teams for configuring either hosted or self-hosted runners with some basic software. Especially useful to have the basics available on self-hosted runners since they come with close to no software.

## Usage

This composite GHA can be used in any repository and should generally run as one of the first actions. Directly before or after the checkout.

### Inputs
| Input name           | Description                                               | default |
|----------------------|-----------------------------------------------------------| --------|
| node-always-auth         | Set always-auth in npmrc. |
| node-version               | Version Spec of the version to use. Examples: 12.x, 10.15.1, >=10.15.0. | 16 |
| node-version-file          | File containing the version Spec of the version to use.  Examples: .nvmrc, .node-version, .tool-versions. |
| node-architecture            | Target architecture for Node to use. Examples: x86, x64. Will use system architecture by default. |
| node-check-latest       | Set this option if you want the action to check for the latest available version that satisfies the version spec. |
| node-registry-url | Optional registry to set up for auth. Will set the registry in a project level .npmrc and .yarnrc file, and set up auth to read in from env.NODE_AUTH_TOKEN. |
| node-scope | Optional scope for authenticating against scoped registries. Will fall back to the repository owner when using the GitHub Packages registry (https://npm.pkg.github.com/). |
| node-token | Used to pull node distributions from node-versions. Since there's a default, this is typically not supplied by the user. When running this action on github.com, the default value is sufficient. When running on GHES, you can pass a personal access token for github.com if you are experiencing rate limiting. |
| node-cache | Used to specify a package manager for caching in the default directory. Supported values: npm, yarn, pnpm. |
| node-cache-dependency-path | Used to specify the path to a dependency file: package-lock.json, yarn.lock, etc. Supports wildcards or a list of file names for caching multiple dependencies. |
| node-enabled | Whether to install node or not |
| yarn-enabled | Whether to install the latest yarn or not | latest (~1.22) |
| buildx-version | Buildx version. (eg. v0.3.0)| latest |
| buildx-driver | Sets the builder driver to be used |
| buildx-driver-opts | List of additional driver-specific options. (eg. image=moby/buildkit:master) |
| buildx-buildkitd-flags | Flags for buildkitd daemon |
| buildx-install | Sets up docker build command as an alias to docker buildx build |
| buildx-use | Switch to this builder instance |
| buildx-endpoint | Optional address for docker socket or context from `docker context ls` |
| buildx-platforms | Fixed platforms for current node. If not empty, values take priority over the detected ones |
| buildx-config | BuildKit config file |
| buildx-config-inline | Inline BuildKit config |
| buildx-append | Append additional nodes to the builder |
| buildx-cleanup | Cleanup temp files and remove builder at the end of a job |
| buildx-enabled | Whether to install buildx or not |
| qemu-image | QEMU static binaries Docker image (e.g. tonistiigi/binfmt:latest) |
| qemu-platforms | Platforms to install (e.g. arm64,riscv64,arm) | all |
| qemu-enabled | Whether to install qemu or not |
| java-version | The Java version to set up | 17 |
| java-distribution | Java distribution | temurin |
| java-cache-prefix | Cache key prefix |
| java-cache-path | Cache path |
| java-cache-path-add | Additional item for cache path |
| java-maven-version | The Maven version to set up |
| java-enabled | Whether to install java or not |
| python-version | Version range or exact version of Python or PyPy to use, using SemVer's version range syntax. Reads from .python-version if unset. | 3.11 |
| python-version-file | File containing the Python version to use. Example: .python-version |
| python-cache | Used to specify a package manager for caching in the default directory. Supported values: pip, pipenv, poetry. |
| python-architecture | The target architecture (x86, x64) of the Python or PyPy interpreter. |
| python-check-latest | Set this option if you want the action to check for the latest available version that satisfies the version spec. |
| python-token | The token used to authenticate when fetching Python distributions from https://github.com/actions/python-versions. When running this action on github.com, the default value is sufficient. When running on GHES, you can pass a personal access token for github.com if you are experiencing rate limiting. |
| python-cache-dependency-path | Used to specify the path to dependency files. Supports wildcards or a list of file names for caching multiple dependencies. |
| python-update-environment | Set this option if you want the action to update environment variables. |
| python-allow-prereleases | When 'true', a version range passed to 'python-version' input will match prerelease versions if no GA versions are found. Only 'x.y' version range is supported for CPython. |
| python-enabled | Whether to install python or not |
| overwrite | Defines whether on hosted runners the present version should be overwritten | true |
| secrets | toJSON passed GitHub secrets |
| berlin-timezone | Whether to keep the runner at UTC or set Berlin timezone| true|

### Workflow Example
```yaml
---
name: example
on:
  pull_request:
jobs:
  some-job:
    runs-on: ubuntu-latest
    steps:
    # install any defaults
    - uses: camunda/infra-global-github-actions/common-tooling@main
    # install any defaults and configure maven-settings.xml
    - uses: camunda/infra-global-github-actions/common-tooling@main
      with:
        secrets: ${{ toJSON(secrets) }}
    # only install missing software components
    - uses: camunda/infra-global-github-actions/common-tooling@main
      with:
        overwrite: "false"
```
