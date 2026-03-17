# Global Github Actions

This repository contains Github Actions (GHA) maintained by the Infra team. Those actions are intended to be consumed by other teams inside Camunda.

They are **publicly accessible** and thus must not contain any secrets.

## Contributing

### Pre-Commit Hooks

This repository uses [pre-commit](https://pre-commit.com/) to enforce code quality and commit conventions.
To set up pre-commit hooks locally, run:

```shell
pre-commit install --install-hooks -t commit-msg -t pre-commit
```

This installs two types of hooks:
- **pre-commit hooks** (`-t pre-commit`): Run linters (trailing whitespace, shellcheck, actionlint, etc.) before each commit.
- **commit-msg hooks** (`-t commit-msg`): Validate that commit messages follow [conventional commit](https://www.conventionalcommits.org/en/v1.0.0/) format (e.g. `feat: ...`, `fix: ...`, `chore: ...`).

### Conventional Commits

This repository enforces [conventional commits](https://www.conventionalcommits.org/en/v1.0.0/) to enable automated releases via [release-please](https://github.com/googleapis/release-please).

All commit messages and PR titles must follow the format: `<type>[optional scope]: <description>`

Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`, `deps`

Breaking changes can be indicated by appending `!` after the type (e.g. `feat!: ...` or `fix!: ...`).
