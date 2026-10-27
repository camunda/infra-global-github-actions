# Workflow policy check

Composite action that checks jobs in the **calling repository** for configured
required actions. Configuration and workflow files come from the caller's checkout;
the checker and Conftest policy are bundled with the action.

## Add configuration to the calling repository

Create `.github/workflow-policy.yml`:

```yaml
required-actions:
  - actions/checkout
  - camunda/infra-global-github-actions/submit-build-status

exceptions:
  - workflow: .github/workflows/workflow-policy.yml
    jobs: [check]
    reason: Policy validation only; not a monitored build
```

Action paths must not include `@ref`. Remote composites and local paths such as
`./.github/actions/observe-build-status` are supported.

The exception excludes the checker-only job below from workload requirements.
Other exceptions use exact workflow paths and job IDs, or `"*"` for all workflows
or jobs; partial globs are unsupported. Each exception needs a reason and must
match at least one job.

## Add the caller workflow

Create `.github/workflows/workflow-policy.yml`:

```yaml
name: Workflow policy
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: camunda/infra-global-github-actions/workflow-policy@main
        with:
          config-path: .github/workflow-policy.yml
```

Checkout must populate the workspace root, as shown above. The action checks every
`.yml` and `.yaml` directly in that checkout's `.github/workflows/`. `config-path` is
relative to the checkout. Missing required actions or invalid configuration fail the
step; the checker does not execute caller scripts or referenced actions.

Once published, pin `@main` to a released commit SHA following the
[repository's usage convention](../README.md). The action code and policy are then
pinned together; no separate checker checkout or ref is needed.

Supports Linux and macOS on x86-64 or ARM64. The action sets up Python 3.13 and
installs its dependency directly into that Python environment. Conftest is downloaded
directly from its pinned GitHub release with HTTPS retries and checksum verification;
no asdf or mise setup is needed. Use a dedicated checker job to avoid conflicts with
other Python tooling. No secrets are needed; checkout requires `contents: read`.

This checks direct action presence, not execution, ordering, versions, or nested
composite steps. Reusable-workflow call jobs need explicit exceptions because
their steps are elsewhere. Exceptions remain controlled by the calling repository.
