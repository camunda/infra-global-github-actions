#!/bin/bash
# Writes the fixtures served by test/bin/gh into the directory given as $1.
#
# Open backport PRs opened by "backport-action", with their ages relative to now:
#   #101  stable/8.8        3 days old   -> stale with the default 24h threshold
#   #102  self-managed/1.0  3 days old   -> stale with the default 24h threshold
#   #103  self-managed/1.1  1 hour old   -> only stale with a threshold of 1h or less
#   #104  release/9.0       3 days old   -> never a backport target
# Open backport PRs opened by "camunda-hub-helper" (camunda-hub's backport bot), see below.
set -euo pipefail

dir="$1"
mkdir -p "$dir"

old=$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)
recent=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)

jq -n --arg old "$old" --arg recent "$recent" '
  def pr($n; $base; $created): {
    number: $n,
    title: "[Backport \($base)] Fix \($n)",
    url: "https://github.com/camunda/test/pull/\($n)",
    body: "Backport of #1\($n)",
    createdAt: $created,
    isDraft: false,
    baseRefName: $base,
    author: {login: "backport-action"},
    assignees: [{login: "alice"}],
    labels: [],
    mergeable: "MERGEABLE"
  };
  [pr(101; "stable/8.8"; $old), pr(102; "self-managed/1.0"; $old), pr(103; "self-managed/1.1"; $recent), pr(104; "release/9.0"; $old)]
' > "$dir/prs-backport-action.json"

# camunda-hub's backport workflow opens its PRs as "camunda-hub-helper".
#   #105  self-managed/1.2  3 days old   -> only found when backport_authors includes camunda-hub-helper
jq -n --arg old "$old" '
  [{
    number: 105,
    title: "[Backport self-managed/1.2] Fix 105",
    url: "https://github.com/camunda/test/pull/105",
    body: "Backport of #1105",
    createdAt: $old,
    isDraft: false,
    baseRefName: "self-managed/1.2",
    author: {login: "camunda-hub-helper"},
    assignees: [{login: "alice"}],
    labels: [],
    mergeable: "MERGEABLE"
  }]
' > "$dir/prs-camunda-hub-helper.json"

jq -n '{title: "Original fix", url: "https://github.com/camunda/test/pull/1", author: {login: "bob"}, assignees: [], reviews: []}' \
  > "$dir/original-pr.json"
