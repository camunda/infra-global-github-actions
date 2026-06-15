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
         severity="high", fix=None, ghsas=("GHSA-aaaa-bbbb-cccc",), cve="CVE-2024-0001"):
    return {
        "change_type": change_type,
        "scope": scope,
        "name": name,
        "version": version,
        "ecosystem": "maven",
        "manifest": "pom.xml",
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
    blocking, _, _ = _run([_dep(severity="low", fix="2.0.0")])
    assert len(blocking) == 1
    assert blocking[0]["rule"] == "fixable"


def test_no_fix_high_blocks():
    blocking, _, _ = _run([_dep(severity="high", fix=None)])
    assert len(blocking) == 1
    assert blocking[0]["rule"] == "no-fix/high-severity"


def test_no_fix_moderate_does_not_block():
    blocking, allowed, excluded = _run([_dep(severity="moderate", fix=None)])
    assert (blocking, allowed, excluded) == ([], [], [])


def test_development_scope_excluded_by_default():
    blocking, _, excluded = _run([_dep(scope="development", severity="critical", fix="2.0.0")])
    assert blocking == []
    assert len(excluded) == 1


def test_allow_ghsas_moves_to_allowed():
    blocking, allowed, _ = _run([_dep(fix="2.0.0")], allowed={"GHSA-AAAA-BBBB-CCCC"})
    assert blocking == []
    assert len(allowed) == 1


def test_unchanged_and_removed_ignored():
    diff = [_dep(change_type="removed", fix="2.0.0"), _dep(change_type="unchanged", fix="2.0.0")]
    assert _run(diff) == ([], [], [])


def test_downgrade_added_low_version_blocks():
    # A downgrade surfaces the vulnerable lower version as `added`.
    blocking, _, _ = _run([_dep(version="1.0.0", change_type="added", fix="1.5.0")])
    assert len(blocking) == 1


# --- threshold input behavior --------------------------------------------------

def test_raising_fixable_threshold_spares_low():
    blocking, _, _ = _run([_dep(severity="low", fix="2.0.0")], fail_fix=HIGH)
    assert blocking == []


def test_lowering_severity_threshold_blocks_moderate_no_fix():
    blocking, _, _ = _run([_dep(severity="moderate", fix=None)], fail_sev=LOW)
    assert len(blocking) == 1


def test_gating_development_scope_blocks_it():
    blocking, _, excluded = _run(
        [_dep(scope="development", fix="2.0.0")],
        scopes={"runtime", "development"},
    )
    assert len(blocking) == 1
    assert excluded == []


# --- unknown-severity legacy contract -----------------------------------------

def test_unknown_severity_fixable_blocks():
    blocking, _, _ = _run([_dep(severity="", fix="2.0.0")])
    assert len(blocking) == 1


def test_unknown_severity_no_fix_does_not_block():
    blocking, allowed, excluded = _run([_dep(severity="", fix=None)])
    assert (blocking, allowed, excluded) == ([], [], [])


# --- GraphQL fallback for missing first_patched_version -----------------------

def test_graphql_fallback_marks_fixable(monkeypatch):
    monkeypatch.setattr(check, "_lookup_patch", lambda *a, **k: "9.9.9")
    blocking, _, _ = _run([_dep(severity="low", fix=None)])
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


def test_ancestor_picks_newest(monkeypatch):
    runs = {"workflow_runs": [
        {"head_sha": "newer", "id": 3},
        {"head_sha": "anc", "id": 2},
        {"head_sha": "older", "id": 1},
    ]}
    monkeypatch.setattr(check, "_http_get_json", lambda url, tok: (runs, {}))
    statuses = {"newer": "diverged", "anc": "ahead", "older": "ahead"}
    monkeypatch.setattr(check, "_compare_status", lambda repo, head, base, tok: statuses[head])
    eff, run_id, scanned = check.latest_snapshotted_ancestor("o/r", "main", "BASE", "wf.yml", "tok", 30)
    assert (eff, run_id, scanned) == ("anc", 2, 2)  # skipped newer (diverged), matched anc


def test_ancestor_identical_at_top(monkeypatch):
    runs = {"workflow_runs": [{"head_sha": "BASE", "id": 9}]}
    monkeypatch.setattr(check, "_http_get_json", lambda url, tok: (runs, {}))
    monkeypatch.setattr(check, "_compare_status", lambda *a: "identical")
    eff, _, scanned = check.latest_snapshotted_ancestor("o/r", "main", "BASE", "wf.yml", "tok", 30)
    assert eff == "BASE" and scanned == 1


def test_ancestor_none_found(monkeypatch):
    runs = {"workflow_runs": [{"head_sha": "x", "id": 1}, {"head_sha": "y", "id": 2}]}
    monkeypatch.setattr(check, "_http_get_json", lambda url, tok: (runs, {}))
    monkeypatch.setattr(check, "_compare_status", lambda *a: "behind")
    eff, run_id, scanned = check.latest_snapshotted_ancestor("o/r", "main", "BASE", "wf.yml", "tok", 30)
    assert eff is None and run_id is None and scanned == 2


def test_ancestor_query_uses_base_ref_and_workflow(monkeypatch):
    captured = {}

    def fake_get(url, tok):
        captured["url"] = url
        return {"workflow_runs": []}, {}

    monkeypatch.setattr(check, "_http_get_json", fake_get)
    check.latest_snapshotted_ancestor("o/r", "stable/8.8", "BASE", "maven-dependency-snapshot.yml", "tok", 30)
    assert "branch=stable/8.8" in captured["url"]
    assert "maven-dependency-snapshot.yml" in captured["url"]
    assert "event=push" in captured["url"] and "status=success" in captured["url"]


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
    monkeypatch.setattr(check, "latest_snapshotted_ancestor", lambda *a, **k: ("eff", 1, 1))
    monkeypatch.setattr(check, "_api_get", lambda url, tok: [_dep(severity="high", fix="2.0.0")])
    monkeypatch.setattr(check, "has_override_label", lambda *a, **k: True)
    with pytest.raises(SystemExit) as ei:
        check.main()
    assert ei.value.code == 1


def test_main_fail_closed_when_no_ancestor(monkeypatch):
    _set_main_env(monkeypatch)
    monkeypatch.setattr(check, "latest_snapshotted_ancestor", lambda *a, **k: (None, None, 5))
    monkeypatch.setattr(check, "has_override_label", lambda *a, **k: False)
    with pytest.raises(SystemExit) as ei:
        check.main()
    assert ei.value.code == 1
