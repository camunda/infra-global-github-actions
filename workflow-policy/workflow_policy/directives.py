"""Inline `# workflow-policy: skip-job|skip-workflow` directives in workflow files.

Directives are found by a plain text search, so `# workflow-policy:` inside a `run:` script or a
quoted string is read as a directive too.
"""

import re

from ruamel.yaml.nodes import MappingNode

from .model import Exclusion
from .yaml_documents import child


# Case-insensitive, so a miscased directive fails the check.
DIRECTIVE = re.compile(r"#\s*workflow-policy:", re.IGNORECASE)
SKIP_DIRECTIVE = re.compile(
    r"#\s*workflow-policy:\s*skip-(job|workflow)(?:\s+rule=(\S+))?\s+(\S.*)"
)
SKIP_SYNTAX = "expected '# workflow-policy: skip-job|skip-workflow [rule=<rule>] <reason>'"


def job_id_lines(lines, jobs):
    """Map each job ID line, and the full-line comments right above it at its column, to job IDs.

    Flow-style jobs can share a line, so a line can map to several job IDs.
    """
    owners = {}
    for key, _ in jobs.value if isinstance(jobs, MappingNode) else []:
        line, column = key.start_mark.line, key.start_mark.column
        owners.setdefault(line, []).append(key.value)
        line -= 1
        while line >= 0 and lines[line].startswith(" " * column + "#"):
            owners.setdefault(line, []).append(key.value)
            line -= 1
    return owners


def inline_exclusions(text, document, relative_path, rule_names):
    """Return the workflow's exclusions and {job_id: exclusions} from skip directives.

    `skip-workflow` belongs in the comment lines before the workflow's first key.
    `skip-job` belongs to the job whose ID shares its line, or to the job ID directly
    below a block of full-line comments at that job ID's indentation. Without `rule=`,
    a directive skips every rule; otherwise a job or workflow takes one directive per rule.
    """
    lines = text.splitlines()
    first_key_line = document.value[0][0].start_mark.line
    owners = job_id_lines(lines, child(document, "jobs"))
    workflow_exclusions, job_exclusions = [], {}
    for line, content in enumerate(lines):
        found = DIRECTIVE.search(content)
        if not found:
            continue
        where = f"{relative_path}:{line + 1}"
        directive = SKIP_DIRECTIVE.fullmatch(content[found.start():].rstrip())
        # `skip-job rule=<rule>` with no reason matches with `rule=<rule>` as its reason.
        if not directive or directive[3].startswith("rule="):
            raise ValueError(f"{where}: {SKIP_SYNTAX}")
        scope, rule, reason = directive.groups()
        if scope == "workflow":
            if line >= first_key_line:
                raise ValueError(
                    f"{where}: place skip-workflow in the comment lines before "
                    "the workflow's first key"
                )
            target, exclusions = "the workflow", workflow_exclusions
        else:
            if len(owners.get(line, [])) != 1:
                raise ValueError(
                    f"{where}: place skip-job on a job ID line, or directly above "
                    "the job ID at the same indentation"
                )
            job_id = owners[line][0]
            target, exclusions = f"job {job_id}", job_exclusions.setdefault(job_id, [])
        if rule is not None and rule not in rule_names:
            raise ValueError(
                f"{where}: rule {rule} is not configured; "
                f"configured rules: {', '.join(rule_names)}"
            )
        present = [exclusion.rule for exclusion in exclusions]
        if present and None in (rule, *present):
            raise ValueError(
                f"{where}: {target} has a skip-{scope} directive without rule= "
                f"and another skip-{scope} directive"
            )
        if rule in present:
            raise ValueError(
                f"{where}: {target} has more than one skip-{scope} directive for rule {rule}"
            )
        exclusions.append(Exclusion(
            source="inline", file=relative_path, line=line + 1, reason=reason.strip(), rule=rule,
        ))
    return workflow_exclusions, job_exclusions
