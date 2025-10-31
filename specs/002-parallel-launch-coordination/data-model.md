# Data Model: Parallel Launch Coordination

**Feature**: 002-parallel-launch-coordination
**Date**: 2025-01-30
**Status**: Complete

## Overview

This document defines the core entities, their relationships, state transitions, and validation rules for the parallel launch coordination feature.

## Entity Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     Coordination Session                     │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Session ID (PGID or RP_SESSION_ID)                     │ │
│  │ Launch Name                                             │ │
│  │ Start Time                                              │ │
│  └────────────────────────────────────────────────────────┘ │
│                              │                               │
│                              │ manages                       │
│                              ▼                               │
│      ┌──────────────────────────────────────────┐           │
│      │           Launch (ReportPortal)          │           │
│      │  ┌────────────────────────────────────┐  │           │
│      │  │ Launch ID (UUID)                   │  │           │
│      │  │ Launch Name                        │  │           │
│      │  │ Status (PASSED/FAILED)             │  │           │
│      │  │ Start Time                         │  │           │
│      │  │ End Time                           │  │           │
│      │  └────────────────────────────────────┘  │           │
│      └──────────────────────────────────────────┘           │
│                              │                               │
│                              │ reported by                   │
│                              ▼                               │
│      ┌──────────────────────────────────────────┐           │
│      │         Worker (Test Process)            │           │
│      │  ┌────────────────────────────────────┐  │           │
│      │  │ Worker ID (UUID)                   │  │           │
│      │  │ Process ID                         │  │           │
│      │  │ Role (Primary/Secondary)           │  │           │
│      │  │ Status (Running/Completed)         │  │           │
│      │  │ Test Count                         │  │           │
│      │  └────────────────────────────────────┘  │           │
│      └──────────────────────────────────────────┘           │
│                              │                               │
│                              │ executes                      │
│                              ▼                               │
│      ┌──────────────────────────────────────────┐           │
│      │           Test Result                    │           │
│      │  ┌────────────────────────────────────┐  │           │
│      │  │ Test Name                          │  │           │
│      │  │ Status (PASSED/FAILED/SKIPPED)     │  │           │
│      │  │ Start Time                         │  │           │
│      │  │ End Time                           │  │           │
│      │  │ Error Message (if failed)          │  │           │
│      │  └────────────────────────────────────┘  │           │
│      └──────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────┘

Storage:
┌────────────────────────────────────────────────────────┐
│  File System (/tmp/reportportal_coordination/)         │
│  ┌──────────────────────────────────────────────────┐  │
│  │ launch_{name}_{session}.lock (POSIX flock)       │  │
│  │ launch_{name}_{session}.sync (Launch ID storage) │  │
│  │ events_{pgid}.log (Coordination event log)       │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────┘
```

## Core Entities

### 1. Coordination Session

Represents a single coordinated test run with multiple workers.

**Properties**:
```swift
struct CoordinationSession {
    let sessionID: String          // PGID or RP_SESSION_ID
    let launchName: String          // ReportPortal launch name
    let startTime: Date
    var endTime: Date?
    var workers: [Worker]
    var launchID: String?           // ReportPortal Launch ID (when created)
}
```

**Lifecycle**:
1. Created when first worker starts test execution
2. Workers register themselves during startup
3. Launch ID set when primary worker creates launch
4. Workers mark themselves complete as they finish
5. Session ends when all workers complete

**Validation Rules**:
- `sessionID` must not be empty
- `launchName` must not be empty
- `workers` must have at least 1 worker
- `launchID` set only after primary worker creates launch
- `endTime` set only after all workers complete

---

### 2. Launch (ReportPortal Entity)

Represents a test execution session in ReportPortal containing results from all workers.

**Properties**:
```swift
struct Launch {
    let launchID: String            // UUID from ReportPortal
    let launchName: String          // User-defined launch name
    var status: LaunchStatus        // Aggregated status
    let startTime: Date
    var endTime: Date?
    let mode: LaunchMode            // DEFAULT/DEBUG
    let attributes: [String: String]? // Tags, metadata
}

