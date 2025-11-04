# Migrating from File Lock to Hybrid Coordination (v3.x → v4.0.0)

## Overview

Version 4.0.0 introduces a **hybrid coordination approach** that combines UUID-based launch coordination with optional file-based suite/finish coordination. This replaces the previous POSIX file lock implementation used in v3.x.

## What Changed

### Removed Components
- ❌ **LaunchCoordinator.swift** - File lock-based launch coordination
- ❌ **LaunchIdLock.swift** - POSIX flock wrapper
- ❌ Environment variable `RP_LAUNCH_LOCK_FILE` - No longer used

### New Components
- ✅ **UUID-based Launch Coordination** - ReportPortal v2 API with 409 Conflict handling
- ✅ **File-based Suite Coordination** - Prevents duplicate suites (simulators only)
- ✅ **File-based Finish Coordination** - Single finish call with status aggregation (simulators only)
- ✅ **Platform Detection** - Automatic simulator vs real device detection

### Coordination Strategy

| Coordination Type | v3.x Approach | v4.0 Approach |
|-------------------|---------------|---------------|
| Launch Creation | POSIX file locks | UUID with 409 Conflict |
| Suite Creation | Direct API calls (duplicates) | File-based deduplication |
| Launch Finish | Tolerant 404/409 | Single finish with aggregation |
| Real Devices | Full coordination | Launch only |
| Simulators | Full coordination | Full coordination |

## Breaking Changes

### Version: 4.0.0 (MAJOR)

**Breaking changes from v3.x:**

1. **Minimum Swift Version**: Swift 5.5+ required (async/await, Actor model)
2. **Minimum iOS Version**: iOS 13+ (Swift Concurrency runtime)
3. **API Changes**:
   - `ReportingService.startLaunchV2()` now accepts optional `uuid` parameter
   - `ReportingService.finalizeLaunchV2()` signature changed (added coordination parameters)
   - Removed file lock-based coordination classes

4. **Environment Variables**:
   - ⚠️ **Removed**: `RP_LAUNCH_LOCK_FILE` (no longer used)
   - ✅ **New**: `RP_LAUNCH_UUID` (optional, recommended for CI/CD)

5. **File Paths**:
   - Old: `/tmp/reportportal_launch.lock` (lock file)
   - New: `/tmp/reportportal/launch_{uuid}_*.txt` (coordination files)
   - New: `/tmp/reportportal/suite_*_{launchID}.*` (suite sync files)

## Migration Steps

### For Most Users (Simulators)

**Good news: No action required!** 🎉

The new hybrid coordination is **backward compatible** for simulator testing:

1. ✅ Launch coordination happens automatically via UUID
2. ✅ Suite deduplication works out of the box
3. ✅ Single finish call with correct status aggregation
4. ✅ All coordination files cleaned up automatically

**Optional: Set RP_LAUNCH_UUID for reproducibility**

If you want guaranteed single launch in CI/CD, set the UUID in your pre-action script:

```bash
# Old approach (v3.x) - Don't use anymore
export RP_LAUNCH_LOCK_FILE="/tmp/reportportal_launch.lock"

# New approach (v4.0) - Recommended
export RP_LAUNCH_UUID=$(uuidgen)
```

See [xcode-pre-action-setup.md](xcode-pre-action-setup.md) for complete setup.

### For Real Device Testing

**Important**: File-based coordination (suite/finish) is **not available** on real devices.

**What works:**
- ✅ UUID-based launch coordination (single launch across workers)
- ✅ Launch creation with 409 Conflict handling

**What doesn't work:**
- ❌ Suite deduplication (may create duplicate suites)
- ❌ Single finish coordination (may have multiple finish attempts)

**Fallback behavior:**
- Direct API calls for suite creation (as in v3.x)
- Tolerant finish handling (first succeeds, others get 404/409)

**Recommendation**: Use simulators for parallel testing to get full coordination benefits.

### Cleanup Old Environment Variables

Remove these from your Xcode schemes or CI/CD scripts:

```bash
# Remove these (v3.x only)
unset RP_LAUNCH_LOCK_FILE
```

Keep these (still needed):

```bash
# Required
ReportPortalURL="https://your-instance.com/api/v1"
ReportPortalProjectName="your-project"
ReportPortalToken="your-token"
ReportPortalLaunchName="iOS Tests"
PushTestDataToReportPortal="true"

# Optional (recommended for parallel testing)
export RP_LAUNCH_UUID=$(uuidgen)
```

