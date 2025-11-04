# Xcode Pre-Action Script for UUID Coordination (OPTIONAL)

> **ℹ️ Note**: This setup is **OPTIONAL** for most use cases. The agent works out-of-the-box with zero configuration for simulator testing.

## When Do You Need This?

**✅ You NEED this for:**
- Parallel testing on **real devices** (isolated sandboxes require explicit UUID)
- CI/CD pipelines with complex coordination requirements
- Debugging coordination issues
- Explicit control over launch UUID for tracking

**❌ You DON'T need this for:**
- **Local simulator testing** (auto-generation works perfectly)
- **CI/CD simulator testing** (auto-generation works perfectly)
- **90% of use cases** (let the agent handle it automatically)

## How Auto-Generation Works (Zero Config)

When you don't set `RP_LAUNCH_UUID`, the agent automatically:
1. Generates a proper RFC 4122 UUID using `UUID().uuidString`
2. All workers in the same Xcode test run share the same process group ID (PGID)
3. Workers coordinate using the generated UUID
4. Result: **Single unified launch** in ReportPortal

**Example log output (auto-generation):**
```
⚙️ [ReportPortal] No RP_LAUNCH_UUID env var, auto-generating (PID: 5263, PGID: 5263)
🔧 [ReportPortal] Generated UUID: CADF496A-7B77-42A2-BAA8-6F263FA99F91
✅ [ReportPortal] Launch created successfully - ID: CADF496A-7B77-42A2-BAA8-6F263FA99F91
```

## Manual Setup (Advanced Users)

If you need explicit control (real devices, CI/CD), follow these steps:

1. **Open Xcode** → Select your scheme → **Edit Scheme** (⌘<)
2. Navigate to **Test** → **Pre-Actions** → Click **+** → **New Run Script Action**
3. Paste this script:

```bash
#!/bin/bash
# Generate RFC 4122 UUID for ReportPortal coordination
export RP_LAUNCH_UUID=$(uuidgen)
echo "🚀 ReportPortal Launch UUID: $RP_LAUNCH_UUID"
```

4. Set **"Provide build settings from"** to your **test target**
5. Click **Close**
6. Run tests (**⌘U**)

## Benefits of Manual UUID

- **Explicit control**: You choose the UUID format and generation strategy
- **Real device support**: Required for parallel testing across multiple real devices
- **CI/CD integration**: Integrate with pipeline UUIDs for traceability
- **Debugging**: Easier to track specific test runs

## CI/CD Setup

```bash
# GitLab CI / GitHub Actions / Jenkins
# Generate RFC 4122 UUID for ReportPortal coordination
export RP_LAUNCH_UUID=$(uuidgen)
xcodebuild test -scheme MyApp -parallel-testing-enabled YES
```

## Verification

After running tests, check console for:
```
🌍 [ReportPortal] UUID from environment: 550E8400-E29B-41D4-A716-446655440000
✅ [ReportPortal] Launch created successfully - ID: abc-123-def
⚡️ [ReportPortal] 409 Conflict - Worker joining existing launch
✅ [ReportPortal] Extracted launch ID from 409 response: abc-123-def
```

Check ReportPortal UI:
- Only **1 launch** (not 2 or more)
- All test results from all simulators in that launch
- Correct aggregated status (PASSED/FAILED)

## Troubleshooting

**Problem**: Multiple launches created  
**Solution**: Verify all workers have same `RP_LAUNCH_UUID` (check logs)

**Problem**: 409/404 logged as errors  
**Solution**: Update to latest version (should be INFO level)

**Problem**: Workers can't read environment variable  
**Solution**: Ensure "Provide build settings from" is set to test target

## Advanced: UUID Best Practices

**Important**: ReportPortal v2 API **requires** RFC 4122 UUID format. Custom string formats will be rejected.

```bash
# ✅ Correct: Generate proper UUID
export RP_LAUNCH_UUID=$(uuidgen)

# ✅ Correct: Use existing UUID variable
export RP_LAUNCH_UUID="${CI_PIPELINE_UUID}"  # If your CI provides one

# ❌ Wrong: Custom string formats won't work
# export RP_LAUNCH_UUID="MyApp_20251031_12345"  # ReportPortal will reject this
```

**Why RFC 4122 format?**
- ReportPortal API validates UUID format server-side
- Custom formats cause each worker to create separate launches
- Results in multiple reports instead of 1 unified report

## No Pre-Action? Automatic Fallback

If you don't set `RP_LAUNCH_UUID`, the agent will:
1. **Auto-generate** a proper RFC 4122 UUID using `UUID().uuidString`
2. **⚠️ Each worker generates its own UUID** (not coordinated)
3. **Results in multiple launches** (one per worker/process group)

**Why this creates multiple launches:**
- Each test worker process generates its own random UUID
- No shared UUID = no coordination = separate launches

**Recommendation**: **Always set the pre-action script** for guaranteed single launch! 🎯

---

**Last Updated**: 2025-01-31  
**Agent Version**: 4.0.0+  
**ReportPortal API**: v2 (async)
