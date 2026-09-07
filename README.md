# 🌍 Global GitHub Actions

GitHub Actions maintained by the Infra team, primarily for other teams inside Camunda to consume.

> ⚠️ This repository is **public**. Nothing in it may contain a secret.

## 🔧 Using an Action

Every action is released on its own line, tagged `<family>-X.Y.Z`, where the family is the last path segment of the released directory. Sub-actions share their parent's family: `fossa/setup` releases under `fossa-*`, `teams/infra/pull-request/automerge` under `pull-request-*`.

Reference an action by commit SHA and name its release in a trailing comment:

```yaml
- uses: camunda/infra-global-github-actions/teams/infra/pull-request/automerge@d56c158341637cc71ed42e34040e9db0d0026b6c  # pull-request-1.1.0
```

Resolve a tag to its SHA with:

```shell
gh api repos/camunda/infra-global-github-actions/git/refs/tags/pull-request-1.1.0 --jq '.object.sha'
```

### 🔄 Keeping Pins Current

Extend [`renovate-action-versions.json5`](renovate-action-versions.json5) so Renovate tracks each family on its own release line:

```json5
{
  extends: ["github>camunda/infra-global-github-actions:renovate-action-versions.json5"],
}
```

Renovate's built-in `github-actions` manager drops the sub-action path from the dependency name, so without the preset every family here collapses into one `camunda/infra-global-github-actions` entry with no version to compare, and pins go stale with no signal at all. The preset adds a custom manager that reads the family out of the trailing comment, which is why that comment has to carry the full release (`# pull-request-1.1.0`, never `# 1.1.0`).

It ships that manager only. Labels, grouping and automerge stay with the consumer, matched on the dependency name the manager emits:

```json5
{
  packageRules: [
    {
      matchDepNames: ["/^camunda\\/infra-global-github-actions\\//"],
      addLabels: ["component:ci", "group:github-actions"],
    },
  ],
}
```

Consumers that pin by SHA without extending the preset freeze silently: `camunda/mcp` sat on five-month-old pins for exactly that reason.

## 🤝 Contributing

### 🪝 Pre-Commit Hooks

```shell
pre-commit install --install-hooks -t commit-msg -t pre-commit
```

- **pre-commit hooks** run the linters (trailing whitespace, shellcheck, actionlint, zizmor).
- **commit-msg hooks** validate [conventional commit](https://www.conventionalcommits.org/en/v1.0.0/) format.

### 📝 Conventional Commits

Commit messages and PR titles follow `<type>[optional scope]: <description>`, with `!` after the type for a breaking change.

Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`, `deps`.

Releases are cut by [release-please](https://github.com/googleapis/release-please) from those messages, so the type decides the version bump: `feat` minor, `fix` patch.

### 🚀 Adding a New Action

Register it in [`release-please-config.json`](.github/config/release-please-config.json) and seed it at `0.0.0` in [`.release-please-manifest.json`](.github/config/.release-please-manifest.json), unless it belongs to an existing family, in which case it inherits that family's release.

Skipping this leaves the action without a version tag, so consumers can only pin a bare SHA and Renovate has nothing to track.

### 📌 Pinning Third-Party Actions

Every action used here, in a workflow or in a composite `action.yml`, **including GitHub's own `actions/*`**, must be referenced by a full commit SHA with the full version in a trailing comment:

```yaml
- uses: hashicorp/vault-action@892a26828f195e65540a40b4768ae4571f51ebfc  # v4.0.0
```

A tag is a mutable pointer that a compromised upstream can force-push; a SHA cannot be moved. Several consuming repositories also enforce GitHub's **Require actions to be pinned to a full-length commit SHA** setting, which exempts no namespace and is evaluated over the whole dependency tree, so an action left on a tag here refuses the consumer's job at `Set up job`, before any step runs.

The one exemption is `camunda/*`, because this repository references itself at `@main` by contract. The rule is enforced by the `zizmor` hook and configured in [`.github/zizmor.yml`](.github/zizmor.yml).

## 📚 References

- [GitHub Actions pinning policy](docs/github-actions-pinning.md) for the full rationale, the known gap around `@main` self-references, and how to resolve a tag to a SHA
- [zizmor `unpinned-uses` audit](https://docs.zizmor.sh/audits/#unpinned-uses)
