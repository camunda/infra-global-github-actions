# configure-pull-request

This composite Github Action (GHA) is aimed to be used by Camunda teams for configuring basic parameters of a GitHub Pull Request like labels, project and reviewers.

## Usage

This composite GHA can be used in any repository and must be triggered on `pull_request` events.

### Inputs
| Input name           | Description                                               |
|----------------------|-----------------------------------------------------------|
| github-token         | A GitHub personal access token with sufficient scope (*) |
| labels               | Comma-separated list of labels to set |
| project-url          | URL of a GitHub project to which to add the PR |
| reviewers            | Comma-separated list of users to set as reviewers |
| team-reviewers       | Comma-separated list of teams to set as reviewers |

(*) minimum scope required:
- repo
- admin:org/read:org (required if `team-reviewers` input is set)
- project (required if `project-url` input is set)

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
    - uses: camunda/infra-global-github-actions/configure-pull-request@main
      with:
        github-token: ${{ secrets.MY_PAT }}
        labels: label-1,label-2
        project-url: https://github.com/orgs/camunda/projects/project-id/
        reviewers: user1,user2
        team-reviewers: team1,team2
```
