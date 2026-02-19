# Add to Quality Board

This GitHub Action automatically adds new issues labeled as `kind/bug` to a GitHub Project (defaults to the [Camunda Quality Board project](https://github.com/orgs/camunda/projects/187)) and updates the Severity, Likelihood & Component fields based on issue labels. The action works with any organization's project.

## Usage

```yaml
name: Add bug issues to Quality Board

on:
  issues:
    types: [opened, reopened, transferred, labeled]

jobs:
  add-to-quality-board:
    runs-on: ubuntu-latest

    steps:
      - id: add-bug-to-quality-board
        name: Add issue to Quality Board
        uses: camunda/infra-global-github-actions/add-bug-to-quality-board@main
        with:
          github-token: ${{ secrets.ADD_TO_QUALITY_BOARD_PAT }}
          project-number: "187"               # Optional, defaults to 187
          component-label: "component/zeebe"  # Optional, adds a component label to the issue
          version-label: "affects/8.9"        # Optional, adds a version label to the issue
        if: >
          # Only run this job for issues labeled as 'kind/bug' and
          # for the relevant GitHub issue events that indicate a new or updated issue.
          contains(github.event.issue.labels.*.name, 'kind/bug') &&
          (
              github.event.action == 'opened' ||
              github.event.action == 'reopened' ||
              github.event.action == 'transferred' ||
              (github.event.action == 'labeled' && github.event.label.name == 'kind/bug')
          )
```

## Inputs
| Input           | Description                                                                                |
| --------------  | -------------------------------------------------------------------------------------------|
| `github-token`  | **Required.** A GitHub token with permission to access projects and update issues.         |
| `project-number`| **Optional.** The number of the GitHub Project where the issue is added. Defaults to 187.  |
| `component-label`| **Optional.** A component label to add to the issue (e.g., 'component/zeebe'). If not provided, no label is added. |
| `version-label` | **Optional.** A version label to add to the issue (e.g., 'affects/8.9'). Only added if the issue doesn't already have an `affects/*` label. |

## How it works
* Adds the issue to the specified GitHub Project (defaults to project number 187).
* Automatically detects the repository owner/organization and uses it for all project operations.
* Optionally adds a component label to the issue if `component-label` input is provided.
* Optionally adds a version label to the issue if `version-label` input is provided and the issue doesn't already have an `affects/*` label.
* Extracts component/*, severity/*, and likelihood/* labels from the issue.
* If severity or likelihood labels are missing, automatically adds `severity/unknown` or `likelihood/unknown` labels respectively.
* Updates the corresponding project fields with the extracted values.
* Only runs if the issue has the kind/bug label.
* **Component handling:**
  * Only components that are defined as custom fields in the Quality Board project are considered.
  * Labels that do not match a project-defined component are ignored.
  * If multiple valid component labels exist, only the first matching component is used.

## Prerequisites
* Bug issues have the label `kind/bug`
* Component labels follow the pattern `component/COMPONENTNAME`
* Severity labels follow the pattern `severity/SEVERITYLEVEL`* Likelihood labels follow the pattern `likelihood/LEVEL`* Version labels follow the pattern `affects/VERSION`

## Author
Camunda QA Engineering Team
