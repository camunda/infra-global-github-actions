#!/usr/bin/env python3
"""Experimental workflow job policy check: presets evaluated by Conftest."""

import argparse
import json
from pathlib import Path
import sys

# Import the package beside this script, not one from the caller's environment:
# PYTHONSAFEPATH or -P leaves the script's directory off sys.path, and PYTHONPATH
# could then supply another workflow_policy.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from ruamel.yaml.error import YAMLError

from workflow_policy.config import load_config
from workflow_policy.report import (
    build_report, markdown_summary, print_report, print_skips,
)
from workflow_policy.runner import evaluate
from workflow_policy.selection import select_jobs


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
    manifest = {"rules": [], "overrides": [], "workflows": [], "jobs": []}
    findings, error = [], None
    try:
        root = args.root.resolve()
        config_file = root / args.config  # pathlib join: relative to --root; absolute --config wins
        resolved = config_file.resolve()
        config_path = (
            resolved.relative_to(root) if resolved.is_relative_to(root) else config_file
        ).as_posix()
        text = config_file.read_text(encoding="utf-8")
        rules, exceptions, overrides = load_config(text, config_path)
        manifest, workflows = select_jobs(root, rules, exceptions)
        manifest["overrides"] = overrides
        print_skips(manifest)
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
    # Writing the report happens outside main's checks.
    except (OSError, ValueError, YAMLError) as error:
        print(f"workflow-policy: {error}", file=sys.stderr)
        sys.exit(2)
