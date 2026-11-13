"""The runner reports what a rule yields and turns a rule bug into an error, never a pass."""

import pytest

from workflow_policy.model import Rule
from workflow_policy.runner import evaluate


WORKFLOWS = {"ci.yml": {"jobs": {"build": {"steps": [{"run": "make"}]}}}}


def run(*checks):
    rules = {f"rule-{index}": Rule(check=check, params={}) for index, check in enumerate(checks)}
    manifest = {"jobs": [{"workflow": "ci.yml", "job": "build", "rules": list(rules)}]}
    return evaluate(manifest, WORKFLOWS, rules)


def test_every_distinct_message_is_one_finding():
    findings = run(lambda job, params: ["one", "two", "one"])
    assert [finding["message"] for finding in findings] == ["job build: one", "job build: two"]


def test_a_rule_cannot_change_what_the_next_rule_sees():
    def mutate(job, params):
        job["steps"].clear()
        return []

    def count_steps(job, params):
        return [f"{len(job['steps'])} steps"]

    assert [finding["message"] for finding in run(mutate, count_steps)] == ["job build: 1 steps"]


@pytest.mark.parametrize("check, message", [
    pytest.param(lambda job, params: [job["missing"]], "failed: KeyError('missing')", id="raises"),
    pytest.param(lambda job, params: [None], "yielded a finding that is not a message", id="None"),
    pytest.param(lambda job, params: [""], "yielded a finding that is not a message", id="empty"),
])
def test_a_broken_rule_is_an_error(check, message):
    with pytest.raises(ValueError, match="rule rule-0 on ci.yml:build ") as error:
        run(check)
    assert str(error.value).endswith(message)
