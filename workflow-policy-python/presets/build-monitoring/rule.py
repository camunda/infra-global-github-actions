"""build-monitoring: start-build-monitor runs first, and the status submission runs last, best-effort.

Rule contract: the checker calls `check(job, params)` for each job with steps that the rule applies
to, with the preset's effective parameters, and reports each message it yields as a finding.
"""

import glob
import re


def action(step):
    """The action path of a `uses:` step without its `@ref`; None for a `run:` step."""
    uses = step.get("uses")
    return uses.split("@")[0] if isinstance(uses, str) else None


def uses(pattern, step):
    """`*` matches one path segment, `**` any number including none."""
    path = action(step)
    expression = glob.translate(pattern, recursive=True, include_hidden=True, seps="/")
    return path is not None and re.fullmatch(expression, path) is not None


def best_effort(step):
    condition = step.get("if")
    return (
        isinstance(condition, str) and "always()" in condition
        and step.get("continue-on-error") is True
    )


def check(job, params):
    steps = job["steps"]
    if not steps or not uses(params["first-step"], steps[0]):
        yield f"first step must use {params['first-step']}"
    observers = params["last-step-any-of"]
    if not steps or not any(uses(pattern, steps[-1]) for pattern in observers):
        yield f"last step must use one of {', '.join(observers)}"
    elif not best_effort(steps[-1]):
        yield "last step must set if: always() and continue-on-error: true"
