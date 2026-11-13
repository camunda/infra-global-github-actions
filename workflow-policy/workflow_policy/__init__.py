"""Workflow job policy check: presets evaluated by Conftest.

check.py at the action root is the entry point. Each module is one stage:

- model: the exclusion, exception, and rule types passed between stages
- yaml_documents: the YAML loader and node lookup the stages share
- config: the configuration file and the presets it extends
- directives: inline `# workflow-policy: skip-*` directives in workflow files
- selection: workflow validation and the rules each job is checked against
- runner: running Conftest and collecting its findings
- report: the JSON report, the Markdown job summary, and the console output
"""
