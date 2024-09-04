# setup-yarn-cache

This composite Github Action (GHA) can be used by Camunda teams to reduce GHA cache usage for Yarn projects by only persisting caches on `main` or other persistent branches, see the [C8 Monorepo Caching Strategy](https://github.com/camunda/camunda/wiki/CI-&-Automation#caching-strategy) for details. This reduces likelihood of build failures and increases cache hit rate especially in mono repositories.

## Usage

This composite GHA can be used in any repository that uses Yarn and wants to utilize GHA cache more efficiently than e.g. `setup-node` [does by default](https://github.com/actions/setup-node/issues/663) at scale.

### Inputs

| Input name           | Description                                        |
|----------------------|----------------------------------------------------|
| directory | Directory of the project for which Yarn to GHA cache should be configured |
| cache_create_branch_regex | GHA cache will only be saved on branches that match this regex |

### Behavior

This action should be invoked by a GHA job after installing NodeJS/Yarn in the desired version (make sure to disable caching for e.g. `setup-node` since it will conflict) to set up more efficient GHA cache usage for Yarn. No further configuration is needed, see example below.

### Integration

It is task of the user to integrate this action into their GHA workflows by invoking it at all suitable places and providing the desired inputs. See the next section for one possible simple integration.

### Workflow Example

Assuming a Yarn workspace resides in the directory `frontend/client` in the repository:

```yaml
---
name: ci

on: [push, pull_request]

jobs:
  frontend-build:
    runs-on: ubuntu-22.04
    steps:
    # Needed to create a workspace and have composite GHA available
    - uses: actions/checkout@v4

    - name: Setup NodeJS
      uses: actions/setup-node@v4
      with:
        node-version: "20"
        # DON'T specify any cache-related options here!

    # This sets up the GHA cache for Yarn (no save on PRs)
    - uses: camunda/infra-global-github-actions/setup-yarn-cache@main
      with:
        directory: frontend/client

    - name: Install node dependencies
      working-directory: ./frontend/client
      run: yarn install

    - name: Build frontend
      working-directory: ./frontend/client
      run: yarn build

```
