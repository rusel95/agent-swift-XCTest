#!/usr/bin/env bash
# Copyright 2026 EPAM Systems — Apache License 2.0

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MERGE_SCRIPT="${SCRIPT_DIR}/merge_rp_launches.sh"
TMPDIR_TEST=$(mktemp -d)
PASS=0 FAIL=0

cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# --- Mock curl: emulates `-o <file>` (writes body) + `-w '%{http_code}'` (prints code). ---
# Returns an empty-launches list for any request so the script deterministically reaches its
# "nothing to merge" path with no network access.
MOCK_CURL="${TMPDIR_TEST}/curl"
cat > "$MOCK_CURL" <<'MOCK'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "-o" ]] && out="$arg"
  prev="$arg"
done
body='{"content":[],"page":{"totalElements":0}}'
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '200'   # value captured by -w '%{http_code}'
exit 0
MOCK
chmod +x "$MOCK_CURL"

# Prepend mock to PATH
export PATH="${TMPDIR_TEST}:${PATH}"

# --- Test 1: Missing parameters → exit 3 ---
output=$(RP_ENDPOINT="" RP_PROJECT="" RP_TOKEN="" RP_MERGE_GROUP="" \
  "$MERGE_SCRIPT" 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 3 ]]; then
  pass "missing params exits 3"
else
  fail "missing params exits 3 (got rc=$rc)"
fi

# --- Test 2: Zero launches found → exit 0 (nothing to merge is not a failure) ---
output=$(RP_ENDPOINT="https://rp.example.com" RP_PROJECT="proj" \
  RP_TOKEN="secret_token_value" RP_MERGE_GROUP="test-group" \
  RP_CI_RUN_ID="" GITHUB_RUN_ID="" RP_MERGE_FINALIZE_TIMEOUT=1 \
  "$MERGE_SCRIPT" 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 0 ]]; then
  pass "zero launches exits 0"
else
  fail "zero launches exits 0 (got rc=$rc, output: $output)"
fi

# --- Test 3: Token never appears in output ---
if echo "$output" | grep -qF "secret_token_value"; then
  fail "token masked in output (token found in output)"
else
  pass "token masked in output"
fi

# --- Test 4: Non-numeric RP_MERGE_FINALIZE_TIMEOUT is sanitized, not fatal ---
output=$(RP_ENDPOINT="https://rp.example.com" RP_PROJECT="proj" \
  RP_TOKEN="secret123" RP_MERGE_GROUP="grp" \
  RP_CI_RUN_ID="" GITHUB_RUN_ID="" RP_MERGE_FINALIZE_TIMEOUT="60s" \
  "$MERGE_SCRIPT" 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 0 ]] && echo "$output" | grep -q "not an integer"; then
  pass "non-numeric timeout is sanitized (exit 0 + warning)"
else
  fail "non-numeric timeout is sanitized (got rc=$rc, output: $output)"
fi

# --- Test 5: RP_EXPECTED_LAUNCHES waits for the count, then proceeds on timeout (no hang) ---
# Mock always returns 0 launches, so the script can never reach 6; it must poll until
# RP_DISCOVER_TIMEOUT, warn "Found 0/6", then exit 0 ("nothing to merge") without hanging.
start=$(date +%s)
output=$(RP_ENDPOINT="https://rp.example.com" RP_PROJECT="proj" \
  RP_TOKEN="secret" RP_MERGE_GROUP="grp" \
  RP_CI_RUN_ID="" GITHUB_RUN_ID="" \
  RP_EXPECTED_LAUNCHES=6 RP_DISCOVER_TIMEOUT=1 RP_DISCOVER_POLL=1 RP_MERGE_FINALIZE_TIMEOUT=1 \
  "$MERGE_SCRIPT" 2>&1) && rc=$? || rc=$?
elapsed=$(( $(date +%s) - start ))
if [[ $rc -eq 0 ]] && echo "$output" | grep -q "0/6" && (( elapsed < 30 )); then
  pass "expected-count discovery waits then times out gracefully (exit 0)"
else
  fail "expected-count discovery (got rc=$rc, elapsed=${elapsed}s, output: $output)"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
