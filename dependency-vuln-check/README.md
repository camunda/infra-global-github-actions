# dependency-vuln-check

A reusable CI gate that prevents a pull request from introducing **newly-added**
vulnerable dependencies. It diffs the PR base and head with the **GitHub Dependency
Review API**, then applies two configurable severity thresholds.

The blocking logic lives in [check.py](check.py) (pure Python stdlib, no pip deps).

## Blocking rules

For every dependency whose `change_type` is `added` and whose `scope` is gated
(see `fail-on-scopes`):

| Vulnerability | Blocked? |
|---------------|----------|
| Fix available, severity ≥ `fail-on-fixable-severity` (default `low` → any) | ✅ Yes |
| No fix, severity ≥ `fail-on-severity` (default `high`) | ✅ Yes |
| Severity below the applicable threshold | ❌ No |
| Dependency scope not in `fail-on-scopes` (default gated scope: `runtime`, so `development` is excluded) | ❌ No (non-blocking notice) |
| GHSA listed in the config `allow-ghsas` | ❌ No (non-blocking warning) |
| `removed` or `unchanged` dependency | ❌ No |

Defaults reproduce the policy from camunda/camunda issue
[#29729](https://github.com/camunda/camunda/issues/29729): block any fixable vuln
(an available fix means there is no excuse to ship it), and block unfixable vulns
only when high/critical. Version **downgrades** are covered — the lower vulnerable
version shows up as `added` in the diff and is evaluated normally.

## Usage

```yaml
- uses: actions/checkout@v6
- uses: camunda/infra-global-github-actions/dependency-vuln-check@main
  with:
    base-sha: ${{ github.event.pull_request.base.sha }}
    head-sha: ${{ github.event.pull_request.head.sha }}
    base-ref: ${{ github.event.pull_request.base.ref }}
    snapshot-workflow: maven-dependency-snapshot.yml
    # optional — defaults shown
    fallback-base-ref: main
    max-snapshot-lookback: "30"
    override-label: ci:vuln-gate-override
    config-file: .github/dependency-review-config.json
    fail-on-severity: high
    fail-on-fixable-severity: low
    fail-on-scopes: runtime
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `base-sha` | yes | — | Base commit SHA of the PR |
| `head-sha` | yes | — | Head commit SHA of the PR |
| `base-ref` | yes | — | Base **branch** of the PR (e.g. `main`, `stable/8.8`). Used to find the nearest snapshotted ancestor on the correct branch |
| `fallback-base-ref` | no | `main` | Branch to fall back to when `base-ref` has no dependency snapshots (e.g. stacked PRs targeting a feature branch). The gate searches this branch for the nearest snapshotted ancestor of `base-sha` instead of failing closed, and posts a notice to the PR comment |
| `snapshot-workflow` | yes | — | Filename of the workflow that submits the base snapshot (e.g. `maven-dependency-snapshot.yml`). Its successful push-event runs are scanned to resolve the effective base |
| `max-snapshot-lookback` | no | `30` | How many recent successful snapshot runs to scan when resolving the effective base |
| `override-label` | no | `ci:vuln-gate-override` | PR label that bypasses the gate **only** when it cannot verify the PR (outage / no-ancestor). Never bypasses a real finding |
| `config-file` | no | `.github/dependency-review-config.json` | Path to the JSON config holding `allow-ghsas` |
| `fail-on-severity` | no | `high` | Min severity (`low`/`moderate`/`high`/`critical`) that blocks when **no fix** is available |
| `fail-on-fixable-severity` | no | `low` | Min severity that blocks when a **fix is** available |
| `fail-on-scopes` | no | `runtime` | Comma-separated scopes to gate (`runtime`,`development`) |

## Required permissions

The action uses the workflow's `github.token`. The calling job must grant:

```yaml
permissions:
  contents: read         # read the dependency graph / Dependency Review API
  actions: read          # list snapshot-workflow runs to resolve the effective base
  pull-requests: write   # post or update the findings comment; read the override label
```

- `contents: read` is required for `GET /repos/{owner}/{repo}/dependency-graph/compare/{base}...{head}`
  **and** the commit-compare used during base resolution. The repository must have the
  **Dependency graph** feature enabled.
- `actions: read` is required to list runs of the `snapshot-workflow`
  (`GET /repos/{owner}/{repo}/actions/workflows/{workflow}/runs`) when resolving the base.
- `pull-requests: write` is required to post the findings comment and to read the PR's
  labels (override check). On **fork PRs** the token is often read-only; the action then
  emits a `::warning::` instead of failing.
- The GraphQL Advisory fallback (used only when the diff omits `first_patched_version`)
  reads public advisory data and needs no extra scope.

## Base-snapshot resolution & fail-closed contract

The diff compares `effective_base...head`, **not** the raw `base.sha`. The base snapshot
workflow is path-filtered (it only runs when poms change), so a code-only base commit has
**no snapshot** — leaving the base side of the compare empty and flagging the *entire* head
tree as `added` (pre-existing dependencies falsely surface as new). To avoid this, the action
resolves `base.sha` to the most recent commit on `base-ref` that has a submitted snapshot and
is an **ancestor-or-equal** of `base.sha`, then diffs from there.

The gate **fails closed** when it cannot verify a PR:

| Situation | Result |
|-----------|--------|
| GitHub API error, transient | retried (3 attempts, exponential backoff) |
| API error survives retries | **fail closed** (block), reason named in the log |
| No snapshotted ancestor on `base-ref`; `base-ref` differs from `fallback-base-ref` | retry on `fallback-base-ref`; notice posted to PR comment |
| No snapshotted ancestor on either branch within `max-snapshot-lookback` | **fail closed** (block) |
| API works, real vulnerable dependency added | block (normal finding) |
| API works, no vulnerable dependency added | pass |

Every run writes a summary trail (resolved base, runs scanned, verdict). Failure reasons are
named explicitly in the log (rate-limit vs 5xx vs timeout vs permissions vs not-found).

### Ancestor-staleness filter (Pattern A false positive prevention)

After resolving `effective_base`, the gate compares `effective_base...latest_on_base_branch`
to find dependency versions that were bumped on the base branch *after* the snapshot was taken
(e.g. by a Renovate commit that landed on `main` while the PR was open). Any `(name, version,
manifest)` triple present in that drift is treated as pre-existing and moved to the
informational section of the PR comment rather than blocking. This prevents false positives
where a PR that never touched a given dependency is blamed for a vulnerability introduced by
an unrelated bump on `main`.

The filter is manifest-level: if the same dep version is added to a *new* manifest by the PR,
it is still evaluated normally. Fail-open: if the drift comparison API call fails, the filter
returns empty and no real findings are silently suppressed.

### Override label (for sustained outages)

If the gate fails closed because it genuinely **cannot verify** the PR (a sustained GitHub
outage, or no resolvable base snapshot), a maintainer may bypass it:

1. Add the `override-label` (default `ci:vuln-gate-override`) to the PR.
2. **Re-run** the failed gate job.

The label is read **live** from the PR (not the frozen event payload), so a re-run after
labeling takes effect. The bypass is logged loudly (`::warning::` + PR comment) for audit. The
label **never** bypasses a real vulnerability finding — only the can't-verify (fail-closed)
paths. Create the label in the consuming repo first: `gh label create "ci:vuln-gate-override"`.

## Configuration — exceptions (`allow-ghsas`)

A **GHSA ID** is GitHub's identifier for a security advisory (format
`GHSA-xxxx-xxxx-xxxx`). Each vulnerability surfaced by the Dependency Review API
carries one or more GHSA IDs and, usually, a CVE. To vet and suppress a specific
advisory, add its GHSA ID to the config file:

```json
{
  "allow-ghsas": [
    "GHSA-xxxx-xxxx-xxxx"
  ]
}
```

Matching is case-insensitive. Each entry should carry a tracking issue / comment
explaining why it is accepted and a review-by date. Protect this file with
CODEOWNERS in the consuming repository so exceptions require security review.

### Where the config file lives

The config file belongs in the **repository being gated** (the one running the
workflow) — **not** in this action's repository.

- The path is resolved relative to the workflow's checkout, so the file must be
  committed to the consuming repo and checked out (via `actions/checkout`) before
  this action runs.
- Default location: **`.github/dependency-review-config.json`** at the root of the
  consuming repo. Use the default unless you have a reason to move it.
- To use a different path, set the `config-file` input (relative to the repo root):

  ```yaml
  - uses: camunda/infra-global-github-actions/dependency-vuln-check@main
    with:
      base-sha: ${{ github.event.pull_request.base.sha }}
      head-sha: ${{ github.event.pull_request.head.sha }}
      config-file: path/to/your-config.json
  ```

- If the file is absent, the action does **not** fail — it logs a `::notice::` and
  proceeds with an empty allow-list (every vulnerability is gated normally). Commit
  the file only when you actually need to suppress an advisory.

Example layout in a consuming repo:

```
your-repo/
├── .github/
│   ├── dependency-review-config.json   ← exceptions live here (default path)
│   └── workflows/
│       └── ci.yml                      ← calls the action
└── ...
```

## Outputs / behavior

- Posts (or updates in place) a single PR comment marked `<!-- dependency-vuln-check -->`,
  with separate sections for blocking findings (🚨), allowed exceptions (⚠️), and
  non-gated-scope findings (⚠️).
- Writes the same tables to the job step summary, plus the resolved-base trail.
- Exits non-zero if any blocking finding remains, or if the gate fails closed
  (unverifiable PR without the override label).

## Limitations

- Evaluates only **newly added** dependencies in the PR diff; deps already on the base
  branch are not re-scanned (pair with a scheduled SCA scan for ongoing monitoring).
- For transitive / BOM-pinned dependencies to appear in the diff, both base and head
  commits need a submitted dependency snapshot (GitHub Dependency Submission API). The
  base side is resolved automatically to the nearest snapshotted ancestor; the head side
  must be submitted by the consuming workflow before this action runs.

## Tests

```bash
cd dependency-vuln-check
pip install pytest
python -m pytest -q
```

Run automatically by `.github/workflows/test-dependency-vuln-check.yml` on changes
to this directory.

## Related

- camunda/camunda issue [#29729](https://github.com/camunda/camunda/issues/29729) — original requirement
- camunda/camunda [#53506](https://github.com/camunda/camunda/pull/53506) — the consuming gate job
