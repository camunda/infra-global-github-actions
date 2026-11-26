#!/usr/bin/env bash
#
# Builds the build status row from the environment set by action.yml and inserts it with tabledata.insertAll.
# Bash only: job containers may lack jq.

set -eo pipefail

WORKFLOW_REF_PATH="${GITHUB_WORKFLOW_REF%@*}"
WORKFLOW_REF_PATH="${WORKFLOW_REF_PATH#"$GITHUB_REPOSITORY/"}"

# ── Parse BigQuery table name (format: project_id:dataset.table) ──
PROJECT_ID="${BIG_QUERY_TABLE_NAME%%:*}"
DATASET_TABLE="${BIG_QUERY_TABLE_NAME#*:}"
DATASET="${DATASET_TABLE%%.*}"
TABLE="${DATASET_TABLE#*.}"

# Print $1 as a JSON string, dropping control chars other than \n \r \t.
json_string() {
  local s="$1" bs=\\ q=\"
  # Unquoted on purpose: Bash < 4.3 keeps the replacement's inner quotes inside "${...}".
  s=${s//"$bs"/"$bs$bs"}
  s=${s//"$q"/"$bs$q"}
  s=${s//$'\n'/"${bs}n"}
  s=${s//$'\r'/"${bs}r"}
  s=${s//$'\t'/"${bs}t"}
  printf '"%s"' "$(printf '%s' "$s" | tr -d '\001-\037')"
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ── Row fields; each name is a BigQuery column and every value is JSON-escaped ──
ROW=""
add_field() { ROW="${ROW:+$ROW, }$(json_string "$1"): $(json_string "$2")"; }
add_field report_time "$(date -u '+%Y-%m-%d %H:%M:%S')"
add_field ci_url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
add_field workflow_name "$GITHUB_WORKFLOW"
add_field workflow_ref "$WORKFLOW_REF_PATH"
add_field job_name "${JOB_NAME_OVERRIDE:-$GITHUB_JOB}"
add_field build_id "$GITHUB_RUN_ID/$GITHUB_RUN_ATTEMPT"
add_field build_trigger "$GITHUB_EVENT_NAME"
add_field build_status "$BUILD_STATUS"
add_field build_ref "$GITHUB_REF"
add_field runner_name "$(lower "$RUNNER_NAME")"
add_field runner_arch "$(lower "$RUNNER_ARCH")"
add_field runner_os "$(lower "$RUNNER_OS")"
# Optional fields are sent only when set.
[ -z "$JOB_ID" ] || add_field job_id "$JOB_ID"
[ -z "$BUILD_BASE_REF" ] || add_field build_base_ref "$BUILD_BASE_REF"
[ -z "$BUILD_HEAD_REF" ] || add_field build_head_ref "$BUILD_HEAD_REF"
[ -z "$BUILD_DURATION_MILLIS" ] || add_field build_duration_milliseconds "$BUILD_DURATION_MILLIS"
[ -z "$USER_REASON" ] || add_field user_reason "$USER_REASON"
[ -z "$USER_DESCRIPTION" ] || add_field user_description "$USER_DESCRIPTION"
if [ -f "$RUNNER_INFO_RUNS_ON_FILE" ]; then
  # The runs-on label from GHA jobs represents the runner type for self-hosted runners.
  add_field runner_type "$(tr -cd '[:alnum:]_. -' < "$RUNNER_INFO_RUNS_ON_FILE")"
fi

# ── Tool install figures: camunda/infra-tools appends one JSON object per line to this file. ──
# The lines are opaque here: their fields belong to infra-tools. Blank lines are skipped.
TOOL_INSTALLS_FILE="$RUNNER_TEMP/ci-analytics/tool-installs.jsonl"
TOOL_INSTALLS_ITEMS=""
# Set TOOL_INSTALLS_ITEMS to the file's lines joined with commas; returns non-zero when the file can't be read.
read_tool_installs() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "${line//[[:space:]]/}" ] || TOOL_INSTALLS_ITEMS="${TOOL_INSTALLS_ITEMS:+$TOOL_INSTALLS_ITEMS,}$line"
  done < "$TOOL_INSTALLS_FILE"
}
# `if !`: set -e would otherwise end the step on an unreadable file.
if [ -f "$TOOL_INSTALLS_FILE" ] && ! read_tool_installs; then
  TOOL_INSTALLS_ITEMS=""
  echo "::warning::Cannot read $TOOL_INSTALLS_FILE; sending the build status without tool_installs."
fi

# Insert the row fields $1 plus MONITOR_FIELDS (already ', "key": number, ...') with the BigQuery REST API.
# The payload goes on stdin: Linux caps one argument at 128 KiB, and tool_installs can be larger.
# Prints the response and sets RESPONSE; returns curl's exit status, which -f makes non-zero on an HTTP error.
insert_row() {
  RESPONSE=$(printf '{"rows": [{"json": {%s%s}}]}' "$1" "$MONITOR_FIELDS" | curl -fsS -X POST \
    "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/datasets/${DATASET}/tables/${TABLE}/insertAll" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @-) || return
  printf '%s\n' "$RESPONSE"
}

echo "Submitting build status to BigQuery..."
if [ -n "$TOOL_INSTALLS_ITEMS" ]; then
  # insertAll takes a JSON column's value as a JSON-encoded string. It answers HTTP 200 with
  # insertErrors for a rejected row, which curl -f does not catch.
  if insert_row "$ROW, $(json_string tool_installs): $(json_string "[$TOOL_INSTALLS_ITEMS]")" \
    && [[ "$RESPONSE" != *'"insertErrors"'* ]]; then
    exit 0
  fi
  # A bad file must never lose the build status row.
  echo "::warning::BigQuery did not insert the row with tool_installs from $TOOL_INSTALLS_FILE; sending it again without them."
fi
# Without tool_installs, as before: a curl or HTTP error fails the step, and insertErrors are not checked.
insert_row "$ROW"
