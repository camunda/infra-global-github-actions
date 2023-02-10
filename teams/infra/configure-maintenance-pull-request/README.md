# configure-maintenance-pull-request

This composite Github Action (GHA) is aimed to be used by the Camunda Infrastructure team for configuring a maintenance Pull Request according to the team guidelines.

**Infra team guidelines**
- If the PR is opened by a vendor (Renovate or Snyk):
    - Add the label `dependency-upgrade` to the PR
    - Add the PR to the maintenance [project](https://github.com/orgs/camunda/projects/42/)
    - Add the `infra-maintenance-dri` team as reviewer of the PR
- If the PR is labeled with `dependency-upgrade`:
    - Add the PR to the maintenance [project](https://github.com/orgs/camunda/projects/42/)

## Usage

This composite GHA can be used in any repository and must be triggered on `pull_request` events.

### Inputs
| Input name           | Description                                               |
|----------------------|-----------------------------------------------------------|
| github-token         | A GitHub access token with sufficient scope (*) |

(*) This action relies on the [configure-pull-request](../../../configure-pull-request) action to edit a Pull Request and requires sufficient scope.

### Workflow Example
```yaml
---
name: example
on:
  pull_request:
jobs:
  configure-pr:
    runs-on: ubuntu-latest
    steps:
    - uses: camunda/infra-global-github-actions/teams/infra/configure-maintenance-pull-request@main
      with:
        github-token: ${{ secrets.GITHUB_TOKEN }}
```