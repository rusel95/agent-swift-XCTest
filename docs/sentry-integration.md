# Sentry Integration for Distributed Logging

## Overview

Sentry is now integrated to capture warnings and errors from **all parallel test workers**, not just the primary process visible in Xcode console.

## What Gets Logged

### Warnings (Breadcrumbs)
- **All warning messages** are added as Sentry breadcrumbs
- Includes context: file, line, thread, correlation ID
- Helps trace the sequence of events leading to errors

### Errors (Events)
- **All error messages** are captured as Sentry events
- Full context included:
  - Source file and line number
  - Thread name
  - Process ID (PID) and Process Group ID (PGID)
  - Correlation ID for tracing
- Appears in Sentry dashboard with full stack trace

## Example Logs You'll See in Sentry

### Launch Coordination Errors
```
❌ HTTP error 500 during launch creation
Context:
- file: ReportingService.swift
- line: 128
- pid: 12345
- pgid: 12345
- correlationID: abc123...
```

### 409 Conflict Warnings
```
⚠️ Could not extract ID from 409 response, using provided UUID as launch ID
Context:
- file: ReportingService.swift
- line: 117
- thread: Thread 5
- correlationID: def456...
```

## Benefits

### 1. **See All Workers**
- Xcode console only shows primary process
- Sentry aggregates logs from all 5 simulators

### 2. **Correlation Tracking**
- Every log includes correlation ID
- Trace a single test across multiple workers

### 3. **Historical Analysis**
- Logs persist in Sentry dashboard
- Debug issues that happened hours/days ago

### 4. **Process Group Visibility**
- See which workers are in which PGID
- Understand why multiple launches were created

## Configuration

### Environment Variables

Enable detailed logging:
```bash
export RP_LOG_ENABLED=true
export RP_LOG_LEVEL=DEBUG
```

### Log Levels

- `DEBUG`: All logs (verbose)
- `INFO`: Normal operations (default)
- `WARNING`: Potential issues (**sent to Sentry**)
- `ERROR`: Failures (**sent to Sentry**)

## Viewing Logs in Sentry

1. Open Sentry dashboard: [https://sentry.io](https://sentry.io)
2. Navigate to your project
3. Filter by:
   - **Tag**: `component:ReportPortalAgent`
   - **Tag**: `correlationID:<uuid>` (for specific test)
   - **Tag**: `file:ReportingService.swift` (for specific component)

### Useful Queries

**Find all 409 Conflicts:**
```
message:"409 Conflict"
```

**Find errors from specific worker:**
```
extra.pgid:12345
```

**Find all coordination issues:**
```
file:ReportingService.swift level:error
```

## Integration Details

### Code Location
- **File**: [Sources/Utilities/Logger.swift](../Sources/Utilities/Logger.swift)
- **Lines**: 116-167

### Conditional Compilation
- Uses `#if canImport(Sentry)` to avoid breaking non-Sentry builds
- SPM builds work without Sentry
- Xcode builds include Sentry automatically

### What's Sent
**Breadcrumbs** (for warnings):
- Message
- File, line, thread
- Correlation ID
- Level: warning

**Events** (for errors):
- Message
- Tags: component, file, correlationID
- Extra context: line, thread, PID, PGID
- Level: error

## Performance Impact

- **Minimal**: Only warnings and errors are sent
- **Async**: Sentry uploads asynchronously
- **Batched**: Multiple events batched together
- **Sample Rate**: 50% profiling, 50% traces (configured in AppDelegate)

## Troubleshooting

### Logs not appearing in Sentry

**Check:**
1. Logging is enabled: `export RP_LOG_ENABLED=true`
2. Sentry DSN is configured in AppDelegate
3. Network connectivity (Sentry uses HTTPS)

### Too much noise

**Solution:**
```bash
# Only log errors
export RP_LOG_LEVEL=ERROR
```

### Need more detail

**Solution:**
```bash
# Include debug logs
export RP_LOG_LEVEL=DEBUG
```

## Next Steps

1. **Add pre-action script** to fix multiple launches issue
2. **Run tests** with `RP_LOG_ENABLED=true`
3. **Check Sentry dashboard** to see all worker logs
4. **Filter by PGID** to understand process grouping

---

**Last Updated**: 2025-10-31
**Sentry SDK Version**: Latest
**Integration Status**: ✅ Active
