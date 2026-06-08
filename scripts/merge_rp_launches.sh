#!/usr/bin/env bash
# Copyright 2026 EPAM Systems — Apache License 2.0
# merge_rp_launches.sh — Query ReportPortal for launches matching a merge_group
# attribute, wait for them to finish, and merge them into a single launch.
# Portable: macOS + Ubuntu/Linux. Dependencies: curl, jq.
set -euo pipefail

# --- Configuration (env vars, overridable by positional CLI args) ---
RP_ENDPOINT="${RP_ENDPOINT:-${1:-}}"
RP_PROJECT="${RP_PROJECT:-${2:-}}"
RP_TOKEN="${RP_TOKEN:-${3:-}}"
RP_MERGE_GROUP="${RP_MERGE_GROUP:-${4:-}}"
RP_CI_RUN_ID="${RP_CI_RUN_ID:-${GITHUB_RUN_ID:-}}"
RP_EXPECTED_LAUNCHES="${RP_EXPECTED_LAUNCHES:-}"
RP_MERGED_LAUNCH_NAME="${RP_MERGED_LAUNCH_NAME:-"${RP_MERGE_GROUP:-} (merged)"}"
RP_MERGE_FINALIZE_TIMEOUT="${RP_MERGE_FINALIZE_TIMEOUT:-120}"
RP_DISCOVER_TIMEOUT="${RP_DISCOVER_TIMEOUT:-300}"
RP_DISCOVER_POLL="${RP_DISCOVER_POLL:-5}"
RP_DISCOVER_STABLE_POLLS="${RP_DISCOVER_STABLE_POLLS:-0}"

# --- Token masking (single source of truth, reused by log() and rp_curl_retry) ---
mask() {
  if [[ -n "${RP_TOKEN:-}" ]]; then
    printf '%s' "${1//$RP_TOKEN/***}"
  else
    printf '%s' "$1"
  fi
}

log() {
  local level="$1"; shift
  printf "%-5s %s\n" "$level" "$(mask "$*")" >&2
}

# --- Proxy support ---
curl_opts=(-s -S --fail-with-body)
if [[ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]]; then
  curl_opts+=(--proxy "${HTTPS_PROXY:-${https_proxy:-}}")
fi

# --- curl with retry + exponential backoff (3 attempts, no retry on 4xx) ---
rp_curl_retry() {
  local attempt=0 max=3 delay=2 http_code body tmpfile
  while (( attempt < max )); do
    tmpfile=$(mktemp)
    http_code=$(curl "${curl_opts[@]}" -w '%{http_code}' -o "$tmpfile" \
      -H "Authorization: Bearer ${RP_TOKEN}" \
      -H "Content-Type: application/json" \
      "$@" 2>/dev/null) || true
    body=$(mask "$(cat "$tmpfile")")
    rm -f "$tmpfile"

    if [[ "$http_code" =~ ^2 ]]; then
      printf '%s' "$body"
      return 0
    elif [[ "$http_code" =~ ^4 ]]; then
      log WARN "HTTP $http_code (no retry): ${body:0:200}"
      printf '%s' "$body"
      return 1
    else
      attempt=$((attempt + 1))
      if (( attempt < max )); then
        log INFO "HTTP $http_code, retrying in ${delay}s (attempt $((attempt + 1))/$max)"
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
  [[ -z "${RP_ENDPOINT:-}" ]]    && missing+=(RP_ENDPOINT)
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

  # Numeric tunables must be plain integers — a unit-suffixed value like "60s" would
  # otherwise abort the arithmetic below under set -e/-u. Fall back with a warning.
  if ! [[ "$RP_MERGE_FINALIZE_TIMEOUT" =~ ^[0-9]+$ ]]; then
    log WARN "RP_MERGE_FINALIZE_TIMEOUT='${RP_MERGE_FINALIZE_TIMEOUT}' is not an integer (seconds); using 120"
    RP_MERGE_FINALIZE_TIMEOUT=120
  fi
  if [[ -n "${RP_EXPECTED_LAUNCHES:-}" ]] && ! [[ "$RP_EXPECTED_LAUNCHES" =~ ^[0-9]+$ ]]; then
    log WARN "RP_EXPECTED_LAUNCHES='${RP_EXPECTED_LAUNCHES}' is not an integer; ignoring"
    RP_EXPECTED_LAUNCHES=""
  fi
  if ! [[ "$RP_DISCOVER_TIMEOUT" =~ ^[0-9]+$ ]]; then
    log WARN "RP_DISCOVER_TIMEOUT='${RP_DISCOVER_TIMEOUT}' is not an integer (seconds); using 300"
    RP_DISCOVER_TIMEOUT=300
  fi
  if ! [[ "$RP_DISCOVER_POLL" =~ ^[0-9]+$ ]] || (( RP_DISCOVER_POLL < 1 )); then
    log WARN "RP_DISCOVER_POLL='${RP_DISCOVER_POLL}' is not a positive integer (seconds); using 5"
    RP_DISCOVER_POLL=5
  fi
  if ! [[ "$RP_DISCOVER_STABLE_POLLS" =~ ^[0-9]+$ ]]; then
    log WARN "RP_DISCOVER_STABLE_POLLS='${RP_DISCOVER_STABLE_POLLS}' is not an integer; using 0 (disabled)"
    RP_DISCOVER_STABLE_POLLS=0
  fi
}

