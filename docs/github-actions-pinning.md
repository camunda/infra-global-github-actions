# 📌 GitHub Actions pinning policy

## 📌 What

Every third-party GitHub Action referenced in this repository — in a workflow under `.github/workflows/` or in any composite `action.yml` — must be referenced by a full 40-character commit SHA, with the human-readable version kept in a trailing comment:

```yaml
- uses: hashicorp/vault-action@892a26828f195e65540a40b4768ae4571f51ebfc # v4.0.0
```

The policy lives in [`.github/zizmor.yml`](../.github/zizmor.yml) and is enforced by the [`zizmor`](https://docs.zizmor.sh/) [pre-commit](../.pre-commit-config.yaml) hook, which runs locally and in the `pre-commit` workflow.

Pinning levels per owner:

| Owner pattern | Level | Accepted refs |
|:--------------|:------|:--------------|
| everything, **including `actions/*`, `github/*` and `camunda/*`** | `hash-pin` | 40-character commit SHA only |

Local references (`uses: ./common-tooling`) are same-repo and out of scope.

> ℹ️ This is stricter than the equivalent policy in `camunda/camunda` and `camunda/infra-core`, which exempt `actions/*` and `github/*`. See [Why GitHub's own actions are not exempt](#why-githubs-own-actions-are-not-exempt).

## 🤔 Why

A git tag is a **mutable pointer**. An attacker who compromises an upstream repository can force-push an existing tag to malicious code, and every consumer executes it on the next run — with no pull request, no diff, and no notification. The [`tj-actions/changed-files` compromise](https://unit42.paloaltonetworks.com/github-actions-supply-chain-attack/) (March 2025) did exactly that and leaked CI secrets from thousands of repositories. A commit SHA cannot be moved, so a pinned reference always resolves to code somebody reviewed.

This matters more here than in a normal repository, for two reasons:

- **This repository is public and consumed by other teams.** Its composite actions run inside workflows across Camunda, frequently in jobs holding Vault, GCP, Teleport, and Artifactory credentials. An unpinned third-party action in a composite action is not just our exposure — every downstream repository inherits it transitively, and none of those consumers can see or gate it.
- **Consumers pin this repository as `@<sha> # <family>-X.Y.Z`, kept current by the [`renovate-action-versions.json5`](../renovate-action-versions.json5) preset.** Each Renovate bump carries the third-party references of a release into every consumer, so those references must be pinned here.

### Why GitHub's own actions are not exempt

`camunda/camunda` and `camunda/infra-core` exempt `actions/*` and `github/*` on the reasoning that they sit inside the same trust boundary as the runners: if `actions/checkout` is compromised, SHA-pinning it elsewhere buys little, because GitHub already controls the environment the job runs in.

That reasoning does not carry over here, because the binding constraint for this repository is not our own threat model but GitHub's **Require actions to be pinned to a full-length commit SHA** setting, which a number of consuming repositories already enforce. That setting grants no namespace exemptions:

> all actions must be pinned to a full-length commit SHA to be used. This includes actions from your organization and actions authored by GitHub. Reusable workflows can still be referenced by tag.
>
> — [Managing GitHub Actions settings for a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)

It is evaluated over the **whole dependency tree**, and refusal happens at `Set up job`, before any step executes. So an `actions/foo@v1` left on a tag inside a composite action here breaks the consumer's job outright, and the consumer cannot work around it by choosing a different revision of this repository. A `ref-pin` policy for `actions/*` would be weaker than the policy already binding on the repositories this gate exists to protect: green here, broken downstream.

Note the carve-out is for **reusable workflows**, not for organization ownership — which is why `camunda/*` cannot be exempted on "it's ours" grounds either. See below.

### References to this repository

This repository's references to itself are pinned like any other action, as `@<sha> # <family>-X.Y.Z`, and kept current by the [`renovate-action-versions.json5`](../renovate-action-versions.json5) preset that [`.github/renovate.json5`](../.github/renovate.json5) extends. A change to a self-referenced action therefore reaches the actions that use it through a Renovate bump, not on its own.

The preset scans every YAML file, but only tracks pins whose trailing comment is `# <family>-X.Y.Z`. Pins commented `# main` or `# generate-github-app-token-from-vault-secrets: v1.1.0`, or without a comment, are not tracked.

### Alternatives considered

- **Pin only new references, leave existing tags alone.** Cheaper, but leaves the actual exposure in place — the tags already on `main` are the ones a compromised upstream would move. Rejected.
- **Enable zizmor's full default audit set.** 238 findings on arrival (template injection, excessive permissions, artipacked, …). A gate that is red from day one gates nothing. Rejected in favour of adopting audits one at a time; see [Scope](#scope-of-the-zizmor-adoption).
- **Mirror the `camunda/camunda` and `infra-core` trust boundary exactly** (`actions/*` and `github/*` on `ref-pin`). Consistent across repositories, and defensible on pure threat-model grounds, but it would leave this repository's consumers broken under a setting they already enforce. Rejected; see [above](#why-githubs-own-actions-are-not-exempt).
- **Renovate's `helpers:pinGitHubActionDigests` preset.** Pins digests automatically, but it is not a gate: nothing stops a contributor from adding an unpinned action, and it would also pin `actions/*` and `camunda/*` against the trust boundary above. Rejected.
- **A hand-rolled pre-commit script.** No new dependency, but it reimplements a maintained tool and diverges from the policy the other Camunda repositories already run. Rejected.
- **Limit the preset to `.github/` and `action.yml`, or extend it to Markdown.** The preset scans every YAML file instead, so pins outside `.github/` (e.g. `agents/_template/workflow.yml`) are tracked too. Its regex only matches `uses: camunda/infra-global-github-actions/<path>@<40-char SHA> # <family>-X.Y.Z`, so the wider glob adds no false positives. Markdown would rewrite examples in the CHANGELOGs, ADRs and docs of every consumer; a repository that wants that can add the pattern locally. Both rejected.
- **Floating major tags in the comment (`@<sha> # v4`).** Shorter, but it converts routine upstream releases into review toil — see below. Rejected.

## 🔧 How

### Adding or updating a third-party action

Resolve the tag to its commit SHA and keep the version as a comment:

```bash
# annotated tags need the peeled ref (^{}), lightweight tags do not
git ls-remote https://github.com/<owner>/<repo> 'refs/tags/<tag>*'
```

```yaml
- uses: <owner>/<repo>@<40-char-sha> # <full version>
```

> 🚨 The comment must carry the **full** version (`# v4.6.0`), never a floating major (`# v4`), even when the floating major is the tag you resolved.

This is load-bearing rather than cosmetic. Renovate derives the update type from that comment, and [`.github/renovate.json5`](../.github/renovate.json5) auto-merges `minor` and `patch` for the `github-actions` manager but not `digest`:

| Comment | Upstream ships v4.6.0 | Update type | Auto-merged? |
|:--------|:----------------------|:------------|:-------------|
| `# v4.5.0` | comment and SHA both updated | `patch` | ✅ yes |
| `# v4` | `v4` tag moves, comment unchanged | `digest` | ❌ no, costs a review |

With full-version comments, ordinary upgrades keep auto-merging exactly as they did before pinning, so the policy adds no recurring review load. It also preserves the signal: a digest-only PR now genuinely means an upstream tag moved without a release, which is the event this policy exists to surface. Review those, don't rubber-stamp them.

To find the precise version behind a floating major, list every tag pointing at the same commit:

```bash
git ls-remote --tags https://github.com/<owner>/<repo> \
  | awk -v s=<40-char-sha> '$1==s {print $2}'
```

### Verifying locally

```bash
pre-commit run zizmor --all-files
```

### Exceptions

If an action genuinely cannot be pinned, suppress it on the line itself so the justification sits next to the code:

```yaml
- uses: <owner>/<repo>@v1 # zizmor: ignore[unpinned-uses] vendor only ships moving tags
```

Whole-file exemptions go in the `rules.unpinned-uses.ignore` list in [`.github/zizmor.yml`](../.github/zizmor.yml).

### Scope of the zizmor adoption

Only the `unpinned-uses` audit is enabled. Every other audit that fires on this repository is explicitly disabled in [`.github/zizmor.yml`](../.github/zizmor.yml), each `disable: true` acting as a standing TODO with its finding count recorded. Enabling one means fixing its findings in the same change. The hook runs with `--offline`, so zizmor's network-backed audits never execute and no token is needed.

## 📚 References

- [zizmor `unpinned-uses` audit](https://docs.zizmor.sh/audits/#unpinned-uses)
- [zizmor configuration](https://docs.zizmor.sh/configuration/)
- [GitHub: using third-party actions securely](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#using-third-party-actions)
- [Unit 42: the `tj-actions/changed-files` supply-chain attack](https://unit42.paloaltonetworks.com/github-actions-supply-chain-attack/)
