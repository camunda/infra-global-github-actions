"""Unit tests for the dependency vulnerability gate.

The GitHub Dependency Review API diff and the Advisory GraphQL lookup are not
hit: tests feed `find_blocking` synthetic diff entries and stub `_lookup_patch`.
Base-resolution, retry, and fail-closed tests stub the HTTP layer (`_http_get_json`
/ `urllib.request.urlopen`) and `time.sleep`, so nothing touches the network.
"""
import urllib.error

import pytest

import check
from check import (
    SEVERITY_ORDER,
    find_blocking,
    parse_scopes,
    severity_rank,
    _blocks,
)

HIGH = SEVERITY_ORDER["high"]
LOW = SEVERITY_ORDER["low"]


@pytest.fixture(autouse=True)
def _no_network(monkeypatch):
    """Default: any unfixable vuln stays unfixable (no GraphQL fallback)."""
    monkeypatch.setattr(check, "_lookup_patch", lambda *a, **k: None)


def _dep(name="acme", version="1.0.0", scope="runtime", change_type="added",
         severity="high", fix=None, ghsas=("GHSA-aaaa-bbbb-cccc",), cve="CVE-2024-0001",
         manifest="pom.xml"):
    return {
        "change_type": change_type,
        "scope": scope,
        "name": name,
        "version": version,
        "ecosystem": "maven",
        "manifest": manifest,
        "vulnerabilities": [{
            "severity": severity,
            "first_patched_version": fix,
            "advisory_ghsa_ids": list(ghsas),
            "advisory_url": "https://github.com/advisories/" + (ghsas[0] if ghsas else ""),
            "advisory_cve_id": cve,
        }],
    }


def _run(diff, allowed=None, fail_sev=HIGH, fail_fix=LOW, scopes=None):
    return find_blocking(
        diff, allowed or set(), token="",
        fail_sev_rank=fail_sev, fail_fixable_rank=fail_fix,
        gated_scopes=scopes if scopes is not None else {"runtime"},
    )


# --- default-policy rule matrix ------------------------------------------------

def test_fixable_any_severity_blocks():
    blocking, _, _, _ = _run([_dep(severity="low", fix="2.0.0")])
    assert len(blocking) == 1
    assert blocking[0]["rule"] == "fixable"


def test_no_fix_high_blocks():
    blocking, _, _, _ = _run([_dep(severity="high", fix=None)])
    assert len(blocking) == 1
    assert blocking[0]["rule"] == "no-fix/high-severity"


def test_no_fix_moderate_does_not_block():
    blocking, allowed, excluded, _ = _run([_dep(severity="moderate", fix=None)])
    assert (blocking, allowed, excluded) == ([], [], [])


def test_development_scope_excluded_by_default():
    blocking, _, excluded, _ = _run([_dep(scope="development", severity="critical", fix="2.0.0")])
    assert blocking == []
    assert len(excluded) == 1


def test_allow_ghsas_moves_to_allowed():
    blocking, allowed, _, _ = _run([_dep(fix="2.0.0")], allowed={"GHSA-AAAA-BBBB-CCCC"})
    assert blocking == []
    assert len(allowed) == 1


def test_unchanged_and_removed_ignored():
    diff = [_dep(change_type="removed", fix="2.0.0"), _dep(change_type="unchanged", fix="2.0.0")]
    assert _run(diff) == ([], [], [], [])


def test_downgrade_added_low_version_blocks():
    # A downgrade surfaces the vulnerable lower version as `added`.
    blocking, _, _, _ = _run([_dep(version="1.0.0", change_type="added", fix="1.5.0")])
    assert len(blocking) == 1


# --- threshold input behavior --------------------------------------------------

def test_raising_fixable_threshold_spares_low():
    blocking, _, _, _ = _run([_dep(severity="low", fix="2.0.0")], fail_fix=HIGH)
    assert blocking == []


def test_lowering_severity_threshold_blocks_moderate_no_fix():
    blocking, _, _, _ = _run([_dep(severity="moderate", fix=None)], fail_sev=LOW)
    assert len(blocking) == 1


