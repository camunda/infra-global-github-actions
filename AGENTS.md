# AGENTS.md

Public repository of reusable GitHub Actions (composite actions and reusable workflows) for Camunda's CI. Every directory with an `action.yml` is one action, consumed by other repositories through `camunda/infra-global-github-actions/<action>@<ref>`.

## Stack and checks

- Composite actions in YAML and Bash, linted by `pre-commit run -a` (actionlint, zizmor, shellcheck, Renovate config validator). Tool versions are pinned in `.tool-versions`.
- Third-party actions are pinned by commit SHA with the full version in the comment.
- Every workflow step has a `name:`.
- New actions use hyphenated input names (e.g. `repository-owner`); existing underscore inputs are kept for compatibility.

## Tests

Each action with a test has a `.github/workflows/test-<action>.yml` that runs on `pull_request` when the action changes. See [TESTING.md](./TESTING.md) for what is covered and which risks are accepted.

## 🧪 Test-driven development

- No change goes untested: every usage path a change touches is covered by a test that CI runs when that path changes, or by an accepted risk the maintainers signed off, recorded in [TESTING.md](./TESTING.md).
- Find and close gaps with the [`test-gap-closer`](https://github.com/camunda/infra-core/tree/stage/.claude/skills/test-gap-closer) skill. If it is not loaded, read its `SKILL.md` from there.
- Renovate automerges a dependency only while its tests cover every way this repo uses it. A change that adds a new usage of an automerged dependency extends its tests or disables its automerge (local entries removed, inherited rules overridden with `automerge: false`), in the same PR.
