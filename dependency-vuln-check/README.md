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
| Dependency scope not in `fail-on-scopes` (default: development) | ❌ No (non-blocking notice) |
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
    # optional — defaults shown
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
| `config-file` | no | `.github/dependency-review-config.json` | Path to the JSON config holding `allow-ghsas` |
| `fail-on-severity` | no | `high` | Min severity (`low`/`moderate`/`high`/`critical`) that blocks when **no fix** is available |
| `fail-on-fixable-severity` | no | `low` | Min severity that blocks when a **fix is** available |
| `fail-on-scopes` | no | `runtime` | Comma-separated scopes to gate (`runtime`,`development`) |

## Required permissions

The action uses the workflow's `github.token`. The calling job must grant:

```yaml
permissions:
  contents: read         # read the dependency graph / Dependency Review API
  pull-requests: write   # post or update the findings comment
```

- `contents: read` is required for `GET /repos/{owner}/{repo}/dependency-graph/compare/{base}...{head}`.
  The repository must have the **Dependency graph** feature enabled.
- `pull-requests: write` is required to post the findings comment. On **fork PRs** the
  token is often read-only; the action then emits a `::warning::` instead of failing.
- The GraphQL Advisory fallback (used only when the diff omits `first_patched_version`)
  reads public advisory data and needs no extra scope.

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

## Outputs / behavior

- Posts (or updates in place) a single PR comment marked `<!-- dependency-vuln-check -->`,
  with separate sections for blocking findings (🚨), allowed exceptions (⚠️), and
  non-gated-scope findings (⚠️).
- Writes the same tables to the job step summary.
- Exits non-zero if any blocking finding remains.

## Limitations

- Evaluates only **newly added** dependencies in the PR diff; deps already on the base
  branch are not re-scanned (pair with a scheduled SCA scan for ongoing monitoring).
- For transitive / BOM-pinned dependencies to appear in the diff, both base and head
  commits need a submitted dependency snapshot (GitHub Dependency Submission API).

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
