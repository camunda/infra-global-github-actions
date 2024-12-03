# actionlint

This composite GitHub Action (GHA) is supposed to be used to lint GitHub action workflows.

The goal is to provide a consistent way to lint GitHub action workflows across all Camunda repositories,
especially when using self-hosted runners.

## Inputs

| Input Name              | Default Value | Description                                                                 |
|-------------------------|---------------|-------------------------------------------------------------------------|
| `version`               | "1.7.4"       | Actionlint version                                                      |
| `ignore`                |               | Multiline field. Allow you to customized ignored errors using regular expression. One ignore pattern per line         |
| `format`                |               | Format error messages using Go template                                 |
| `custom-config-file`    |               | Actionlint custom configuration file path (relative to root of base repostiory)         |
| `sanitize-runner-labels`| "true"        | Sanitize custom runner labels to only those supported by infra-team     |

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

## Configuration examples

1. Set specific actionlint version

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
      with:
        version: "1.7.2"
```

2. Specify custom configuration file and disable sanitization

```yaml
name: actionlint

on:
  pull_request

jobs:
  actionlint:
    runs-on: ubuntu-latest
    steps:
    - uses: camunda/infra-global-github-actions/actionlint@main
      with:
        custom-config-file: .github/actionlint.yml
        sanitize-runner-labels: "false"
```

3. Specify custom ignore patterns

```yaml
name: actionlint

on:
  pull_request

jobs:
  actionlint:
    runs-on: ubuntu-latest
    steps:
    - uses: camunda/infra-global-github-actions/actionlint@main
      with:
        ignore: |-
          property "vault_.+" is not defined in object type
          object type "{}" cannot be filtered by object filtering `.*` since it has no object element

```
