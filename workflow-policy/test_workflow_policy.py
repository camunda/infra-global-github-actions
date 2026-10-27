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


def run_check(tmp_path, workflows, config, *args):
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
    assert "job build is missing required action actions/checkout" in result.stdout


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
    assert manifest["selection"] == {
        "ci.yml": {
            "path": ".github/workflows/ci.yml",
            "jobs": ["build", "notify-and-deploy"],
        },
    }
    assert manifest["excluded_jobs"] == [{
        "workflow": ".github/workflows/ci.yml",
        "job": "notify",
        "reason": "Notification-only",
    }]


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
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "all jobs are explicitly excluded" in result.stderr


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
    assert "exception #1 does not match any job" in result.stderr


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


@pytest.mark.parametrize("excluded", [False, True])
def test_reusable_workflow_jobs_require_an_explicit_exception(tmp_path, excluded):
    config = "required-actions: [actions/checkout]\n"
    if excluded:
        config += textwrap.dedent("""
            exceptions:
              - workflow: "*"
                jobs: [shared-build]
                reason: Required steps are managed in the shared workflow
        """)
    result = run_check(
        tmp_path,
        {"ci.yml": """
            jobs:
              shared-build:
                uses: acme/shared/.github/workflows/build.yml@main
        """},
        config,
    )

    assert result.returncode == (0 if excluded else 1), result.stdout + result.stderr
    if not excluded:
        assert "job shared-build calls a reusable workflow" in result.stdout
        assert "missing required action" not in result.stdout


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
    command = action["runs"]["steps"][-1]["run"]
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
