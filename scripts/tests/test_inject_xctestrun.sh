#!/usr/bin/env bash
# Copyright 2026 EPAM Systems — Apache License 2.0

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INJECT_SCRIPT="${SCRIPT_DIR}/inject_xctestrun_env.sh"
PB=/usr/libexec/PlistBuddy
TMPDIR_TEST=$(mktemp -d)
PASS=0 FAIL=0

cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

create_flat_plist() {
  local f="$1"
  cat > "$f" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>MyTestTarget</key>
  <dict>
    <key>BlueprintName</key>
    <string>MyTestTarget</string>
    <key>EnvironmentVariables</key>
    <dict/>
  </dict>
  <key>__xctestrun_metadata__</key>
  <dict>
    <key>FormatVersion</key>
    <integer>1</integer>
  </dict>
</dict>
</plist>
EOF
}

# --- Test 1: Wrong number of args ---
output=$("$INJECT_SCRIPT" 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 1 ]]; then
  pass "exits 1 with no args"
else
  fail "exits 1 with no args (got rc=$rc)"
fi

# --- Test 2: Missing file ---
output=$("$INJECT_SCRIPT" "/nonexistent/file.xctestrun" "KEY" "VAL" 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 1 ]]; then
  pass "exits 1 for missing file"
else
  fail "exits 1 for missing file (got rc=$rc)"
fi

# --- Test 3: Inject key-value into flat plist ---
PLIST="${TMPDIR_TEST}/test.xctestrun"
create_flat_plist "$PLIST"

output=$("$INJECT_SCRIPT" "$PLIST" "RP_LAUNCH_UUID" "abc-123" 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 0 ]]; then
  pass "inject exits 0"
else
  fail "inject exits 0 (got rc=$rc, output: $output)"
fi

# --- Test 4: Verify injected value exists in plist ---
# The script finds the first non-metadata key from PlistBuddy output and injects there.
# Verify the key appears somewhere in the plist.
found=$("$PB" -c "Print" "$PLIST" 2>/dev/null | grep -c "RP_LAUNCH_UUID = abc-123" || true)
if [[ "$found" -gt 0 ]]; then
  pass "injected value reads back correctly"
else
  fail "injected value reads back correctly (RP_LAUNCH_UUID=abc-123 not found in plist)"
fi

# --- Test 5: Overwrite existing key ---
output=$("$INJECT_SCRIPT" "$PLIST" "RP_LAUNCH_UUID" "def-456" 2>&1) && rc=$? || rc=$?
found=$("$PB" -c "Print" "$PLIST" 2>/dev/null | grep -c "RP_LAUNCH_UUID = def-456" || true)
if [[ $rc -eq 0 && "$found" -gt 0 ]]; then
  pass "overwrite existing key"
else
  fail "overwrite existing key (rc=$rc, found=$found)"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