# --- API helpers ---
api_v1() { echo "${RP_ENDPOINT%/}/api/v1/${RP_PROJECT}"; }
api_v2() { echo "${RP_ENDPOINT%/}/api/v2/${RP_PROJECT}"; }

# --- Step 1: Find launches by merge_group, then narrow by ci_run_id client-side ---
# Query parameters go through --data-urlencode so values with spaces/&/# are encoded.
# ci_run_id is filtered in jq (not as a second URL attribute filter) to avoid ReportPortal's
# ambiguous "repeated attributeKey/attributeValue" pairing, which can over-match other runs.
find_launches() {
  local quiet="${1:-0}" resp
  resp=$(rp_curl_retry -G "$(api_v1)/launch" \
    --data-urlencode "filter.has.attributeKey=merge_group" \
    --data-urlencode "filter.has.attributeValue=${RP_MERGE_GROUP}" \
    --data-urlencode "page.size=50") || return 1

  if [[ -n "${RP_CI_RUN_ID:-}" ]]; then
    local filtered fcount
    filtered=$(echo "$resp" | jq --arg rid "$RP_CI_RUN_ID" \
      '.content = ((.content // []) | map(select(any(.attributes[]?; .key == "ci_run_id" and .value == $rid))))' \
      2>/dev/null || true)
    fcount=$(echo "$filtered" | jq '.content | length' 2>/dev/null || echo 0)
    if [[ -n "$filtered" ]] && (( fcount > 0 )); then
      printf '%s' "$filtered"
      return 0
    fi
    if [[ "$quiet" != "1" ]]; then
      log WARN "No launches matched ci_run_id=${RP_CI_RUN_ID}; falling back to merge_group-only filter (cannot disambiguate concurrent CI runs — see docs/SAUCELABS_SETUP.md)"
    fi
  fi

  printf '%s' "$resp"
}

# --- Step 1b: Discovery — wait for launches before merging ---
# A single snapshot races with per-device launch finalization and ReportPortal's attribute
# indexing: a shard that finalizes a moment after `saucectl run` returns is invisible at t=0, so a
# naive merge combines only the launches present then (the "merged 4 of 6" symptom). Two opt-in
# waiting modes avoid this (either or both; both bounded by RP_DISCOVER_TIMEOUT, polled every
# RP_DISCOVER_POLL seconds):
#   * RP_EXPECTED_LAUNCHES=N     — wait until N launches carry the merge_group (precise; needs the count).
#   * RP_DISCOVER_STABLE_POLLS=K — wait until the count stops growing for K consecutive polls
#                                  (count-agnostic; best when the shard count is dynamic/unknown).
# With neither set, discovery is a single snapshot (legacy behavior).
discover_launches() {
  if [[ -z "${RP_EXPECTED_LAUNCHES:-}" ]] && (( RP_DISCOVER_STABLE_POLLS == 0 )); then
    find_launches
    return $?
  fi

  local deadline resp count prev=-1 stable=0
  deadline=$(( $(date +%s) + RP_DISCOVER_TIMEOUT ))
  while :; do
    resp=$(find_launches 1) || return 1
    count=$(echo "$resp" | jq '((.content // []) | length)' 2>/dev/null || echo 0)

    # Precise target reached.
    if [[ -n "${RP_EXPECTED_LAUNCHES:-}" ]] && (( count >= RP_EXPECTED_LAUNCHES )); then
      log INFO "Discovered ${count}/${RP_EXPECTED_LAUNCHES} launches"
      printf '%s' "$resp"; return 0
    fi

    # Count has settled: same (non-zero) count for RP_DISCOVER_STABLE_POLLS consecutive polls.
    if (( RP_DISCOVER_STABLE_POLLS > 0 )) && (( count > 0 )) && (( count == prev )); then
      stable=$(( stable + 1 ))
      if (( stable >= RP_DISCOVER_STABLE_POLLS )); then
        log INFO "Launch count stable at ${count} for ${RP_DISCOVER_STABLE_POLLS} polls; merging"
        printf '%s' "$resp"; return 0
      fi
    else
      stable=0
    fi

    if (( $(date +%s) >= deadline )); then
      log WARN "Discovery timed out after ${RP_DISCOVER_TIMEOUT}s at ${count} launch(es); merging what is available (a shard may have failed to report — check SauceLabs)"
      printf '%s' "$resp"; return 0
    fi

    prev=$count
    if [[ -n "${RP_EXPECTED_LAUNCHES:-}" ]]; then
      log INFO "Found ${count}/${RP_EXPECTED_LAUNCHES} launch(es); waiting ${RP_DISCOVER_POLL}s for the rest…"
    else
      log INFO "Found ${count} launch(es); waiting ${RP_DISCOVER_POLL}s for the count to settle…"
    fi
    sleep "$RP_DISCOVER_POLL"
  done
}

