#!/usr/bin/env bash
# Copyright 2026 EPAM Systems — Apache License 2.0
set -euo pipefail

# Usage: ./scripts/inject_xctestrun_env.sh <xctestrun_file> <key> <value>
# Injects an environment variable into all test targets in an .xctestrun plist file.
# Supports both flat format and TestConfigurations format.

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <xctestrun_file> <key> <value>" >&2
  exit 1
fi

XCTESTRUN_FILE="$1"
KEY="$2"
VALUE="$3"
PB=/usr/libexec/PlistBuddy

if [[ ! -f "$XCTESTRUN_FILE" ]]; then
  echo "Error: File not found: $XCTESTRUN_FILE" >&2
  exit 1
fi

inject_env_var() {
  local base_path="$1"
  # Create EnvironmentVariables dict if missing
  if ! "$PB" -c "Print '${base_path}:EnvironmentVariables'" "$XCTESTRUN_FILE" &>/dev/null; then
    "$PB" -c "Add '${base_path}:EnvironmentVariables' dict" "$XCTESTRUN_FILE"
  fi
  # Remove existing key if present, then add
  "$PB" -c "Delete '${base_path}:EnvironmentVariables:${KEY}'" "$XCTESTRUN_FILE" 2>/dev/null || true
  "$PB" -c "Add '${base_path}:EnvironmentVariables:${KEY}' string '${VALUE}'" "$XCTESTRUN_FILE"
}

# Detect format: TestConfigurations (new) vs flat
if "$PB" -c "Print :TestConfigurations" "$XCTESTRUN_FILE" &>/dev/null; then
  # TestConfigurations format
  config_idx=0
  while "$PB" -c "Print :TestConfigurations:${config_idx}" "$XCTESTRUN_FILE" &>/dev/null; do
    target_idx=0
    while "$PB" -c "Print :TestConfigurations:${config_idx}:TestTargets:${target_idx}" "$XCTESTRUN_FILE" &>/dev/null; do
      inject_env_var "TestConfigurations:${config_idx}:TestTargets:${target_idx}"
      target_idx=$((target_idx + 1))
    done
    config_idx=$((config_idx + 1))
  done
else
  # Flat format: extract first non-metadata top-level key via JSON (stable, handles spaces in names)
  target_key=$(plutil -convert json -o - "$XCTESTRUN_FILE" 2>/dev/null \
    | python3 -c "import json,sys; keys=[k for k in json.load(sys.stdin) if k!='__xctestrun_metadata__']; print(keys[0] if keys else '')")
  if [[ -z "$target_key" ]]; then
    echo "Error: Could not find test target in $XCTESTRUN_FILE" >&2
    exit 1
  fi
  inject_env_var "$target_key"
fi

# Validate injection by reading back
readback=$("$PB" -c "Print" "$XCTESTRUN_FILE" 2>/dev/null | grep -c "$KEY" || true)
if [[ "$readback" -gt 0 ]]; then
  echo "✅ Injected ${KEY}=${VALUE} into ${XCTESTRUN_FILE}"
else
  echo "❌ Validation failed: ${KEY} not found after injection" >&2
  exit 1
fi