enum LaunchStatus {
    case passed
    case failed
    case stopped
    case interrupted
}

enum LaunchMode {
    case DEFAULT
    case DEBUG
}
```

**State Transitions**:
```
         ┌─────────┐
    ────▶│ Created │
         └────┬────┘
              │ Primary worker calls POST /v2/launch
              ▼
         ┌─────────┐
         │ Running │◀───── Secondary workers join
         └────┬────┘       (use shared Launch ID)
              │
              │ Workers report test results
              │ Status updates to worst result
              │
              ▼
         ┌──────────┐
         │ Finished │
         └──────────┘
              │ Last worker calls PUT /v2/launch/{id}/finish
              ▼
         ┌─────────┐
         │ Merged  │ (if using v2 merge API)
         └─────────┘
```

**Validation Rules**:
- `launchID` must be valid UUID
- `launchName` must not be empty
- `status` follows severity hierarchy: FAILED > STOPPED > PASSED
- `endTime` must be after `startTime`
- Launch cannot finish until all workers complete

**Status Aggregation Logic**:
```swift
func aggregateStatus(_ statuses: [TestStatus]) -> LaunchStatus {
    // Worst status wins
    if statuses.contains(.failed) {
        return .failed
    }
    if statuses.contains(.stopped) || statuses.contains(.interrupted) {
        return .stopped
    }
    return .passed
}
```

---

### 3. Worker (Test Process)

Represents a single test process (simulator) executing a subset of tests.

**Properties**:
```swift
struct Worker {
    let workerID: String            // Unique UUID
    let processID: Int              // OS process ID
    let role: WorkerRole            // Primary or Secondary
    var status: WorkerStatus        // Running or Completed
    let startTime: Date
    var endTime: Date?
    var testCount: Int              // Number of tests executed
    var testResults: [TestResult]   // Test outcomes
}

enum WorkerRole {
    case primary                    // Obtained main lock, creates Launch
    case secondary                  // Reads existing Launch ID
}

enum WorkerStatus {
    case running
    case completed
    case crashed                    // Detected via timeout/staleness
}
```

**State Transitions**:
```
    ┌─────────────┐
    │   Started   │
    └──────┬──────┘
           │ Worker attempts to acquire .lock file
           │
           ▼
     ┌──────────────────┐
     │ Role Determined  │
     └────┬────┬────────┘
          │    │
  Primary │    │ Secondary
          │    │
          ▼    ▼
    ┌─────┐  ┌──────────┐
    │Lock │  │Read .sync│
    │Held │  │   File   │
    └──┬──┘  └────┬─────┘
       │          │
       │          │
       ▼          ▼
    ┌───────────────┐
    │   Running     │◀──── Executing tests
    └───────┬───────┘      Reporting results
            │
            │ All tests complete
            ▼
    ┌───────────────┐
    │  Completed    │
    └───────────────┘
```

**Validation Rules**:
- `workerID` must be unique within session
- `processID` must be valid OS PID
- `role` set during coordination phase (cannot change)
- Only primary worker can create Launch
- `endTime` must be after `startTime`
- `testResults` must match `testCount`

**Role Assignment**:
```swift
func determineRole() async throws -> WorkerRole {
    // Try to acquire exclusive lock on .lock file
    let lockAcquired = try await acquireLock()

    if lockAcquired {
        // This worker obtained lock → PRIMARY
        return .primary
    } else {
        // Another worker holds lock → SECONDARY
        return .secondary
    }
}
```

---

### 4. Test Result

Represents the outcome of a single test execution.

**Properties**:
```swift
struct TestResult {
    let testName: String            // Full test name (suite + test)
    let status: TestStatus          // Test outcome
    let startTime: Date
    let endTime: Date
    let duration: TimeInterval      // Calculated: endTime - startTime
    let errorMessage: String?       // Present if status == .failed
    let stackTrace: String?         // Stack trace for failures
    let logs: [String]              // Test logs
}

