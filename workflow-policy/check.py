#!/usr/bin/env python3
"""Experimental workflow selector and Conftest required-action check."""

import argparse
from datetime import date
from html import escape
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from ruamel.yaml import YAML
from ruamel.yaml.error import YAMLError


def validate_config(config):
    if not isinstance(config, dict) or set(config) - {"required-actions", "exceptions"}:
        raise ValueError("configuration: expected required-actions and optional exceptions")
    actions = config.get("required-actions")
    if not isinstance(actions, list) or not actions or any(
        not isinstance(action, str) or "/" not in action or "@" in action
        or any(character.isspace() for character in action)
        for action in actions
    ):
        raise ValueError(
            "configuration: required-actions must be a non-empty list of "
            "unversioned action paths, such as actions/checkout"
        )
    exceptions = config.get("exceptions", [])
    if not isinstance(exceptions, list):
        raise ValueError("configuration: exceptions must be a list")
    for entry in exceptions:
        if not isinstance(entry, dict) or set(entry) != {"workflow", "jobs", "reason"}:
            raise ValueError("configuration: each exception needs workflow, jobs, and reason")
        workflow = entry["workflow"]
        if not isinstance(workflow, str) or (
            workflow != "*" and (
                Path(workflow).parent.as_posix() != ".github/workflows"
                or Path(workflow).suffix not in {".yml", ".yaml"}
                or any(character in workflow for character in "*?[]")
            )
        ):
            raise ValueError("configuration: workflow must be an exact workflow path or '*'")
        jobs = entry["jobs"]
        if not isinstance(jobs, list) or not jobs or any(
            not isinstance(job, str) or not job
            or (job != "*" and any(character in job for character in "*?[]"))
            for job in jobs
        ):
            raise ValueError("configuration: jobs must be a non-empty list of exact IDs or '*'")
        if not isinstance(entry["reason"], str) or not entry["reason"].strip():
            raise ValueError("configuration: each exception needs a non-empty reason")


def select_jobs(root, config):
    yaml = YAML(typ="safe", pure=True)
    selection = {}
    workflows = {}
    excluded_jobs = []
    exceptions = config.get("exceptions", [])
    matched_exceptions = set()
    directory = root / ".github" / "workflows"
    for path in sorted([*directory.glob("*.yml"), *directory.glob("*.yaml")]):
        workflow = yaml.load(path.read_text(encoding="utf-8"))
        relative_path = path.relative_to(root).as_posix()
        if (
            not isinstance(workflow, dict)
            or not isinstance(workflow.get("jobs"), dict)
            or not workflow["jobs"]
        ):
            raise ValueError(f"{relative_path}: expected a non-empty jobs mapping")
        selected = []
        for job_id, job in workflow["jobs"].items():
            if not isinstance(job_id, str) or not isinstance(job, dict):
                raise ValueError(f"{relative_path}: each job must be a named mapping")
            if "uses" not in job and (
                not isinstance(job.get("steps"), list)
                or any(not isinstance(step, dict) for step in job["steps"])
            ):
                raise ValueError(f"{relative_path}:{job_id}: expected a list of step mappings")
            matches = [
                (index, entry) for index, entry in enumerate(exceptions)
                if entry["workflow"] in ("*", relative_path)
                and (job_id in entry["jobs"] or "*" in entry["jobs"])
            ]
            if matches:
                matched_exceptions.update(index for index, _ in matches)
                excluded_jobs.append({
                    "workflow": relative_path,
                    "job": job_id,
                    "reason": matches[0][1]["reason"],
                })
            else:
                selected.append(job_id)
        selection[path.name] = {
            "path": relative_path,
            "jobs": selected,
        }
        workflows[path.name] = workflow
    if not selection:
        raise ValueError(f"no workflow files found in {directory}")
    for index in range(len(exceptions)):
        if index not in matched_exceptions:
            raise ValueError(f"exception #{index + 1} does not match any job")
    return {
        "required_actions": list(dict.fromkeys(config["required-actions"])),
        "selection": selection,
        "excluded_jobs": excluded_jobs,
    }, workflows


def json_value(value):
    if isinstance(value, date):
        return value.isoformat()
    raise ValueError(f"unsupported YAML value: {type(value).__name__}")


