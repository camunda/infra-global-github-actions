# previous-version

Given a release version identifies release type and a corresponding previous release version in a current repository.

## Usage

This GHA can be used in any repository, but requires it to be fetched with full history,
so that existing tags can be analyzed. Otherwise, results may be incorrect.

### Inputs
| Input name | Description                            | Mandatory | Default |
|------------|----------------------------------------|-----------|---------|
| version    | Current release version (e.g. 8.8.0)   | Yes       |         |
| verbose    | Provide verbose output (true \| false) | No        | false   |

### Outputs
| Input name        | Description                                  |
|-------------------|----------------------------------------------|
| previous_version  | Previous version (e.g. 8.7.0)                |
| release_type      | Current release type (NORMAL \| ALPHA \| RC) |

### Workflow Example
```yaml
---
name: example
on:
  pull_request:
jobs:
  test-previous-version:
    runs-on: ubuntu-latest

    steps:
      - id: checkout
        uses: actions/checkout@v4
        with:
          ref: ${{ env.RELEASE_BRANCH }}
          fetch-depth: 0 # To fetch tags as well - required for tags processing
      - id: prev_version
        uses: camunda/infra-global-github-actions/previous-version@main
        with:
          version: '8.8.0'
          verbose: 'true'
      - run: |
          echo ${{ steps.prev_version.outputs.previous_version }}
          echo ${{ steps.prev_version.outputs.release_type }}
```
