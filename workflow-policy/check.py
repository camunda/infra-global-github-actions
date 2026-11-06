#!/usr/bin/env python3
"""Experimental workflow job policy check: required actions and presets, evaluated by Conftest."""

import argparse
from datetime import date
from html import escape
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from ruamel.yaml import YAML
from ruamel.yaml.error import YAMLError
from ruamel.yaml.nodes import MappingNode, ScalarNode, SequenceNode


DIRECTIVE = re.compile(r"#\s*workflow-policy\b", re.IGNORECASE)
SKIP_DIRECTIVE = re.compile(
    r"#\s*workflow-policy:\s*skip-(job|workflow)(?:\s+rule=(\S+))?\s+(\S.*)"
)
SKIP_SYNTAX = "expected '# workflow-policy: skip-job|skip-workflow [rule=<rule>] <reason>'"
COMMENT_START = re.compile(r"(?<!\S)#")
PRESET_NAME = re.compile(r"[a-z][a-z0-9-]*")
ACTION_DIRECTORY = Path(__file__).resolve().parent
PRESETS = ACTION_DIRECTORY / "presets"
REQUIRED_ACTIONS = "required-actions"
EXCLUSION_FIELDS = ("source", "file", "line", "reason", "rule")
UNINSPECTABLE = "Calls a reusable workflow; inspect it separately and add an exception"


def validate_exceptions(exceptions, rules, label):
    """Check exception entries; `rules` lists the allowed `rule` values, or None to forbid it."""
    if not isinstance(exceptions, list):
        raise ValueError(f"{label}: exceptions must be a list")
    required = {"workflow", "jobs", "reason"}
    for entry in exceptions:
        if (
            not isinstance(entry, dict) or not required <= set(entry)
            or set(entry) - required - ({"rule"} if rules is not None else set())
        ):
            raise ValueError(
                f"{label}: each exception needs workflow, jobs, and reason"
                + (", and accepts rule" if rules is not None else "")
            )
        workflow = entry["workflow"]
        if not isinstance(workflow, str) or (
            workflow != "*" and (
                Path(workflow).parent.as_posix() != ".github/workflows"
                or Path(workflow).suffix not in {".yml", ".yaml"}
                or any(character in workflow for character in "*?[]")
            )
        ):
            raise ValueError(f"{label}: workflow must be an exact workflow path or '*'")
        jobs = entry["jobs"]
        if not isinstance(jobs, list) or not jobs or any(
            not isinstance(job, str) or not job
            or (job != "*" and any(character in job for character in "*?[]"))
            for job in jobs
        ):
            raise ValueError(f"{label}: jobs must be a non-empty list of exact IDs or '*'")
        if not isinstance(entry["reason"], str) or not entry["reason"].strip():
            raise ValueError(f"{label}: each exception needs a non-empty reason")
        if "rule" in entry and entry["rule"] not in rules:
            raise ValueError(f"{label}: exception rule must be one of: {', '.join(rules)}")


def validate_config(config):
    if not isinstance(config, dict) or set(config) - {"extends", REQUIRED_ACTIONS, "exceptions"}:
        raise ValueError("configuration: expected extends, required-actions, and exceptions")
    if "extends" not in config and REQUIRED_ACTIONS not in config:
        raise ValueError("configuration: set required-actions, extends, or both")
    rules = []
    if REQUIRED_ACTIONS in config:
        actions = config[REQUIRED_ACTIONS]
        if not isinstance(actions, list) or not actions or any(
            not isinstance(action, str) or "/" not in action or "@" in action
            or any(character.isspace() for character in action)
            for action in actions
        ):
            raise ValueError(
                "configuration: required-actions must be a non-empty list of "
                "unversioned action paths, such as actions/checkout"
            )
        rules.append(REQUIRED_ACTIONS)
    if "extends" in config:
        presets = config["extends"]
        if not isinstance(presets, list) or not presets or any(
            not isinstance(name, str) or not PRESET_NAME.fullmatch(name)
            or name == REQUIRED_ACTIONS
            for name in presets
        ) or len(set(presets)) != len(presets):
            raise ValueError("configuration: extends must be a non-empty list of distinct preset names")
        rules.extend(presets)
    validate_exceptions(config.get("exceptions", []), rules, "configuration")


