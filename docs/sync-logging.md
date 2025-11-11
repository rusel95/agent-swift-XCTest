# Centralized Synchronization Logging

## Overview

A **shared, thread-safe log file** that captures synchronization events from all devices/simulators in one place.

**Log File Location:** `/Users/Ruslan_Popesku/Desktop/reportportal_sync.log`

## Log Format

```
[timestamp] [PID] [device_id] [category] message
```

### Example

```
[2025-11-06 10:32:18.123] [2555] [2555_2555] [LAUNCH] Creating/joining with UUID: B60EA9AC-3C83-4D02-970C-74127CD73B0E
[2025-11-06 10:32:18.456] [2555] [2555_2555] [LAUNCH] Launch created - ID: B60EA9AC-3C83-4D02-970C-74127CD73B0E
[2025-11-06 10:32:18.789] [2555] [2555_2555] [WORKER] Registered: 2555_2555 for UUID: B60EA9AC-3C83-4D02-970C-74127CD73B0E
[2025-11-06 10:32:19.012] [2555] [2555_2555] [SUITE] Registered 'ParallelCalculationsUITests' - UUID: B60EA9AC-..., Total active: 1
[2025-11-06 10:32:25.345] [3010] [3010_3010] [LAUNCH] Creating/joining with UUID: B60EA9AC-3C83-4D02-970C-74127CD73B0E
[2025-11-06 10:32:25.678] [3010] [3010_3010] [WORKER] Registered: 3010_3010 for UUID: B60EA9AC-3C83-4D02-970C-74127CD73B0E
[2025-11-06 10:32:25.901] [3010] [3010_3010] [SUITE] Registered 'ParallelNavigationUITests' - UUID: B60EA9AC-..., Total active: 2
```

## Fields

| Field | Description | Example |
|-------|-------------|---------|
| **timestamp** | When the event occurred | `2025-11-06 10:32:18.123` |
| **PID** | Process ID (unique per simulator) | `2555` |
| **device_id** | PID_PGID format | `2555_2555` |
| **category** | Event type | `LAUNCH`, `SUITE`, `WORKER`, `FINISH` |
| **message** | Event details | `Registered: 2555_2555 for UUID: ...` |

## Categories

### LAUNCH
- Launch creation/joining
- UUID coordination
- Launch ID assignment

### SUITE
- Suite registration (start)
- Suite unregistration (finish)
- Active suite counts

### WORKER
- Worker registration
- Worker unregistration
- Worker count tracking

### FINISH
- Finalization attempts
- 409 conflict handling
- Success/failure outcomes

### UUID
- UUID generation
- UUID file coordination
- Stale UUID detection

### FILE
- File-based coordination
- Lock acquisition/release
- File I/O operations

### BUNDLE
- Test bundle lifecycle
- Bundle count tracking

## Usage

### Run Tests

Tests automatically write to the log file:

```bash
# Run from Xcode (Cmd+U)
# Or from command line:
xcodebuild test -scheme ReportPortalAgent -destination 'platform=iOS Simulator,name=iPhone 15'
```

### View Logs

```bash
# Tail the log in real-time
tail -f /Users/Ruslan_Popesku/Desktop/reportportal_sync.log

# View entire log
cat /Users/Ruslan_Popesku/Desktop/reportportal_sync.log

# Filter by device
grep "\[2555\]" /Users/Ruslan_Popesku/Desktop/reportportal_sync.log

# Filter by category
grep "\[FINISH\]" /Users/Ruslan_Popesku/Desktop/reportportal_sync.log

# Filter by UUID
grep "B60EA9AC-3C83-4D02-970C-74127CD73B0E" /Users/Ruslan_Popesku/Desktop/reportportal_sync.log
```

### Clear Logs

```bash
# Delete the log file to start fresh
rm /Users/Ruslan_Popesku/Desktop/reportportal_sync.log
```

## Analysis Examples

### Track a Single Device

```bash
# All events from device 2555
grep "\[2555\]" reportportal_sync.log
```

### Trace a Launch UUID

```bash
# All events for a specific launch
grep "B60EA9AC-3C83-4D02-970C-74127CD73B0E" reportportal_sync.log
```

### Find Finalization Issues

```bash
# See which device finalized successfully
grep "\[FINISH\].*SUCCESS" reportportal_sync.log

# See which devices got 409
grep "\[FINISH\].*409" reportportal_sync.log

# See finalization errors
grep "\[FINISH\].*ERROR" reportportal_sync.log
```

### Timeline of Events

```bash
# Events in chronological order (already sorted by timestamp)
cat reportportal_sync.log | grep "\[SUITE\]"
```

## Thread Safety

The `SyncLogger` uses file locking to ensure thread-safe writes:

1. **Acquire lock**: Creates `.lock` file
2. **Write**: Appends log line
3. **Release lock**: Removes `.lock` file

Multiple devices can write simultaneously without corruption.

## Benefits

✅ **Single Source of Truth**: All devices write to one file
✅ **Perfect Timeline**: Chronological order across all devices  
✅ **Easy Debugging**: Grep/filter by device, category, UUID
✅ **No Lost Logs**: Thread-safe writes prevent data loss
✅ **Desktop Access**: Easy to view, share, or analyze

## Console vs File

- **Console**: Still shows real-time progress (kept for now)
- **File**: Complete historical record for analysis

Both are synchronized - same messages go to both.

## Example Session

```
================================================================================
ReportPortal Synchronization Log
Started: 2025-11-06 10:32:00.000
Format: [timestamp] [PID] [device_id] [category] message
================================================================================

[2025-11-06 10:32:18.123] [2555] [2555_2555] [UUID] Previous run detected (age: 409s) - creating fresh launch
[2025-11-06 10:32:18.124] [2555] [2555_2555] [UUID] First worker - wrote launch UUID to file: B60EA9AC-3C83-4D02-970C-74127CD73B0E
[2025-11-06 10:32:18.200] [2555] [2555_2555] [LAUNCH] Creating/joining with UUID: B60EA9AC-3C83-4D02-970C-74127CD73B0E
[2025-11-06 10:32:18.500] [2555] [2555_2555] [LAUNCH] Launch created - ID: B60EA9AC-3C83-4D02-970C-74127CD73B0E
[2025-11-06 10:32:18.600] [2555] [2555_2555] [WORKER] Registered: 2555_2555 for UUID: B60EA9AC-3C83-4D02-970C-74127CD73B0E
[2025-11-06 10:32:19.000] [2555] [2555_2555] [SUITE] Registered 'ParallelCalculationsUITests' - UUID: B60EA9AC-..., Total active: 1
[2025-11-06 10:33:00.000] [2555] [2555_2555] [SUITE] Unregistered 'ParallelCalculationsUITests' - UUID: B60EA9AC-..., Remaining: 0
[2025-11-06 10:33:00.100] [2555] [2555_2555] [FINISH] All suites done! Checking finalization - UUID: B60EA9AC-...
[2025-11-06 10:33:00.200] [2555] [2555_2555] [FINISH] Worker 2555_2555 attempting finalization - UUID: B60EA9AC-..., Status: PASSED, LaunchID: B60EA9AC-...
[2025-11-06 10:33:00.500] [2555] [2555_2555] [FINISH] SUCCESS - Launch finalized - ID: B60EA9AC-..., status: PASSED
```

## Tips

1. **Keep file open in editor** during test runs to see real-time updates
2. **Use grep** to filter by device/category/UUID
3. **Compare timestamps** to understand timing issues
4. **Share the file** when asking for help - it has complete context!
