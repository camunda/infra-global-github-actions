#!/usr/bin/env bash
# Runs Renovate's extraction with only the given preset (default: the published one) on the
# fixtures next to this script, and asserts which files it tracks the pull-request-1.1.0 pin in.
# Usage: test.sh [preset.json5]
set -euo pipefail

cd "$(dirname "$0")"
preset="$(realpath "${1:-../../renovate-action-versions.json5}")"
report="$(mktemp)"

# The preset is loaded as the global config file because the local platform cannot resolve
# `local>` or `github>` presets offline.
RENOVATE_CONFIG_FILE="${preset}" renovate \
  --platform=local \
  --dry-run=extract \
  --onboarding=false \
  --require-config=ignored \
  --enabled-managers=custom.regex \
  --report-type=file \
  --report-path="${report}"

dep="camunda/infra-global-github-actions/pull-request"
tracked="$(jq -r --arg dep "${dep}" \
  '.repositories.local.packageFiles.regex // [] | .[]
   | select(any(.deps[]; .depName == $dep and .currentValue == "1.1.0")) | .packageFile' \
  "${report}")"
scanned="$(jq -r '.repositories.local.packageFiles.regex // [] | .[].packageFile' "${report}")"

echo "Files where ${dep} 1.1.0 is tracked:"
echo "${tracked:-<none>}"

failed=0
for file in .github/workflows/ci.yml agents/_template/workflow.yml action.yml; do
  if ! grep -qxF "${file}" <<<"${tracked}"; then
    echo "FAIL: ${dep} 1.1.0 not extracted from ${file}" >&2
    failed=1
  fi
done
if grep -qxF README.md <<<"${scanned}"; then
  echo "FAIL: README.md was extracted, Markdown must not be scanned" >&2
  failed=1
fi

[[ "${failed}" -eq 0 ]] && echo "PASS"
exit "${failed}"
