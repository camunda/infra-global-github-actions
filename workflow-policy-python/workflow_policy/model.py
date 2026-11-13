"""The exclusion, exception, and rule types passed between the stages."""

from collections.abc import Callable, Iterable
from dataclasses import dataclass


def location(file, line):
    """`file:line`, or the file alone when the line is unknown."""
    return file if line is None else f"{file}:{line}"


@dataclass(frozen=True)
class Exclusion:
    """Why a job skips one rule, or every rule when `rule` is None, and where that is declared.

    Its fields, in order, are the keys of each entry in a report's `exclusions` list.
    """

    source: str
    file: str
    line: int | None
    reason: str
    rule: str | None


@dataclass(frozen=True)
class PolicyException:
    """A configured exception: the jobs it matches and the exclusion it grants them."""

    workflow: str
    jobs: tuple[str, ...]
    exclusion: Exclusion

    def covers(self, relative_path, job_id):
        """Whether the exception matches the job."""
        return self.workflow in ("*", relative_path) and (
            job_id in self.jobs or "*" in self.jobs
        )


@dataclass(frozen=True)
class Rule:
    """A loaded preset: the `check` function of its rule.py, and its effective parameters."""

    check: Callable[[dict, dict], Iterable[str]]
    params: dict
