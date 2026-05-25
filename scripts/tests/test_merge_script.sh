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

# --- Create mock curl ---
MOCK_CURL="${TMPDIR_TEST}/curl"
cat > "$MOCK_CURL" <<'MOCK'
#!/usr/bin/env bash
# Mock curl: return empty launches response for any GET request
for arg in "$@"; do
  if [[ "$arg" == *"/launch?"* ]]; then
    echo '{"content":[],"page":{"totalElements":0}}'
    exit 0
  fi
done
echo '{}'
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

# --- Test 2: Zero launches found → exit 1 ---
output=$(RP_ENDPOINT="https://rp.example.com" RP_PROJECT="proj" \
  RP_TOKEN="secret_token_value" RP_MERGE_GROUP="test-group" \
  RP_MERGE_FINALIZE_TIMEOUT=1 \
  "$MERGE_SCRIPT" 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 1 ]]; then
  pass "zero launches exits 1"
else
  fail "zero launches exits 1 (got rc=$rc)"
fi

# --- Test 3: Token never appears in output ---
if echo "$output" | grep -qF "secret_token_value"; then
  fail "token masked in output (token found in output)"
else
  pass "token masked in output"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
