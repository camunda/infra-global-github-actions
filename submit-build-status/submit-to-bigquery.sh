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

# Create insertAll request payload; MONITOR_FIELDS is already ', "key": number, ...'.
PAYLOAD=$(printf '{"rows": [{"json": {%s%s}}]}' "$ROW" "$MONITOR_FIELDS")

# Submit to BigQuery REST API
echo "Submitting build status to BigQuery..."
curl -fsS -X POST \
  "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/datasets/${DATASET}/tables/${TABLE}/insertAll" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD"
