# Add to Quality Board

This GitHub Action automatically adds new issues labeled as `kind/bug` to a GitHub Project (defaults to the [Camunda Quality Board project](https://github.com/orgs/camunda/projects/187)) and updates the Severity & Component fields based on issue labels. The action works with any organization's project.

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
          project-number: "187"            # Optional, defaults to 187
          component-label: "component/zeebe"  # Optional, adds a single component label to the issue
          labels: |                        # Optional, comma or newline separated list of labels
            component/zeebe
            severity/critical
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
| `component-label`| **Optional.** A single component label to add to the issue (e.g., `component/zeebe`). Kept for backwards compatibility. If not provided, no label is added. |
| `labels`        | **Optional.** A list of labels to add to the issue and consider when setting project fields. Supports comma-separated or newline-separated values (e.g., `component/zeebe,severity/critical`). `component/*` and `severity/*` labels in this list are used to update the corresponding project fields. |

## How it works
* Adds the issue to the specified GitHub Project (defaults to project number 187).
* Automatically detects the repository owner/organization and uses it for all project operations.
* Optionally adds a single component label to the issue if `component-label` input is provided.
* Optionally adds multiple labels to the issue if `labels` input is provided (comma or newline separated).
* Extracts component/* and severity/* labels from the issue, the `labels` input, and the `component-label` input.
* Updates the corresponding project fields with the extracted values.
* Only runs if the issue has the kind/bug label.
* **Component handling:**
  * Only components that are defined as custom fields in the Quality Board project are considered.
  * Labels that do not match a project-defined component are ignored.
  * If multiple valid component labels exist, only the first matching component is used.

## Prerequisites
* Bug issues have the label `kind/bug`
* Component labels follow the pattern component/COMPONENTNAME
* Severity labels follow the pattern severity/SEVERITYLEVEL

## Author
Camunda QA Engineering Team
