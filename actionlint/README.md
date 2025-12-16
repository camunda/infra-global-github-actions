# actionlint

This composite GitHub Action (GHA) is a wrapper of the `actionlint` tool, with the goal to provide a consistent way
to lint GitHub action workflows across all Camunda repositories, especially when using self-hosted runners.

You can read more about `actionlint` [here](https://github.com/rhysd/actionlint/tree/main)

You can see the list of checks supported by `actionlint` [here](https://github.com/rhysd/actionlint/blob/main/docs/checks.md)

## Inputs

| Input Name              | Default Value | Description  |
|-------------------------|---------------|-------------------------------------------------------------------------|
| `version`               | "1.7.9"       | Actionlint version that will be downloaded  |
| `ignore`                |               | Multiline field. Allow you to customized ignored errors using regular expression. One ignore pattern per line |
| `use_shellcheck`        | "false"       | Enable actionlint to use shellcheck for all shell scripts in the repository. |

## Customizations

As a wrap around the `actionlint` tool, this composite GHA provides the following customizations:

### Ignore errors patterns

`actionlint` provides the ability to ignore specific checks and errors using regular expressions. This composite GHA allows you to provide
a multiline field to specify the ignore patterns. One ignore pattern per line.

⚠️ **Note** ⚠️

Make sure when adding ignore patterns to use the `|-` instead of the `|` yaml syntax to avoid any issues with new lines.
The action will try to sanitize this input by removing any empty or space-only lines.
Check the usage below for an example of a correct input.

### Additional configuration

Additional configuration could be included by creating a dedicated `actinlint.yaml` under the `custom` directory.
The folder structure should follow this convention:

```path
custom/${owner}/${repository}/actionlint.yaml
```

where `${owner}` and `${repository}` are the owner and repository of the repository where the action is used, e.g. `camunda` and `camunda` for the monorepo.

The default configuration and the custom configuration will be merged together in an additive way.

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

1. Default usage

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

2. Set specific actionlint version

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