def test_gating_development_scope_blocks_it():
    blocking, _, excluded, _ = _run(
        [_dep(scope="development", fix="2.0.0")],
        scopes={"runtime", "development"},
    )
    assert len(blocking) == 1
    assert excluded == []


# --- unknown-severity legacy contract -----------------------------------------

def test_unknown_severity_fixable_blocks():
    blocking, _, _, _ = _run([_dep(severity="", fix="2.0.0")])
    assert len(blocking) == 1


def test_unknown_severity_no_fix_does_not_block():
    blocking, allowed, excluded, _ = _run([_dep(severity="", fix=None)])
    assert (blocking, allowed, excluded) == ([], [], [])


# --- GraphQL fallback for missing first_patched_version -----------------------

def test_graphql_fallback_marks_fixable(monkeypatch):
    monkeypatch.setattr(check, "_lookup_patch", lambda *a, **k: "9.9.9")
    blocking, _, _, _ = _run([_dep(severity="low", fix=None)])
    assert len(blocking) == 1
    assert blocking[0]["fix"] == "9.9.9"
    assert blocking[0]["rule"] == "fixable"


# --- helpers -------------------------------------------------------------------

@pytest.mark.parametrize("severity,fixable,expected", [
    ("low", True, True),
    ("low", False, False),
    ("high", False, True),
    ("critical", False, True),
    ("moderate", False, False),
    ("", True, True),
    ("", False, False),
])
def test_blocks_default_thresholds(severity, fixable, expected):
    assert _blocks(severity, fixable, HIGH, LOW) is expected


def test_parse_scopes():
    assert parse_scopes("runtime, development") == {"runtime", "development"}
    assert parse_scopes("Runtime") == {"runtime"}
    assert parse_scopes("") == set()


def test_severity_rank_invalid_exits():
    with pytest.raises(SystemExit):
        severity_rank("bogus")


# --- base-snapshot resolution (Workstream D) ----------------------------------

class _FakeResp:
    """Minimal context-manager stand-in for urllib's response."""

    def __init__(self, body: bytes, headers=None):
        self._body = body
        self.headers = headers or {}

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _http_error(code, headers=None):
    return urllib.error.HTTPError("https://api.github.com/x", code, "err", headers or {}, None)


def test_http_get_json_retries_then_succeeds(monkeypatch):
    sleeps, attempts = [], []
    monkeypatch.setattr(check.time, "sleep", lambda s: sleeps.append(s))

    def fake_urlopen(req, timeout=30):
        attempts.append(1)
        if len(attempts) < 3:
            raise _http_error(503)
        return _FakeResp(b'{"ok": true}', {"Link": ""})

    monkeypatch.setattr(check.urllib.request, "urlopen", fake_urlopen)
    payload, _ = check._http_get_json("https://api.github.com/x", "tok")
    assert payload == {"ok": True}
    assert len(attempts) == 3
    assert sleeps == [2, 4]  # exponential backoff before attempts 2 and 3


def test_http_get_json_exhausts_then_raises(monkeypatch):
    monkeypatch.setattr(check.time, "sleep", lambda s: None)
    monkeypatch.setattr(check.urllib.request, "urlopen", lambda req, timeout=30: (_ for _ in ()).throw(_http_error(500)))
    with pytest.raises(check.ApiError) as ei:
        check._http_get_json("https://api.github.com/x", "tok")
    assert ei.value.retryable is True
    assert "server error" in ei.value.reason


def test_classify_429_retryable():
    err = check._classify_http_error(_http_error(429))
    assert err.retryable is True and "rate limit" in err.reason


def test_classify_403_perms_not_retryable():
    err = check._classify_http_error(_http_error(403))
    assert err.retryable is False and "permission" in err.reason


def test_classify_403_secondary_ratelimit_retryable():
    err = check._classify_http_error(_http_error(403, {"Retry-After": "5"}))
    assert err.retryable is True and "secondary rate limit" in err.reason


