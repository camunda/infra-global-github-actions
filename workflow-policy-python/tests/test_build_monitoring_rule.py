"""The build-monitoring rule, on the cases of the Conftest preset's policy_test.rego."""

import pytest

from workflow_policy.config import PRESETS, preset_rule


check = preset_rule("build-monitoring", PRESETS / "build-monitoring" / "rule.py")
PARAMS = {
    "first-step": "acme/start",
    "last-step-any-of": ["acme/submit", "./**/.github/actions/observe"],
}
START = {"uses": "acme/start@0123456789012345678901234567890123456789"}
SUBMIT = {"uses": "acme/submit@v1", "if": "always()", "continue-on-error": True}
FIRST = "first step must use acme/start"
LAST = "last step must use one of acme/submit, ./**/.github/actions/observe"
BEST_EFFORT = "last step must set if: always() and continue-on-error: true"


def messages(steps):
    return set(check({"steps": steps}, PARAMS))


def observer(path, **step):
    return {"uses": path, "if": "always()", "continue-on-error": True, **step}


@pytest.mark.parametrize("steps, expected", [
    pytest.param([START, {"run": "make"}, SUBMIT], set(), id="direct submission passes"),
    pytest.param(
        [START, {"uses": "actions/checkout@v5"},
         observer("./.github/actions/observe", **{"if": "${{ always() }}"})],
        set(), id="local wrapper with expression passes",
    ),
    pytest.param(
        [START, {"uses": "actions/checkout@v5"}, observer("./tool/.github/actions/observe")],
        set(), id="local wrapper under a checkout path passes",
    ),
    pytest.param(
        [START, observer("./.github/actions/observe-extra")], {LAST},
        id="wrapper with a longer name fails",
    ),
    pytest.param(
        [{"uses": "actions/checkout@v5"}, START, SUBMIT], {FIRST},
        id="monitor after another step fails",
    ),
    pytest.param([{"run": "make"}, START, SUBMIT], {FIRST}, id="run step first fails"),
    pytest.param([START, {"run": "make"}], {LAST}, id="missing observer fails"),
    pytest.param(
        [START, {"uses": "acme/submit@v1", "continue-on-error": True}], {BEST_EFFORT},
        id="submission without always fails",
    ),
    pytest.param(
        [START, {"uses": "acme/submit@v1", "if": "always()"}], {BEST_EFFORT},
        id="submission that can fail the job fails",
    ),
    pytest.param([], {FIRST, LAST}, id="job without steps fails both checks"),
])
def test_build_monitoring(steps, expected):
    assert messages(steps) == expected


def test_yaml_1_2_strings_are_not_booleans():
    # GitHub reads `continue-on-error: yes` as the string "yes", as ruamel.yaml does.
    assert messages([START, observer("acme/submit", **{"continue-on-error": "yes"})]) == {
        BEST_EFFORT,
    }
