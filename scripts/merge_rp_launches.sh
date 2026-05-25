#!/usr/bin/env bash
# Copyright 2026 EPAM Systems — Apache License 2.0
# merge_rp_launches.sh — Query ReportPortal for launches matching a merge_group
# attribute, wait for them to finish, and merge them into a single launch.
# Portable: macOS + Ubuntu/Linux. Dependencies: curl, jq.
set -euo pipefail

# --- Configuration (env vars, overridable by CLI args) ---
RP_ENDPOINT="${RP_ENDPOINT:-${1:-}}"
RP_PROJECT="${RP_PROJECT:-${2:-}}"
RP_TOKEN="${RP_TOKEN:-${3:-}}"
RP_MERGE_GROUP="${RP_MERGE_GROUP:-${4:-}}"
RP_CI_RUN_ID="${RP_CI_RUN_ID:-${GITHUB_RUN_ID:-}}"
RP_EXPECTED_LAUNCHES="${RP_EXPECTED_LAUNCHES:-}"
RP_MERGED_LAUNCH_NAME="${RP_MERGED_LAUNCH_NAME:-"${RP_MERGE_GROUP:-} (merged)"}"
RP_MERGE_FINALIZE_TIMEOUT="${RP_MERGE_FINALIZE_TIMEOUT:-120}"

# --- Token masking ---
log() {
  local level="$1"; shift
  local msg="$*"
  if [[ -n "${RP_TOKEN:-}" ]]; then
    msg="${msg//$RP_TOKEN/***}"
  fi
  printf "%-5s %s\n" "$level" "$msg" >&2
}

# --- Proxy support ---
curl_opts=(-s -S --fail-with-body)
if [[ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]]; then
  curl_opts+=(--proxy "${HTTPS_PROXY:-${https_proxy:-}}")
fi

rp_curl() {
  curl "${curl_opts[@]}" \
    -H "Authorization: Bearer ${RP_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@" 2>&1 | while IFS= read -r line; do
      if [[ -n "${RP_TOKEN:-}" ]]; then
        printf '%s\n' "${line//$RP_TOKEN/***}"
      else
        printf '%s\n' "$line"
      fi
    done
}

# --- Retry with exponential backoff (3 attempts, no retry on 4xx) ---
rp_curl_retry() {
  local attempt=0 max=3 delay=2 http_code body
  while (( attempt < max )); do
    # Use a temp file for body so we can inspect http_code separately
    local tmpfile; tmpfile=$(mktemp)
    http_code=$(curl "${curl_opts[@]}" --fail-with-body -w '%{http_code}' -o "$tmpfile" \
      -H "Authorization: Bearer ${RP_TOKEN}" \
      -H "Content-Type: application/json" \
      "$@" 2>/dev/null) || true
    body=$(cat "$tmpfile")
    rm -f "$tmpfile"

    # Mask token in body
    if [[ -n "${RP_TOKEN:-}" ]]; then
      body="${body//$RP_TOKEN/***}"
    fi

    if [[ "$http_code" =~ ^2 ]]; then
      printf '%s' "$body"
      return 0
    elif [[ "$http_code" =~ ^4 ]]; then
      # No retry on 4xx
      log WARN "HTTP $http_code (no retry): ${body:0:200}"
      printf '%s' "$body"
      return 1
    else
      attempt=$((attempt + 1))
      if (( attempt < max )); then
        log INFO "HTTP $http_code, retrying in ${delay}s (attempt $((attempt+1))/$max)"
        sleep "$delay"
        delay=$((delay * 2))
      else
        log ERROR "HTTP $http_code after $max attempts: ${body:0:200}"
        printf '%s' "$body"
        return 1
      fi
    fi
  done
}

