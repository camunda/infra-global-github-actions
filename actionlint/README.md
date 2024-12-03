# actionlint

Thok,lk,,is composite GitHub Action (GHA) is supposed to be used to lint GitHub action workflows.

It's basically a wrap around the `actionlint` tool, with the goal to provide a consistent way
to lint GitHub action workflows across all Camunda repositories, especially when using self-hosted runners.

You can read more about `actionlint` [here](https://github.com/rhysd/actionlint/tree/main)

## Customizations

As a wrap around the `actionlint` tool, this composite GHA provides the following customizations:

### Default supported self-hosted labels

We provide and maintain a list of self-hosted runner labels that are supported by the infra team.
If no custom configuration is provided by the user, these labels are used during the validation of the workflow files

### Custom configuration support

Some teams already use `actionlint` as part of their CI/CD pipeline or pre-commit configuration, and they might have a custom configuration file.
They can pass the path tho this file as an input to this composite GHA to reuse the same configuration. The GHA will perform
a sanitization of the runner labels based on the labels supported by the infra-team.

Check the [actionlint configuration documentation](https://github.com/rhysd/actionlint/blob/main/docs/config.md) for more details

### Sanitization of runner labels

Sanitization of custom runner labels is performed by default. This means that if the user provides a custom configuration file,
the runner labels will be sanitized to only those supported by the infra-team.
This feature could be disabled by setting the `sanitize-runner-labels` input to `false`.
Please note that this feature is only available when a custom configuration file is provided.
Make sure to provide a valid custom configuration file. If invalid labels are provided, `actionlint` will not be able to identify
unsupported labels.

### Ignore errors patterns

`actionlint` provides the ability to ignore specific checks and errors using regular expressions. This composite GHA allows you to provide
a multiline field to specify the ignore patterns. One ignore pattern per line.
Alternatevely, you can use the `custom-config-file` to provide a custom configuration file that already contains the ignore patterns.

Check the [actionlint configuration documentation](https://github.com/rhysd/actionlint/blob/main/docs/config.md) for more details

### Format error messages

This composite GHA provides the ability to format error messages using Go template. You can use the `format` input to specify the template.

You can read more about it in the `actionlint` [here](https://github.com/rhysd/actionlint/tree/main) documentation

## Inputs

| Input Name              | Default Value | Description  |
|-------------------------|---------------|-------------------------------------------------------------------------|
| `version`               | "1.7.4"       | Actionlint version that will be downloaded  |
| `ignore`                |               | Multiline field. Allow you to customized ignored errors using regular expression. One ignore pattern per line |
| `format`                |               | Format error messages using Go template  |
| `custom-config-file`    |               | Actionlint custom configuration file path (relative to root of base repostiory) |
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
