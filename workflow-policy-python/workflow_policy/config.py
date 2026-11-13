"""The configuration file and the presets bundled with the action."""

import importlib.util
from pathlib import Path
import re
import sys

from ruamel.yaml.nodes import MappingNode, SequenceNode

from .model import Exclusion, PolicyException, Rule
from .yaml_documents import YAML_LOADER, child


EXTENDS_SYNTAX = (
    "configuration: extends must be a non-empty list of distinct preset names"
)
PRESET_NAME = re.compile(r"[a-z][a-z0-9-]*")
# The action root, which holds check.py, this package, and the presets.
ACTION_DIRECTORY = Path(__file__).resolve().parent.parent
PRESETS = ACTION_DIRECTORY / "presets"


def has_wildcard(value):
    return any(character in value for character in "*?[]")


def is_workflow_path(value):
    """An exact path of a workflow file directly in .github/workflows."""
    return (
        isinstance(value, str)
        and Path(value).parent.as_posix() == ".github/workflows"
        and Path(value).suffix in {".yml", ".yaml"}
        and not has_wildcard(value)
    )


def is_job_id(value):
    """An exact job ID, or '*' for every job."""
    return (
        isinstance(value, str)
        and bool(value)
        and (value == "*" or not has_wildcard(value))
    )


def is_action_path(value):
    """An action path or pattern without `@ref`, such as ./**/.github/actions/x.

    `*` is the only wildcard accepted, so every pattern means the same to glob.translate.
    """
    return (
        isinstance(value, str)
        and "/" in value
        and "@" not in value
        and not any(
            character.isspace() or character in "?[]{}\\" for character in value
        )
    )


def validate_exceptions(exceptions, rule_names):
    """Check the configured exceptions; `rule_names` lists the allowed `rule` values."""
    if not isinstance(exceptions, list):
        raise ValueError("configuration: exceptions must be a list")
    required = {"workflow", "jobs", "reason"}
    for entry in exceptions:
        if not isinstance(entry, dict) or not required <= set(entry) <= required | {"rule"}:
            raise ValueError(
                "configuration: each exception needs workflow, jobs, and reason, and accepts rule"
            )
        if entry["workflow"] != "*" and not is_workflow_path(entry["workflow"]):
            raise ValueError(
                "configuration: workflow must be an exact workflow path or '*'"
            )
        jobs = entry["jobs"]
        if not isinstance(jobs, list) or not jobs or not all(map(is_job_id, jobs)):
            raise ValueError(
                "configuration: jobs must be a non-empty list of exact IDs or '*'"
            )
        if not isinstance(entry["reason"], str) or not entry["reason"].strip():
            raise ValueError("configuration: each exception needs a non-empty reason")
        if "rule" in entry and entry["rule"] not in rule_names:
            raise ValueError(
                f"configuration: exception rule must be one of: {', '.join(rule_names)}"
            )


def preset_entry(entry):
    """Split an `extends` entry, a preset name or {name, params?}, into (name, overrides)."""
    if isinstance(entry, dict):
        if "name" not in entry or set(entry) - {"name", "params"}:
            raise ValueError(
                "configuration: an extends mapping needs name and accepts params"
            )
        name, overrides = entry["name"], entry.get("params", {})
        if "params" in entry and (not isinstance(overrides, dict) or not overrides):
            raise ValueError(
                f"configuration: params of preset {name} must be a non-empty mapping"
            )
    else:
        name, overrides = entry, {}
    if not isinstance(name, str) or not PRESET_NAME.fullmatch(name):
        raise ValueError(EXTENDS_SYNTAX)
    return name, overrides


def parse_config(config):
    """Validate the configuration and return its (preset name, overrides) entries in order."""
    if not isinstance(config, dict) or not {"extends"} <= set(config) <= {
        "extends",
        "exceptions",
    }:
        raise ValueError("configuration: expected extends and optional exceptions")
    presets = config["extends"]
    if not isinstance(presets, list) or not presets:
        raise ValueError(EXTENDS_SYNTAX)
    entries = [preset_entry(entry) for entry in presets]
    names = [name for name, _ in entries]
    if len(set(names)) != len(names):
        raise ValueError(EXTENDS_SYNTAX)

    validate_exceptions(config.get("exceptions", []), names)
    return entries


