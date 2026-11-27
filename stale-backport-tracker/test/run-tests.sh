#!/bin/bash
# Offline tests of the stale-backport-tracker scripts, against a stubbed GitHub CLI.
# Run from anywhere: bash stale-backport-tracker/test/run-tests.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/../scripts"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export FIXTURE_DIR="$work/fixtures"
export PATH="$here/bin:$PATH"
export GH_TOKEN=unused
export REPOSITORIES="camunda/test"
bash "$here/make-fixtures.sh" "$FIXTURE_DIR"

failures=0
check() { # check <description> <actual> <expected>
  if [[ "$2" == "$3" ]]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1: expected '$3', got '$2'"
    failures=$((failures + 1))
  fi
}
contains() { # contains <description> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1: '$3' not found in: $2"
    failures=$((failures + 1))
  fi
}
branches() { jq -r '[.[].backport_prs[].target_branch] | sort | join(",")'; }

# --- collect ---------------------------------------------------------------
default=$(bash "$scripts/collect-stale-backports.sh" 2>/dev/null)
check "default prefix keeps stable/* only" "$(branches <<< "$default")" "stable/8.8"

hub=$(TARGET_BRANCH_PREFIX="self-managed/" bash "$scripts/collect-stale-backports.sh" 2>/dev/null)
check "self-managed/ prefix drops stable/* and recent PRs" "$(branches <<< "$hub")" "self-managed/1.0"

short=$(TARGET_BRANCH_PREFIX="self-managed/" STALE_HOURS_THRESHOLD=1 bash "$scripts/collect-stale-backports.sh" 2>/dev/null)
check "threshold of 1h includes the 1h old PR" "$(branches <<< "$short")" "self-managed/1.0,self-managed/1.1"

exact=$(TARGET_BRANCH="self-managed/1.0" TARGET_BRANCH_PREFIX="stable/" bash "$scripts/collect-stale-backports.sh" 2>/dev/null)
check "TARGET_BRANCH overrides the prefix" "$(branches <<< "$exact")" "self-managed/1.0"

none=$(BACKPORT_AUTHORS="someone-else" bash "$scripts/collect-stale-backports.sh" 2>/dev/null)
check "unknown author finds nothing" "$none" "[]"

hub_author=$(TARGET_BRANCH_PREFIX="self-managed/" BACKPORT_AUTHORS="camunda-hub-helper" bash "$scripts/collect-stale-backports.sh" 2>/dev/null)
check "camunda-hub's backport author is found with backport_authors" "$(branches <<< "$hub_author")" "self-managed/1.2"
hub_default=$(TARGET_BRANCH_PREFIX="self-managed/" bash "$scripts/collect-stale-backports.sh" 2>/dev/null)
check "camunda-hub's backport author is not a default" "$(branches <<< "$hub_default")" "self-managed/1.0"

check "repository is set on each group" "$(jq -r '.[0].repository' <<< "$hub")" "camunda/test"
check "original PR is resolved" "$(jq -r '.[0].original_pr_title' <<< "$hub")" "Original fix"

# --- format ----------------------------------------------------------------
report=$(bash "$scripts/format-slack-report.sh" <<< "$hub")
check "report is a blocks array" "$(jq -r '.blocks | type' <<< "$report")" "array"
contains "default title" "$report" "*Stale Backport PRs*"

custom=$(REPORT_TITLE="Stale Hub Backports" bash "$scripts/format-slack-report.sh" <<< "$hub")
contains "custom title" "$custom" "*Stale Hub Backports*"

fallback=$(SLACK_USER_MAP_FALLBACK=true SLACK_CC="<!subteam^S1|@team>" bash "$scripts/format-slack-report.sh" <<< "$hub")
contains "fallback warning mentions the cc" "$fallback" "cc <!subteam^S1|@team>_"
nocc=$(SLACK_USER_MAP_FALLBACK=true bash "$scripts/format-slack-report.sh" <<< "$hub")
contains "fallback warning without cc" "$nocc" "instead of Slack mentions._"

clean=$(bash "$scripts/format-slack-report.sh" <<< '[]')
contains "clean report, default title" "$clean" "No stale backport PRs"
clean_custom=$(REPORT_TITLE="Stale Hub Backports" bash "$scripts/format-slack-report.sh" <<< '[]')
contains "clean report keeps a custom title findable" "$clean_custom" "Stale Hub Backports"

# --- notify (dry run: no GitHub writes, and the stub cannot write anyway) ---
notify=$(DRY_RUN=true bash "$scripts/notify-stale-backports.sh" <<< "$hub" 2>&1)
contains "dry run would comment on the backport PR" "$notify" "Would comment on PR #102"
contains "dry run mentions the assignee" "$notify" "@alice"

# --- notify (real writes against the stub) -----------------------------------
set +e
ok_out=$(bash "$scripts/notify-stale-backports.sh" <<< "$hub" 2>&1)
ok_rc=$?
comment_out=$(STUB_FAIL=comment bash "$scripts/notify-stale-backports.sh" <<< "$hub" 2>&1)
comment_rc=$?
label_out=$(STUB_FAIL=edit bash "$scripts/notify-stale-backports.sh" <<< "$hub" 2>&1)
label_rc=$?
set -e
check "successful writes exit 0" "$ok_rc" "0"
contains "successful writes are counted" "$ok_out" "1 new, 0 re-notified, 0 skipped (recently notified), 0 failed"
check "a failed comment fails the run" "$comment_rc" "1"
contains "a failed comment is counted as failed" "$comment_out" "0 new, 0 re-notified, 0 skipped (recently notified), 1 failed"
check "a failed label fails the run" "$label_rc" "1"
contains "a failed label is reported" "$label_out" "Failed to add the stale-backport label"

if [[ "$failures" -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