def evaluate(root, manifest, workflows):
    paths = [
        entry["path"] for entry in manifest["selection"].values()
        if entry["jobs"]
    ]
    if not paths:
        print("No jobs selected; all jobs are explicitly excluded.", file=sys.stderr)
        return []
    with tempfile.TemporaryDirectory(prefix="workflow-policy-") as temporary:
        data = Path(temporary) / "selection.json"
        data.write_text(json.dumps(manifest), encoding="utf-8")
        normalized_paths = []
        # Keep basenames for Conftest's file lookup, but avoid its YAML 1.1 coercion.
        for basename, entry in manifest["selection"].items():
            if entry["jobs"]:
                normalized = Path(temporary) / basename
                normalized.write_text(
                    json.dumps(workflows[basename], default=json_value), encoding="utf-8",
                )
                normalized_paths.append(str(normalized))
        conftest_config = Path(temporary) / "conftest.toml"
        conftest_config.touch()
        result = subprocess.run(
            [
                "conftest", "--config-file", str(conftest_config),
                "test", "--namespace", "main", "--policy",
                str(Path(__file__).resolve().parent / "policy"),
                "--data", str(data), "--parser", "json", "--output", "json",
                *normalized_paths,
            ],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode not in (0, 1):
            raise ValueError(
                f"Conftest failed (exit {result.returncode}): "
                f"{result.stderr.strip() or result.stdout.strip()}"
            )
        results = json.loads(result.stdout)
        if (
            not isinstance(results, list)
            or any(
                not isinstance(entry, dict) or not isinstance(entry.get("filename"), str)
                for entry in results
            )
            or {entry.get("filename") for entry in results} != set(normalized_paths)
        ):
            raise ValueError("Conftest did not return results for every selected workflow")
        findings = {}
        selected_jobs = {
            entry["path"]: set(entry["jobs"])
            for entry in manifest["selection"].values()
        }
        try:
            for entry in results:
                for failure in entry.get("failures", []):
                    metadata = failure["metadata"]
                    finding = {
                        "workflow": failure["loc"]["file"],
                        "job": metadata["job"],
                        "kind": metadata["kind"],
                        "action": metadata.get("action"),
                        "message": failure["msg"],
                    }
                    if (
                        finding["job"] not in selected_jobs[finding["workflow"]]
                        or finding["kind"] not in {"missing-action", "reusable-workflow"}
                        or (
                            finding["kind"] == "missing-action"
                            and finding["action"] not in manifest["required_actions"]
                        )
                    ):
                        raise ValueError("Conftest returned an unexpected violation")
                    key = (
                        finding["workflow"], finding["job"],
                        finding["kind"], finding["action"],
                    )
                    findings[key] = finding
        except (KeyError, TypeError) as error:
            raise ValueError("Conftest returned invalid violation metadata") from error
        if result.returncode == 1 and not findings:
            raise ValueError("Conftest failed without reporting any violations")
        return list(findings.values())


def build_report(manifest, workflows, findings, error=None):
    required = manifest["required_actions"]
    excluded = {
        (entry["workflow"], entry["job"]): entry["reason"]
        for entry in manifest["excluded_jobs"]
    }
    by_job = {}
    for finding in findings:
        by_job.setdefault((finding["workflow"], finding["job"]), []).append(finding)
    jobs = []
    for basename, selected in manifest["selection"].items():
        for job_id, job in workflows[basename]["jobs"].items():
            key = (selected["path"], job_id)
            row = {
                "workflow": selected["path"], "job": job_id,
                "status": "passed", "action_checks": 0,
                "missing_actions": [], "reason": "",
            }
            if key in excluded:
                row.update(status="excluded", reason=excluded[key])
            elif error:
                row.update(status="error", reason=error)
            elif "uses" in job:
                row.update(
                    status="uninspectable",
                    reason="Calls a reusable workflow; inspect it separately and add an exception",
                )
            else:
                missing = {finding["action"] for finding in by_job.get(key, [])}
                row["missing_actions"] = [action for action in required if action in missing]
                row["action_checks"] = len(required)
                if missing:
                    row["status"] = "failed"
            jobs.append(row)
    action_checks = sum(job["action_checks"] for job in jobs)
    failed_checks = sum(len(job["missing_actions"]) for job in jobs)
    failed_jobs = sum(job["status"] in {"failed", "uninspectable"} for job in jobs)
    return {
        "status": "error" if error else "failed" if failed_jobs else "passed",
        "required_actions": required,
        "summary": {
            "workflows": len(manifest["selection"]),
            "selected_jobs": len(jobs) - len(excluded),
            "excluded_jobs": len(excluded),
            "required_actions": len(required),
            "action_checks": action_checks,
            "passed_checks": action_checks - failed_checks,
            "failed_checks": failed_checks,
            "passed_jobs": sum(job["status"] == "passed" for job in jobs),
            "failed_jobs": failed_jobs,
            "uninspectable_jobs": sum(job["status"] == "uninspectable" for job in jobs),
        },
        "jobs": jobs,
        "findings": findings,
        "errors": [error] if error else [],
    }


def markdown_cell(value):
    value = escape(str(value)).replace("|", "&#124;").replace("\r", "").replace("\n", "<br>")
    return f"<code>{value}</code>"


def markdown_summary(report):
    summary = report["summary"]
    lines = [
        "## Workflow policy", "", f"**Status: {report['status'].upper()}**", "",
        f"{summary['selected_jobs']} selected jobs across {summary['workflows']} workflows; "
        f"{summary['excluded_jobs']} excluded.",
        f"Action checks: {summary['action_checks']} "
        f"({summary['passed_checks']} passed, {summary['failed_checks']} failed).",
        "",
    ]
    for error in report["errors"]:
        lines.extend([markdown_cell(error), ""])
    lines.extend([
        "| Workflow | Job | Result | Action checks | Details |",
        "| --- | --- | --- | --- | --- |",
    ])
    for job in report["jobs"]:
        checks = "-"
        details = job["reason"]
        if job["status"] in {"passed", "failed"}:
            checks = f"{job['action_checks'] - len(job['missing_actions'])}/{job['action_checks']} passed"
            details = (
                "Missing: " + ", ".join(job["missing_actions"])
                if job["missing_actions"] else "All required actions present"
            )
        lines.append(
            f"| {markdown_cell(job['workflow'])} | {markdown_cell(job['job'])} "
            f"| {job['status'].capitalize()} | {checks} | {markdown_cell(details)} |"
        )
    return "\n".join(lines) + "\n"


def annotation_value(value, property_value=False):
    value = str(value).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    if property_value:
        value = value.replace(":", "%3A").replace(",", "%2C")
    return value


def print_report(report):
    if report["errors"]:
        for error in report["errors"]:
            print(f"workflow-policy: {error}", file=sys.stderr)
        return
    summary = report["summary"]
    print(
        f"{summary['selected_jobs']} selected jobs across {summary['workflows']} workflows; "
        f"{summary['excluded_jobs']} excluded."
    )
    print(
        f"Action checks: {summary['action_checks']} "
        f"({summary['passed_checks']} passed, {summary['failed_checks']} failed); "
        f"{summary['required_actions']} required actions per inspectable job."
    )
    print(
        f"Jobs: {summary['passed_jobs']} passed, {summary['failed_jobs']} failed "
        f"({summary['uninspectable_jobs']} uninspectable)."
    )
    for workflow in dict.fromkeys(job["workflow"] for job in report["jobs"]):
        jobs = [job for job in report["jobs"] if job["workflow"] == workflow]
        checks = sum(job["action_checks"] for job in jobs)
        failures = sum(len(job["missing_actions"]) for job in jobs)
        selected = sum(job["status"] != "excluded" for job in jobs)
        display_path = workflow.replace("\r", "\\r").replace("\n", "\\n")
        print(f"{display_path}: {selected} selected jobs, {checks} action checks, {failures} failed.")
    for finding in report["findings"]:
        path = annotation_value(finding["workflow"], property_value=True)
        print(f"::error file={path},line=1::{annotation_value(finding['message'])}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument(
        "--select-only", action="store_true",
        help="Print the selection manifest as JSON without invoking Conftest.",
    )
    parser.add_argument(
        "--report-dir", type=Path,
        help="Write report.json and summary.md to this directory, including on failure.",
    )
    args = parser.parse_args()
    manifest = {"required_actions": [], "selection": {}, "excluded_jobs": []}
    workflows = {}
    findings = []
    error = None
    try:
        root = args.root.resolve()
        config = YAML(typ="safe", pure=True).load(
            (root / args.config).read_text(encoding="utf-8")
        )
        validate_config(config)
        manifest, workflows = select_jobs(root, config)
        for excluded in manifest["excluded_jobs"]:
            print(
                f"SKIP {excluded['workflow']}:{excluded['job']}: {excluded['reason']}",
                file=sys.stderr,
            )
        if args.select_only:
            print(json.dumps(manifest, indent=2))
            return 0
        findings = evaluate(root, manifest, workflows)
    except (OSError, ValueError, YAMLError) as failure:
        error = str(failure)
    report = build_report(manifest, workflows, findings, error)
    if args.report_dir:
        args.report_dir.mkdir(parents=True, exist_ok=True)
        (args.report_dir / "report.json").write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8",
        )
        (args.report_dir / "summary.md").write_text(markdown_summary(report), encoding="utf-8")
    print_report(report)
    return {"passed": 0, "failed": 1, "error": 2}[report["status"]]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, YAMLError) as error:
        print(f"workflow-policy: {error}", file=sys.stderr)
        sys.exit(2)
