# sanitize-branch-name

This composite Github Action (GHA) is supposed to be used by other teams inside Camunda and mostly targeted at [preview environments](https://confluence.camunda.com/display/HAN/Preview+Environments). It's a highly opinionated function derived from its [groovy equivalent](https://github.com/camunda/jenkins-global-shared-library/blob/master/src/org/camunda/helper/GitUtilities.groovy#L4-L10).

## Usage

This composite GHA can be used in any repository.

The resulting branch name will be converted to lowercase, remove `dependabot/` and `renovate/` and transform any non numeric and alphanumeric characters to `-`.

### Inputs
| Input name           | Description                                        |
|----------------------|----------------------------------------------------|
| branch               | the branch name to be sanitized |
| max_length           | max length to cut the branch name at |

### Workflow Example
```yaml
---
name: example
on:
  pull_request:
jobs:
  trigger-branch-deployment:
    runs-on: ubuntu-latest

    steps:
      - id: sanitize
        uses: camunda/infra-global-github-actions/sanitize-branch-name@main
        with:
          branch: ${{ github.head_ref }}
          max_length: '50'
      - run: echo ${{ steps.sanitize.outputs.branch_name }}
```
