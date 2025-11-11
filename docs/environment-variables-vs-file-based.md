# Environment Variables vs File-Based Coordination

## TL;DR

- **Local Xcode**: Use file-based coordination (automatic, already works)
- **CI/CD**: Use environment variables (required for multi-machine builds)

## Why Pre-Action Scripts Don't Work for Local Development

Xcode pre-action scripts **cannot** reliably pass environment variables to test processes because:

1. Test processes spawn as **separate processes** from the Xcode build
2. `launchctl setenv` only affects the current user session
3. Test simulator processes don't inherit these environment variables
4. Each simulator device is a separate process with its own environment

### What Happens

```
Pre-Action Script (in Xcode build process):
  ├─ Runs: launchctl setenv RP_LAUNCH_UUID "ABC123..."
  └─ Sets environment variable in BUILD process ✅
  
Test Process 1 (Simulator 1):
  ├─ Spawns separately
  ├─ Checks: ProcessInfo.processInfo.environment["RP_LAUNCH_UUID"]
  └─ Result: nil ❌ (doesn't inherit launchctl environment)
  
Test Process 2 (Simulator 2):
  └─ Same problem ❌
```

## Solutions by Use Case

### 1. Local Xcode Development (Recommended: File-Based)

**Just run tests normally!** No setup needed.

```bash
# In Xcode: Cmd+U
# Or from command line:
xcodebuild test -scheme ReportPortalAgent -destination 'platform=iOS Simulator,name=iPhone 15'
```

**How it works:**
- First test run creates `/tmp/reportportal/launch_uuid.txt`
- All devices read from this file → share same UUID
- If file is >10 seconds old → creates new UUID (fresh test run)
- Automatic cleanup and coordination

**Logs you'll see:**
```
⚙️ [ReportPortal] No RP_LAUNCH_UUID env var, using file-based UUID coordination
🔄 [SYNC] [LAUNCH] Previous run detected (UUID age: 409s) - creating fresh launch
✍️ First worker - wrote launch UUID to file: B60EA9AC-3C83-4D02-970C-74127CD73B0E
```

**This is CORRECT!** The framework automatically:
- Detects stale UUID from previous run
- Creates fresh UUID for this run
- Shares it across all devices via file

### 2. CI/CD (Jenkins, GitLab, GitHub Actions)

**Use environment variables** set in your pipeline script:

```bash
#!/bin/bash

# Generate unique UUID for this pipeline run
export RP_LAUNCH_UUID=$(uuidgen)
export RP_LAUNCH_ID=$(uuidgen)

echo "🚀 Pipeline Launch UUID: $RP_LAUNCH_UUID"

# Run tests - environment variables are inherited
xcodebuild test \
  -scheme YourScheme \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -parallel-testing-enabled YES
```

**Why this works in CI:**
- Pipeline script sets `export RP_LAUNCH_UUID=...`
- `xcodebuild` inherits these environment variables
- Test processes inherit from `xcodebuild`
- All devices see the same UUID

**Logs you'll see:**
```
🌍 [ReportPortal] UUID from environment: 550E8400-E29B-41D4-A716-446655440000
✅ [SYNC] [LAUNCH] Created - ID: 550E8400-E29B-41D4-A716-446655440000
```

### 3. Command-Line Testing (Alternative for Local)

If you want to test the environment variable approach locally:

```bash
### 2. CI/CD Multi-Machine Builds (Required: Environment Variables)

**Use `export` to set environment variables**, then run xcodebuild:

```bash
#!/bin/zsh

# Generate or receive UUID from CI system
LAUNCH_UUID=$(uuidgen)  # Or from CI pipeline variable

# CRITICAL: Use 'export' so variables are inherited by child processes
export RP_LAUNCH_UUID="$LAUNCH_UUID"
export RP_LAUNCH_ID="$LAUNCH_UUID"

# Now run tests - environment variables will be inherited
xcodebuild test \
  -scheme ReportPortalAgent \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -parallel-testing-enabled YES \
  -maximum-parallel-testing-workers 4
```

**Why `export` is required:**
- `export` makes variables available to ALL child processes
- Without `export`, variables only exist in current shell
- Test processes inherit exported variables via `ProcessInfo.processInfo.environment`

**What DOESN'T work:**
```bash
# ❌ WRONG - passing as xcodebuild arguments (not supported)
xcodebuild test -scheme X RP_LAUNCH_UUID="$UUID"

# ❌ WRONG - launchctl (doesn't propagate to test processes)
launchctl setenv RP_LAUNCH_UUID "$UUID"
xcodebuild test -scheme X
```
```

Save as `run_tests_local.sh` and run:
```bash
chmod +x run_tests_local.sh
./run_tests_local.sh
```

## Comparison

| Approach | Local Xcode | CI/CD | Setup Complexity | UUID Uniqueness |
|----------|-------------|-------|------------------|-----------------|
| **File-Based** | ✅ Works | ❌ No (different machines) | None | ✅ Automatic |
| **Environment Variables** | ⚠️ Requires script | ✅ Works | Medium | ✅ Per-pipeline |
| **Pre-Action Script** | ❌ Doesn't work | ❌ Doesn't work | High | ❌ N/A |

## Recommendation

**Use file-based coordination for local development** - it's simpler, works automatically, and creates fresh UUIDs for each test run without any manual setup.

**Use environment variables only for CI/CD** - where you control the entire build environment and can guarantee variables are inherited.

## Verifying It Works

### File-Based (Local)
```
⚙️ No RP_LAUNCH_UUID env var, using file-based UUID coordination
✍️ First worker - wrote launch UUID to file: <UUID>
✅ All devices use: <SAME UUID>
```

### Environment Variables (CI/CD)
```
🌍 UUID from environment: <UUID>
✅ All devices use: <SAME UUID from environment>
```

### Tolerant Finalization (Both)
```
Device 1:
✅ [SYNC] [FINISH] Launch finalized successfully

Device 2-N:
ℹ️  [SYNC] [FINISH] Launch already finalized by another worker (409)
```

## Troubleshooting

**Q: I see "UUID age: 409s - creating fresh launch" - is this a problem?**

A: No! This is **normal and correct**. It means:
- You ran tests before (409 seconds ago = ~7 minutes ago)
- The old UUID is stale (>10 second threshold)
- Framework creates a fresh UUID for this new test run
- This ensures each test run has a unique launch in ReportPortal

**Q: Can I force all test runs to use the same UUID?**

A: Yes, but **not recommended** for local development:
```bash
# Force same UUID (all test runs go to same launch)
env RP_LAUNCH_UUID="550E8400-E29B-41D4-A716-446655440000" xcodebuild test ...
```

This will append all test results to the same launch, which is usually not what you want.

**Q: How do I clean up old UUID files?**

A: Automatic! Files older than 10 seconds are ignored and overwritten.

Manual cleanup:
```bash
rm -rf /tmp/reportportal/
```