# --- Step 1c: Orphan patching — rescue launches that lost their merge_group ---
# On real SauceLabs devices, a race condition in the agent can cause 1–2 shards to have
# their launch auto-created by ReportPortal (from the first test-item POST) BEFORE the
# startLaunch call completes. These launches exist with the correct name and timeframe
# but have NO attributes (no merge_group, no device info). This function finds them by:
#   1. Querying launches with the same launch name in the same time window
#   2. Filtering out those that already have merge_group (the good ones)
#   3. PATCHing the orphans with merge_group so the merge script picks them up
#
# Called only when discover_launches found fewer than RP_EXPECTED_LAUNCHES.
patch_orphan_launches() {
  local good_ids_json="$1"
  local launch_name="${RP_MERGED_LAUNCH_NAME%% (merged)}"  # Strip " (merged)" suffix
  # Use the base launch name from RP_MERGE_GROUP pattern if possible
  # e.g., "Appvengers RegressioniOS" — but we don't know it statically.
  # Instead, get the name from one of the found launches.
  
  if [[ $(echo "$good_ids_json" | jq 'length') -eq 0 ]]; then
    log WARN "No good launches to derive name from; cannot patch orphans"
    return 1
  fi
  
  # Get the name of the first good launch
  local first_good_id
  first_good_id=$(echo "$good_ids_json" | jq -r '.[0]')
  local name_resp
  name_resp=$(rp_curl_retry -X GET "$(api_v1)/launch?filter.eq.id=${first_good_id}&page.size=1") || return 1
  local known_name
  known_name=$(echo "$name_resp" | jq -r '.content[0].name // empty')
  
  if [[ -z "$known_name" ]]; then
    log WARN "Could not determine launch name from existing launches"
    return 1
  fi
  
  log INFO "Looking for orphan launches with name='${known_name}' missing merge_group..."
  
  # Find all launches with the same name in the last 2 hours (generous window)
  local all_resp
  all_resp=$(rp_curl_retry -G "$(api_v1)/launch" \
    --data-urlencode "filter.eq.name=${known_name}" \
    --data-urlencode "page.size=50" \
    --data-urlencode "page.sort=startTime,desc") || return 1
  
  local all_ids
  all_ids=$(echo "$all_resp" | jq -c '[(.content // [])[].id]')
  
  # Filter: find IDs that are NOT in good_ids_json AND have no merge_group attribute
  local orphans
  orphans=$(echo "$all_resp" | jq -c --argjson good "$good_ids_json" \
    '[(.content // []) | .[] | select(
      (.id as $id | $good | index($id) | not) and
      ((.attributes // []) | all(.key != "merge_group"))
    ) | .id]')
  
  local orphan_count
  orphan_count=$(echo "$orphans" | jq 'length')
  
  if (( orphan_count == 0 )); then
    log INFO "No orphan launches found"
    return 1
  fi
  
  log INFO "Found ${orphan_count} orphan launch(es) — patching merge_group attribute..."
  
  local patched=0
  for orphan_id in $(echo "$orphans" | jq -r '.[]'); do
    local patch_body
    patch_body=$(jq -n --arg mg "$RP_MERGE_GROUP" '{
      attributes: [{"key": "merge_group", "value": $mg}]
    }')
    
    if rp_curl_retry -X PUT "$(api_v1)/launch/${orphan_id}/update" -d "$patch_body" >/dev/null 2>&1; then
      log INFO "  Patched orphan launch ID=${orphan_id} with merge_group=${RP_MERGE_GROUP}"
      patched=$((patched + 1))
    else
      log WARN "  Failed to patch orphan launch ID=${orphan_id}"
    fi
  done
  
  if (( patched > 0 )); then
    log INFO "Patched ${patched} orphan(s); re-discovering launches..."
    return 0
  fi
  return 1
}

wait_for_launches() {
  local ids_json="$1"
  local deadline=$(( $(date +%s) + RP_MERGE_FINALIZE_TIMEOUT ))
  local all_done id resp status

  while (( $(date +%s) < deadline )); do
    all_done=true
    for id in $(echo "$ids_json" | jq -r '.[]'); do
      # A failed status query means we don't KNOW the launch is terminal — keep polling.
      resp=$(rp_curl_retry -X GET "$(api_v1)/launch?filter.eq.id=${id}&page.size=1") || { all_done=false; continue; }
      status=$(echo "$resp" | jq -r '.content[0].status // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
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

# --- Step 3: Force-finish an open launch (best-effort, but surface failures) ---
finish_launch() {
  local uuid="$1" ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if ! rp_curl_retry -X PUT "$(api_v2)/launch/${uuid}/finish" -d "{\"endTime\":\"${ts}\"}" >/dev/null; then
    log WARN "Force-finish failed for launch ${uuid}"
  fi
}

# --- Step 4: Merge ---
merge_launches() {
  local ids_json="$1" name="$2" body
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

  local response
  response=$(discover_launches) || { log ERROR "Failed to query launches"; exit 1; }

  local ids uuids count
  ids=$(echo "$response" | jq -c '[(.content // [])[].id]')
  uuids=$(echo "$response" | jq -r '[(.content // [])[].uuid] | .[]')
  count=$(echo "$ids" | jq 'length')

  # --- Orphan patching: if we found fewer than expected, look for attribute-less launches ---
  if [[ -n "${RP_EXPECTED_LAUNCHES:-}" ]] && (( count > 0 )) && (( count < RP_EXPECTED_LAUNCHES )); then
    log WARN "Found ${count}/${RP_EXPECTED_LAUNCHES} — attempting orphan rescue..."
    if patch_orphan_launches "$ids"; then
      # Re-discover after patching
      sleep 2  # Brief pause for RP to index the new attribute
      response=$(find_launches) || { log ERROR "Failed to re-query launches after orphan patch"; exit 1; }
      ids=$(echo "$response" | jq -c '[(.content // [])[].id]')
      uuids=$(echo "$response" | jq -r '[(.content // [])[].uuid] | .[]')
      count=$(echo "$ids" | jq 'length')
      log INFO "After orphan patching: found ${count} launch(es)"
    fi
  fi

  if (( count == 0 )); then
    # "Nothing to merge" is not a failure: the merge step usually runs with `if: always()`,
    # so exit 0 to avoid reddening a pipeline that simply produced no launches.
    log WARN "No launches found for merge_group=${RP_MERGE_GROUP} (nothing to merge)"
    exit 0
  fi

  log INFO "Found $count launch(es)"

  if [[ -n "${RP_EXPECTED_LAUNCHES:-}" ]] && (( count != RP_EXPECTED_LAUNCHES )); then
    log WARN "Expected $RP_EXPECTED_LAUNCHES launches, found $count"
  fi

  # Wait for launches to finish; if they don't, force-finish and re-poll so they reach a
  # terminal status before merging (the merge API rejects a mix of statuses).
  if ! wait_for_launches "$ids"; then
    log INFO "Force-finishing open launches"
    for uuid in $uuids; do
      finish_launch "$uuid"
    done
    if ! wait_for_launches "$ids"; then
      log WARN "Launches still not all terminal after force-finish; attempting merge anyway"
    fi
  fi

  log INFO "Merging $count launches: $(echo "$ids" | jq -c '.')"
  local merge_resp merged_id
  if merge_resp=$(merge_launches "$ids" "$RP_MERGED_LAUNCH_NAME"); then
    merged_id=$(echo "$merge_resp" | jq -r '.id // empty' 2>/dev/null || true)
    if [[ -n "$merged_id" ]]; then
      log INFO "Merged launch: ${RP_ENDPOINT%/}/ui/#${RP_PROJECT}/launches/all/${merged_id}"
      exit 0
    fi
  fi

  # Merge failed — print individual launch UUIDs for manual recovery.
  log ERROR "Merge failed. Individual launch UUIDs:"
  for uuid in $uuids; do
    log ERROR "  $uuid"
  done
  exit 2
}

main "$@"
