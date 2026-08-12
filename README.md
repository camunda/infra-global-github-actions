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
- **pre-commit hooks** (`-t pre-commit`): Run linters (trailing whitespace, shellcheck, actionlint, zizmor, etc.) before each commit.
- **commit-msg hooks** (`-t commit-msg`): Validate that commit messages follow [conventional commit](https://www.conventionalcommits.org/en/v1.0.0/) format (e.g. `feat: ...`, `fix: ...`, `chore: ...`).

### Pinning Third-Party Actions

Every action used here — in a workflow or in a composite `action.yml`, **including GitHub's own `actions/*`** — must be referenced by a full commit SHA, with the full version in a trailing comment:

```yaml
- uses: hashicorp/vault-action@892a26828f195e65540a40b4768ae4571f51ebfc # v4.0.0
```

Two reasons. A tag is a mutable pointer that a compromised upstream can force-push, while a SHA cannot be moved. And several consuming repositories enforce GitHub's **Require actions to be pinned to a full-length commit SHA** setting, which exempts no namespace and is evaluated over the whole dependency tree — so an action left on a tag here refuses the consumer's job at `Set up job`, before any step runs.

The only exemption is `camunda/*`, because this repository references itself at `@main` by contract. The rule is enforced by the `zizmor` pre-commit hook and configured in [`.github/zizmor.yml`](.github/zizmor.yml).

See [docs/github-actions-pinning.md](docs/github-actions-pinning.md) for the full policy, why `actions/*` is not exempt here even though it is in `camunda/camunda` and `infra-core`, the known gap around `@main` self-references, how to resolve a tag to a SHA, and why the comment must carry the full version rather than a floating major.

### Conventional Commits

This repository enforces [conventional commits](https://www.conventionalcommits.org/en/v1.0.0/) to enable automated releases via [release-please](https://github.com/googleapis/release-please).

All commit messages and PR titles must follow the format: `<type>[optional scope]: <description>`

Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`, `deps`

Breaking changes can be indicated by appending `!` after the type (e.g. `feat!: ...` or `fix!: ...`).