def located_exceptions(entries, document, file, source, rule=None):
    """Attach the source, file, line, and rule of each entry under the document's `exceptions`."""
    nodes = []
    if isinstance(document, MappingNode):
        node = next(
            (value for key, value in document.value if key.value == "exceptions"), None,
        )
        if isinstance(node, SequenceNode):
            nodes = node.value
    return [
        {
            **entry, "source": source, "file": file,
            "line": nodes[index].start_mark.line + 1 if index < len(nodes) else None,
            "rule": entry.get("rule", rule),
        }
        for index, entry in enumerate(entries)
    ]


def load_preset(name, yaml):
    """Load a preset bundled with the action: its Rego policy, parameters, and exceptions."""
    path = PRESETS / name / "preset.yml"
    if not path.is_file():
        available = ", ".join(sorted(preset.parent.name for preset in PRESETS.glob("*/preset.yml")))
        raise ValueError(f"configuration: unknown preset {name}; available presets: {available}")
    text = path.read_text(encoding="utf-8")
    preset = yaml.load(text)
    label = f"preset {name}"
    if (
        not isinstance(preset, dict) or set(preset) - {"description", "params", "exceptions"}
        or not isinstance(preset.get("description"), str)
        or not isinstance(preset.get("params", {}), dict)
    ):
        raise ValueError(f"{label}: expected description, params, and exceptions")
    validate_exceptions(preset.get("exceptions", []), None, label)
    exceptions = located_exceptions(
        preset.get("exceptions", []), yaml.compose(text),
        f"workflow-policy/presets/{name}/preset.yml", "preset", name,
    )
    return {
        "namespace": "workflow_policy." + name.replace("-", "_"),
        "policy": path.parent,
        "params": preset.get("params", {}),
        # A preset serves many repositories, so its exceptions may match no job in one of them.
        "exceptions": [{**entry, "optional": True} for entry in exceptions],
    }


def load_rules(config, yaml):
    """Return {rule: {namespace, policy, params, exceptions}} in evaluation order."""
    rules = {}
    if REQUIRED_ACTIONS in config:
        rules[REQUIRED_ACTIONS] = {
            "namespace": "workflow_policy.required_actions",
            "policy": ACTION_DIRECTORY / "policy",
            "params": {"actions": list(dict.fromkeys(config[REQUIRED_ACTIONS]))},
            "exceptions": [],
        }
    for name in config.get("extends", []):
        rules[name] = load_preset(name, yaml)
    return rules


def comment_columns(lines, document):
    """Map line numbers to the column where a YAML comment starts.

    A '#' inside any scalar, such as a `run: |` script or a quoted string, is content.
    """
    spans = []
    pending, seen = [document], set()
    while pending:
        node = pending.pop()
        if id(node) in seen:
            continue
        seen.add(id(node))
        if isinstance(node, ScalarNode):
            spans.append((
                (node.start_mark.line, node.start_mark.column),
                (node.end_mark.line, node.end_mark.column),
            ))
        elif isinstance(node, MappingNode):
            pending.extend(item for pair in node.value for item in pair)
        else:
            pending.extend(node.value)
    columns = {}
    for number, line in enumerate(lines):
        for match in COMMENT_START.finditer(line):
            position = (number, match.start())
            if not any(start <= position < end for start, end in spans):
                columns[number] = match.start()
                break
    return columns


def inline_exceptions(text, document, relative_path, rules):
    """Return the workflow's exclusions and {job_id: exclusions} from skip directives.

    `skip-workflow` belongs in the comment lines before the workflow's first key.
    `skip-job` belongs to the job whose ID shares its line, or to the job ID directly
    below a block of full-line comments at that job ID's indentation. Without `rule=`,
    a directive skips every rule; otherwise a job or workflow takes one directive per rule.
    """
    lines = text.splitlines()
    comments = comment_columns(lines, document)
    first_key_line = document.value[0][0].start_mark.line
    jobs = next((value for key, value in document.value if key.value == "jobs"), None)
    owners = {}
    for key, _ in jobs.value if isinstance(jobs, MappingNode) else []:
        line, column = key.start_mark.line, key.start_mark.column
        owners.setdefault(line, []).append(key.value)
        line -= 1
        while comments.get(line) == column and not lines[line][:column].strip():
            owners.setdefault(line, []).append(key.value)
            line -= 1
    workflow_exclusions, job_exclusions = [], {}
    for line, column in sorted(comments.items()):
        comment = lines[line][column:].rstrip()
        if not DIRECTIVE.match(comment):
            continue
        location = f"{relative_path}:{line + 1}"
        directive = SKIP_DIRECTIVE.fullmatch(comment)
        # Without a reason, `skip-job rule=<rule>` would otherwise read as a reason for every rule.
        if not directive or directive[3].startswith("rule="):
            raise ValueError(f"{location}: {SKIP_SYNTAX}")
        scope, rule, reason = directive.groups()
        if scope == "workflow":
            if line >= first_key_line:
                raise ValueError(
                    f"{location}: place skip-workflow in the comment lines before "
                    "the workflow's first key"
                )
            target, existing = "the workflow", workflow_exclusions
        else:
            if len(owners.get(line, [])) != 1:
                raise ValueError(
                    f"{location}: place skip-job on a job ID line, or directly above "
                    "the job ID at the same indentation"
                )
            job_id = owners[line][0]
            target, existing = f"job {job_id}", job_exclusions.setdefault(job_id, [])
        if rule is not None and rule not in rules:
            raise ValueError(
                f"{location}: rule {rule} is not configured; configured rules: {', '.join(rules)}"
            )
        if existing and (rule is None or None in {exclusion["rule"] for exclusion in existing}):
            raise ValueError(
                f"{location}: {target} has a skip-{scope} directive without rule= "
                f"and another skip-{scope} directive"
            )
        if any(exclusion["rule"] == rule for exclusion in existing):
            raise ValueError(
                f"{location}: {target} has more than one skip-{scope} directive for rule {rule}"
            )
        existing.append({
            "source": "inline", "file": relative_path,
            "line": line + 1, "reason": reason.strip(), "rule": rule,
        })
    return workflow_exclusions, job_exclusions


