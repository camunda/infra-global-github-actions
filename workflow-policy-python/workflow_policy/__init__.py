"""Workflow job policy check: presets as Python rules.

check.py at the action root is the entry point. Each module is one stage:

- model: the exclusion, exception, and rule types passed between stages
- yaml_documents: the YAML loader and node lookup the stages share
- config: the configuration file and the presets it extends
- directives: inline `# workflow-policy: skip-*` directives in workflow files
- selection: workflow validation and the rules each job is checked against
- runner: running each preset's rule and collecting its findings
- report: the JSON report, the Markdown job summary, and the console output

check.py runs the stages in this order:

1. config.load_config returns the rules ({preset name: Rule}), the configured exceptions, and the parameter overrides.
2. selection.select_jobs returns the manifest and the parsed workflows. The manifest lists every job with its `calls`, its `exclusions`, and the `rules` it is checked against: the configured rules minus those an exclusion covers.
3. runner.evaluate calls each checked rule's `check(job, params)` on a copy of the parsed job, and returns the findings (workflow, job, rule, message) of every message it yields.
4. report.build_report combines the manifest and the findings into the report that markdown_summary and print_report render.

An OSError, ValueError, or YAMLError in any stage becomes the report's error; a rule that raises becomes a ValueError. The exit status is 0 for passed, 1 for findings, and 2 for an error.
"""