def test_classify_403_primary_ratelimit_retryable():
    err = check._classify_http_error(_http_error(403, {"X-RateLimit-Remaining": "0"}))
    assert err.retryable is True and "primary rate limit" in err.reason


def test_ancestor_picks_newest(monkeypatch):
    runs = {"workflow_runs": [
        {"head_sha": "newer", "id": 3},
        {"head_sha": "anc", "id": 2},
        {"head_sha": "older", "id": 1},
    ]}
    monkeypatch.setattr(check, "_http_get_json", lambda url, tok: (runs, {}))
    statuses = {"newer": "diverged", "anc": "ahead", "older": "ahead"}
    monkeypatch.setattr(check, "_compare_status", lambda repo, head, base, tok: statuses[head])
    eff, run_id, scanned, _ = check.latest_snapshotted_ancestor("o/r", "main", "BASE", "wf.yml", "tok", 30)
    assert (eff, run_id, scanned) == ("anc", 2, 2)  # skipped newer (diverged), matched anc


def test_ancestor_identical_at_top(monkeypatch):
    runs = {"workflow_runs": [{"head_sha": "BASE", "id": 9}]}
    monkeypatch.setattr(check, "_http_get_json", lambda url, tok: (runs, {}))
    monkeypatch.setattr(check, "_compare_status", lambda *a: "identical")
    eff, _, scanned, _ = check.latest_snapshotted_ancestor("o/r", "main", "BASE", "wf.yml", "tok", 30)
    assert eff == "BASE" and scanned == 1


def test_ancestor_none_found(monkeypatch):
    runs = {"workflow_runs": [{"head_sha": "x", "id": 1}, {"head_sha": "y", "id": 2}]}
    monkeypatch.setattr(check, "_http_get_json", lambda url, tok: (runs, {}))
    monkeypatch.setattr(check, "_compare_status", lambda *a: "behind")
    eff, run_id, scanned, _ = check.latest_snapshotted_ancestor("o/r", "main", "BASE", "wf.yml", "tok", 30)
    assert eff is None and run_id is None and scanned == 2


def test_ancestor_query_uses_base_ref_and_workflow(monkeypatch):
    captured = {}

    def fake_get(url, tok):
        captured["url"] = url
        return {"workflow_runs": []}, {}

    monkeypatch.setattr(check, "_http_get_json", fake_get)
    check.latest_snapshotted_ancestor("o/r", "stable/8.8", "BASE", "maven-dependency-snapshot.yml", "tok", 30)
    # branch name with slash must be percent-encoded so it is not misread as a path segment
    assert "branch=stable%2F8.8" in captured["url"]
    assert "maven-dependency-snapshot.yml" in captured["url"]
    assert "event=push" in captured["url"] and "status=success" in captured["url"]


def test_ancestor_query_plain_branch_not_double_encoded(monkeypatch):
    captured = {}
    monkeypatch.setattr(check, "_http_get_json", lambda url, tok: (captured.update(url=url) or ({}, {})) and ({"workflow_runs": []}, {}))

    def fake_get(url, tok):
        captured["url"] = url
        return {"workflow_runs": []}, {}

    monkeypatch.setattr(check, "_http_get_json", fake_get)
    check.latest_snapshotted_ancestor("o/r", "main", "BASE", "wf.yml", "tok", 30)
    assert "branch=main" in captured["url"]  # no encoding needed, no %


def test_has_override_label_no_pr_number(monkeypatch):
    # pr_number=None → return False without touching the API
    api_called = []
    monkeypatch.setattr(check, "_api_get", lambda url, tok: api_called.append(url) or [])
    assert check.has_override_label("o/r", None, "tok", "ci:vuln-gate-override") is False
    assert api_called == []