def location(exclusion):
    if exclusion["line"] is None:
        return exclusion["file"]
    return f"{exclusion['file']}:{exclusion['line']}"


def describe_exclusions(exclusions):
    return [
        ("" if exclusion["rule"] is None else f"{exclusion['rule']}: ")
        + f"{exclusion['reason']} ({exclusion['source']}, {location(exclusion)})"
        for exclusion in exclusions
    ]


def select_jobs(root, rules, exceptions):
    """Decide, for every job, which rules it is checked against and which exceptions apply."""
    yaml = YAML(typ="safe", pure=True)
    workflows = {}
    jobs = []
    matched_exceptions = set()
    directory = root / ".github" / "workflows"
    for path in sorted([*directory.glob("*.yml"), *directory.glob("*.yaml")]):
        # utf-8-sig drops a BOM so comment columns match the parser's.
        text = path.read_text(encoding="utf-8-sig")
        workflow = yaml.load(text)
        relative_path = path.relative_to(root).as_posix()
        if (
            not isinstance(workflow, dict)
            or not isinstance(workflow.get("jobs"), dict)
            or not workflow["jobs"]
        ):
            raise ValueError(f"{relative_path}: expected a non-empty jobs mapping")
        workflow_exclusions, job_exclusions = inline_exceptions(
            text, yaml.compose(text), relative_path, list(rules)
        )
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
            matched_exceptions.update(index for index, _ in matches)
            # Every exception covering the job is reported, so removing one shows what remains.
            exclusions = [*workflow_exclusions, *job_exclusions.get(job_id, [])]
            exclusions.extend(
                {key: entry[key] for key in EXCLUSION_FIELDS} for _, entry in matches
            )
            skipped = {exclusion["rule"] for exclusion in exclusions}
            jobs.append({
                "workflow": relative_path,
                "job": job_id,
                "inspectable": "uses" not in job,
                "rules": [] if None in skipped else [rule for rule in rules if rule not in skipped],
                "exclusions": exclusions,
            })
        workflows[relative_path] = workflow
    if not workflows:
        raise ValueError(f"no workflow files found in {directory}")
    for index, entry in enumerate(exceptions):
        if index not in matched_exceptions and not entry.get("optional"):
            raise ValueError(
                f"{location(entry)}: exception #{index + 1} does not match any job"
            )
    return {"rules": list(rules), "workflows": list(workflows), "jobs": jobs}, workflows


def json_value(value):
    if isinstance(value, date):
        return value.isoformat()
    raise ValueError(f"unsupported YAML value: {type(value).__name__}")


