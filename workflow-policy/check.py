#!/usr/bin/env python3
"""Experimental workflow selector and Conftest required-action check."""

import argparse
from datetime import date
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
        "required_actions": config["required-actions"],
        "selection": selection,
        "excluded_jobs": excluded_jobs,
    }, workflows


def json_value(value):
    if isinstance(value, date):
        return value.isoformat()
    raise ValueError(f"unsupported YAML value: {type(value).__name__}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument(
        "--select-only", action="store_true",
        help="Print the selection manifest as JSON without invoking Conftest.",
    )
    args = parser.parse_args()

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
    paths = [
        entry["path"] for entry in manifest["selection"].values()
        if entry["jobs"]
    ]
    if not paths:
        print("No jobs selected; all jobs are explicitly excluded.", file=sys.stderr)
        return 0
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
                "--data", str(data), "--parser", "json", "--output", "github",
                *normalized_paths,
            ],
            cwd=root,
            check=False,
        )
        return result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, YAMLError) as error:
        print(f"workflow-policy: {error}", file=sys.stderr)
        sys.exit(2)