enum TestStatus {
    case passed
    case failed
    case skipped
    case cancelled
    case stopped
    case reseted
}
```

**Validation Rules**:
- `testName` must not be empty
- `endTime` must be after `startTime`
- `duration` must equal `endTime - startTime`
- `errorMessage` required if `status == .failed`
- `stackTrace` optional but recommended for failures

---

## File-Based Coordination

### Lock File Format

**File**: `/tmp/reportportal_coordination/launch_{name}_{session}.lock`

**Purpose**: Exclusive lock for determining primary worker

**Content**: Empty file (lock state is file descriptor status)

**Locking Mechanism**:
```c
// POSIX flock (exclusive, non-blocking)
int fd = open(lockFile, O_WRONLY | O_CREAT, 0644);
int result = flock(fd, LOCK_EX | LOCK_NB);

if (result == 0) {
    // Lock acquired → PRIMARY WORKER
} else {
    // Lock failed → SECONDARY WORKER
}
```

---

### Sync File Format

**File**: `/tmp/reportportal_coordination/launch_{name}_{session}.sync`

**Purpose**: Storage for shared Launch ID

**Content Format**:
```
<Launch UUID>
<workerID>:<timestamp>
```

**Example**:
```
a1b2c3d4-e5f6-7890-abcd-ef1234567890
worker-uuid-123:1706659200.123
```

**Line 1**: ReportPortal Launch ID (UUID)
**Line 2**: Writer metadata (worker ID and timestamp)

**Operations**:
```swift
// Write (by Primary Worker)
func writeLaunchID(_ id: String) async throws {
    let content = "\(id)\n\(workerID):\(Date().timeIntervalSince1970)\n"
    try content.write(to: syncFile, atomically: true, encoding: .utf8)
}

// Read (by Secondary Workers)
func readLaunchID() async throws -> String {
    let content = try String(contentsOf: syncFile, encoding: .utf8)
    let lines = content.components(separatedBy: "\n")
    return lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
}
```

---

### Event Log Format

**File**: `/tmp/reportportal_coordination/events_{pgid}.log`

**Purpose**: Debugging coordination events

**Content Format** (JSON Lines):
```jsonl
{"timestamp":"2025-01-30T10:30:45Z","type":"Launch","event":"PRIMARY_LOCK_ACQUIRED","workerID":"worker-1","launchID":"uuid-123"}
{"timestamp":"2025-01-30T10:30:46Z","type":"Launch","event":"LAUNCH_CREATED","workerID":"worker-1","launchID":"uuid-123"}
{"timestamp":"2025-01-30T10:30:47Z","type":"Launch","event":"SECONDARY_JOINED","workerID":"worker-2","launchID":"uuid-123"}
{"timestamp":"2025-01-30T10:31:20Z","type":"Worker","event":"COMPLETED","workerID":"worker-1","testCount":25}
{"timestamp":"2025-01-30T10:31:35Z","type":"Worker","event":"COMPLETED","workerID":"worker-2","testCount":30}
{"timestamp":"2025-01-30T10:31:36Z","type":"Launch","event":"FINALIZED","launchID":"uuid-123","totalTests":55}
```

**Fields**:
- `timestamp`: ISO 8601 format
- `type`: Entity type (Launch, Worker, Session)
- `event`: Event name (see Events section)
- `workerID`: UUID of worker
- `launchID`: ReportPortal Launch ID (when applicable)
- Additional context fields

---

## State Management (Actors)

### LaunchCoordinator (Actor)

Manages multi-process coordination via file system.

**State**:
```swift
actor LaunchCoordinator {
    private var launchID: String?
    private let coordinationDirectory: URL
    private let sessionID: String
}
```

**Key Methods**:
```swift
func getOrCreateLaunchID(
    launchName: String,
    createBlock: () async throws -> String
) async throws -> String

func getOrCreateSuiteID(
    suiteName: String,
    createBlock: () async throws -> String
) async throws -> String

