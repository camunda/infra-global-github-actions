"""Unit tests for the dependency vulnerability gate.

The GitHub Dependency Review API diff and the Advisory GraphQL lookup are not
hit: tests feed `find_blocking` synthetic diff entries and stub `_lookup_patch`.
"""
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