def test_ancestor_paginates_to_honor_lookback(monkeypatch):
    # lookback > 100 → per_page capped at 100, follow the next page to keep scanning.
    page1 = {"workflow_runs": [{"head_sha": f"p1-{i}", "id": i} for i in range(100)]}
    page2 = {"workflow_runs": [{"head_sha": "anc", "id": 999}]}
    calls = []

    def fake_get(url, tok):
        calls.append(url)
        if len(calls) == 1:
            assert "per_page=100" in url  # capped, not per_page=150
            return page1, {"Link": '<https://api.github.com/next>; rel="next"'}
        return page2, {"Link": ""}

    monkeypatch.setattr(check, "_http_get_json", fake_get)
    # only "anc" (on page 2) is an ancestor
    monkeypatch.setattr(
        check, "_compare_status",
        lambda repo, head, base, tok: "ahead" if head == "anc" else "diverged",
    )
    eff, run_id, scanned, _ = check.latest_snapshotted_ancestor(
        "o/r", "main", "BASE", "wf.yml", "tok", 150
    )
    assert eff == "anc" and run_id == 999
    assert scanned == 101  # 100 from page 1 + 1 match on page 2
    assert len(calls) == 2  # followed pagination


def test_has_override_label_live_read(monkeypatch):
    monkeypatch.setattr(check, "_api_get", lambda url, tok: [{"name": "other"}, {"name": "ci:vuln-gate-override"}])
    assert check.has_override_label("o/r", 5, "tok", "ci:vuln-gate-override") is True


def test_has_override_label_api_failure_stays_closed(monkeypatch):
    def boom(url, tok):
        raise check.ApiError("labels API down", retryable=False)

    monkeypatch.setattr(check, "_api_get", boom)
    assert check.has_override_label("o/r", 5, "tok", "ci:vuln-gate-override") is False


def test_fail_closed_bypassed_with_label(monkeypatch):
    monkeypatch.setattr(check, "has_override_label", lambda *a, **k: True)
    monkeypatch.setattr(check, "_upsert_comment", lambda *a, **k: None)
    with pytest.raises(SystemExit) as ei:
        check.fail_closed("o/r", 5, "tok", "ci:vuln-gate-override", "outage", None)
    assert ei.value.code == 0  # honored bypass


def test_fail_closed_blocks_without_label(monkeypatch):
    monkeypatch.setattr(check, "has_override_label", lambda *a, **k: False)
    monkeypatch.setattr(check, "_upsert_comment", lambda *a, **k: None)
    with pytest.raises(SystemExit) as ei:
        check.fail_closed("o/r", 5, "tok", "ci:vuln-gate-override", "no ancestor", None)
    assert ei.value.code == 1


def _set_main_env(monkeypatch):
    monkeypatch.setenv("GH_TOKEN", "t")
    monkeypatch.setenv("GITHUB_REPOSITORY", "o/r")
    monkeypatch.setenv("BASE_SHA", "B")
    monkeypatch.setenv("HEAD_SHA", "H")
    monkeypatch.setenv("BASE_REF", "main")
    monkeypatch.setenv("SNAPSHOT_WORKFLOW", "wf.yml")
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)
    monkeypatch.delenv("GITHUB_EVENT_PATH", raising=False)
    monkeypatch.delenv("CONFIG_FILE", raising=False)


def test_main_real_vuln_blocks_even_with_override_label(monkeypatch):
    # API works, base resolves, a real fixable vuln is added → blocks (exit 1).
    # The override label is present but must be IGNORED for a genuine finding.
    _set_main_env(monkeypatch)
    monkeypatch.setattr(check, "latest_snapshotted_ancestor", lambda *a, **k: ("eff", 1, 1, "latest"))
    monkeypatch.setattr(check, "_base_branch_pre_existing", lambda *a, **k: set())
    monkeypatch.setattr(check, "_api_get", lambda url, tok: [_dep(severity="high", fix="2.0.0")])
    monkeypatch.setattr(check, "has_override_label", lambda *a, **k: True)
    with pytest.raises(SystemExit) as ei:
        check.main()
    assert ei.value.code == 1


