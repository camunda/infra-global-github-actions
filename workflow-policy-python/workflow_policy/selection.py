"""Workflow validation and the rules each job is checked against."""

from dataclasses import asdict

from .directives import inline_exclusions
from .model import location
from .yaml_documents import YAML_LOADER


NEVER_CHECKED = "calls a reusable workflow, which is never checked"


def check_job(relative_path, job_id, job):
    """Raise unless the job is a named mapping with a list of steps or a reusable workflow call."""
    if not isinstance(job_id, str) or not isinstance(job, dict):
        raise ValueError(f"{relative_path}: each job must be a named mapping")
    if "uses" in job:
        if not isinstance(job["uses"], str):
            raise ValueError(f"{relative_path}:{job_id}: uses must be a reusable workflow path")
    elif not isinstance(job.get("steps"), list) or not all(
        isinstance(step, dict) for step in job["steps"]
    ):
        raise ValueError(f"{relative_path}:{job_id}: expected a list of step mappings")


def select_jobs(root, rules, exceptions):
    """Validate every workflow and decide which rules each job is checked against.

    A job that calls a reusable workflow is never checked: a called workflow in this repository
    is checked as its own file, and one from another repository is outside this check. Each
    configured exception must match a checked job.
    """
    directory = root / ".github" / "workflows"
    paths = sorted([*directory.glob("*.yml"), *directory.glob("*.yaml")])
    if not paths:
        raise ValueError(f"no workflow files found in {directory}")
    rule_names = list(rules)
    workflows, jobs = {}, []
    checked_matches, caller_matches = set(), set()
    for path in paths:
        # utf-8-sig drops a BOM so comment columns match the parser's.
        text = path.read_text(encoding="utf-8-sig")
        workflow = YAML_LOADER.load(text)
        relative_path = path.relative_to(root).as_posix()
        if (
            not isinstance(workflow, dict)
            or not isinstance(workflow.get("jobs"), dict)
            or not workflow["jobs"]
        ):
            raise ValueError(f"{relative_path}: expected a non-empty jobs mapping")
        workflow_exclusions, job_exclusions = inline_exclusions(
            text, YAML_LOADER.compose(text), relative_path, rule_names
        )
        for job_id, job in workflow["jobs"].items():
            check_job(relative_path, job_id, job)
            matches = {
                index for index, entry in enumerate(exceptions)
                if entry.covers(relative_path, job_id)
            }
            calls = job.get("uses")
            if calls is not None:
                if job_id in job_exclusions:
                    directive = job_exclusions[job_id][0]
                    raise ValueError(
                        f"{location(directive.file, directive.line)}: job {job_id} "
                        f"{NEVER_CHECKED}; remove the directive"
                    )
                caller_matches.update(matches)
                checked_rules, exclusions = [], []
            else:
                checked_matches.update(matches)
                # Every exception covering the job is reported, so removing one shows what remains.
                exclusions = [
                    *workflow_exclusions, *job_exclusions.get(job_id, []),
                    *(exceptions[index].exclusion for index in sorted(matches)),
                ]
                skipped = {exclusion.rule for exclusion in exclusions}
                # An exclusion without a rule skips every rule.
                checked_rules = (
                    [] if None in skipped else [rule for rule in rules if rule not in skipped]
                )
            jobs.append({
                "workflow": relative_path, "job": job_id, "calls": calls,
                "rules": checked_rules,
                "exclusions": [asdict(exclusion) for exclusion in exclusions],
            })
        if workflow_exclusions and all("uses" in job for job in workflow["jobs"].values()):
            directive = workflow_exclusions[0]
            raise ValueError(
                f"{location(directive.file, directive.line)}: every job in the workflow "
                f"{NEVER_CHECKED}; remove the directive"
            )
        workflows[relative_path] = workflow
    for index, entry in enumerate(exceptions):
        if index in checked_matches:
            continue
        where = location(entry.exclusion.file, entry.exclusion.line)
        if index in caller_matches:
            raise ValueError(
                f"{where}: exception #{index + 1} matches only jobs that call "
                "reusable workflows, which are never checked"
            )
        raise ValueError(f"{where}: exception #{index + 1} does not match any job")
    return {"rules": rule_names, "workflows": list(workflows), "jobs": jobs}, workflows
