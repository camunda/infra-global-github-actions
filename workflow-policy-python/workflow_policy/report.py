"""The JSON report, the Markdown job summary, and the console output."""

from collections import Counter
from html import escape
import sys

from .model import location


# Shown only in the Markdown summary; an error means the check could not finish.
STATUS_EMOJI = {
    "passed": "🟢", "failed": "🔴", "error": "🔴", "excluded": "⚪", "reusable": "⚪",
}


def job_status(job, findings, error):
    if job["calls"] is not None:
        return "reusable"
    if not job["rules"]:
        return "excluded"
    if error:
        return "error"
    return "failed" if findings else "passed"


def failed_rules(job):
    """The number of rules with findings on the job."""
    return len({finding["rule"] for finding in job["findings"]})


def tally(jobs):
    """Return (selected jobs, rule checks, failed rule checks) over report jobs.

    A rule check is one rule evaluated on one passed or failed job.
    """
    checked = [job for job in jobs if job["status"] in {"passed", "failed"}]
    return (
        sum(job["status"] not in {"excluded", "reusable"} for job in jobs),
        sum(len(job["rules"]) for job in checked),
        sum(map(failed_rules, checked)),
    )


def build_report(manifest, findings, error):
    by_job = {}
    for finding in findings:
        by_job.setdefault((finding["workflow"], finding["job"]), []).append(finding)
    jobs = []
    for job in manifest["jobs"]:
        job_findings = by_job.get((job["workflow"], job["job"]), [])
        jobs.append({
            "workflow": job["workflow"], "job": job["job"],
            "status": job_status(job, job_findings, error),
            "calls": job["calls"], "rules": job["rules"],
            "findings": job_findings, "exclusions": job["exclusions"],
        })
    statuses = Counter(job["status"] for job in jobs)
    selected, checks, failed_checks = tally(jobs)
    return {
        "status": "error" if error else "failed" if statuses["failed"] else "passed",
        "rules": manifest["rules"],
        "overrides": manifest["overrides"],
        "summary": {
            "workflows": len(manifest["workflows"]),
            "selected_jobs": selected,
            "excluded_jobs": statuses["excluded"],
            "rules": len(manifest["rules"]),
            "checks": checks,
            "passed_checks": checks - failed_checks,
            "failed_checks": failed_checks,
            "passed_jobs": statuses["passed"],
            "failed_jobs": statuses["failed"],
            "reusable_jobs": statuses["reusable"],
        },
        "jobs": jobs,
        "findings": findings,
        "errors": [error] if error else [],
    }


def describe_override(override):
    value = override["value"]
    value = ", ".join(value) if isinstance(value, list) else value
    where = location(override["file"], override["line"])
    return f"{override['rule']}: {override['param']} = {value} ({where})"


def describe_exclusions(exclusions):
    return [
        ("" if exclusion["rule"] is None else f"{exclusion['rule']}: ")
        + f"{exclusion['reason']} ({exclusion['source']}, "
        f"{location(exclusion['file'], exclusion['line'])})"
        for exclusion in exclusions
    ]


def summary_sentences(summary):
    """The job and rule check counts shared by the job summary and the console output."""
    return [
        f"{summary['selected_jobs']} selected jobs across {summary['workflows']} workflows; "
        f"{summary['excluded_jobs']} excluded; {summary['reusable_jobs']} call reusable workflows.",
        f"Rule checks: {summary['checks']} "
        f"({summary['passed_checks']} passed, {summary['failed_checks']} failed).",
    ]


def markdown_cell(value):
    value = escape(str(value)).replace("|", "&#124;").replace("\r", "").replace("\n", "<br>")
    return f"<code>{value}</code>"


def markdown_summary(report):
    lines = [
        "## Workflow policy", "",
        f"**Status: {STATUS_EMOJI[report['status']]} {report['status'].upper()}**", "",
        f"Rules: {', '.join(report['rules']) or 'none'}.",
        *summary_sentences(report["summary"]),
        "",
    ]
    if report["overrides"]:
        lines.extend(["Parameter overrides:", ""])
        lines.extend(
            f"- {markdown_cell(describe_override(override))}" for override in report["overrides"]
        )
        lines.append("")
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
            checks = f"{len(job['rules']) - failed_rules(job)}/{len(job['rules'])} passed"
            details = (
                [finding["message"] for finding in job["findings"]] or ["All checked rules passed"]
            )
        elif job["status"] == "reusable":
            details = [f"Calls reusable workflow {job['calls']}"]
        elif job["status"] == "error":
            details = list(report["errors"])
        details.extend(describe_exclusions(job["exclusions"]))
        cell = markdown_cell("\n".join(details))
        lines.append(
            f"| {markdown_cell(job['workflow'])} | {markdown_cell(job['job'])} "
            f"| {STATUS_EMOJI[job['status']]} {job['status'].capitalize()} | {checks} | {cell} |"
        )
    return "\n".join(lines) + "\n"


def annotation_value(value, property_value=False):
    """Escape a workflow command value; a property value also escapes ':' and ','."""
    value = str(value).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    if property_value:
        value = value.replace(":", "%3A").replace(",", "%2C")
    return value


def print_skips(manifest):
    """Print each job that calls a reusable workflow or has exclusions, with the reasons."""
    for job in manifest["jobs"]:
        if job["calls"] is not None:
            reasons = f"calls reusable workflow {job['calls']}"
        elif job["exclusions"]:
            reasons = "; ".join(describe_exclusions(job["exclusions"]))
        else:
            continue
        print(f"SKIP {job['workflow']}:{job['job']}: {reasons}", file=sys.stderr)


def print_report(report):
    if report["errors"]:
        for error in report["errors"]:
            print(f"workflow-policy: {error}", file=sys.stderr)
        return
    summary = report["summary"]
    print(f"Rules: {', '.join(report['rules'])}.")
    for override in report["overrides"]:
        print(f"Override: {describe_override(override)}")
    for sentence in summary_sentences(summary):
        print(sentence)
    print(f"Jobs: {summary['passed_jobs']} passed, {summary['failed_jobs']} failed.")
    by_workflow = {}
    for job in report["jobs"]:
        by_workflow.setdefault(job["workflow"], []).append(job)
    for workflow, jobs in by_workflow.items():
        selected, checks, failures = tally(jobs)
        # Escaped so a file name cannot start a new workflow command line.
        display_path = workflow.replace("\r", "\\r").replace("\n", "\\n")
        print(f"{display_path}: {selected} selected jobs, {checks} rule checks, {failures} failed.")
    for finding in report["findings"]:
        path = annotation_value(finding["workflow"], property_value=True)
        print(f"::error file={path},line=1::{annotation_value(finding['message'])}")
