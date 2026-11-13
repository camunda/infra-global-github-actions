# 🐍 Workflow policy check (Python rules)

An experimental port of [`workflow-policy`](../workflow-policy/README.md) with no policy engine: each preset's rule is a Python function called on the jobs the checker has already parsed. It is compared with the Conftest and Checkov variants in [the workflow policy comparison](../docs/workflow-policy-comparison.md#-conftest-checkov-and-python-rules-side-by-side).

Configuration, exceptions, inline directives, outputs, and exit statuses are the same as in [`workflow-policy`](../workflow-policy/README.md), and the caller workflow differs only in the action path. The only dependency is `ruamel.yaml`; no binary is downloaded.

## 🧩 Presets

A preset is `presets/<name>/preset.yml`, unchanged, plus `rule.py` in place of the Rego package. `rule.py` defines `check(job, params)`:

| Argument or result | Contents |
| --- | --- |
| `job` | A copy of one job with steps, as ruamel.yaml parses it (YAML 1.2, like GitHub). Jobs that are excluded or call a reusable workflow are never passed. |
| `params` | The preset's effective parameters: its defaults with the repository's overrides |
| Each yielded value | One finding, a non-empty message. A job can have any number; a repeated message is reported once. |

The checker prefixes each message with `job <id>: ` and records it under the preset's name. A rule that raises or yields anything other than a non-empty string fails the check with an error (exit status 2), never a pass.

```python
def check(job, params):
    steps = job["steps"]
    if not steps or not uses(params["first-step"], steps[0]):
        yield f"first step must use {params['first-step']}"
```

## 🔬 Tests

```bash
python3.13 -m venv .venv
.venv/bin/pip install -r requirements.txt pytest
.venv/bin/python -m pytest
```

| File | Covers |
| --- | --- |
| `tests/test_build_monitoring_rule.py` | The cases of the Conftest preset's `policy_test.rego` |
| `tests/test_runner.py` | One finding per distinct message, rules isolated from each other, a broken rule as an error |
| `tests/test_parity.py` | Same exit status, `report.json`, and `summary.md` as `../workflow-policy` on nine repositories. Skipped without `conftest` on `PATH`. |

To check a local repository, set `POLICY` to this folder and `REPO` to the repository:

```bash
python3 "$POLICY/check.py" --root "$REPO" --config .github/workflow-policy.yml --report-dir /tmp/workflow-policy
```