func cleanupCoordinationFile(for launchName: String) async
```

---

### LaunchManager (Actor)

Manages single-process launch state with reference counting.

**State**:
```swift
actor LaunchManager {
    private var launchID: String?
    private var launchCreationTask: Task<String, Error>?
    private var activeBundleCount: Int = 0
    private var aggregatedStatus: TestStatus = .passed
    private var isFinalized: Bool = false
    private var launchStartTime: Date?
}
```

**Key Methods**:
```swift
func getOrAwaitLaunchID(launchTask: Task<String, Error>) async throws -> String
func incrementBundleCount()
func decrementBundleCount() -> Bool  // Returns true if should finalize
func updateStatus(_ newStatus: TestStatus)
func getAggregatedStatus() -> TestStatus
func markFinalized()
```

---

### LaunchIdLock (Actor)

Low-level POSIX file locking (based on Java client).

**State**:
```swift
actor LaunchIdLock {
    private let lockFile: URL
    private let syncFile: URL
    private let instanceUuid: String
    private var lockUuid: String?
    private var mainLock: FileHandle?
    private var liveInstances: Set<String> = []
}
```

**Key Methods**:
```swift
func obtainLaunchUuid() async throws -> (uuid: String, isPrimary: Bool)
func getLiveInstanceUuids() -> [String]
func finishInstanceUuid(_ uuid: String) -> Bool  // Returns true if last
func reset()
```

---

## Coordination Events

Events logged to `/tmp/reportportal_coordination/events_{pgid}.log` for debugging.

| Event Name | Description | Logged By | Context |
|------------|-------------|-----------|---------|
| `SESSION_STARTED` | Coordination session created | First worker | sessionID, launchName |
| `WORKER_REGISTERED` | Worker registered with session | Each worker | workerID, processID |
| `PRIMARY_LOCK_ACQUIRED` | Primary worker obtained lock | Primary worker | workerID, lockFile |
| `LAUNCH_CREATED` | Launch created on ReportPortal | Primary worker | launchID, launchName |
| `LAUNCH_ID_WRITTEN` | Launch ID written to .sync file | Primary worker | launchID, syncFile |
| `SECONDARY_JOINED` | Secondary worker joined | Secondary worker | workerID, launchID |
| `LAUNCH_ID_READ` | Secondary read Launch ID | Secondary worker | launchID, syncFile |
| `WORKER_COMPLETED` | Worker finished all tests | Each worker | workerID, testCount |
| `LAUNCH_FINALIZED` | Launch finalized on ReportPortal | Last worker | launchID, totalTests |
| `COORDINATION_ERROR` | Coordination failure | Any worker | errorType, errorMessage |
| `CLEANUP_STARTED` | Cleanup of coordination files | Last worker | sessionID |
| `CLEANUP_COMPLETED` | Cleanup successful | Last worker | filesRemoved |

---

## Validation Summary

### Launch Coordination Rules
1. ✅ Exactly one Launch per coordination session
2. ✅ Exactly one primary worker per session
3. ✅ All secondary workers use same Launch ID
4. ✅ Launch finalized exactly once (by last worker)
5. ✅ Worker count >= 1 (at least one worker required)

### File Coordination Rules
1. ✅ Lock file held exclusively by primary worker
2. ✅ Sync file created before any secondary worker reads
3. ✅ Sync file contains valid UUID on line 1
4. ✅ Event log append-only (no deletions mid-session)
5. ✅ Coordination directory created if not exists

### State Transition Rules
1. ✅ Worker role determined before test execution starts
2. ✅ Launch status updated after each test completes
3. ✅ Worker marked complete only after all its tests finish
4. ✅ Launch finalized only after all workers complete
5. ✅ Coordination files cleaned up after finalization

---

## Implementation Notes

### Thread Safety
- All state mutations happen in actors (LaunchCoordinator, LaunchManager, LaunchIdLock)
- File operations use NSFileCoordinator for coordinated reads/writes
- POSIX flock ensures exclusive lock across processes

### Error Recovery
- Coordination errors trigger retry with exponential backoff
- After max retries, fallback to separate launch (graceful degradation)
- Crashed workers detected via timeout/staleness
- Primary worker crash: next worker can detect and take over (future enhancement)

### Performance
- File operations are I/O bound (~10ms per read/write)
- Lock acquisition is immediate (non-blocking flock)
- Launch ID distribution < 5 seconds (target)
- Total coordination overhead < 5 seconds

---

**Data Model Complete** | Ready for Contract Definition
