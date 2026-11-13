"""Running Conftest on the selected jobs and collecting its findings."""

from datetime import date
import json
from pathlib import Path
import subprocess
import sys
import tempfile


# Finding metadata the checker reads itself; Conftest adds `query`, and other keys pass through.
CONFTEST_METADATA = {"job", "rule", "query"}


def json_default(value):
    """YAML dates become ISO strings; any other value JSON cannot hold fails."""
    if isinstance(value, date):
        return value.isoformat()
    raise ValueError(f"unsupported YAML value: {type(value).__name__}")


def run_conftest(root, workflows, rules):
    """Run every rule on the jobs with steps of `workflows`.

    Return Conftest's exit code, its result entries as (workflow, rule, entry), and the
    (workflow, job) pairs it was given.
    """
    namespaces = {rule.namespace: name for name, rule in rules.items()}
    with tempfile.TemporaryDirectory(prefix="workflow-policy-") as temporary:
        data = Path(temporary) / "data.json"
        data.write_text(
            json.dumps({"params": {name: rule.params for name, rule in rules.items()}}),
            encoding="utf-8",
        )
        files, inspectable = {}, set()
        for relative_path, workflow in workflows.items():
            # Rules see only jobs with steps, as JSON to avoid Conftest's YAML 1.1 coercion.
            step_jobs = {
                job_id: job for job_id, job in workflow["jobs"].items() if "uses" not in job
            }
            inspectable.update((relative_path, job_id) for job_id in step_jobs)
            normalized = Path(temporary) / Path(relative_path).name
            normalized.write_text(
                json.dumps({**workflow, "jobs": step_jobs}, default=json_default),
                encoding="utf-8",
            )
            files[str(normalized)] = relative_path
        # An empty configuration file keeps Conftest from reading the caller's conftest.toml.
        conftest_config = Path(temporary) / "conftest.toml"
        conftest_config.touch()
        command = [
            "conftest", "--config-file", str(conftest_config), "test",
            "--parser", "json", "--output", "json", "--data", str(data),
        ]
        for namespace in namespaces:
            command.extend(["--namespace", namespace])
        for rule in rules.values():
            command.extend(["--policy", str(rule.policy)])
        result = subprocess.run(
            [*command, *files], cwd=root, capture_output=True, text=True, check=False,
        )
    if result.returncode not in (0, 1):
        raise ValueError(
            f"Conftest failed (exit {result.returncode}): "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    results = json.loads(result.stdout)
    well_formed = isinstance(results, list) and all(
        isinstance(entry, dict) and isinstance(entry.get("filename"), str)
        and entry.get("namespace") in namespaces
        for entry in results
    )
    expected = {(file, namespace) for file in files for namespace in namespaces}
    if not well_formed or (
        {(entry["filename"], entry["namespace"]) for entry in results} != expected
    ):
        raise ValueError("Conftest did not return results for every workflow and rule")
    entries = [
        (files[entry["filename"]], namespaces[entry["namespace"]], entry) for entry in results
    ]
    return result.returncode, entries, inspectable


def evaluate(root, manifest, workflows, rules):
    """Run Conftest on workflows with a checked job; keep findings of each job's checked rules."""
    checked = {
        (job["workflow"], job["job"]): set(job["rules"])
        for job in manifest["jobs"] if job["rules"]
    }
    if not checked:
        print(
            "No jobs selected; every job is excluded or calls a reusable workflow.",
            file=sys.stderr,
        )
        return []
    targets = {workflow: workflows[workflow] for workflow, _ in checked}
    returncode, entries, inspectable = run_conftest(root, targets, rules)
    findings = {}
    reported = False
    try:
        for workflow, rule, entry in entries:
            failures = entry.get("failures") or []
            # A namespace without deny rules, such as a misnamed package, has neither outcome.
            if not entry.get("successes") and not failures:
                raise ValueError(f"Conftest evaluated no policy for rule {rule}")
            for failure in failures:
                metadata = failure["metadata"]
                finding = {
                    "workflow": workflow,
                    "job": metadata["job"],
                    "rule": metadata["rule"],
                    "message": failure["msg"],
                    **{
                        key: value for key, value in metadata.items()
                        if key not in CONFTEST_METADATA
                    },
                }
                if (
                    finding["rule"] != rule or not isinstance(finding["message"], str)
                    or (workflow, finding["job"]) not in inspectable
                ):
                    raise ValueError("Conftest returned an unexpected violation")
                reported = True
                if rule in checked.get((workflow, finding["job"]), ()):
                    # Keyed by content, so a repeated finding is reported once.
                    findings[tuple(finding.values())] = finding
    except (KeyError, TypeError) as error:
        raise ValueError("Conftest returned invalid violation metadata") from error
    if returncode == 1 and not reported:
        raise ValueError("Conftest failed without reporting any violations")
    return list(findings.values())