def override_params(name, defaults, overridable, overrides):
    """Replace the overridable preset parameters named in `overrides`.

    Parameters are action paths: a value keeps the shape of its default, a string or a non-empty
    list of strings.
    """
    label = f"configuration: preset {name}"
    unknown = sorted(str(key) for key in set(overrides) - set(defaults))
    if unknown:
        raise ValueError(
            f"{label} has no parameter {', '.join(unknown)}; "
            f"available parameters: {', '.join(defaults) or 'none'}"
        )
    fixed = [key for key in overrides if key not in overridable]
    if fixed:
        raise ValueError(
            f"{label}: parameter {', '.join(fixed)} cannot be overridden; "
            f"overridable parameters: {', '.join(overridable) or 'none'}"
        )
    params = dict(defaults)
    for key, value in overrides.items():
        is_list = isinstance(defaults[key], list)
        if is_list:
            valid = (
                isinstance(value, list)
                and bool(value)
                and all(map(is_action_path, value))
            )
        else:
            valid = is_action_path(value)
        if not valid:
            raise ValueError(
                f"{label}: parameter {key} must be "
                + (
                    "a non-empty list of unversioned action paths"
                    if is_list
                    else "an unversioned action path"
                )
                + ", such as actions/checkout"
            )
        # Repeated entries are kept once.
        params[key] = list(dict.fromkeys(value)) if is_list else value
    return params


def located_exceptions(entries, document, file):
    """Build the validated configured exceptions, each with its file and line."""
    node = child(document, "exceptions")
    nodes = node.value if isinstance(node, SequenceNode) else []
    return [
        PolicyException(
            workflow=entry["workflow"],
            jobs=tuple(entry["jobs"]),
            exclusion=Exclusion(
                source="config",
                file=file,
                # Entries brought in by a YAML merge key have no node of their own, so no line.
                line=nodes[index].start_mark.line + 1 if index < len(nodes) else None,
                reason=entry["reason"],
                rule=entry.get("rule"),
            ),
        )
        for index, entry in enumerate(entries)
    ]


def override_lines(document):
    """Map each `extends` entry index to {param: line} for the params it overrides."""
    extends = child(document, "extends")
    lines = {}
    for index, entry in enumerate(
        extends.value if isinstance(extends, SequenceNode) else []
    ):
        params = child(entry, "params")
        if isinstance(params, MappingNode):
            lines[index] = {
                key.value: key.start_mark.line + 1 for key, _ in params.value
            }
    return lines


def preset_rule(name, path):
    """Import the preset's rule.py once and return its `check` function."""
    module_name = "workflow_policy_presets." + name.replace("-", "_")
    if module_name not in sys.modules:
        spec = importlib.util.spec_from_file_location(module_name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        sys.modules[module_name] = module
    check = getattr(sys.modules[module_name], "check", None)
    if not callable(check):
        raise ValueError(f"preset {name}: rule.py must define a check(job, params) function")
    return check


def load_preset(name, overrides):
    """Load a preset bundled with the action: its rule and parameters.

    `overrides` replace the parameters the preset lists as `overridable`.
    """
    path = PRESETS / name / "preset.yml"
    if not path.is_file():
        available = ", ".join(
            sorted(preset.parent.name for preset in PRESETS.glob("*/preset.yml"))
        )
        raise ValueError(
            f"configuration: unknown preset {name}; available presets: {available}"
        )
    text = path.read_text(encoding="utf-8")
    preset = YAML_LOADER.load(text)
    label = f"preset {name}"
    if (
        not isinstance(preset, dict)
        or set(preset) - {"description", "params", "overridable"}
        or not isinstance(preset.get("description"), str)
        or not isinstance(preset.get("params", {}), dict)
    ):
        raise ValueError(f"{label}: expected description, params, and overridable")
    params = preset.get("params", {})
    overridable = preset.get("overridable", [])
    if (
        not isinstance(overridable, list)
        or len(set(overridable)) != len(overridable)
        or any(key not in params for key in overridable)
    ):
        raise ValueError(
            f"{label}: overridable must list distinct parameters of the preset"
        )
    return Rule(
        check=preset_rule(name, path.parent / "rule.py"),
        params=override_params(name, params, overridable, overrides),
    )


def load_config(text, config_path):
    """Return {name: Rule} in `extends` order, the configured exceptions, and every override.

    Each override records where it is set.
    """
    config = YAML_LOADER.load(text)
    entries = parse_config(config)
    document = YAML_LOADER.compose(text)
    lines = override_lines(document)
    rules, overrides = {}, []
    for index, (name, values) in enumerate(entries):
        rules[name] = load_preset(name, values)
        overrides.extend(
            {
                "rule": name,
                "param": key,
                "value": rules[name].params[key],
                "file": config_path,
                "line": lines.get(index, {}).get(key),
            }
            for key in values
        )
    exceptions = located_exceptions(config.get("exceptions", []), document, config_path)
    return rules, exceptions, overrides
