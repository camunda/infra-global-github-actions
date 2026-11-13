"""The Python-rule and Conftest implementations report the same results on the same repository.

Each scenario runs ../workflow-policy (Conftest) and this action on one repository and compares
their exit status, report.json, and summary.md. Needs `conftest` on PATH.
"""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import textwrap

import pytest


PYTHON_ACTION = Path(__file__).resolve().parent.parent
CONFTEST_ACTION = PYTHON_ACTION.parent / "workflow-policy"

pytestmark = pytest.mark.skipif(
    shutil.which("conftest") is None or not (CONFTEST_ACTION / "check.py").is_file(),
    reason="the Conftest implementation needs conftest on PATH",
)

MONITOR = "      - uses: camunda/infra-global-github-actions/start-build-monitor@main\n"
SUBMIT = (
    "      - uses: camunda/infra-global-github-actions/submit-build-status@main\n"
    "        if: always()\n"
    "        continue-on-error: true\n"
)


def job(job_id, *steps, comment=""):
    """A job running on ubuntu-latest; `comment` goes on its ID line."""
    suffix = f" # {comment}" if comment else ""
    return f"  {job_id}:{suffix}\n    runs-on: ubuntu-latest\n    steps:\n" + "".join(steps)


def workflow(*jobs, header=""):
    return f"{header}name: CI\non: push\njobs:\n" + "".join(jobs)


def run(step):
    return f"      - run: {step}\n"


EXTENDS = "extends:\n  - build-monitoring\n"

SCENARIOS = {
    "passing and failing jobs": (EXTENDS, {
        "ci.yml": workflow(
            job("build", MONITOR, run("make"), SUBMIT),
            job(
                "wrapped", MONITOR,
                "      - uses: ./tool/.github/actions/observe-build-status\n"
                "        if: ${{ always() }}\n        continue-on-error: true\n",
            ),
            job("checkout-first", "      - uses: actions/checkout@v5\n", MONITOR, SUBMIT),
            job("no-submission", MONITOR, run("make")),
            job(
                "no-always", MONITOR,
                "      - uses: camunda/infra-global-github-actions/submit-build-status@v1\n"
                "        continue-on-error: true\n",
            ),
            job(
                "can-fail-the-job", MONITOR,
                "      - uses: camunda/infra-global-github-actions/submit-build-status@v1\n"
                "        if: always()\n",
            ),
            job(
                "longer-wrapper-name", MONITOR,
                "      - uses: ./.github/actions/observe-build-status-extra\n"
                "        if: always()\n        continue-on-error: true\n",
            ),
            "  no-steps:\n    runs-on: ubuntu-latest\n    steps: []\n",
        ),
    }),
    "every kind of exception": (
        EXTENDS + textwrap.dedent("""\
            exceptions:
              - workflow: .github/workflows/policy.yml
                jobs: [check]
                reason: Policy validation only
              - workflow: "*"
                jobs: [lint]
                rule: build-monitoring
                reason: Too short to monitor
        """),
        {
            "policy.yml": workflow(job("check", run("check"))),
            "ci.yml": workflow(
                job("build", MONITOR, run("make")),
                job("lint", run("lint")),
                job("notify", run("notify"), comment="workflow-policy: skip-job notification only"),
                "  # workflow-policy: skip-job rule=build-monitoring housekeeping\n"
                + job("cleanup", run("clean")),
                "  call:\n    uses: ./.github/workflows/legacy.yml\n",
            ),
            "legacy.yml": workflow(
                job("old", run("make")), job("lint", run("lint")),
                header="# workflow-policy: skip-workflow rule=build-monitoring legacy\n",
            ),
        },
    ),
    "parameter override": (
        textwrap.dedent("""\
            extends:
              - name: build-monitoring
                params:
                  last-step-any-of:
                    - ./.github/actions/report-build
        """),
        {"ci.yml": workflow(
            job(
                "own-wrapper", MONITOR,
                "      - uses: ./.github/actions/report-build\n"
                "        if: always()\n        continue-on-error: true\n",
            ),
            job("default-submission", MONITOR, SUBMIT),
        )},
    ),
    "every job excluded": (
        EXTENDS + 'exceptions:\n  - workflow: "*"\n    jobs: ["*"]\n    reason: Not yet\n',
        {"ci.yml": workflow(job("build", run("make")))},
    ),
    "unused exception": (
        EXTENDS + 'exceptions:\n  - workflow: "*"\n    jobs: [lnit]\n    reason: Typo\n',
        {"ci.yml": workflow(job("build", run("make")))},
    ),
    "misplaced skip-workflow": (EXTENDS, {"ci.yml": workflow(
        job("build", run("make"), comment="workflow-policy: skip-workflow too late"),
    )}),
    "fixed parameter override": (
        "extends:\n  - name: build-monitoring\n    params:\n      first-step: acme/start\n",
        {"ci.yml": workflow(job("build", run("make")))},
    ),
    # Both read YAML 1.2, so the job ID `yes` stays a string; Checkov reads it as True.
    "YAML 1.1 job ID": (EXTENDS, {"ci.yml": workflow(job("yes", run("make")))}),
    # Neither validates the workflow schema; Checkov skips a workflow without `on`.
    "workflow without on": (EXTENDS, {"ci.yml": "name: CI\njobs:\n" + job("build", run("make"))}),
}


# (status, passed jobs, failed jobs, excluded jobs), so a scenario cannot drift into an outcome
# both implementations share for the wrong reason.
EXPECTED = {
    "passing and failing jobs": ("failed", 2, 6, 0),
    "every kind of exception": ("failed", 0, 1, 6),
    "parameter override": ("failed", 1, 1, 0),
    "every job excluded": ("passed", 0, 0, 1),
    "unused exception": ("error", 0, 0, 0),
    "misplaced skip-workflow": ("error", 0, 0, 0),
    "fixed parameter override": ("error", 0, 0, 0),
    "YAML 1.1 job ID": ("failed", 0, 1, 0),
    "workflow without on": ("failed", 0, 1, 0),
}


def repository(tmp_path, config, workflows):
    repo = tmp_path / "repo"
    (repo / ".github" / "workflows").mkdir(parents=True)
    (repo / ".github" / "workflow-policy.yml").write_text(config, encoding="utf-8")
    for name, text in workflows.items():
        (repo / ".github" / "workflows" / name).write_text(text, encoding="utf-8")
    return repo


def check(action, repo, tmp_path):
    """Run one implementation; return its exit status, normalized report, and summary."""
    output = tmp_path / action.name
    result = subprocess.run(
        [
            sys.executable, str(action / "check.py"), "--root", str(repo),
            "--config", ".github/workflow-policy.yml", "--report-dir", str(output),
        ],
        capture_output=True, text=True, check=False,
    )
    report = json.loads((output / "report.json").read_text(encoding="utf-8"))

    # Conftest lists top-level findings in its own file order; jobs keep manifest order.
    def key(finding):
        return finding["workflow"], finding["job"], finding["message"]

    report["findings"].sort(key=key)
    for entry in report["jobs"]:
        entry["findings"].sort(key=key)
    return result.returncode, report, (output / "summary.md").read_text(encoding="utf-8")


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_same_report(tmp_path, scenario):
    repo = repository(tmp_path, *SCENARIOS[scenario])
    conftest = check(CONFTEST_ACTION, repo, tmp_path)
    python = check(PYTHON_ACTION, repo, tmp_path)
    assert python == conftest
    summary = conftest[1]["summary"]
    assert (
        conftest[1]["status"], summary["passed_jobs"], summary["failed_jobs"],
        summary["excluded_jobs"],
    ) == EXPECTED[scenario]
