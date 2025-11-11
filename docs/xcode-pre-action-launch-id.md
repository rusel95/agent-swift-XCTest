# Xcode Pre-Action Script for Launch ID Setup

## Overview

This script generates a unique `RP_LAUNCH_ID` for each test run, ensuring all devices/simulators share the same launch ID in ReportPortal. This solves the "source of truth" problem when running tests across multiple devices.

## How It Works

1. **Generate Launch ID Once**: Pre-action script creates a single UUID for the entire test run
2. **Share via Environment Variable**: `RP_LAUNCH_ID` is set and passed to all test bundles
3. **All Devices Use Same ID**: Every simulator/device references the same launch
4. **Tolerant Finalization**: Each device tries to finalize; 409 errors are expected and OK

## Setup Instructions

### 1. Open Your Test Scheme

1. In Xcode, click the scheme dropdown (near Run/Stop buttons)
2. Select **Edit Scheme...**
3. Navigate to **Test** → **Pre-actions**

### 2. Add Pre-Action Script

Click the **+** button → **New Run Script Action**

**Provide build settings from:** Select your app target (e.g., "Example")

**Shell:** `/bin/zsh`

**Script:**

```bash
#!/bin/zsh

# Generate unique launch UUID for this test run
# All simulators/devices will share this UUID
LAUNCH_UUID=$(uuidgen)

echo "🚀 [ReportPortal] Generated Launch UUID: $LAUNCH_UUID"

# Export as environment variable (accessible to all test bundles)
launchctl setenv RP_LAUNCH_UUID "$LAUNCH_UUID"

# Also export RP_LAUNCH_ID with same value for consistency
# (Launch ID will be set after API call, but UUID is used for coordination)
launchctl setenv RP_LAUNCH_ID "$LAUNCH_UUID"

echo "✅ [ReportPortal] Environment variables set for test run"
echo "   RP_LAUNCH_UUID=$LAUNCH_UUID"
echo "   RP_LAUNCH_ID=$LAUNCH_UUID"
```

### 3. Optional: Add Post-Action Cleanup

Navigate to **Test** → **Post-actions**

Click the **+** button → **New Run Script Action**

**Script:**

```bash
#!/bin/zsh

# Clean up environment variables after test run
launchctl unsetenv RP_LAUNCH_UUID
launchctl unsetenv RP_LAUNCH_ID

echo "🧹 [ReportPortal] Cleaned up environment variables"
```

## How Launch ID is Used

### Priority Order (in `LaunchManager.getOrCreateLaunchUUID()`):

1. **Cached UUID** (if already generated this session)
2. **RP_LAUNCH_UUID environment variable** ← **Set this in pre-action!**
3. File-based coordination (fallback for simulators)

### Priority Order (in `LaunchManager.getLaunchID()`):

1. **RP_LAUNCH_ID environment variable** ← **Set this in pre-action!**
2. Cached launch ID from API response

### Example Flow:

```
Pre-Action Script:
  ├─ Generates: LAUNCH_UUID = "A1B2C3D4-..."
  ├─ Sets: RP_LAUNCH_UUID = "A1B2C3D4-..."
  └─ Sets: RP_LAUNCH_ID = "A1B2C3D4-..." (optional, will be same as UUID)

Device 1 (starts immediately):
  ├─ Reads RP_LAUNCH_UUID from environment ✅ (no file-based coordination)
  ├─ Creates launch in ReportPortal with UUID
  ├─ Launch ID returned = A1B2C3D4-... (same as UUID)
  ├─ Runs tests
  └─ Tries to finalize → ✅ Success (first to finish)

Device 2 (starts 2 minutes later):
  ├─ Reads SAME RP_LAUNCH_UUID from environment ✅
  ├─ Joins existing launch (or creates if doesn't exist)
  ├─ Runs tests
  └─ Tries to finalize → ℹ️ 409 Conflict (already finalized) ← EXPECTED

Device 3, 4, 5... (similar to Device 2)
```

## Benefits

✅ **Single Source of Truth**: Pre-action script generates ID once, all devices use it
✅ **No Coordination Complexity**: No need to track "last worker" across staggered starts
✅ **Tolerant to Failures**: If device crashes, others still finalize correctly
✅ **Works with CI**: Same approach works for Jenkins, GitLab CI, etc.
✅ **Simple Mental Model**: Each device tries to finalize; first wins, others get 409

## Verification

After running tests, check the console output:

```
Pre-Action:
🚀 [ReportPortal] Generated Launch UUID: A1B2C3D4-5678-90AB-CDEF-1234567890AB
✅ [ReportPortal] Environment variables set for test run
   RP_LAUNCH_UUID=A1B2C3D4-5678-90AB-CDEF-1234567890AB
   RP_LAUNCH_ID=A1B2C3D4-5678-90AB-CDEF-1234567890AB

Device 1 (starts at T+0s):
🌍 [ReportPortal] UUID from environment: A1B2C3D4-5678-90AB-CDEF-1234567890AB
🌍 [LAUNCH] Using launch ID from RP_LAUNCH_ID: A1B2C3D4-...
✅ [SYNC] [FINISH] Launch finalized successfully - ID: A1B2C3D4-...

Device 2 (starts at T+90s):
🌍 [ReportPortal] UUID from environment: A1B2C3D4-5678-90AB-CDEF-1234567890AB
🌍 [LAUNCH] Using launch ID from RP_LAUNCH_ID: A1B2C3D4-...
ℹ️  [SYNC] [FINISH] Launch already finalized by another worker (409) - ID: A1B2C3D4-...

Device 3 (starts at T+120s):
🌍 [ReportPortal] UUID from environment: A1B2C3D4-5678-90AB-CDEF-1234567890AB
🌍 [LAUNCH] Using launch ID from RP_LAUNCH_ID: A1B2C3D4-...
ℹ️  [SYNC] [FINISH] Launch already finalized by another worker (409) - ID: A1B2C3D4-...

Device 4, 5: (similar to Device 2/3)
```

## Troubleshooting

### Launch UUID not detected

- Ensure **"Provide build settings from"** is set to your app target
- Check pre-action script runs before tests: `echo` statements should appear in logs
- Verify `launchctl setenv` commands executed successfully
- You should see: `🌍 [ReportPortal] UUID from environment: ...` in logs
- If you see: `⚙️ No RP_LAUNCH_UUID env var...` → environment variable not set

### Multiple launches created

- Check if all devices are reading the same `RP_LAUNCH_UUID`
- Ensure pre-action script runs ONCE per test run, not per device
- Verify environment variable persists across test bundle launches
- Check logs for: `🌍 [ReportPortal] UUID from environment: ...` (should be SAME UUID for all devices)

### 409 errors appearing as failures

- This is EXPECTED behavior - 409 means another device already finalized
- Check logs: should show `ℹ️ Launch already finalized by another worker (409)`
- Test results should still be preserved in ReportPortal

## Advanced: CI/CD Integration

For CI systems (Jenkins, GitLab CI, etc.), set `RP_LAUNCH_ID` in the pipeline script:

```bash
# GitLab CI example
script:
  - export RP_LAUNCH_UUID=$(uuidgen)
  - export RP_LAUNCH_ID=$(uuidgen)  # Can use same or different UUID
  - xcodebuild test -scheme YourScheme -destination 'platform=iOS Simulator,name=iPhone 15' ...
```

The agent will automatically detect and use these environment variables.
