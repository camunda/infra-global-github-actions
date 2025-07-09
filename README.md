# Global Github Actions

This repository contains Github Actions (GHA) maintained by the Infra team. Those actions are intended to be consumed by other teams inside Camunda.

They are **publicly accessible** and thus must not contain any secrets.

## Available Actions

### Security & Compliance
- [assert-camunda-git-emails](./assert-camunda-git-emails/README.md) - Ensures only Camunda email addresses are used in git commits
- [assert-no-ai-commits](./assert-no-ai-commits/README.md) - Prevents AI-authored commits from being merged (enforces AI Policy)

### CI/CD & Build
- [actionlint](./actionlint/README.md) - Lints GitHub Actions workflows
- [build-docker-image](./build-docker-image/README.md) - Builds and pushes Docker images
- [common-tooling](./common-tooling/README.md) - Sets up common development tools
- [setup-yarn-cache](./setup-yarn-cache/README.md) - Sets up Yarn caching

### Pull Request Management
- [configure-pull-request](./configure-pull-request/README.md) - Configures PR labels, reviewers, and projects
- [preview-env](./preview-env/README.md) - Manages preview environments for PRs

### Monitoring & Analytics
- [submit-build-status](./submit-build-status/README.md) - Submits build status to CI Analytics
- [submit-test-status](./submit-test-status/README.md) - Submits test status to CI Analytics
- [submit-aborted-gha-status](./submit-aborted-gha-status/README.md) - Submits aborted workflow status

### Utilities
- [generate-github-app-token-from-vault-secrets](./generate-github-app-token-from-vault-secrets/README.md) - Generates GitHub App tokens from Vault
- [sanitize-branch-name](./sanitize-branch-name/README.md) - Sanitizes branch names for use in environments
- [yq-yaml-processor](./yq-yaml-processor/README.md) - Processes YAML files with yq

For team-specific actions, see the [teams](./teams/) directory.

## Contributing

Before contributing, please make sure to activate `pre-commit` in this repository:

```shell
pre-commit install --install-hooks -t commit-msg -t pre-commit
```
