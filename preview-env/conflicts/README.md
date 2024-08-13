# preview-env-conflicts

This composite Github Action (GHA) can be used to manage sticky comments on PRs which indicate a merge conflict.

It's intended to be run as cron-job on a repository level to check all PRs with certain labels for merge conflicts.

## Comment Template
You can find the comment template [here](./templates/comment-body.md).

## Usage

### Cron Job
You can simply add a new workflow file (e.g. `check-pr-conflicts.yml`) which looks like this:
```yaml
...
---
  name: Check for PR conflicts

  on:
    schedule:
    - cron: 23 1 * * 1-5
    workflow_dispatch:

  jobs:
    check-pr-conflicts:
      runs-on: ubuntu-latest
      steps:
      - uses: actions/checkout@692973e3d937129bcbf40652eb9f2f61becf3332 # v4.1.7
      - name: Check all PRs for conflict
        uses: camunda/infra-global-github-actions/preview-env/conflicts@main # checks ALL PRs in repository
```

### Quick Cleanup
To allow an even better UX, you can add a job to your `preview-env-deploy` workflow, which calls the action with the current PR-ID as parameter.
This will, as soon as the PR becomes mergeable, remove the comment from the affected PR. You can include the cleanup in your workflow like this:
```yaml
...
jobs:
  ...
  conflicts:
    if: github.event.pull_request.state != 'closed' && (contains( github.event.label.name, 'deploy-preview') || contains( github.event.pull_request.labels.*.name, 'deploy-preview'))
    runs-on: ubuntu-22.04
    steps:
    - name: Check all PRs for conflict
      if: github.event_name == 'pull_request'
      uses: camunda/infra-global-github-actions/preview-env/conflicts@main
      with:
        pull-request-id: ${{ github.event.pull_request.number }} # only affects current PR
  ...
```

### Custom Labels
Besides the `pull-request-id` you can also set the parameter `label-filters`.
It defaults to `deploy-preview` but you can also provide a comma-separated list (e.g.: `label-filters: "deploy-preview,deploy-preview-customized,you-name-it`) of labels which act as limiter for the conflict check.
