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

if ! [[ "$KEY" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "Error: KEY must be a valid environment variable name (got: '$KEY')" >&2
  exit 1
fi

# PlistBuddy's -c command parser cannot represent a single quote inside a value (it raises
# "Unclosed Quotes" yet still exits 0, so the value would silently not be injected). Reject
# it up front. Spaces and double quotes ARE supported via the escaping/quoting below.
if [[ "$VALUE" == *\'* ]]; then
  echo "Error: VALUE must not contain a single quote (PlistBuddy limitation)" >&2
  exit 1
fi

if [[ ! -f "$XCTESTRUN_FILE" ]]; then
  echo "Error: File not found: $XCTESTRUN_FILE" >&2
  exit 1
fi

# Escape embedded double quotes so values can be wrapped in double quotes (handles spaces).
VALUE_ESCAPED=${VALUE//\"/\\\"}

inject_env_var() {
  local base_path="$1"
  # Create EnvironmentVariables dict if missing. Tolerate non-dict top-level keys (e.g. a
  # stray scalar entry) by skipping them rather than aborting the whole run under set -e.
  if ! "$PB" -c "Print \"${base_path}:EnvironmentVariables\"" "$XCTESTRUN_FILE" &>/dev/null; then
    if ! "$PB" -c "Add \"${base_path}:EnvironmentVariables\" dict" "$XCTESTRUN_FILE" &>/dev/null; then
      echo "⚠️  Skipping '${base_path}' (cannot add EnvironmentVariables — not a test-target dict?)" >&2
      return 0
    fi
  fi
  "$PB" -c "Delete \"${base_path}:EnvironmentVariables:${KEY}\"" "$XCTESTRUN_FILE" &>/dev/null || true
  "$PB" -c "Add \"${base_path}:EnvironmentVariables:${KEY}\" string \"${VALUE_ESCAPED}\"" "$XCTESTRUN_FILE" &>/dev/null \
    || echo "⚠️  Failed to set ${KEY} on '${base_path}'" >&2
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
  # Flat format: iterate ALL non-metadata top-level keys (multiple test targets possible).
  # Guard against a non-object JSON root so we never feed garbage tokens to PlistBuddy.
  target_keys=$(plutil -convert json -o - "$XCTESTRUN_FILE" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(k for k in d if k!='__xctestrun_metadata__') if isinstance(d, dict) else '')" 2>/dev/null)
  if [[ -z "$target_keys" ]]; then
    echo "Error: Could not find any test targets in $XCTESTRUN_FILE" >&2
    exit 1
  fi
  while IFS= read -r target_key; do
    [[ -z "$target_key" ]] && continue
    inject_env_var "$target_key"
  done <<< "$target_keys"
fi

# Validate injection by reading the exact "KEY = VALUE" back (grep -F: no regex surprises,
# no false positive from an unrelated key that merely contains KEY as a substring).
if "$PB" -c "Print" "$XCTESTRUN_FILE" 2>/dev/null | grep -qF -- "${KEY} = ${VALUE}"; then
  echo "✅ Injected ${KEY}=${VALUE} into ${XCTESTRUN_FILE}"
else
  echo "❌ Validation failed: ${KEY}=${VALUE} not found after injection" >&2
  exit 1
fi
