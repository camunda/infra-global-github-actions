#!/usr/bin/env python3
"""PR vulnerability gate — GitHub Dependency Review API.

Blocks on newly-added dependencies carrying known vulnerabilities, according to
two independent severity thresholds:

  * fixable vulns (a patched version exists) block at/above FAIL_ON_FIXABLE_SEVERITY
  * unfixable vulns block at/above FAIL_ON_SEVERITY

Only dependencies whose scope is listed in FAIL_ON_SCOPES are gated; others are
reported as non-blocking. Covers the downgrade scenario: a version downgrade
shows the old version as "removed" and the new vulnerable version as "added".

Base-snapshot resolution
------------------------
The dependency diff is ``effective_base...head``. ``effective_base`` is the most
recent commit on the PR's base branch that (a) has a submitted Maven dependency
snapshot and (b) is an ancestor-or-equal of the PR's ``base.sha``. Trusting the
raw ``base.sha`` is unsafe: the snapshot workflow is path-filtered, so a code-only
base commit has no snapshot, leaving the base side of the compare empty and
flagging the *entire* head tree as "added" (pre-existing deps surface as new).

Stacked PR fallback
-------------------
When the PR targets a branch that has no snapshots (e.g. a feature branch used as
the base for a stacked PR), the gate falls back to the configured
``FALLBACK_BASE_REF`` (default: ``main``).  The diff ``effective_base...head`` then
covers both the stacked branch's changes and the PR's own changes — conservative
but avoids a hard fail-closed on a normally-safe pattern.  A notice is posted to
the PR comment so engineers understand why the effective base differs from the
branch they targeted.

The gate FAILS CLOSED when it cannot verify a PR (no snapshotted ancestor on
either ``base_ref`` or the fallback, or a GitHub API failure that survives retries).
A human may bypass a genuinely un-checkable PR by adding the override label (read
live, not from the stale event payload). The label never bypasses a real finding.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


_GITHUB_API = "https://api.github.com"
_COMMENT_MARKER = "<!-- dependency-vuln-check -->"
_DEVOPS_TEAM = "@camunda/monorepo-devops-team"

# Retry policy for transient GitHub API failures (5xx, network, timeout, rate limit).
_MAX_ATTEMPTS = 3
_BACKOFF_BASE_SECONDS = 2

# Severity ranking used by both threshold gates. These are the only values the
# Dependency Review API emits for `severity`.
SEVERITY_ORDER = {"low": 0, "moderate": 1, "high": 2, "critical": 3}


class ApiError(Exception):
    """A GitHub API call that could not be completed.

    `reason` is a short, human-readable cause — deliberately named so the GHA log
    states *why* the gate failed (rate limit vs 5xx vs timeout vs permissions vs
    not-found), instead of a bare stack trace. `retryable` separates transient
    infra failures (retried) from definitive responses (surfaced immediately).
    """

    def __init__(self, reason: str, status: int | None = None, retryable: bool = False):
        self.reason = reason
        self.status = status
        self.retryable = retryable
        super().__init__(reason)


def severity_rank(name: str) -> int:
    """Rank a threshold severity name. Raises on unknown — used to validate inputs."""
    try:
        return SEVERITY_ORDER[name]
    except KeyError:
        raise SystemExit(
            f"::error::Invalid severity '{name}'. Expected one of: {', '.join(SEVERITY_ORDER)}"
        )


def parse_scopes(raw: str) -> set:
    """Parse a comma-separated scopes input into a normalized set."""
    return {s.strip().lower() for s in (raw or "").split(",") if s.strip()}


def _blocks(severity: str, fixable: bool, fail_sev_rank: int, fail_fixable_rank: int) -> bool:
    """Decide whether a vulnerability meets the configured blocking threshold.

    A vulnerability with no/unknown severity preserves the legacy contract:
    fixable ones always block; unfixable ones never block on severity alone.
    """
    threshold = fail_fixable_rank if fixable else fail_sev_rank
    rank = SEVERITY_ORDER.get(severity)
    if rank is None:
        return fixable
    return rank >= threshold


def _classify_http_error(e: urllib.error.HTTPError) -> ApiError:
    """Map an HTTPError to a named ApiError, deciding retryability.

    Retryable (transient infra): 5xx, 429, and 403 carrying rate-limit signals
    (secondary rate limit). Definitive (surfaced at once): 403 without rate-limit
    headers (genuine permission/scope denial), 404, 422, other 4xx.
    """
    code = e.code
    if code >= 500:
        return ApiError(f"GitHub server error (HTTP {code})", code, retryable=True)
    if code == 429:
        return ApiError("rate limit exceeded (HTTP 429)", code, retryable=True)
    if code == 403:
        headers = e.headers or {}
        # Retry-After signals a *secondary* rate limit; X-RateLimit-Remaining: 0
        # signals the *primary* rate limit is exhausted. Both are transient, but
        # the named reason must distinguish them for accurate audit/troubleshooting.
        if headers.get("Retry-After") is not None:
            return ApiError("secondary rate limit (HTTP 403)", code, retryable=True)
        if headers.get("X-RateLimit-Remaining") == "0":
            return ApiError("primary rate limit exhausted (HTTP 403)", code, retryable=True)
        return ApiError(
            "permission denied — token lacks required scope (HTTP 403)", code, retryable=False
        )
    if code == 404:
        return ApiError("resource not found (HTTP 404)", code, retryable=False)
    if code == 422:
        return ApiError("unprocessable request (HTTP 422)", code, retryable=False)
    return ApiError(f"client error (HTTP {code})", code, retryable=False)


def _http_get_json(url: str, token: str):
    """Single authenticated GET, returning (parsed_json, headers).

    Retries transient failures with exponential backoff; raises ApiError (with a
    named reason) on a definitive response or once retries are exhausted. Each
    retry is logged with its cause so the GHA log shows exactly why.
    """
    last: ApiError | None = None
    for attempt in range(1, _MAX_ATTEMPTS + 1):
        req = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2026-03-10",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read()), resp.headers
        except urllib.error.HTTPError as e:  # subclass of URLError — catch first
            err = _classify_http_error(e)
        except (urllib.error.URLError, TimeoutError) as e:
            err = ApiError(f"network error ({e})", None, retryable=True)

        if not err.retryable:
            print(f"::error::API call failed, no retry ({err.reason}): {url}")
            raise err
        last = err
        if attempt < _MAX_ATTEMPTS:
            delay = _BACKOFF_BASE_SECONDS * (2 ** (attempt - 1))
            print(
                f"::warning::API call failed (attempt {attempt}/{_MAX_ATTEMPTS}, {err.reason}) "
                f"— retrying in {delay}s: {url}"
            )
            time.sleep(delay)
    print(f"::error::API call failed after {_MAX_ATTEMPTS} attempts ({last.reason}): {url}")
    raise last


def _api_get(url: str, token: str) -> list:
    """Fetch all pages of a list GitHub API GET. Retries transient failures per page."""
    results, next_url = [], url
    while next_url:
        payload, headers = _http_get_json(next_url, token)
        results.extend(payload)
        match = re.search(r'<([^>]+)>;\s*rel="next"', headers.get("Link", ""))
        next_url = match.group(1) if match else None
    return results


def _compare_status(repository: str, base: str, head: str, token: str) -> str:
    """Return the commit-comparison status: identical | ahead | behind | diverged."""
    payload, _ = _http_get_json(
        f"{_GITHUB_API}/repos/{repository}/compare/{base}...{head}?per_page=1", token
    )
    return payload.get("status", "") if isinstance(payload, dict) else ""


def latest_snapshotted_ancestor(
    repository: str, base_ref: str, base_sha: str, workflow: str, token: str, lookback: int
):
    """Most recent snapshotted commit that is an ancestor-or-equal of base_sha.

    Lists successful push-event runs of `workflow` on `base_ref` (newest-first;
    a successful run guarantees a submitted snapshot — the workflow's submit step
    is unconditional). For each run's head_sha, compares head_sha...base_sha and
    accepts the first whose status is `identical` (same commit) or `ahead`
    (base_sha is ahead → the run commit is an ancestor).

    Returns (effective_base_sha, run_id, scanned_count, latest_on_branch); the first
    three are (None, None, scanned) if no ancestor is found within the window.
    `latest_on_branch` is the head_sha of the most recent successful run on
    `base_ref` (the very first run examined), regardless of ancestry — the latest
    *snapshotted* tip of the branch. The pre-existing dep filter diffs against this
    (to surface Maven base-branch drift, which is only visible at snapshotted
    commits) unioned with the PR's base-sha (to surface natively-detected
    ecosystems like Go/npm at the true branch tip). NOTE: because this is the latest
    *snapshotted* commit rather than the actual branch tip, a path-filtered push
    (e.g. a Go-only change that never triggers the Maven snapshot workflow) leaves it
    behind the branch tip — which is exactly why the filter also needs base-sha. See
    `_base_branch_pre_existing`.
    Raises ApiError on API failure so the caller can fail closed.

    `lookback` is honored even beyond the API's 100-per-page cap by following
    pagination, so a large lookback never silently scans fewer runs than asked.
    """
    per_page = min(lookback, 100)  # GitHub caps per_page at 100
    url = (
        f"{_GITHUB_API}/repos/{repository}/actions/workflows/{workflow}/runs"
        f"?branch={urllib.parse.quote(base_ref, safe='')}"
        f"&status=success&event=push&per_page={per_page}"
    )
    scanned = 0
    latest_on_branch: str | None = None
    while url and scanned < lookback:
        payload, headers = _http_get_json(url, token)
        runs = payload.get("workflow_runs", []) if isinstance(payload, dict) else []
        for run in runs:
            if scanned >= lookback:
                break
            run_sha = run.get("head_sha")
            if not run_sha:
                continue
            if latest_on_branch is None:
                latest_on_branch = run_sha  # most recent snapshot on this branch
            scanned += 1
            # compare/{run_sha}...{base_sha}: "ahead" = base_sha is ahead of run_sha
            # = run_sha is an ancestor of base_sha (what we want).
            status = _compare_status(repository, run_sha, base_sha, token)
            if status in ("identical", "ahead"):
                return run_sha, run.get("id"), scanned, latest_on_branch
        match = re.search(r'<([^>]+)>;\s*rel="next"', headers.get("Link", "") or "")
        url = match.group(1) if match else None
    return None, None, scanned, latest_on_branch


def _base_branch_pre_existing(
    repository: str, effective_base: str, snapshot_tip: str | None,
    base_tip: str | None, token: str,
) -> set:
    """Return (name, version, manifest) triples the base branch added since effective_base.

    Compares effective_base against two reference points via the Dependency Review
    API and unions the "added" triples from both. Any dep at (name, version,
    manifest) that appears as "added" in either drift compare was already on the
    base branch before the PR was opened — the PR did not introduce it.

    This suppresses Pattern A FPs: when a dep version is bumped on main (e.g. by
    Renovate) AFTER the effective_base snapshot was taken, that version shows as
    "added" in the PR's effective_base...head compare even though the PR never
    touched it. The drift compare reveals that main itself added that
    (name, version, manifest) — so it is pre-existing, not PR-introduced.

    Two reference points are required because the dependency graph mixes two data
    sources with different coverage:
    - `snapshot_tip` — the latest *snapshotted* commit on the base branch (from
      `latest_snapshotted_ancestor`). Maven deps exist in the graph only at commits
      where a snapshot was submitted, so a snapshotted tip is the only reference
      that surfaces Maven base-branch drift.
    - `base_tip` — the PR's raw base-sha (the true branch tip). Natively-detected
      ecosystems (Go modules, npm, …) are parsed from the file tree at any commit,
      but they never trigger the Maven snapshot workflow — so `snapshot_tip` can be
      stuck at effective_base even after such a dep was added on the branch,
      collapsing that drift window to nothing. base-sha reflects the true tip
      regardless of which ecosystem changed and recovers the native-ecosystem drift.
    Unioning both covers Maven (via snapshot_tip) and native ecosystems (via
    base_tip); neither alone is sufficient.

    Known limitation — concurrent-bump false negative: if a PR independently
    introduces the same (name, version, manifest) that the base branch also added
    after effective_base (e.g. Renovate and the PR both pin the same dep version),
    the filter cannot distinguish the two and suppresses the PR's finding. This is
    an inherent consequence of triple-level matching without PR authorship data.

    Per-dep advisory coverage: when a dep triple is pre-existing, ALL its
    advisories (including ones published after the snapshot) are suppressed. This
    is intentional — the PR did not introduce the dep version, so it is not
    responsible for any of its advisories regardless of when they were discovered.

    Per-reference fail-open: if a drift compare API call fails, that reference is
    skipped (its FPs may slip through) but the other reference's results still
    apply. Real vulns are never suppressed by a failure. A reference equal to
    effective_base or falsy is skipped (no drift to compute); duplicate references
    are compared once.
    """
    result: set = set()
    seen: set = set()
    for tip in (snapshot_tip, base_tip):
        if not tip or tip == effective_base or tip in seen:
            continue
        seen.add(tip)
        try:
            drift = _api_get(
                f"{_GITHUB_API}/repos/{repository}/dependency-graph/compare"
                f"/{effective_base}...{tip}",
                token,
            )
        except ApiError as e:
            print(
                f"::warning::Could not fetch base-branch drift compare "
                f"({effective_base}...{tip}): {e.reason} — this reference skipped"
            )
            continue
        result |= {
            (dep.get("name", ""), dep.get("version", ""), dep.get("manifest", ""))
            for dep in drift
            if dep.get("change_type") == "added"
        }
    return result


def has_override_label(repository: str, pr_number, token: str, label: str) -> bool:
    """Live read of the PR's labels (NOT the stale event payload) to honor a
    freshly-added override label on a re-run.

    Best-effort: on label-API failure we cannot confirm an override, so we return
    False and stay fail-closed (logged).
    """
    if not pr_number:
        return False
    try:
        labels = _api_get(
            f"{_GITHUB_API}/repos/{repository}/issues/{pr_number}/labels", token
        )
    except ApiError as e:
        print(
            f"::warning::Could not read PR labels to check for '{label}' ({e.reason}) "
            "— treating as not overridden (gate stays closed)"
        )
        return False
    return any(lbl.get("name") == label for lbl in labels)


def _ghsa_ids(vuln: dict) -> set:
    """Extract all GHSA IDs for a vulnerability, falling back to parsing advisory_url."""
    ids = set(vuln.get("advisory_ghsa_ids") or [])
    url = vuln.get("advisory_url", "")
    if not ids and url:
        m = re.search(r"(GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4})", url, re.IGNORECASE)
        if m:
            ids.add(m.group(1).upper())
    return ids


def _graphql(query: str, variables: dict, token: str) -> dict:
    req = urllib.request.Request(
        f"{_GITHUB_API}/graphql",
        data=json.dumps({"query": query, "variables": variables}).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


_PATCH_QUERY = """
query($ghsa: String!) {
  securityAdvisory(ghsaId: $ghsa) {
    vulnerabilities(first: 50) {
      nodes {
        package { ecosystem name }
        firstPatchedVersion { identifier }
      }
    }
  }
}
"""

_patch_cache: dict[tuple[str, str, str], str | None] = {}


def _lookup_patch(ghsa: str, ecosystem: str, package: str, token: str) -> str | None:
    """Query the GitHub Advisory GraphQL API for the first patched version."""
    key = (ghsa, ecosystem.lower(), package.lower())
    if key in _patch_cache:
        return _patch_cache[key]
    try:
        canonical = "GHSA-" + ghsa[5:].lower()  # API requires GHSA- prefix uppercase, hex lowercase
        data = _graphql(_PATCH_QUERY, {"ghsa": canonical}, token)
        nodes = (data.get("data") or {}).get("securityAdvisory") or {}
        nodes = (nodes.get("vulnerabilities") or {}).get("nodes") or []
        for node in nodes:
            pkg = node.get("package") or {}
            if pkg.get("ecosystem", "").lower() == ecosystem.lower() and pkg.get("name", "").lower() == package.lower():
                v = (node.get("firstPatchedVersion") or {}).get("identifier")
                _patch_cache[key] = v
                return v
    except Exception as e:
        print(f"::warning::GraphQL patch lookup failed for {ghsa} ({ecosystem}/{package}): {e}")
    _patch_cache[key] = None
    return None


def find_blocking(
    diff: list,
    allowed_ghsas: set,
    token: str,
    fail_sev_rank: int = SEVERITY_ORDER["high"],
    fail_fixable_rank: int = SEVERITY_ORDER["low"],
    gated_scopes: set | None = None,
    pre_existing_deps: set | None = None,
) -> tuple[list, list, list, list]:
    """Return (blocking, allowed, scope_excluded, pre_existing).

    blocking       – vulns that block the PR
    allowed        – would have blocked but are in allow-ghsas
    scope_excluded – would have blocked but the dep's scope is not gated
    pre_existing   – would have blocked but (name, version, manifest) was already
                     on the base branch before this PR (Pattern A FP filter)
    """
    gated_scopes = gated_scopes if gated_scopes is not None else {"runtime"}
    pre_existing_deps = pre_existing_deps or set()
    blocking, allowed, scope_excluded, pre_existing = [], [], [], []
    for dep in diff:
        if dep.get("change_type") != "added":
            continue
        scope = (dep.get("scope") or "runtime").lower()
        is_gated = scope in gated_scopes
        dep_key = (dep.get("name", ""), dep.get("version", ""), dep.get("manifest", ""))
        is_pre_existing = dep_key in pre_existing_deps
        for vuln in dep.get("vulnerabilities") or []:
            ids = _ghsa_ids(vuln)
            ghsa = sorted(ids)[0] if ids else "unknown"
            fix = vuln.get("first_patched_version")
            if fix is None and ghsa != "unknown":
                fix = _lookup_patch(ghsa, dep.get("ecosystem", ""), dep.get("name", ""), token)
            fixable = fix is not None
            if not _blocks(vuln.get("severity", ""), fixable, fail_sev_rank, fail_fixable_rank):
                continue
            entry = {
                "package": f"{dep.get('name', 'unknown')}@{dep.get('version', 'unknown')}",
                "manifest": dep.get("manifest", ""),
                "ecosystem": dep.get("ecosystem", ""),
                "severity": vuln.get("severity", ""),
                "ghsa": ghsa,
                "cve": vuln.get("advisory_cve_id", ""),
                "url": vuln.get("advisory_url", ""),
                "fix": fix,
                "rule": "fixable" if fixable else "no-fix/high-severity",
                "scope": scope,
            }
            if not is_gated:
                scope_excluded.append(entry)
            elif {i.upper() for i in ids} & allowed_ghsas:
                allowed.append(entry)
            elif is_pre_existing:
                pre_existing.append(entry)
            else:
                blocking.append(entry)
    return blocking, allowed, scope_excluded, pre_existing


def _advisory_cell(b: dict) -> str:
    label = b["cve"] if b.get("cve") else b["ghsa"]
    return f"[{label}]({b['url']})"


def _table(entries: list) -> str:
    rows = "\n".join(
        f"| {b['package']} | `{b['manifest']}` | {b['ecosystem']} | {b['severity']} | {b['rule']}"
        f" | {('`' + b['fix'] + '`') if b['fix'] else 'none'} | {_advisory_cell(b)} |"
        for b in entries
    )
    return "| Package | File | Ecosystem | Severity | Rule | Fix | Advisory |\n|---------|------|-----------|----------|------|-----|----------|\n" + rows


def _api_write(url: str, token: str, method: str, body: dict) -> None:
    # Write calls (PATCH/POST) are not retried: all callers tolerate failure with
    # a warning, so a transient error here surfaces immediately but is non-fatal.
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2026-03-10",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()


def _write_summary(summary_path, text: str) -> None:
    """Append to the GitHub Step Summary if available (always-on run trail)."""
    if summary_path:
        with open(summary_path, "a") as f:
            f.write(text.rstrip("\n") + "\n")


def _upsert_comment(repository: str, pr_number: int, token: str, body: str) -> None:
    """Create or update the gate's single marker comment. Tolerates comment-API
    failures (e.g. fork PR without pull-requests:write) with a warning."""
    full = _COMMENT_MARKER + "\n" + body
    comments_url = f"{_GITHUB_API}/repos/{repository}/issues/{pr_number}/comments"
    try:
        existing_id = next(
            (c["id"] for c in _api_get(comments_url, token) if _COMMENT_MARKER in c.get("body", "")),
            None,
        )
        if existing_id:
            _api_write(
                f"{_GITHUB_API}/repos/{repository}/issues/comments/{existing_id}",
                token, "PATCH", {"body": full},
            )
        else:
            _api_write(comments_url, token, "POST", {"body": full})
    except (ApiError, urllib.error.HTTPError, urllib.error.URLError) as e:
        code = getattr(e, "code", None)
        print(f"::warning::Cannot post PR comment ({code or e}) — token may lack pull-requests:write (fork PR?)")


def post_pr_comment(
    repository: str, pr_number: int, blocking: list, allowed: list, scope_excluded: list, token: str,
    note: str | None = None,
    pre_existing: list | None = None,
) -> None:
    sections = []

    if note:
        sections += [f"> **ℹ️ Note:** {note}", ""]

    if blocking:
        sections += [
            f"## 🚨 Vulnerability Gate: {len(blocking)} blocking issue(s) found 🚨",
            "",
            _table(blocking),
            "",
            "### What to do",
            "- **Fixable**: upgrade the dependency to the fix version shown above.",
            "- **No fix available**: contact `@camunda/monorepo-devops-team` for guidance.",
        ]
    else:
        sections += ["## Vulnerability Gate: no blocking issues found"]

    if allowed:
        sections += [
            "",
            f"### ⚠️ {len(allowed)} exception(s) active — covered by allow-ghsas (not blocking) ⚠️",
            "",
            "> These vulnerabilities would have blocked this PR but are listed in `allow-ghsas`. "
            "Consider upgrading if a fix is available.",
            "",
            _table(allowed),
        ]

    if scope_excluded:
        sections += [
            "",
            f"### ⚠️ {len(scope_excluded)} vulnerability(ies) in non-gated (e.g. test-scoped) deps (not blocking) ⚠️",
            "",
            "> These are in dependencies whose scope is not gated (by default, development/test-only) "
            "and are excluded from blocking. Consider upgrading if a fix is available.",
            "",
            _table(scope_excluded),
        ]

    if pre_existing:
        sections += [
            "",
            f"### ℹ️ {len(pre_existing)} finding(s) pre-existing on the base branch — not blocking",
            "",
            "> These vulnerabilities exist in dependencies that were **already on the base branch "
            "before this PR was opened** — this PR did not introduce them.",
            ">",
            "> The gate compares from the nearest snapshotted ancestor of your base commit. When a "
            "dep version is bumped on the base branch (e.g. by Renovate) after that snapshot was "
            "taken, it can appear as `added` even though the PR is unrelated.",
            ">",
            "> To resolve: upgrade the affected dependency in a dedicated PR, or wait for Renovate.",
            "",
            _table(pre_existing),
        ]

    _upsert_comment(repository, pr_number, token, "\n".join(sections))


def _pr_number():
    """PR number from the event payload, or None if unavailable."""
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if not event_path:
        return None
    try:
        with open(event_path) as f:
            return json.load(f).get("pull_request", {}).get("number")
    except (OSError, json.JSONDecodeError):
        return None


def fail_closed(repository, pr_number, token, override_label, reason, summary_path):
    """Block the PR (exit 1) unless the override label is present (exit 0).

    Loud on both paths: the run log, step summary, and PR comment all explain that
    the gate could not verify the PR and why. The override label only bypasses an
    unverifiable PR — never a real vulnerability finding.
    """
    if has_override_label(repository, pr_number, token, override_label):
        msg = (
            f"Vulnerability gate could not verify dependencies ({reason}), but the "
            f"`{override_label}` label is present — BYPASSING. {_DEVOPS_TEAM}"
        )
        print(f"::warning::{msg}")
        _write_summary(
            summary_path,
            f"### ⚠️ Vulnerability gate bypassed via `{override_label}`\n\n"
            f"The gate could not verify dependencies (**{reason}**). The override label "
            f"is present, so the PR is allowed through. {_DEVOPS_TEAM} — confirm this was intentional.",
        )
        if pr_number:
            _upsert_comment(
                repository, pr_number, token,
                f"## ⚠️ Vulnerability Gate bypassed via `{override_label}`\n\n"
                f"The gate could **not verify** this PR's dependencies (**{reason}**), but the "
                f"`{override_label}` label is present, so it is being bypassed.\n\n"
                f"{_DEVOPS_TEAM} — please confirm this bypass was intentional and remove the label "
                f"once the underlying issue is resolved.",
            )
        sys.exit(0)

    msg = (
        f"Vulnerability gate FAILED CLOSED: {reason}. Add the `{override_label}` label and "
        f"re-run to bypass if this is a known GitHub outage. {_DEVOPS_TEAM}"
    )
    print(f"::error::{msg}")
    _write_summary(
        summary_path,
        f"### 🚨 Vulnerability gate failed closed\n\n"
        f"**Reason:** {reason}\n\n"
        f"The gate blocks when it cannot confirm the PR introduces no new vulnerable "
        f"dependencies. If this is a known GitHub outage, add the `{override_label}` label "
        f"and re-run the job to bypass. {_DEVOPS_TEAM}",
    )
    if pr_number:
        _upsert_comment(
            repository, pr_number, token,
            f"## 🚨 Vulnerability Gate could not verify this PR\n\n"
            f"**Reason:** {reason}\n\n"
            f"The gate blocks when it cannot confirm this PR introduces no new vulnerable "
            f"dependencies (fail-closed). If this is a known GitHub outage, add the "
            f"`{override_label}` label and **re-run the job** to bypass. {_DEVOPS_TEAM}",
        )
    sys.exit(1)


def main() -> None:
    config_file = os.environ.get("CONFIG_FILE", ".github/dependency-review-config.json")
    token = os.environ["GH_TOKEN"]
    repository = os.environ["GITHUB_REPOSITORY"]
    base_sha = os.environ["BASE_SHA"]
    head_sha = os.environ["HEAD_SHA"]
    base_ref = os.environ["BASE_REF"]
    snapshot_workflow = os.environ["SNAPSHOT_WORKFLOW"]
    lookback = int(os.environ.get("MAX_SNAPSHOT_LOOKBACK", "30"))
    override_label = os.environ.get("OVERRIDE_LABEL", "ci:vuln-gate-override")
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    pr_number = _pr_number()

    fail_sev_rank = severity_rank(os.environ.get("FAIL_ON_SEVERITY", "high").strip().lower())
    fail_fixable_rank = severity_rank(os.environ.get("FAIL_ON_FIXABLE_SEVERITY", "low").strip().lower())
    gated_scopes = parse_scopes(os.environ.get("FAIL_ON_SCOPES", "runtime"))

    try:
        with open(config_file) as f:
            allowed_ghsas = set(g.upper() for g in ((json.load(f) or {}).get("allow-ghsas") or []))
    except FileNotFoundError:
        print(f"::notice::Config file {config_file} not found — proceeding with empty allow-ghsas list")
        allowed_ghsas = set()

    fallback_ref = os.environ.get("FALLBACK_BASE_REF", "main")
    stacked_pr_fallback = False

    # ── Resolve the effective base to a snapshotted ancestor (Workstream D) ──
    print(f"::notice::Resolving base {base_sha} on '{base_ref}' to the nearest snapshotted ancestor")
    try:
        effective_base, run_id, scanned, latest_on_branch = latest_snapshotted_ancestor(
            repository, base_ref, base_sha, snapshot_workflow, token, lookback
        )
    except ApiError as e:
        fail_closed(
            repository, pr_number, token, override_label,
            f"could not resolve base snapshot ({e.reason})", summary_path,
        )
        return  # unreachable: fail_closed exits

    # ── Stacked PR fallback: base_ref has no snapshots — try the default branch ──
    scanned_base = scanned
    if effective_base is None and base_ref != fallback_ref:
        print(
            f"::notice::No snapshot found on '{base_ref}' — falling back to '{fallback_ref}' snapshots"
        )
        try:
            effective_base, run_id, scanned, latest_on_branch = latest_snapshotted_ancestor(
                repository, fallback_ref, base_sha, snapshot_workflow, token, lookback
            )
        except ApiError as e:
            fail_closed(
                repository, pr_number, token, override_label,
                f"could not resolve base snapshot on fallback '{fallback_ref}' ({e.reason})",
                summary_path,
            )
            return
        if effective_base is not None:
            stacked_pr_fallback = True
            print(
                f"::notice::Fallback resolved: {effective_base} on '{fallback_ref}' "
                f"(scanned {scanned} run(s))"
            )

    if effective_base is None:
        refs_tried = f"'{base_ref}' (scanned {scanned_base} run(s))"
        if base_ref != fallback_ref:
            refs_tried += f" or fallback '{fallback_ref}' (scanned {scanned} run(s))"
        fail_closed(
            repository, pr_number, token, override_label,
            f"no snapshotted ancestor of {base_sha} found on {refs_tried}",
            summary_path,
        )
        return

    if effective_base == base_sha:
        print(f"::notice::Base {base_sha} is itself snapshotted (scanned {scanned} run(s))")
    else:
        print(
            f"::notice::Resolved effective base {effective_base} "
            f"(scanned {scanned} run(s); snapshot run {run_id})"
        )

    # ── Dependency diff against the resolved base ──
    try:
        diff = _api_get(
            f"{_GITHUB_API}/repos/{repository}/dependency-graph/compare/{effective_base}...{head_sha}",
            token,
        )
    except ApiError as e:
        fail_closed(
            repository, pr_number, token, override_label,
            f"dependency review API failed ({e.reason})", summary_path,
        )
        return

    # ── Pre-existing dep filter: suppress Pattern A FPs (Workstream F) ──
    # Find deps the base branch itself added after our snapshot — those are
    # pre-existing on the branch, not PR-introduced. We diff effective_base against
    # BOTH the latest snapshot commit (latest_on_branch — the only reference that
    # surfaces Maven drift, since Maven deps exist only at snapshotted commits) AND
    # base_sha (the true branch tip — recovers natively-detected ecosystems like Go
    # and npm, which never trigger the Maven snapshot so latest_on_branch can be
    # stuck at effective_base). Unioning both is required; neither alone covers all
    # ecosystems.
    pre_existing_deps = _base_branch_pre_existing(
        repository, effective_base, latest_on_branch, base_sha, token
    )
    if pre_existing_deps:
        print(f"::notice::Pre-existing dep filter: {len(pre_existing_deps)} (name, version, manifest) triple(s) found on base branch since effective_base — will not block")

    blocking, allowed, scope_excluded, pre_existing = find_blocking(
        diff, allowed_ghsas, token, fail_sev_rank, fail_fixable_rank, gated_scopes,
        pre_existing_deps=pre_existing_deps,
    )

    for a in allowed:
        print(f"::notice::Allowed exception: {a['ghsa']} in {a['package']} (severity: {a['severity']}, rule: {a['rule']}) — covered by allow-ghsas")
    for p in pre_existing:
        print(f"::notice::Pre-existing on base branch: {p['ghsa']} in {p['package']} ({p['manifest']}) — not blocking")
    for d in scope_excluded:
        print(f"::notice::Non-gated dep: {d['ghsa']} in {d['package']} (severity: {d['severity']}, rule: {d['rule']}) — excluded (scope: {d['scope']})")

    stacked_note = (
        f"Stacked PR — `{base_ref}` has no dependency snapshots; compared from "
        f"`{fallback_ref}` snapshot `{effective_base}` (diff includes stacked branch changes)."
    ) if stacked_pr_fallback else None

    # ── Always-on run summary trail ──
    base_line = f"`{effective_base}`"
    if stacked_pr_fallback:
        base_line += f" (stacked PR fallback to `{fallback_ref}`, scanned {scanned} run(s))"
    elif effective_base != base_sha:
        base_line += f" (resolved from `{base_sha}`, scanned {scanned} run(s))"
    summary = [
        "## Dependency Vulnerability Gate",
        "",
        f"- **PR base ref:** `{base_ref}`",
        f"- **Effective base:** {base_line}",
        f"- **Head:** `{head_sha}`",
        "",
    ]
    if stacked_note:
        summary += [f"> **ℹ️ Note:** {stacked_note}", ""]
    if blocking:
        summary += [f"**Verdict:** 🚨 {len(blocking)} blocking issue(s)", "", _table(blocking)]
    else:
        summary += ["**Verdict:** ✅ no blocking vulnerabilities"]
    if allowed:
        summary += ["", "### Allowed exceptions (allow-ghsas)", _table(allowed)]
    if scope_excluded:
        summary += ["", "### Non-gated scope (not blocking)", _table(scope_excluded)]
    if pre_existing:
        summary += ["", "### Pre-existing on base branch — not blocking (Pattern A filter)", _table(pre_existing)]
    _write_summary(summary_path, "\n".join(summary))

    if pr_number and (blocking or allowed or scope_excluded or pre_existing or stacked_note):
        post_pr_comment(
            repository, pr_number, blocking, allowed, scope_excluded, token,
            note=stacked_note, pre_existing=pre_existing,
        )
    elif not pr_number and (blocking or allowed or scope_excluded or pre_existing or stacked_note):
        print("::warning::Could not determine PR number from event payload — skipping PR comment")

    if blocking:
        for b in blocking:
            print(f"::error::Blocking: {b['ghsa']} in {b['package']} (severity: {b['severity']}, rule: {b['rule']})")
        sys.exit(1)


if __name__ == "__main__":
    main()