def test_main_fail_closed_when_no_ancestor(monkeypatch):
    _set_main_env(monkeypatch)
    monkeypatch.setattr(check, "latest_snapshotted_ancestor", lambda *a, **k: (None, None, 5, None))
    monkeypatch.setattr(check, "has_override_label", lambda *a, **k: False)
    with pytest.raises(SystemExit) as ei:
        check.main()
    assert ei.value.code == 1


def test_stacked_pr_falls_back_to_default_branch(monkeypatch):
    # base_ref targets a feature branch (no snapshots); fallback_ref (main) resolves.
    _set_main_env(monkeypatch)
    monkeypatch.setenv("BASE_REF", "refactor/some-feature")
    monkeypatch.setenv("FALLBACK_BASE_REF", "main")
    calls = []

    def fake_ancestor(repo, ref, sha, wf, tok, lookback):
        calls.append(ref)
        if ref == "refactor/some-feature":
            return None, None, 0, None  # no snapshots on feature branch
        return "eff-main", 42, 1, "latest-main"  # main has a snapshot

    monkeypatch.setattr(check, "latest_snapshotted_ancestor", fake_ancestor)
    monkeypatch.setattr(check, "_api_get", lambda url, tok: [])  # no dep changes
    monkeypatch.setattr(check, "_pr_number", lambda: 42)
    comment_calls = []
    monkeypatch.setattr(check, "post_pr_comment", lambda *a, **k: comment_calls.append(k))
    check.main()  # must not exit 1
    assert calls == ["refactor/some-feature", "main"]
    # post_pr_comment called with stacked-PR note
    assert comment_calls and "Stacked PR" in (comment_calls[0].get("note") or "")


def test_stacked_pr_fallback_also_empty_fails_closed(monkeypatch):
    # Neither base_ref nor fallback_ref has snapshots → fail closed.
    _set_main_env(monkeypatch)
    monkeypatch.setenv("BASE_REF", "refactor/some-feature")
    monkeypatch.setenv("FALLBACK_BASE_REF", "main")
    monkeypatch.setattr(check, "latest_snapshotted_ancestor", lambda *a, **k: (None, None, 0, None))
    monkeypatch.setattr(check, "has_override_label", lambda *a, **k: False)
    with pytest.raises(SystemExit) as ei:
        check.main()
    assert ei.value.code == 1


def test_no_fallback_when_base_ref_equals_fallback_ref(monkeypatch):
    # base_ref == fallback_ref → no second attempt; fail closed on first miss.
    _set_main_env(monkeypatch)
    monkeypatch.setenv("BASE_REF", "main")
    monkeypatch.setenv("FALLBACK_BASE_REF", "main")
    calls = []

    def fake_ancestor(repo, ref, sha, wf, tok, lookback):
        calls.append(ref)
        return None, None, 5, None

    monkeypatch.setattr(check, "latest_snapshotted_ancestor", fake_ancestor)
    monkeypatch.setattr(check, "has_override_label", lambda *a, **k: False)
    with pytest.raises(SystemExit) as ei:
        check.main()
    assert ei.value.code == 1
    assert calls == ["main"]  # called only once — no fallback to itself


# --- Pattern A pre-existing dep filter (Workstream F) -------------------------

def test_pre_existing_dep_not_blocking(monkeypatch):
    # Dep appears as "added" in the PR diff but is already on the base branch
    # (Renovate bumped it after the effective_base snapshot) → pre_existing, not blocking.
    monkeypatch.setattr(check, "_lookup_patch", lambda *a, **k: None)
    dep = _dep(name="jackson-databind", version="2.21.4", manifest="clients/java/pom.xml", fix="2.21.5")
    pre_existing_set = {("jackson-databind", "2.21.4", "clients/java/pom.xml")}
    blocking, allowed, scope_excluded, pre_existing = find_blocking(
        [dep], set(), token="", pre_existing_deps=pre_existing_set
    )
    assert blocking == []
    assert len(pre_existing) == 1
    assert pre_existing[0]["package"] == "jackson-databind@2.21.4"