## Validation

### How to Verify Migration Success

**1. Check Logs**

Look for these log messages confirming coordination:

```
🌍 [ReportPortal] UUID from environment: {uuid}
✅ Platform: iOS Simulator - Full coordination enabled
✅ RP_LAUNCH_UUID format valid: {uuid}
📱 [ReportPortal] Running on Simulator - file-based coordination available
```

**2. Verify Single Launch**

Run parallel tests (5+ workers) and check ReportPortal:
- ✅ Should see exactly **1 launch** (not 5+)
- ✅ All test results under that single launch
- ✅ Correct hierarchy: Launch → Suites → Tests

**3. Verify Suite Deduplication**

With 10 test classes × 5 workers:
- ✅ Should see exactly **10 suites** (not 50)
- ✅ All tests from all workers appear under correct suite

**4. Verify Single Finish**

Check ReportPortal API logs or traces:
- ✅ Should see exactly **1 finish API call**
- ✅ Launch status reflects aggregated result (FAILED > STOPPED > SKIPPED > PASSED)

### Troubleshooting

**Issue**: Multiple launches created

**Solution**:
```bash
# Set RP_LAUNCH_UUID in pre-action script
export RP_LAUNCH_UUID=$(uuidgen)
```

**Issue**: Duplicate suites on real devices

**Expected**: This is normal - suite deduplication only works on simulators. Consider:
- Use simulators for parallel testing
- Accept duplicate suites on real devices (tests still run correctly)

**Issue**: Invalid UUID format warning

**Solution**:
```bash
# Ensure UUID is RFC 4122 format (use uuidgen)
export RP_LAUNCH_UUID=$(uuidgen)

# Example valid: 550e8400-e29b-41d4-a716-446655440000
# Invalid: "TestLaunch_1234" (use proper UUID)
```

**Issue**: Files not cleaned up in /tmp/reportportal/

**Solution**:
- Check simulator has write permissions
- Files are cleaned automatically - if persisting, check for crashes
- Manual cleanup: `rm -rf /tmp/reportportal/`

## Technical Details

### Hybrid Coordination Flow

**Launch Coordination (UUID-based):**
```
Worker 1: POST /launch (uuid=ABC) → 201 Created (id=123)
Worker 2: POST /launch (uuid=ABC) → 409 Conflict (id=123)
Worker 3: POST /launch (uuid=ABC) → 409 Conflict (id=123)
All workers use launch ID: 123 ✅
```

**Suite Coordination (File-based, simulators):**
```
Worker 1: Acquire lock → Check sync file → Create suite → Write ID → Release lock
Worker 2: Acquire lock → Read sync file → Use existing suite ID → Release lock
Worker 3: Acquire lock → Read sync file → Use existing suite ID → Release lock
All workers use same suite ID ✅
```

**Finish Coordination (File-based, simulators):**
```
Worker 1: Record PASSED → Check workers → Not last → Skip finish
Worker 2: Record PASSED → Check workers → Not last → Skip finish
Worker 3: Record FAILED → Check workers → Last worker → Aggregate → Finish (status=FAILED) ✅
```

### File Structure

```
/tmp/reportportal/
├── launch_{uuid}_workers.txt          # Worker registration
├── launch_{uuid}_statuses.txt         # Status aggregation
├── launch_{uuid}_finish.lock          # Finish coordination lock
├── suite_{name}_{launchID}.id         # Suite ID cache
└── suite_{name}_{launchID}.lock       # Suite coordination lock
```

All files cleaned up automatically after test run.

## Benefits of v4.0

✅ **Simpler**: No manual lock file management  
✅ **Cross-platform**: UUID works on simulators AND real devices  
✅ **Scalable**: File-based coordination handles 100+ suites efficiently  
✅ **Reliable**: Single finish call with correct status aggregation  
✅ **Observable**: Comprehensive logging with correlation IDs  
✅ **Safe**: Automatic cleanup, no leftover files  

## Need Help?

- 📖 [Setup Guide](xcode-pre-action-setup.md)
- 📖 [Multi-Worker Coordination](multi-worker-coordination.md)
- 📖 [Sentry Integration](sentry-integration.md)
- 🐛 [GitHub Issues](https://github.com/reportportal/agent-swift-XCTest/issues)

## Version History

- **v4.0.0** (2025-11-04): Hybrid coordination (UUID + file-based)
- **v3.x.x**: POSIX file lock coordination (deprecated)
