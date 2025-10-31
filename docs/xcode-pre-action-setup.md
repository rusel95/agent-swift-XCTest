# Xcode Pre-Action Script for UUID Coordination

## Quick Setup (30 seconds)

1. **Open Xcode** → Select your scheme → **Edit Scheme** (⌘<)
2. Navigate to **Test** → **Pre-Actions** → Click **+** → **New Run Script Action**
3. Paste this script:

```bash
#!/bin/bash
# Generate unique launch UUID for ReportPortal coordination
export RP_LAUNCH_UUID="MyAppTests_$(date +%Y%m%d_%H%M%S)_$(ps -o pgid= -p $$)"
echo "🚀 Launch UUID: $RP_LAUNCH_UUID"
```

4. Set **"Provide build settings from"** to your **test target**
5. Click **Close**
6. Run tests (**⌘U**) - coordination happens automatically! 🎉

## What This Does

- **Generates unique UUID** using timestamp + process group ID
- **All test workers inherit** this environment variable
- **Workers coordinate** using the same UUID (no file locks needed)
- **Works for simulators AND real devices** 📱

## CI/CD Setup

```bash
# GitLab CI / GitHub Actions / Jenkins
export RP_LAUNCH_UUID="CI_${CI_JOB_NAME}_${CI_PIPELINE_ID}_$(date +%s)"
xcodebuild test -scheme MyApp -parallel-testing-enabled YES
```

## Verification

After running tests, check logs for:
```
✅ Generated Launch UUID: MyAppTests_20251031_143022_12345
✅ Launch already created by another worker (409 Conflict) [INFO]
✅ Launch already finished by another worker [INFO]
```

Check ReportPortal UI:
- Only **1 launch** with your UUID as name
- All test results in that launch
- Correct aggregated status (PASSED/FAILED)

## Troubleshooting

**Problem**: Multiple launches created  
**Solution**: Verify all workers have same `RP_LAUNCH_UUID` (check logs)

**Problem**: 409/404 logged as errors  
**Solution**: Update to latest version (should be INFO level)

**Problem**: Workers can't read environment variable  
**Solution**: Ensure "Provide build settings from" is set to test target

## Advanced: Custom UUID Format

Want a different format? Customize the generation:

```bash
# Include git branch
export RP_LAUNCH_UUID="MyApp_$(git branch --show-current)_$(date +%s)"

# Include device type (for real devices)
export RP_LAUNCH_UUID="MyApp_iPhone15Pro_$(date +%Y%m%d_%H%M%S)"

# Pure UUID (most unique, less readable)
export RP_LAUNCH_UUID=$(uuidgen)
```

## No Pre-Action? Automatic Fallback

If you don't set `RP_LAUNCH_UUID`, the agent will:
1. **Auto-generate** UUID (simulators)
2. **Fall back to file lock** coordination (simulators only)
3. **Create separate launches** (real devices without UUID)

**Recommendation**: Always set the pre-action for best experience! 🎯

---

**Last Updated**: 2025-01-31  
**Agent Version**: 4.0.0+  
**ReportPortal API**: v2 (async)