def test_pre_existing_different_manifest_still_blocks(monkeypatch):
    # Same (name, version) but different manifest → PR genuinely added it to a new module.
    monkeypatch.setattr(check, "_lookup_patch", lambda *a, **k: None)
    dep = _dep(name="jackson-databind", version="2.21.4", manifest="new-module/pom.xml", fix="2.21.5")
    pre_existing_set = {("jackson-databind", "2.21.4", "clients/java/pom.xml")}
    blocking, _, _, pre_existing = find_blocking(
        [dep], set(), token="", pre_existing_deps=pre_existing_set
    )
    assert len(blocking) == 1  # different manifest → not filtered
    assert pre_existing == []


def test_base_branch_pre_existing_no_drift(monkeypatch):
    # effective_base == latest_on_branch → no drift, returns empty set without API call.
    api_called = []
    monkeypatch.setattr(check, "_api_get", lambda url, tok: api_called.append(url) or [])
    result = check._base_branch_pre_existing("o/r", "sha-abc", "sha-abc", "tok")
    assert result == set()
    assert api_called == []


def test_base_branch_pre_existing_no_latest(monkeypatch):
    # latest_on_branch is None (no snapshot on branch) → returns empty set.
    api_called = []
    monkeypatch.setattr(check, "_api_get", lambda url, tok: api_called.append(url) or [])
    result = check._base_branch_pre_existing("o/r", "sha-abc", None, "tok")
    assert result == set()
    assert api_called == []


def test_base_branch_pre_existing_returns_added_triples(monkeypatch):
    drift = [
        {"change_type": "added", "name": "jackson-databind", "version": "2.21.4", "manifest": "clients/java/pom.xml"},
        {"change_type": "removed", "name": "old-dep", "version": "1.0.0", "manifest": "pom.xml"},
    ]
    monkeypatch.setattr(check, "_api_get", lambda url, tok: drift)
    result = check._base_branch_pre_existing("o/r", "base-sha", "latest-sha", "tok")
    assert result == {("jackson-databind", "2.21.4", "clients/java/pom.xml")}


def test_base_branch_pre_existing_api_error_returns_empty(monkeypatch):
    # API error → fail-open, return empty set (don't suppress real findings).
    monkeypatch.setattr(check, "_api_get", lambda url, tok: (_ for _ in ()).throw(
        check.ApiError("server error", 503, retryable=True)
    ))
    result = check._base_branch_pre_existing("o/r", "base-sha", "latest-sha", "tok")
    assert result == set()


def test_base_branch_pre_existing_compares_against_base_tip(monkeypatch):
    # The drift compare URL must use base_tip as the head side, not the latest
    # snapshot commit. Regression guard for the native-ecosystem FP fix.
    captured = {}
    monkeypatch.setattr(
        check, "_api_get",
        lambda url, tok: captured.update(url=url) or [],
    )
    check._base_branch_pre_existing("o/r", "eff-base", "base-tip-sha", "tok")
    assert "eff-base...base-tip-sha" in captured["url"]


def test_main_filter_keys_on_base_sha_not_latest_snapshot(monkeypatch):
    # Regression: a natively-detected dep (Go) added on the base branch after the
    # snapshot must still be filtered even when latest_on_branch == effective_base
    # (a Go-only change never triggers the Maven snapshot). main() must key the
    # pre-existing filter on base_sha — the true branch tip — not the stale snapshot.
    _set_main_env(monkeypatch)  # BASE_SHA = "B"
    # effective_base and latest_on_branch are the SAME stale snapshot commit.
    monkeypatch.setattr(check, "latest_snapshotted_ancestor", lambda *a, **k: ("eff", 1, 1, "eff"))
    monkeypatch.setattr(check, "_lookup_patch", lambda *a, **k: None)
    captured = {}

    def fake_filter(repository, effective_base, base_tip, token):
        captured["effective_base"] = effective_base
        captured["base_tip"] = base_tip
        # main added the Go dep between eff...B → report it as pre-existing.
        return {("golang.org/x/crypto", "0.51.0", "load-tests/metrics-exporter/go.mod")}

    monkeypatch.setattr(check, "_base_branch_pre_existing", fake_filter)
    # The PR diff surfaces that same Go dep as "added" (inherited from main),
    # critical + no fix — would block if the filter used the stale snapshot commit.
    go_dep = _dep(
        name="golang.org/x/crypto", version="0.51.0",
        manifest="load-tests/metrics-exporter/go.mod", severity="critical", fix=None,
    )
    monkeypatch.setattr(check, "_api_get", lambda url, tok: [go_dep])
    monkeypatch.setattr(check, "_pr_number", lambda: None)
    check.main()  # must NOT exit 1 — the FP is filtered
    assert captured["base_tip"] == "B"          # keyed on base_sha, not "eff"
    assert captured["effective_base"] == "eff"