def evaluate(root, manifest, workflows, rules):
    """Run every rule on every inspectable job, then keep findings for checked rules only."""
    checked = {
        (job["workflow"], job["job"]): set(job["rules"])
        for job in manifest["jobs"] if job["inspectable"] and job["rules"]
    }
    targets = list(dict.fromkeys(workflow for workflow, _ in checked))
    if not targets:
        if not any(job["rules"] for job in manifest["jobs"]):
            print("No jobs selected; all jobs are explicitly excluded.", file=sys.stderr)
        return []
    inspectable = {
        (job["workflow"], job["job"]) for job in manifest["jobs"]
        if job["inspectable"] and job["workflow"] in targets
    }
    namespaces = {rule["namespace"]: name for name, rule in rules.items()}
    with tempfile.TemporaryDirectory(prefix="workflow-policy-") as temporary:
        data = Path(temporary) / "data.json"
        data.write_text(
            json.dumps({"params": {name: rule["params"] for name, rule in rules.items()}}),
            encoding="utf-8",
        )
        files = {}
        # Rules see only jobs with steps, as JSON to avoid Conftest's YAML 1.1 coercion.
        for relative_path in targets:
            workflow = workflows[relative_path]
            normalized = Path(temporary) / Path(relative_path).name
            normalized.write_text(
                json.dumps(
                    {**workflow, "jobs": {
                        job_id: job for job_id, job in workflow["jobs"].items() if "uses" not in job
                    }},
                    default=json_value,
                ),
                encoding="utf-8",
            )
            files[str(normalized)] = relative_path
        conftest_config = Path(temporary) / "conftest.toml"
        conftest_config.touch()
        command = [
            "conftest", "--config-file", str(conftest_config), "test",
            "--parser", "json", "--output", "json", "--data", str(data),
        ]
        for namespace in namespaces:
            command.extend(["--namespace", namespace])
        for policy in dict.fromkeys(str(rule["policy"]) for rule in rules.values()):
            command.extend(["--policy", policy])
        result = subprocess.run(
            [*command, *files], cwd=root, capture_output=True, text=True, check=False,
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
                or entry.get("namespace") not in namespaces
                for entry in results
            )
            or {(entry["filename"], entry["namespace"]) for entry in results}
            != {(file, namespace) for file in files for namespace in namespaces}
        ):
            raise ValueError("Conftest did not return results for every workflow and rule")
        findings = {}
        reported = 0
        try:
            for entry in results:
                rule = namespaces[entry["namespace"]]
                failures = entry.get("failures") or []
                # A namespace without deny rules, such as a misnamed package, would pass silently.
                if not entry.get("successes") and not failures:
                    raise ValueError(f"Conftest evaluated no policy for rule {rule}")
                for failure in failures:
                    metadata = failure["metadata"]
                    finding = {
                        "workflow": files[entry["filename"]],
                        "job": metadata["job"],
                        "rule": metadata["rule"],
                        "message": failure["msg"],
                    }
                    if rule == REQUIRED_ACTIONS:
                        finding["action"] = metadata["action"]
                    if (
                        finding["rule"] != rule or not isinstance(finding["message"], str)
                        or (finding["workflow"], finding["job"]) not in inspectable
                        or (
                            rule == REQUIRED_ACTIONS
                            and finding["action"] not in rules[rule]["params"]["actions"]
                        )
                    ):
                        raise ValueError("Conftest returned an unexpected violation")
                    reported += 1
                    if rule in checked.get((finding["workflow"], finding["job"]), ()):
                        findings[tuple(finding.values())] = finding
        except (KeyError, TypeError) as error:
            raise ValueError("Conftest returned invalid violation metadata") from error
        if result.returncode == 1 and not reported:
            raise ValueError("Conftest failed without reporting any violations")
        return list(findings.values())


