# yq-yaml-processor

This composite Github Action (GHA) is aimed to process YAML content by leveraging the capabilities of the [YQ](https://github.com/mikefarah/yq) processor.

## Usage

This composite GHA can be used in any repository.

### Inputs
| Input name | Description                                                                                                       |      Required      |   Default   |
| :--------: | :---------------------------------------------------------------------------------------------------------------- | :----------------: | :---------: |
|  patches   | A list of YAML contents (env, file, inline) with associated YQ expressions to apply (piped in the defined order). | :heavy_check_mark: |             |
|  options   | Command options passed to the YQ CLI                                                                              |                    | `--inplace` |

### Outputs
| Output name | Description                                                                              |
| :---------: | :--------------------------------------------------------------------------------------- |
|   results   | A JSON array with the results of each YQ command executed for each defined YAML content. |


### Workflow Example
```yaml
---
name: example
on:
  push:
jobs:
  processing-yaml-files:
    # With a.yml and b.yml having the following content
    #
    # a.yaml
    # ----
    # a:
    #   count: 0
    #   enabled: false
    #   name: Big A
    #
    # b.yaml
    # ---
    # b:
    #   count: 0
    #   enabled: false
    #   name: Big B
    runs-on: ubuntu-latest
    steps:
    - uses: camunda/infra-global-github-actions/yq-yaml-processor@main
      with:
        patches: |
          - file: path/to/a.yaml
            expressions :
            - '.a.count = 1'
            - '.a.enabled = true'
            - '.a.name = "A"'
          - file: path/to/b.yaml
            expressions :
            - '.b.enabled = true'
        options: "--inplace"
  processing-flow:
    runs-on: ubuntu-latest
    steps:
    - id: step-1
      uses: camunda/infra-global-github-actions/yq-yaml-processor@main
      with:
        patches: |
          - inline: |-
              users:
              - name: a
                age: 10
              - name: b
                age: 5
            expressions :
            - '.'
    - id: step-2
      uses: camunda/infra-global-github-actions/yq-yaml-processor@main
      env:
        PREVIOUS_STEP_OUTPUT: ${{ fromJSON(steps.step-1.outputs.results)[0] }}
      with:
        patches: |
          - env: PREVIOUS_STEP_OUTPUT
            expressions :
            - '(.users[] | select(.name == "a")).age += 1'
    - id: step-3
      uses: camunda/infra-global-github-actions/yq-yaml-processor@main
      env:
        PREVIOUS_STEP_OUTPUT: ${{ fromJSON(steps.step-2.outputs.results)[0] }}
      with:
        patches: |
          - env: PREVIOUS_STEP_OUTPUT
            expressions :
            - '(.users[] | select(.name == "b")).age += 1'
    - name: Print the result
      env:
        PREVIOUS_STEP_OUTPUT: ${{ fromJSON(steps.step-3.outputs.results)[0] }}
      run: |
        echo "${PREVIOUS_STEP_OUTPUT}"
```
