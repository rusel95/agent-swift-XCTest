# Xcode Pre-Action Script for UUID Coordination

## Quick Setup (30 seconds)

1. **Open Xcode** → Select your scheme → **Edit Scheme** (⌘<)
2. Navigate to **Test** → **Pre-Actions** → Click **+** → **New Run Script Action**
3. Paste this script:

```bash
#!/bin/bash
# Generate RFC 4122 UUID for ReportPortal coordination
# Use uuidgen to create a proper UUID format that ReportPortal expects
export RP_LAUNCH_UUID=$(uuidgen)
echo "🚀 ReportPortal Launch UUID: $RP_LAUNCH_UUID"
```

4. Set **"Provide build settings from"** to your **test target**
5. Click **Close**
6. Run tests (**⌘U**) - coordination happens automatically! 🎉

## What This Does

- **Generates proper RFC 4122 UUID** (required by ReportPortal API)
- **All test workers inherit** this environment variable from Xcode
- **Workers coordinate** using the same UUID (409 Conflict handling)
- **Works for simulators AND real devices** 📱
- **Critical**: ReportPortal v2 API requires standard UUID format (8-4-4-4-12 hex digits)

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