def build_report(manifest, findings, error=None):
    by_job = {}
    for finding in findings:
        by_job.setdefault((finding["workflow"], finding["job"]), []).append(finding)
    jobs = []
    for job in manifest["jobs"]:
        row = {
            "workflow": job["workflow"], "job": job["job"], "status": "passed",
            "rules": job["rules"],
            "findings": by_job.get((job["workflow"], job["job"]), []),
            "exclusions": job["exclusions"],
        }
        if not job["rules"]:
            row["status"] = "excluded"
        elif error:
            row["status"] = "error"
        elif not job["inspectable"]:
            row["status"] = "uninspectable"
        elif row["findings"]:
            row["status"] = "failed"
        jobs.append(row)
    checked = [job for job in jobs if job["status"] in {"passed", "failed"}]
    checks = sum(len(job["rules"]) for job in checked)
    failed_checks = sum(len({finding["rule"] for finding in job["findings"]}) for job in checked)
    failed_jobs = sum(job["status"] in {"failed", "uninspectable"} for job in jobs)
    return {
        "status": "error" if error else "failed" if failed_jobs else "passed",
        "rules": manifest["rules"],
        "summary": {
            "workflows": len(manifest["workflows"]),
            "selected_jobs": sum(job["status"] != "excluded" for job in jobs),
            "excluded_jobs": sum(job["status"] == "excluded" for job in jobs),
            "rules": len(manifest["rules"]),
            "checks": checks,
            "passed_checks": checks - failed_checks,
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
        f"Rules: {', '.join(report['rules']) or 'none'}.",
        f"{summary['selected_jobs']} selected jobs across {summary['workflows']} workflows; "
        f"{summary['excluded_jobs']} excluded.",
        f"Rule checks: {summary['checks']} "
        f"({summary['passed_checks']} passed, {summary['failed_checks']} failed).",
        "",
    ]
    for error in report["errors"]:
        lines.extend([markdown_cell(error), ""])
    lines.extend([
        "| Workflow | Job | Result | Rule checks | Details |",
        "| --- | --- | --- | --- | --- |",
    ])
    for job in report["jobs"]:
        checks = "-"
        details = []
        if job["status"] in {"passed", "failed"}:
            failed = len({finding["rule"] for finding in job["findings"]})
            checks = f"{len(job['rules']) - failed}/{len(job['rules'])} passed"
            details = [finding["message"] for finding in job["findings"]] or ["All checked rules passed"]
        elif job["status"] == "uninspectable":
            details = [UNINSPECTABLE]
        elif job["status"] == "error":
            details = list(report["errors"])
        details.extend(describe_exclusions(job["exclusions"]))
        lines.append(
            f"| {markdown_cell(job['workflow'])} | {markdown_cell(job['job'])} "
            f"| {job['status'].capitalize()} | {checks} | {markdown_cell(chr(10).join(details))} |"
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
    print(f"Rules: {', '.join(report['rules'])}.")
    print(
        f"{summary['selected_jobs']} selected jobs across {summary['workflows']} workflows; "
        f"{summary['excluded_jobs']} excluded."
    )
    print(
        f"Rule checks: {summary['checks']} "
        f"({summary['passed_checks']} passed, {summary['failed_checks']} failed)."
    )
    print(
        f"Jobs: {summary['passed_jobs']} passed, {summary['failed_jobs']} failed "
        f"({summary['uninspectable_jobs']} uninspectable)."
    )
    for workflow in dict.fromkeys(job["workflow"] for job in report["jobs"]):
        jobs = [job for job in report["jobs"] if job["workflow"] == workflow]
        checked = [job for job in jobs if job["status"] in {"passed", "failed"}]
        checks = sum(len(job["rules"]) for job in checked)
        failures = sum(len({finding["rule"] for finding in job["findings"]}) for job in checked)
        selected = sum(job["status"] != "excluded" for job in jobs)
        display_path = workflow.replace("\r", "\\r").replace("\n", "\\n")
        print(f"{display_path}: {selected} selected jobs, {checks} rule checks, {failures} failed.")
    for finding in report["findings"]:
        path = annotation_value(finding["workflow"], property_value=True)
        print(f"::error file={path},line=1::{annotation_value(finding['message'])}")
    for job in report["jobs"]:
        if job["status"] == "uninspectable":
            path = annotation_value(job["workflow"], property_value=True)
            message = (
                f"job {job['job']} calls a reusable workflow; "
                "inspect it separately and add an explicit exception"
            )
            print(f"::error file={path},line=1::{annotation_value(message)}")


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
    manifest = {"rules": [], "workflows": [], "jobs": []}
    findings = []
    error = None
    try:
        root = args.root.resolve()
        config_file = root / args.config
        try:
            config_path = config_file.resolve().relative_to(root).as_posix()
        except ValueError:
            config_path = config_file.as_posix()
        text = config_file.read_text(encoding="utf-8")
        yaml = YAML(typ="safe", pure=True)
        config = yaml.load(text)
        validate_config(config)
        rules = load_rules(config, yaml)
        exceptions = [
            *located_exceptions(
                config.get("exceptions", []), yaml.compose(text), config_path, "config",
            ),
            *(entry for rule in rules.values() for entry in rule["exceptions"]),
        ]
        manifest, workflows = select_jobs(root, rules, exceptions)
        for job in manifest["jobs"]:
            if job["exclusions"]:
                reasons = "; ".join(describe_exclusions(job["exclusions"]))
                print(f"SKIP {job['workflow']}:{job['job']}: {reasons}", file=sys.stderr)
        if args.select_only:
            print(json.dumps(manifest, indent=2))
            return 0
        findings = evaluate(root, manifest, workflows, rules)
    except (OSError, ValueError, YAMLError) as failure:
        error = str(failure)
    report = build_report(manifest, findings, error)
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