# --- Validation ---
validate() {
  local missing=()
  [[ -z "${RP_ENDPOINT:-}" ]]     && missing+=(RP_ENDPOINT)
  [[ -z "${RP_PROJECT:-}" ]]     && missing+=(RP_PROJECT)
  [[ -z "${RP_TOKEN:-}" ]]       && missing+=(RP_TOKEN)
  [[ -z "${RP_MERGE_GROUP:-}" ]] && missing+=(RP_MERGE_GROUP)

  if (( ${#missing[@]} > 0 )); then
    log ERROR "Missing required parameters: ${missing[*]}"
    exit 3
  fi

  for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      log ERROR "Required dependency not found: $cmd"
      exit 3
    fi
  done
}

# --- API helpers ---
api_v1() { echo "${RP_ENDPOINT%/}/api/v1/${RP_PROJECT}"; }
api_v2() { echo "${RP_ENDPOINT%/}/api/v2/${RP_PROJECT}"; }

# --- Step 1: Find launches by merge_group (and ci_run_id only when launches have it) ---
find_launches() {
  local url
  url="$(api_v1)/launch?filter.has.attributeKey=merge_group&filter.has.attributeValue=${RP_MERGE_GROUP}&page.size=50"

  if [[ -n "${RP_CI_RUN_ID:-}" ]]; then
    # First try with ci_run_id filter for disambiguation in concurrent CI runs
    local filtered_url="${url}&filter.has.attributeKey=ci_run_id&filter.has.attributeValue=${RP_CI_RUN_ID}"
    local resp
    resp=$(rp_curl_retry -X GET "$filtered_url") || true
    local count
    count=$(echo "$resp" | jq '.content | length // 0' 2>/dev/null || echo 0)
    if (( count > 0 )); then
      printf '%s' "$resp"
      return 0
    fi
    # Fall back to merge_group-only query when no launches have ci_run_id
    # (e.g., SauceLabs real-device runs where env vars are not available)
    log INFO "No launches with ci_run_id=${RP_CI_RUN_ID}, falling back to merge_group-only filter"
  fi

  rp_curl_retry -X GET "$url"
}

# --- Step 2: Poll until launches finish or timeout ---
wait_for_launches() {
  local ids_json="$1"
  local deadline=$(( $(date +%s) + RP_MERGE_FINALIZE_TIMEOUT ))
  local all_done=false

  while (( $(date +%s) < deadline )); do
    all_done=true
    for id in $(echo "$ids_json" | jq -r '.[]'); do
      local resp
      resp=$(rp_curl_retry -X GET "$(api_v1)/launch?filter.eq.id=${id}&page.size=1") || continue
      local status
      status=$(echo "$resp" | jq -r '.content[0].status // "UNKNOWN"')
      case "$status" in
        PASSED|FAILED|STOPPED|INTERRUPTED) ;;
        *) all_done=false ;;
      esac
    done
    if $all_done; then return 0; fi
    sleep 2
  done

  log WARN "Timeout (${RP_MERGE_FINALIZE_TIMEOUT}s) waiting for launches to finish"
  return 1
}

# --- Step 3: Force-finish open launches ---
finish_launch() {
  local uuid="$1"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  rp_curl_retry -X PUT "$(api_v2)/launch/${uuid}/finish" \
    -d "{\"endTime\":\"${ts}\"}" >/dev/null 2>&1 || true
}

# --- Step 4: Merge ---
merge_launches() {
  local ids_json="$1" name="$2"
  local body
  body=$(jq -n --argjson ids "$ids_json" --arg name "$name" '{
    launches: $ids,
    mergeType: "DEEP",
    name: $name,
    extendSuitesDescription: true
  }')
  rp_curl_retry -X POST "$(api_v2)/launch/merge" -d "$body"
}

# --- Main ---
main() {
  validate
  log INFO "Merging launches for merge_group=${RP_MERGE_GROUP}"

  # Find launches
  local response
  response=$(find_launches) || { log ERROR "Failed to query launches"; exit 1; }

  local ids uuids count
  ids=$(echo "$response" | jq '[.content[].id]')
  uuids=$(echo "$response" | jq -r '[.content[].uuid] | .[]')
  count=$(echo "$ids" | jq 'length')

  if (( count == 0 )); then
    log WARN "No launches found for merge_group=${RP_MERGE_GROUP}"
    exit 1
  fi

  log INFO "Found $count launch(es)"

  # Warn if expected count doesn't match
  if [[ -n "${RP_EXPECTED_LAUNCHES:-}" ]] && (( count != RP_EXPECTED_LAUNCHES )); then
    log WARN "Expected $RP_EXPECTED_LAUNCHES launches, found $count"
  fi

  # Wait for launches to finish
  if ! wait_for_launches "$ids"; then
    # Force-finish any still-open launches
    log INFO "Force-finishing open launches"
    for uuid in $uuids; do
      finish_launch "$uuid"
    done
  fi

  # Merge
  log INFO "Merging $count launches: $(echo "$ids" | jq -c '.')"
  local merge_resp
  if merge_resp=$(merge_launches "$ids" "$RP_MERGED_LAUNCH_NAME"); then
    local merged_id
    merged_id=$(echo "$merge_resp" | jq -r '.id // empty')
    if [[ -n "$merged_id" ]]; then
      log INFO "Merged launch: ${RP_ENDPOINT%/}/ui/#${RP_PROJECT}/launches/all/${merged_id}"
      exit 0
    fi
  fi

  # Merge failed — print individual launch UUIDs for manual recovery
  log ERROR "Merge failed. Individual launch UUIDs:"
  for uuid in $uuids; do
    log ERROR "  $uuid"
  done
  exit 2
}

main "$@"