# --- bucket-ordering correctness (fix 3) --------------------------------------

def test_pre_existing_non_gated_scope_wins_over_pre_existing(monkeypatch):
    # A development-scoped dep that is also pre_existing → scope_excluded wins.
    # scope exclusion is a stronger/more informative signal than pre-existing.
    monkeypatch.setattr(check, "_lookup_patch", lambda *a, **k: None)
    dep = _dep(scope="development", name="foo", version="1.0", manifest="pom.xml", fix="2.0")
    pre_existing_set = {("foo", "1.0", "pom.xml")}
    blocking, allowed, scope_excluded, pre_existing = find_blocking(
        [dep], set(), token="", gated_scopes={"runtime"}, pre_existing_deps=pre_existing_set
    )
    assert blocking == []
    assert pre_existing == []
    assert len(scope_excluded) == 1


def test_pre_existing_allow_listed_ghsa_wins_over_pre_existing(monkeypatch):
    # A dep that is both pre_existing and in allowed_ghsas → allowed wins.
    # The allow-list audit trail should reflect the explicit exemption.
    monkeypatch.setattr(check, "_lookup_patch", lambda *a, **k: None)
    dep = _dep(name="bar", version="2.0", manifest="pom.xml", fix="3.0", ghsas=("GHSA-aaaa-bbbb-cccc",))
    pre_existing_set = {("bar", "2.0", "pom.xml")}
    blocking, allowed, scope_excluded, pre_existing = find_blocking(
        [dep], {"GHSA-AAAA-BBBB-CCCC"}, token="", pre_existing_deps=pre_existing_set
    )
    assert blocking == []
    assert pre_existing == []
    assert len(allowed) == 1


# --- elif stacked_note warning (fix 4) ----------------------------------------

def test_stacked_pr_fallback_prints_warning_when_no_pr_number(monkeypatch):
    # When pr_number is None but stacked_note is truthy (and all finding lists empty),
    # a warning should still be printed (stacked_note was missing from elif condition).
    _set_main_env(monkeypatch)
    monkeypatch.setenv("BASE_REF", "refactor/some-feature")
    monkeypatch.setenv("FALLBACK_BASE_REF", "main")
    monkeypatch.delenv("GITHUB_EVENT_PATH", raising=False)

    def fake_ancestor(repo, ref, sha, wf, tok, lookback):
        if ref == "refactor/some-feature":
            return None, None, 0, None
        return "eff-main", 42, 1, "latest-main"

    monkeypatch.setattr(check, "latest_snapshotted_ancestor", fake_ancestor)
    monkeypatch.setattr(check, "_api_get", lambda url, tok: [])
    monkeypatch.setattr(check, "_pr_number", lambda: None)  # no PR number
    monkeypatch.setattr(check, "_base_branch_pre_existing", lambda *a, **k: set())
    printed = []
    monkeypatch.setattr("builtins.print", lambda *a, **k: printed.append(" ".join(str(x) for x in a)))
    check.main()
    warning_lines = [l for l in printed if "Could not determine PR number" in l]
    assert warning_lines, "expected warning about missing PR number when stacked_note is active"
