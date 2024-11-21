# actionlint

This composite GitHub Action (GHA) is supposed to be used to lint GitHub action workflows on their repositories.

## Usage

Place the below Github Action workflow in your private repository as `.github/workflows/actionlint.yml`:

```yaml
---
name: actionlint

on:
  pull_request

jobs:
  actionlint:
    runs-on: ubuntu-latest
    steps:
    - uses: camunda/infra-global-github-actions/actionlint@main
```
