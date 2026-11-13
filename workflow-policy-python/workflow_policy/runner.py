"""Running each preset's rule on the selected jobs and collecting its findings."""

import copy
import sys


def evaluate(manifest, workflows, rules):
    """Run each job's checked rules; every distinct message a rule yields is one finding.

    A rule that raises or yields anything but a non-empty string fails the check, so a bug in a
    rule is an error, never a pass.
    """
    findings = []
    for entry in manifest["jobs"]:
        workflow, job_id = entry["workflow"], entry["job"]
        for name in entry["rules"]:
            rule = rules[name]
            where = f"rule {name} on {workflow}:{job_id}"
            try:
                # A copy, so a rule cannot change what the next rule sees.
                job = copy.deepcopy(workflows[workflow]["jobs"][job_id])
                messages = list(rule.check(job, rule.params))
            except Exception as error:
                raise ValueError(f"{where} failed: {error!r}") from error
            if not all(isinstance(message, str) and message for message in messages):
                raise ValueError(f"{where} yielded a finding that is not a message")
            findings.extend(
                {
                    "workflow": workflow, "job": job_id, "rule": name,
                    "message": f"job {job_id}: {message}",
                }
                # Keyed by content, so a repeated finding is reported once.
                for message in dict.fromkeys(messages)
            )
    if not any(entry["rules"] for entry in manifest["jobs"]):
        print(
            "No jobs selected; every job is excluded or calls a reusable workflow.",
            file=sys.stderr,
        )
    return findings
