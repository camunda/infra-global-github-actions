"""Exercise the public CLI with real workflow files and Conftest."""

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import textwrap

import pytest
from ruamel.yaml import YAML


CHECK = Path(__file__).with_name("check.py")


def run_check(tmp_path, workflows, config, *args, env=None):
    for filename, contents in workflows.items():
        path = tmp_path / ".github" / "workflows" / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(contents), encoding="utf-8")
    config_path = tmp_path / "policy.yml"
    config_path.write_text(textwrap.dedent(config), encoding="utf-8")
    return subprocess.run(
        [
            sys.executable, str(CHECK), "--root", str(tmp_path),
            "--config", str(config_path), *args,
        ],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


def test_missing_required_action_fails_with_workflow_and_job(tmp_path):
    result = run_check(
        tmp_path,
        {"ci.yml": """
            on: push
            jobs:
              build:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/setup-node@v4
        """},
        "required-actions: [actions/checkout]",
    )

    assert result.returncode == 1, result.stderr
    assert "::error file=.github/workflows/ci.yml,line=1::" in result.stdout
    assert result.stdout.count("job build is missing required action actions/checkout") == 1
    assert "ORIGINATING FROM" not in result.stdout
    assert "workflow-policy-" not in result.stdout


def test_reports_count_rule_checks_and_include_every_job(tmp_path):
    reports = tmp_path / "reports"
    result = run_check(
        tmp_path,
        {
            "ci.yml": """
                jobs:
                  build:
                    steps:
                      - uses: actions/checkout@v7
                      - uses: acme/tool@main
                  test:
                    steps:
                      - uses: actions/checkout@v7
                  notify:
                    steps: []
            """,
            "release.yml": """
                jobs:
                  shared:
                    uses: acme/shared/.github/workflows/build.yml@main
            """,
        },
        """
            required-actions: [actions/checkout, acme/tool, acme/tool]
            exceptions:
              - workflow: "*"
                jobs: [notify]
                reason: "Notifications | <only>"
        """,
        "--report-dir", str(reports),
    )

    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads((reports / "report.json").read_text(encoding="utf-8"))
    assert report["status"] == "failed"
    assert report["rules"] == ["required-actions"]
    assert report["summary"] == {
        "workflows": 2,
        "selected_jobs": 2,
        "excluded_jobs": 1,
        "rules": 1,
        "checks": 2,
        "passed_checks": 1,
        "failed_checks": 1,
        "passed_jobs": 1,
        "failed_jobs": 1,
        "reusable_jobs": 1,
    }
    jobs = {job["job"]: job for job in report["jobs"]}
    assert jobs["build"]["status"] == "passed"
    assert jobs["test"]["findings"] == [{
        "workflow": ".github/workflows/ci.yml", "job": "test", "rule": "required-actions",
        "message": "job test is missing required action acme/tool", "action": "acme/tool",
    }]
    assert jobs["notify"]["status"] == "excluded"
    assert jobs["shared"]["status"] == "reusable"
    assert jobs["shared"]["calls"] == "acme/shared/.github/workflows/build.yml@main"
    assert "Rule checks: 2 (1 passed, 1 failed)" in result.stdout
    assert (
        "2 selected jobs across 2 workflows; 1 excluded; 1 call reusable workflows."
        in result.stdout
    )
    assert "policies in namespace" not in result.stdout
    markdown = (reports / "summary.md").read_text(encoding="utf-8")
    assert "| Workflow | Job | Result | Rule checks | Details |" in markdown
    assert "Notifications &#124; &lt;only&gt;" in markdown
    assert "acme/tool" in markdown
    assert (
        "| Reusable | - | <code>Calls reusable workflow acme/shared/.github/workflows/build.yml@main"
        in markdown
    )


@pytest.mark.parametrize("error", [
    "configuration", "missing-conftest", "empty-results", "invalid-results", "unevaluated-rule",
])
def test_report_errors_do_not_claim_success(tmp_path, error):
    reports = tmp_path / "reports"
    env = None
    if error == "missing-conftest":
        env = {**os.environ, "PATH": ""}
    elif error in {"empty-results", "invalid-results", "unevaluated-rule"}:
        commands = tmp_path / "commands"
        commands.mkdir()
        conftest = commands / "conftest"
        output = {
            "empty-results": "printf '%s\\n' '[]'",
            "invalid-results": "printf '%s\\n' '[null]'",
            # What Conftest returns for a namespace that holds no deny rules.
            "unevaluated-rule": (
                "for last; do :; done\n"
                "printf '[{\"filename\":\"%s\",\"namespace\":"
                "\"workflow_policy.required_actions\",\"successes\":0}]\\n' \"$last\""
            ),
        }[error]
        conftest.write_text(f"#!/bin/sh\n{output}\n", encoding="utf-8")
        conftest.chmod(0o755)
        env = {**os.environ, "PATH": str(commands)}
    result = run_check(
        tmp_path,
        {"ci.yml": "jobs: {build: {steps: []}}"},
        "{}" if error == "configuration" else "required-actions: [actions/checkout]",
        "--report-dir", str(reports),
        env=env,
    )

    assert result.returncode == 2, result.stdout + result.stderr
    report = json.loads((reports / "report.json").read_text(encoding="utf-8"))
    assert report["status"] == "error"
    assert report["errors"]
    assert report["summary"]["passed_checks"] == 0
    assert report["summary"]["checks"] == 0
    assert "ERROR" in (reports / "summary.md").read_text(encoding="utf-8")
    if error == "unevaluated-rule":
        assert "Conftest evaluated no policy for rule required-actions" in result.stderr


def test_shared_notification_exception_applies_across_workflows(tmp_path):
    result = run_check(
        tmp_path,
        {
            "ci.yml": """
                on: push
                jobs:
                  build:
                    runs-on: ubuntu-latest
                    env:
                      RELEASE_DATE: 2026-10-26
                    steps:
                      - uses: actions/checkout@0123456789012345678901234567890123456789
                  notify:
                    runs-on: ubuntu-latest
                    steps:
                      - run: echo Notify
            """,
            "release.yaml": """
                on: workflow_dispatch
                jobs:
                  publish:
                    runs-on: ubuntu-latest
                    steps:
                      - uses: actions/checkout@v4
                  notify-on-failure:
                    runs-on: ubuntu-latest
                    steps:
                      - run: echo Notify
            """,
        },
        """
            required-actions: [actions/checkout]
            exceptions:
              - workflow: "*"
                jobs: [notify, notify-on-failure]
                reason: Notification-only jobs
        """,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "SKIP .github/workflows/ci.yml:notify: Notification-only jobs" in result.stderr
    assert "SKIP .github/workflows/release.yaml:notify-on-failure:" in result.stderr


def test_selection_manifest_matches_job_ids_not_display_names_or_prefixes(tmp_path):
    result = run_check(
        tmp_path,
        {"ci.yml": """
            on: push
            jobs:
              build:
                name: notify
                runs-on: ubuntu-latest
                steps: []
              notify:
                runs-on: ubuntu-latest
                steps: []
              notify-and-deploy:
                runs-on: ubuntu-latest
                steps: []
        """},
        """
            required-actions: [actions/checkout]
            exceptions:
              - workflow: "*"
                jobs: [notify]
                reason: Notification-only
        """,
        "--select-only",
    )

    assert result.returncode == 0, result.stderr
    manifest = json.loads(result.stdout)
    assert manifest["rules"] == ["required-actions"]
    assert manifest["workflows"] == [".github/workflows/ci.yml"]
    assert [job["job"] for job in manifest["jobs"] if job["rules"]] == [
        "build", "notify-and-deploy",
    ]
    assert [job for job in manifest["jobs"] if not job["rules"]] == [{
        "workflow": ".github/workflows/ci.yml",
        "job": "notify",
        "calls": None,
        "rules": [],
        "exclusions": [{
            "source": "config", "file": "policy.yml", "line": 4,
            "reason": "Notification-only", "rule": None,
        }],
    }]


def test_inline_directives_exclude_only_the_job_they_annotate(tmp_path):
    result = run_check(
        tmp_path,
        {"ci.yml": """
            on: push
            jobs:
              build:
                runs-on: ubuntu-latest
                steps:
                  - run: |
                      # workflow-policy: skip-job script text is not a directive
                      echo "# workflow-policy: skip-job"
              # Sends Slack messages only.
              # workflow-policy: skip-job notification-only job
              notify:
                steps: []
              cleanup: # workflow-policy: skip-job  housekeeping only
                steps: []
              deploy:
                steps:
                  - run: "echo
                      # workflow-policy: skip-job quoted text"
              lint: {steps: []}  # workflow-policy: skip-job flow-style job
        """},
        "required-actions: [actions/checkout]",
        "--select-only",
    )

    assert result.returncode == 0, result.stderr
    manifest = json.loads(result.stdout)
    assert [job["job"] for job in manifest["jobs"] if job["rules"]] == ["build", "deploy"]
    assert [
        {key: job[key] for key in ("job", "exclusions")}
        for job in manifest["jobs"] if not job["rules"]
    ] == [
        {
            "job": job,
            "exclusions": [{
                "source": "inline", "file": ".github/workflows/ci.yml",
                "line": line, "reason": reason, "rule": None,
            }],
        }
        for job, line, reason in [
            ("notify", 11, "notification-only job"),
            ("cleanup", 14, "housekeeping only"),
            ("lint", 20, "flow-style job"),
        ]
    ]
    assert (
        "SKIP .github/workflows/ci.yml:notify: notification-only job "
        "(inline, .github/workflows/ci.yml:11)"
        in result.stderr
    )


def test_inline_and_config_exceptions_combine(tmp_path):
    reports = tmp_path / "reports"
    result = run_check(
        tmp_path,
        {
            "ci.yml": """
                jobs:
                  build:
                    steps:
                      - uses: actions/checkout@v4
                  notify: # workflow-policy: skip-job Slack only
                    steps: []
                  docs:
                    steps: []
            """,
            "release.yml": """
                jobs:
                  shared:
                    uses: acme/shared/.github/workflows/build.yml@main
                  docs:
                    steps: []
            """,
        },
        """
            required-actions: [actions/checkout]
            exceptions:
              - workflow: "*"
                jobs: [docs, notify]
                reason: Documentation and notification jobs
        """,
        "--report-dir", str(reports),
    )

    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads((reports / "report.json").read_text(encoding="utf-8"))
    assert report["summary"]["excluded_jobs"] == 3
    assert report["summary"]["selected_jobs"] == 1
    assert report["summary"]["reusable_jobs"] == 1
    exclusions = {(job["workflow"], job["job"]): job["exclusions"] for job in report["jobs"]}
    configured = {
        "source": "config", "file": "policy.yml", "line": 4,
        "reason": "Documentation and notification jobs", "rule": None,
    }
    assert exclusions[(".github/workflows/ci.yml", "notify")] == [
        {
            "source": "inline", "file": ".github/workflows/ci.yml",
            "line": 6, "reason": "Slack only", "rule": None,
        },
        configured,
    ]
    assert exclusions[(".github/workflows/ci.yml", "docs")] == [configured]
    assert exclusions[(".github/workflows/release.yml", "shared")] == []
    assert exclusions[(".github/workflows/ci.yml", "build")] == []
    markdown = (reports / "summary.md").read_text(encoding="utf-8")
    assert (
        "Slack only (inline, .github/workflows/ci.yml:6)<br>"
        "Documentation and notification jobs (config, policy.yml:4)"
    ) in markdown


def test_skip_workflow_directive_excludes_every_job_in_its_workflow(tmp_path):
    reports = tmp_path / "reports"
    result = run_check(
        tmp_path,
        {
            "ci.yml": """
                jobs:
                  build:
                    steps:
                      - uses: actions/checkout@v5
            """,
            "maintenance.yml": """
                # Manual cleanup tasks.

                # workflow-policy: skip-workflow manual maintenance only
                name: Maintenance
                on: workflow_dispatch
                jobs:
                  reset:
                    steps: []
                  shared:
                    uses: acme/shared/.github/workflows/cleanup.yml@main
            """,
        },
        "required-actions: [actions/checkout]",
        "--report-dir", str(reports),
    )

    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads((reports / "report.json").read_text(encoding="utf-8"))
    exclusion = {
        "source": "inline", "file": ".github/workflows/maintenance.yml",
        "line": 4, "reason": "manual maintenance only", "rule": None,
    }
    assert {(job["workflow"], job["job"]): job["exclusions"] for job in report["jobs"]} == {
        (".github/workflows/ci.yml", "build"): [],
        (".github/workflows/maintenance.yml", "reset"): [exclusion],
        (".github/workflows/maintenance.yml", "shared"): [],
    }
    assert (
        "SKIP .github/workflows/maintenance.yml:reset: manual maintenance only "
        "(inline, .github/workflows/maintenance.yml:4)"
    ) in result.stderr
    assert (
        "SKIP .github/workflows/maintenance.yml:shared: "
        "calls reusable workflow acme/shared/.github/workflows/cleanup.yml@main"
    ) in result.stderr


def test_skip_workflow_and_skip_job_directives_combine(tmp_path):
    reports = tmp_path / "reports"
    result = run_check(
        tmp_path,
        {"ci.yml": """
            # workflow-policy: skip-workflow rule=build-monitoring jobs finish in seconds
            on: push
            jobs:
              lint:
                steps:
                  - uses: actions/checkout@v5
              cleanup: # workflow-policy: skip-job housekeeping only
                steps: []
        """},
        """
            required-actions: [actions/checkout]
            extends: [build-monitoring]
        """,
        "--report-dir", str(reports),
    )

    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads((reports / "report.json").read_text(encoding="utf-8"))
    jobs = {job["job"]: job for job in report["jobs"]}
    workflow_exclusion = {
        "source": "inline", "file": ".github/workflows/ci.yml", "line": 2,
        "reason": "jobs finish in seconds", "rule": "build-monitoring",
    }
    assert jobs["lint"]["rules"] == ["required-actions"]
    assert jobs["lint"]["exclusions"] == [workflow_exclusion]
    assert jobs["cleanup"]["rules"] == []
    assert jobs["cleanup"]["exclusions"] == [workflow_exclusion, {
        "source": "inline", "file": ".github/workflows/ci.yml", "line": 8,
        "reason": "housekeeping only", "rule": None,
    }]


def test_directives_for_different_rules_combine_on_the_same_job_or_workflow(tmp_path):
    result = run_check(
        tmp_path,
        {
            "ci.yml": """
                # workflow-policy: skip-workflow rule=build-monitoring jobs finish in seconds
                # workflow-policy: skip-workflow rule=required-actions no checkout needed
                on: push
                jobs:
                  lint:
                    steps: []
            """,
            "release.yml": """
                jobs:
                  # workflow-policy: skip-job rule=build-monitoring too short to monitor
                  tag: # workflow-policy: skip-job rule=required-actions tags through the API
                    steps: []
                  publish:
                    steps: []
            """,
        },
        """
            required-actions: [actions/checkout]
            extends: [build-monitoring]
        """,
        "--select-only",
    )

    assert result.returncode == 0, result.stderr
    jobs = {(job["workflow"], job["job"]): job for job in json.loads(result.stdout)["jobs"]}

    def inline(workflow, line, reason, rule):
        return {
            "source": "inline", "file": f".github/workflows/{workflow}",
            "line": line, "reason": reason, "rule": rule,
        }

    lint = jobs[(".github/workflows/ci.yml", "lint")]
    assert lint["rules"] == []
    assert lint["exclusions"] == [
        inline("ci.yml", 2, "jobs finish in seconds", "build-monitoring"),
        inline("ci.yml", 3, "no checkout needed", "required-actions"),
    ]
    tag = jobs[(".github/workflows/release.yml", "tag")]
    assert tag["rules"] == []
    assert tag["exclusions"] == [
        inline("release.yml", 3, "too short to monitor", "build-monitoring"),
        inline("release.yml", 4, "tags through the API", "required-actions"),
    ]
    publish = jobs[(".github/workflows/release.yml", "publish")]
    assert publish["rules"] == ["required-actions", "build-monitoring"]
    assert publish["exclusions"] == []


SYNTAX = "expected '# workflow-policy: skip-job|skip-workflow [rule=<rule>] <reason>'"


@pytest.mark.parametrize("workflow,message", [
    ("jobs:\n  notify: # workflow-policy: skip-job\n    steps: []\n", f"ci.yml:2: {SYNTAX}"),
    (
        "jobs:\n  notify: # workflow-policy: skip-job rule=required-actions\n    steps: []\n",
        f"ci.yml:2: {SYNTAX}",
    ),
    (
        "jobs:\n  notify: # workflow-policy: skip-job rule= no rule name\n    steps: []\n",
        f"ci.yml:2: {SYNTAX}",
    ),
    (
        "jobs:\n  notify: # workflow-policy: skip-job rule=build-monitoring Slack only\n"
        "    steps: []\n",
        "ci.yml:2: rule build-monitoring is not configured; configured rules: required-actions",
    ),
    (
        "jobs:\n  notify: # workflow-policy skip-job missing colon\n    steps: []\n",
        f"ci.yml:2: {SYNTAX}",
    ),
    (
        "jobs:\n  notify: # Workflow-Policy: skip-job wrong case\n    steps: []\n",
        f"ci.yml:2: {SYNTAX}",
    ),
    ("jobs:\n  notify: # workflow-policy: skip no scope\n    steps: []\n", f"ci.yml:2: {SYNTAX}"),
    ("# workflow-policy: skip-file legacy\njobs:\n  notify:\n    steps: []\n", f"ci.yml:1: {SYNTAX}"),
    ("# workflow-policy: skip-job whole file\njobs:\n  notify:\n    steps: []\n", "ci.yml:1: place skip-job"),
    (
        "jobs:\n  notify:\n    steps:\n      # workflow-policy: skip-job step\n      - run: echo\n",
        "ci.yml:4: place skip-job",
    ),
    (
        "jobs:\n  # workflow-policy: skip-job blank line\n\n  notify:\n    steps: []\n",
        "ci.yml:2: place skip-job",
    ),
    (
        "jobs:\n    # workflow-policy: skip-job indentation\n  notify:\n    steps: []\n",
        "ci.yml:2: place skip-job",
    ),
    (
        "jobs: # workflow-policy: skip-job jobs key\n  notify:\n    steps: []\n",
        "ci.yml:1: place skip-job",
    ),
    (
        "jobs: {build: {steps: []}, notify: {steps: []}} # workflow-policy: skip-job which\n",
        "ci.yml:1: place skip-job",
    ),
    (
        "jobs:\n  # workflow-policy: skip-job one\n  notify: # workflow-policy: skip-job two\n"
        "    steps: []\n",
        "ci.yml:3: job notify has a skip-job directive without rule= and another skip-job directive",
    ),
    (
        "jobs:\n  # workflow-policy: skip-job rule=required-actions one\n"
        "  notify: # workflow-policy: skip-job two\n    steps: []\n",
        "ci.yml:3: job notify has a skip-job directive without rule= and another skip-job directive",
    ),
    (
        "jobs:\n  # workflow-policy: skip-job rule=required-actions one\n"
        "  notify: # workflow-policy: skip-job rule=required-actions two\n    steps: []\n",
        "ci.yml:3: job notify has more than one skip-job directive for rule required-actions",
    ),
    (
        "jobs:\n  notify: # workflow-policy: skip-workflow on a job\n    steps: []\n",
        "ci.yml:2: place skip-workflow",
    ),
    (
        "on: push # workflow-policy: skip-workflow first key line\njobs:\n  notify:\n    steps: []\n",
        "ci.yml:1: place skip-workflow",
    ),
    (
        "on: push\n# workflow-policy: skip-workflow after the first key\njobs:\n  notify:\n    steps: []\n",
        "ci.yml:2: place skip-workflow",
    ),
    (
        "# workflow-policy: skip-workflow rule=build-monitoring legacy\njobs:\n  notify:\n    steps: []\n",
        "ci.yml:1: rule build-monitoring is not configured; configured rules: required-actions",
    ),
    (
        "# workflow-policy: skip-workflow one\n"
        "# workflow-policy: skip-workflow rule=required-actions two\njobs:\n  notify:\n    steps: []\n",
        "ci.yml:2: the workflow has a skip-workflow directive without rule= "
        "and another skip-workflow directive",
    ),
    (
        "# workflow-policy: skip-workflow rule=required-actions one\n"
        "# workflow-policy: skip-workflow rule=required-actions two\njobs:\n  notify:\n    steps: []\n",
        "ci.yml:2: the workflow has more than one skip-workflow directive for rule required-actions",
    ),
    (
        "jobs:\n  shared: # workflow-policy: skip-job shared steps\n"
        "    uses: acme/shared/.github/workflows/build.yml@main\n",
        "ci.yml:2: job shared calls a reusable workflow, which is never checked; "
        "remove the directive",
    ),
    (
        "# workflow-policy: skip-workflow shared steps\njobs:\n  shared:\n"
        "    uses: acme/shared/.github/workflows/build.yml@main\n",
        "ci.yml:1: every job in the workflow calls a reusable workflow, which is never checked; "
        "remove the directive",
    ),
])
def test_invalid_or_misplaced_inline_directives_fail(tmp_path, workflow, message):
    result = run_check(
        tmp_path,
        {"ci.yml": workflow},
        "required-actions: [actions/checkout]",
    )

    assert result.returncode == 2, result.stdout + result.stderr
    assert message in result.stderr
    assert "Traceback" not in result.stderr


@pytest.mark.parametrize("uses,exit_code", [
    ("acme/tool/setup@v1", 0),
    ("acme/tool/setup-extra@v1", 1),
    ("acme/tool@v1", 1),
])
def test_all_required_actions_match_exact_subpaths_independently_of_ref(
    tmp_path, uses, exit_code,
):
    result = run_check(
        tmp_path,
        {"ci.yml": f"""
            jobs:
              build:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@0123456789012345678901234567890123456789
                  - name: acme/tool/setup
                    uses: {uses}
        """},
        "required-actions: [actions/checkout, acme/tool/setup]",
    )

    assert result.returncode == exit_code, result.stdout + result.stderr


def test_whole_workflow_exception_does_not_exclude_same_job_elsewhere(tmp_path):
    workflow = """
        jobs:
          notify:
            runs-on: ubuntu-latest
            steps:
              - run: echo Notify
    """
    result = run_check(
        tmp_path,
        {"ci.yml": workflow, "release.yaml": workflow},
        """
            required-actions: [actions/checkout]
            exceptions:
              - workflow: .github/workflows/ci.yml
                jobs: ["*"]
                reason: Entire workflow is notification-only
        """,
    )

    assert result.returncode == 1, result.stdout + result.stderr
    assert "::error file=.github/workflows/release.yaml" in result.stdout
    assert "::error file=.github/workflows/ci.yml" not in result.stdout


def test_all_jobs_can_be_explicitly_excluded(tmp_path):
    result = run_check(
        tmp_path,
        {"notify.yml": "jobs: {notify: {runs-on: ubuntu-latest, steps: []}}"},
        """
            required-actions: [actions/checkout]
            exceptions:
              - workflow: "*"
                jobs: ["*"]
                reason: Repository only sends notifications
        """,
        "--report-dir", str(tmp_path / "reports"),
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert (
        "No jobs selected; every job is excluded or calls a reusable workflow." in result.stderr
    )
    report = json.loads((tmp_path / "reports/report.json").read_text(encoding="utf-8"))
    assert report["status"] == "passed"
    assert report["summary"]["selected_jobs"] == 0
    assert report["summary"]["excluded_jobs"] == 1
    assert report["summary"]["checks"] == 0


MONITOR = "camunda/infra-global-github-actions/start-build-monitor@0123456789012345678901234567890123456789"
SUBMIT = "camunda/infra-global-github-actions/submit-build-status@0123456789012345678901234567890123456789"


def test_build_monitoring_preset_checks_jobs_and_applies_its_exceptions(tmp_path):
    reports = tmp_path / "reports"
    result = run_check(
        tmp_path,
        {"ci.yml": f"""
            jobs:
              build:
                runs-on: ubuntu-latest
                steps:
                  - uses: {MONITOR}
                  - run: make
                  - uses: ./.github/actions/observe-build-status
                    if: ${{{{ always() }}}}
                    continue-on-error: true
              deploy:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v5
                  - uses: {MONITOR}
                  - uses: {SUBMIT}
              notify:
                runs-on: ubuntu-latest
                steps:
                  - run: echo notify
        """},
        "extends: [build-monitoring]",
        "--report-dir", str(reports),
    )

    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads((reports / "report.json").read_text(encoding="utf-8"))
    assert report["rules"] == ["build-monitoring"]
    jobs = {job["job"]: job for job in report["jobs"]}
    assert jobs["build"]["status"] == "passed"
    assert {finding["message"] for finding in jobs["deploy"]["findings"]} == {
        "job deploy: first step must use camunda/infra-global-github-actions/start-build-monitor",
        "job deploy: last step must set if: always() and continue-on-error: true",
    }
    assert jobs["notify"]["status"] == "excluded"
    assert jobs["notify"]["exclusions"] == [{
        "source": "preset", "file": "workflow-policy/presets/build-monitoring/preset.yml",
        "line": 12, "reason": "Notification-only jobs are not monitored",
        "rule": "build-monitoring",
    }]
    assert report["summary"]["checks"] == 2
    assert report["summary"]["failed_checks"] == 1
    assert (
        "::error file=.github/workflows/ci.yml,line=1::job deploy: first step must use"
        in result.stdout
    )


def test_preset_exceptions_may_match_no_job(tmp_path):
    result = run_check(
        tmp_path,
        {"ci.yml": f"""
            jobs:
              build:
                runs-on: ubuntu-latest
                steps:
                  - uses: {MONITOR}
                  - uses: {SUBMIT}
                    if: always()
                    continue-on-error: true
        """},
        "extends: [build-monitoring]",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Rule checks: 1 (1 passed, 0 failed)" in result.stdout


def test_rule_scoped_exceptions_leave_other_rules_checked(tmp_path):
    reports = tmp_path / "reports"
    result = run_check(
        tmp_path,
        {"ci.yml": """
            jobs:
              lint:
                runs-on: ubuntu-latest
                steps:
                  - run: make lint
              notify:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v5
        """},
        """
            required-actions: [actions/checkout]
            extends: [build-monitoring]
            exceptions:
              - workflow: "*"
                jobs: [lint]
                rule: build-monitoring
                reason: Too short to monitor
        """,
        "--report-dir", str(reports),
    )

    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads((reports / "report.json").read_text(encoding="utf-8"))
    assert report["rules"] == ["required-actions", "build-monitoring"]
    jobs = {job["job"]: job for job in report["jobs"]}
    assert jobs["lint"]["status"] == "failed"
    assert jobs["lint"]["rules"] == ["required-actions"]
    assert [finding["rule"] for finding in jobs["lint"]["findings"]] == ["required-actions"]
    assert jobs["notify"]["status"] == "passed"
    assert jobs["notify"]["rules"] == ["required-actions"]
    markdown = (reports / "summary.md").read_text(encoding="utf-8")
    assert "build-monitoring: Too short to monitor (config, policy.yml:5)" in markdown
    assert "build-monitoring: Notification-only jobs are not monitored (preset, " in markdown


@pytest.mark.parametrize("has_checkout", [False, True])
def test_inline_directive_can_skip_a_single_rule(tmp_path, has_checkout):
    reports = tmp_path / "reports"
    steps = "[{uses: actions/checkout@v5}]" if has_checkout else "[{run: make lint}]"
    result = run_check(
        tmp_path,
        {"ci.yml": f"""
            jobs:
              lint: # workflow-policy: skip-job rule=build-monitoring too short to monitor
                runs-on: ubuntu-latest
                steps: {steps}
        """},
        """
            required-actions: [actions/checkout]
            extends: [build-monitoring]
        """,
        "--report-dir", str(reports),
    )

    assert result.returncode == (0 if has_checkout else 1), result.stdout + result.stderr
    report = json.loads((reports / "report.json").read_text(encoding="utf-8"))
    [job] = report["jobs"]
    assert job["rules"] == ["required-actions"]
    assert job["exclusions"] == [{
        "source": "inline", "file": ".github/workflows/ci.yml", "line": 3,
        "reason": "too short to monitor", "rule": "build-monitoring",
    }]
    assert [finding["rule"] for finding in job["findings"]] == (
        [] if has_checkout else ["required-actions"]
    )
    assert (
        "SKIP .github/workflows/ci.yml:lint: build-monitoring: too short to monitor "
        "(inline, .github/workflows/ci.yml:3)"
    ) in result.stderr


@pytest.mark.parametrize("policy", sorted(
    path.parent for path in CHECK.parent.glob("presets/*/preset.yml")
))
def test_preset_policies_pass_their_rego_tests(policy):
    assert list(policy.glob("*_test.rego")), f"{policy.name} has no Rego tests"
    result = subprocess.run(
        ["conftest", "verify", "--no-color", "--policy", str(policy)],
        capture_output=True, text=True, check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr


def test_unused_exception_fails_instead_of_hiding_a_typo(tmp_path):
    result = run_check(
        tmp_path,
        {"ci.yml": """
            jobs:
              build:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
        """},
        """
            required-actions: [actions/checkout]
            exceptions:
              - workflow: "*"
                jobs: [notifiy]
                reason: Misspelled notification job
        """,
    )

    assert result.returncode == 2, result.stdout + result.stderr
    assert "policy.yml:4: exception #1 does not match any job" in result.stderr


@pytest.mark.parametrize("config", [
    "{}",
    "required-actions: []",
    "required-actions: actions/checkout",
    "required-actions: [actions/checkout@v4]",
    "required-actions: [actions/checkout]\nexception: []",
    """
        required-actions: [actions/checkout]
        exceptions: [{workflow: "*", jobs: [notify], reason: ""}]
    """,
    """
        required-actions: [actions/checkout]
        exceptions: [{workflow: "*", jobs: notify, reason: Notifications}]
    """,
    """
        required-actions: [actions/checkout]
        exceptions: [{workflow: "*", jobs: ["notify-*"], reason: Notifications}]
    """,
    "extends: build-monitoring",
    "extends: [missing]",
    "extends: [../policy]",
    "extends: [build-monitoring, build-monitoring]",
    "extends: [required-actions]",
    """
        required-actions: [actions/checkout]
        exceptions: [{workflow: "*", jobs: [notify], rule: build-monitoring, reason: Notify}]
    """,
])
def test_invalid_configuration_fails_before_policy_evaluation(tmp_path, config):
    result = run_check(
        tmp_path,
        {"ci.yml": "jobs: {notify: {runs-on: ubuntu-latest, steps: []}}"},
        config,
    )

    assert result.returncode == 2, result.stdout + result.stderr
    assert "configuration:" in result.stderr
    assert "Traceback" not in result.stderr


def test_empty_workflow_discovery_is_not_a_successful_check(tmp_path):
    result = run_check(tmp_path, {}, "required-actions: [actions/checkout]")

    assert result.returncode == 2, result.stdout + result.stderr
    assert "no workflow files found" in result.stderr


@pytest.mark.parametrize("workflow", [
    "",
    "jobs: {}",
    "jobs: {build: null}",
    "jobs: {build: {steps: not-a-list}}",
    "jobs: {build: {steps: [not-a-mapping]}}",
    "jobs: [",
])
def test_malformed_workflows_fail_even_with_a_whole_file_exception(tmp_path, workflow):
    result = run_check(
        tmp_path,
        {"ci.yml": workflow},
        """
            required-actions: [actions/checkout]
            exceptions:
              - workflow: "*"
                jobs: ["*"]
                reason: Explicit exception must not hide invalid workflows
        """,
    )

    assert result.returncode == 2, result.stdout + result.stderr
    assert "Traceback" not in result.stderr


def test_reusable_workflow_calls_are_never_checked_and_called_workflows_are(tmp_path):
    reports = tmp_path / "reports"
    result = run_check(
        tmp_path,
        {
            "ci.yml": """
                jobs:
                  build:
                    steps:
                      - uses: actions/checkout@v5
                  local:
                    uses: ./.github/workflows/shared.yml
                  remote:
                    uses: acme/shared/.github/workflows/build.yml@main
            """,
            "shared.yml": """
                on: workflow_call
                jobs:
                  test:
                    steps:
                      - run: make test
            """,
        },
        "required-actions: [actions/checkout]",
        "--report-dir", str(reports),
    )

    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads((reports / "report.json").read_text(encoding="utf-8"))
    jobs = {job["job"]: job for job in report["jobs"]}
    assert {job_id: (job["status"], job["calls"]) for job_id, job in jobs.items()} == {
        "build": ("passed", None),
        "local": ("reusable", "./.github/workflows/shared.yml"),
        "remote": ("reusable", "acme/shared/.github/workflows/build.yml@main"),
        "test": ("failed", None),
    }
    assert jobs["local"]["rules"] == jobs["local"]["exclusions"] == []
    assert "job test is missing required action actions/checkout" in result.stdout
    assert [line for line in result.stdout.splitlines() if line.startswith("::error")] == [
        "::error file=.github/workflows/shared.yml,line=1::"
        "job test is missing required action actions/checkout",
    ]
    assert (
        "SKIP .github/workflows/ci.yml:local: calls reusable workflow ./.github/workflows/shared.yml"
        in result.stderr
    )


def test_exceptions_matching_only_reusable_workflow_calls_fail(tmp_path):
    result = run_check(
        tmp_path,
        {"ci.yml": """
            jobs:
              shared-build:
                uses: acme/shared/.github/workflows/build.yml@main
        """},
        """
            required-actions: [actions/checkout]
            exceptions:
              - workflow: "*"
                jobs: [shared-build]
                reason: Required steps are managed in the shared workflow
        """,
    )

    assert result.returncode == 2, result.stdout + result.stderr
    assert (
        "policy.yml:4: exception #1 matches only jobs that call reusable workflows, "
        "which are never checked"
    ) in result.stderr


def test_callers_conftest_configuration_cannot_disable_the_bundled_policy(tmp_path):
    (tmp_path / "conftest.toml").write_text(
        'namespace = "unrelated"\n', encoding="utf-8",
    )
    result = run_check(
        tmp_path,
        {"ci.yml": "jobs: {build: {runs-on: ubuntu-latest, steps: []}}"},
        "required-actions: [actions/checkout]",
    )

    assert result.returncode == 1, result.stdout + result.stderr
    assert "job build is missing required action actions/checkout" in result.stdout


@pytest.mark.parametrize("job_id", ["on", "off"])
@pytest.mark.parametrize("has_checkout", [False, True])
def test_yaml_12_job_ids_are_not_lost_during_policy_evaluation(
    tmp_path, job_id, has_checkout,
):
    steps = "[{uses: actions/checkout@v4}]" if has_checkout else "[]"
    result = run_check(
        tmp_path,
        {"ci.yml": f"""
            on: push
            jobs:
              {job_id}:
                runs-on: ubuntu-latest
                steps: {steps}
        """},
        "required-actions: [actions/checkout]",
    )

    assert result.returncode == (0 if has_checkout else 1), result.stdout + result.stderr
    if not has_checkout:
        assert f"job {job_id} is missing required action actions/checkout" in result.stdout


@pytest.mark.parametrize("has_checkout", [False, True])
def test_composite_action_runs_bundled_checker_with_literal_caller_config(
    tmp_path, has_checkout,
):
    action = YAML(typ="safe", pure=True).load(
        CHECK.with_name("action.yml").read_text(encoding="utf-8"),
    )
    command = next(step for step in action["runs"]["steps"] if step.get("id") == "check")["run"]
    output = tmp_path / "output"
    tooling = tmp_path / "tooling"
    tooling.mkdir()
    caller = tmp_path / "caller"
    workflows = caller / ".github/workflows"
    workflows.mkdir(parents=True)
    steps = "[{uses: actions/checkout@v4}]" if has_checkout else "[]"
    (workflows / "ci.yml").write_text(
        f"jobs:\n  build:\n    runs-on: ubuntu-latest\n    steps: {steps}\n",
        encoding="utf-8",
    )
    config = "policy file $(touch injected).yml"
    (caller / config).write_text(
        "required-actions: [actions/checkout]\n", encoding="utf-8",
    )
    (caller / "workflow-policy").mkdir()
    (caller / "workflow-policy/check.py").write_text(
        "raise RuntimeError('caller checker must not run')\n", encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", command],
        cwd=tmp_path,
        env={
            **os.environ,
            "PATH": f"{Path(sys.executable).parent}{os.pathsep}{os.environ['PATH']}",
            "GITHUB_WORKSPACE": str(caller),
            "ACTION_DIRECTORY": str(CHECK.parent),
            "TOOLING_DIRECTORY": str(tooling),
            "CONFIG_PATH": config,
            "GITHUB_OUTPUT": str(output),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == (0 if has_checkout else 1), result.stdout + result.stderr
    assert not (tmp_path / "injected").exists()
    assert not (caller / "injected").exists()
    if not has_checkout:
        assert "job build is missing required action actions/checkout" in result.stdout
    outputs = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
    report = json.loads(Path(outputs["report-path"]).read_text(encoding="utf-8"))
    assert report["status"] == ("passed" if has_checkout else "failed")
    summary = tmp_path / "job-summary"
    summary.write_text("Existing summary\n", encoding="utf-8")
    summary_step = next(step for step in action["runs"]["steps"] if step["name"] == "Write job summary")
    subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", summary_step["run"]],
        env={
            **os.environ,
            "SUMMARY_PATH": outputs["summary-path"],
            "GITHUB_STEP_SUMMARY": str(summary),
        },
        check=True,
    )
    markdown = summary.read_text(encoding="utf-8")
    assert markdown.startswith("Existing summary\n")
    assert "| Workflow | Job | Result | Rule checks | Details |" in markdown
    assert ("Status: PASSED" if has_checkout else "Status: FAILED") in markdown


@pytest.mark.parametrize("checksum", ["valid", "mismatched", "missing", "malformed"])
def test_conftest_installer_verifies_release_before_extraction(tmp_path, checksum):
    action = YAML(typ="safe", pure=True).load(
        CHECK.with_name("action.yml").read_text(encoding="utf-8"),
    )
    installer = next(step for step in action["runs"]["steps"] if step.get("id") == "tooling")
    release = tmp_path / "release.tar.gz"
    contents = b"#!/bin/sh\nexit 0\n"
    with tarfile.open(release, "w:gz") as archive:
        binary = tarfile.TarInfo("conftest")
        binary.mode = 0o755
        binary.size = len(contents)
        archive.addfile(binary, io.BytesIO(contents))
    digest = hashlib.sha256(release.read_bytes()).hexdigest()
    if checksum == "mismatched":
        digest = "0" * 64
    elif checksum == "malformed":
        digest = "invalid-checksum"
    version = installer["env"]["CONFTEST_VERSION"]
    checksums = "\n".join(
        f"{digest}  conftest_{version}_{os_name}_{arch}.tar.gz"
        for os_name in ("Linux", "Darwin")
        for arch in ("x86_64", "arm64")
    )
    (tmp_path / "checksums.txt").write_text(
        checksums if checksum != "missing" else f"{digest}  unrelated.tar.gz\n",
        encoding="utf-8",
    )
    commands = tmp_path / "commands"
    commands.mkdir()
    curl = commands / "curl"
    curl.write_text(textwrap.dedent("""\
        #!/usr/bin/env bash
        set -euo pipefail
        while [[ "$1" != "--output" ]]; do shift; done
        case "$3" in
          */checksums.txt) cp "${DOWNLOAD_FIXTURES}/checksums.txt" "$2" ;;
          *) cp "${DOWNLOAD_FIXTURES}/release.tar.gz" "$2" ;;
        esac
    """), encoding="utf-8")
    curl.chmod(0o755)
    output = tmp_path / "output"

    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", installer["run"]],
        env={
            **os.environ,
            **installer["env"],
            "PATH": f"{commands}{os.pathsep}{os.environ['PATH']}",
            "DOWNLOAD_FIXTURES": str(tmp_path),
            "RUNNER_TEMP": str(tmp_path),
            "GITHUB_OUTPUT": str(output),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    if checksum == "valid":
        assert result.returncode == 0, result.stdout + result.stderr
        tooling = Path(output.read_text(encoding="utf-8").strip().split("=", 1)[1])
        assert (tooling / "bin/conftest").read_bytes() == contents
    else:
        assert result.returncode != 0, result.stdout + result.stderr
        assert not output.exists()
        assert not list(tmp_path.glob("workflow-policy.*/bin/conftest"))
