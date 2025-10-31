# Research: Parallel Launch Coordination

**Feature**: 002-parallel-launch-coordination
**Date**: 2025-01-30
**Status**: Complete

## Overview

This document captures research findings and technical decisions for implementing multi-process launch coordination in the iOS XCTest ReportPortal agent.

## Research Questions

### 1. File-Based Coordination Mechanism

**Question**: What is the most reliable file-based coordination mechanism for iOS simulators?

**Decision**: Use POSIX `flock()` for file locking with NSFileCoordinator for coordinated reads/writes

**Rationale**:
- iOS simulators share the host Mac's `/tmp` directory via `NSTemporaryDirectory()`
- POSIX `flock()` provides reliable exclusive locks across processes on macOS
- NSFileCoordinator ensures atomic file operations and proper coordination
- ReportPortal Java client successfully uses similar file-locking approach
- NSFileCoordinator's previous issues were due to incorrect usage patterns, not the API itself

**Alternatives Considered**:
1. **XPC (Inter-Process Communication)**: Rejected because:
   - Requires running daemon/service process
   - More complex setup (violates zero-configuration requirement)
   - Requires additional entitlements and permissions

2. **Distributed Notifications**: Rejected because:
   - Not reliable for coordination (fire-and-forget, no acknowledgment)
   - Race conditions when multiple processes start simultaneously
   - No way to ensure message delivery

3. **SQLite Database**: Rejected because:
   - Overkill for simple ID coordination
   - Additional dependency
   - More complex error handling
   - File locking still needed for database access

**Implementation Pattern** (from Java client):
```swift
// Primary worker:
1. Try to acquire exclusive lock on .lock file using flock()
2. If successful: Create Launch, write UUID to .sync file
3. Keep .lock file open until tests complete

// Secondary workers:
1. Try to acquire lock on .lock file (will fail)
2. Wait for .sync file to appear
3. Read Launch UUID from .sync file
4. Report tests to shared Launch
```

**References**:
- ReportPortal Java Client: https://github.com/reportportal/client-java/tree/main/src/main/java/com/epam/reportportal/service/launch/lock
- Apple NSFileCoordinator: https://developer.apple.com/documentation/foundation/nsfilecoordinator
- POSIX flock: `man 2 flock`

---

### 2. ReportPortal API Version (v1 vs v2)

**Question**: Should we use ReportPortal v1 or v2 API for parallel execution?

**Decision**: Use v2 async API for parallel runs, keep v1 for sequential runs

**Rationale**:
- **v2 async API benefits** for parallel execution:
  - `POST /v2/{project}/launch/merge` - Purpose-built for merging parallel launches
  - `POST /v2/{project}/log` - Batch log creation (non-blocking)
  - Designed for high-throughput parallel test reporting
  - Deep merge intelligently consolidates matching test items

- **v1 API benefits** for sequential execution:
  - Simpler synchronous model
  - Existing codebase already uses v1
  - No coordination overhead needed
  - Backward compatibility

- **Hybrid approach**:
  - Detect parallel mode at runtime (multiple workers detected)
  - Use v2 API only when parallel coordination is active
  - Sequential runs continue using v1 (no breaking changes)

**Alternatives Considered**:
1. **v1 only**: Rejected because:
   - No native launch merge capability
   - Would require custom merge logic
   - Synchronous API causes blocking in parallel scenarios

2. **v2 only**: Rejected because:
   - Breaking change for existing sequential users
   - Adds complexity when coordination not needed
   - v2 not required for single-worker scenarios

**Implementation Strategy**:
```swift
if isParallelExecution {
    // Use v2 API
    // - POST /v2/{project}/launch (per worker)
    // - POST /v2/{project}/log (batch logs)
    // - POST /v2/{project}/launch/merge (last worker)
} else {
    // Use v1 API (existing behavior)
    // - POST /v1/{project}/launch
    // - POST /v1/{project}/log
    // - PUT /v1/{project}/launch/{id}/finish
}
```

**References**:
- ReportPortal API Docs: https://developers.reportportal.io/
- v2 Merge API: https://github.com/reportportal/reportportal/wiki/Launch-Merge

---

### 3. Worker Count Detection

**Question**: How do we detect the number of parallel workers at runtime?

**Decision**: Primary method: `RP_PARALLEL_WORKERS` environment variable. Fallback: timeout-based detection (30 seconds)

**Rationale**:
- **Environment variable approach**:
  - User sets `RP_PARALLEL_WORKERS=5` in Xcode test scheme
  - Deterministic and predictable
  - Works in CI/CD pipelines
  - No waiting/timeout needed

- **Timeout-based fallback**:
  - When env var not set, assume all workers start within 30 seconds
  - If no new workers join after 30 seconds → all workers have started
  - Graceful degradation for ad-hoc testing
  - Similar to Java client's timeout-based approach

- **Why not other methods**:
  - Cannot query Xcode for worker count (no API)
  - Process group ID (PGID) only tells us workers share parent, not count
  - XCTest framework doesn't expose worker count

**Implementation Pattern**:
```swift
func detectWorkerCount() async -> Int? {
    // Priority 1: Check environment variable
    if let count = ProcessInfo.processInfo.environment["RP_PARALLEL_WORKERS"],
       let workerCount = Int(count) {
        return workerCount
    }

    // Priority 2: Timeout-based detection
    // Wait 30 seconds, count unique workers in tracking file
    let startTime = Date()
    var lastWorkerCount = 0

    while Date().timeIntervalSince(startTime) < 30 {
        let currentCount = countWorkersInTrackingFile()
        if currentCount > lastWorkerCount {
            lastWorkerCount = currentCount
            // Reset timer if new worker detected
            startTime = Date()
        }
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    }

    return lastWorkerCount > 0 ? lastWorkerCount : nil
}
```

**Alternatives Considered**:
1. **PGID-based detection**: Rejected because:
   - PGID tells us workers share parent, but not count
   - Workers may have different PGIDs in some CI environments

2. **Hardcoded maximum**: Rejected because:
   - Inflexible (user might use 2 or 20 workers)
   - Would waste time waiting for non-existent workers

**References**:
- Xcode Test Plans: https://developer.apple.com/documentation/xcode/test-plans
- Environment Variables in Xcode: https://developer.apple.com/documentation/xcode/customizing-the-build-schemes-for-a-project

---

### 4. Thread Safety and Concurrency

**Question**: How do we ensure thread-safe coordination state management?

**Decision**: Use Swift actors for all coordination state (`LaunchCoordinator`, `LaunchManager`)

**Rationale**:
- **Swift actors provide**:
  - Built-in data race prevention (compile-time safety)
  - Automatic serialization of access
  - Clean async/await integration
  - No manual lock management

- **LaunchCoordinator (actor)**:
  - Manages file-based coordination across processes
  - Handles Launch ID distribution
  - Serializes file operations

- **LaunchManager (actor)**:
  - Manages in-process launch state
  - Reference counting for test bundles
  - Status aggregation across tests

**Alternatives Considered**:
1. **DispatchQueue with barriers**: Rejected because:
   - Manual lock management error-prone
   - No compile-time safety
   - More complex code

2. **NSLock/pthread_mutex**: Rejected because:
   - Low-level C APIs
   - No async/await integration
   - More verbose

3. **Serial DispatchQueue**: Rejected because:
   - Cannot async/await properly
   - Harder to reason about
   - Legacy pattern

**Implementation Pattern**:
```swift
actor LaunchCoordinator {
    private var launchID: String?

    func getOrCreateLaunchID(...) async throws -> String {
        // Actor ensures serialized access
        // No manual locks needed
        if let existing = launchID {
            return existing
        }

        // Coordinate with file system
        let id = try await coordinateWithFile()
        launchID = id
        return id
    }
}
```

**References**:
- Swift Actors: https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#ID645
- Actor Isolation: https://developer.apple.com/videos/play/wwdc2021/10133/

---

### 5. Error Handling and Graceful Degradation

**Question**: What should happen when coordination fails?

**Decision**: Best-effort retry with exponential backoff, then graceful fallback to separate launches

**Rationale**:
- **Coordination can fail for many reasons**:
  - File system permission issues
  - Network issues (ReportPortal API unavailable)
  - Worker crashes mid-execution
  - Timeout waiting for Launch ID

- **Retry strategy** (matching Java client):
  - Exponential backoff: 1s, 2s, 4s, 8s
  - Max 4 retries (total ~15 seconds)
  - Log each retry attempt

- **Graceful fallback**:
  - If all retries fail, create separate launch for this worker
  - Log warning with clear explanation
  - Tests still execute and report results
  - Better than failing entire test run

**Implementation Pattern**:
```swift
func getOrCreateLaunchID() async throws -> String {
    var retryDelay: TimeInterval = 1.0
    var attempts = 0

    while attempts < 4 {
        do {
            return try await coordinateWithFile()
        } catch {
            attempts += 1
            Logger.shared.warning("Coordination attempt \(attempts) failed: \(error)")

            if attempts < 4 {
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                retryDelay *= 2 // Exponential backoff
            }
        }
    }

    // Fallback: Create separate launch
    Logger.shared.warning("Coordination failed after 4 retries. Creating separate launch.")
    return try await createLaunch()
}
```

**Alternatives Considered**:
1. **Fail fast**: Rejected because:
   - Blocks entire test run
   - Poor user experience
   - Tests could still provide value

2. **Infinite retry**: Rejected because:
   - Can hang test execution indefinitely
   - No timeout guarantee

**References**:
- Exponential Backoff: https://en.wikipedia.org/wiki/Exponential_backoff
- ReportPortal Java Client error handling: https://github.com/reportportal/client-java

---

### 6. Logging and Observability

**Question**: How do we debug coordination issues in production?

**Decision**: Implement FileLogger for coordination events, separate from main Logger

**Rationale**:
- **FileLogger writes to**:
  - `/tmp/reportportal_coordination/events_{PGID}.log`
  - Persists across worker processes
  - Accessible after test run for debugging

- **Logs capture**:
  - Worker registration events
  - Launch ID creation/distribution
  - File lock acquisition/release
  - Completion status updates
  - Error conditions with full context

- **Main Logger** (console output):
  - High-level progress
  - Warnings and errors
  - Summary information

**Implementation Pattern**:
```swift
actor FileLogger {
    static let shared = FileLogger()

    func logCoordinationEvent(_ message: String, type: String, id: String? = nil) async {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] [\(type)] \(message)"
        if let id = id {
            entry += " | ID: \(id)"
        }

        // Append to coordination log file
        try? await appendToFile(entry)
    }
}
```

**Usage**:
```swift
// In LaunchCoordinator
await FileLogger.shared.logCoordinationEvent(
    "PRIMARY LAUNCH: Obtained main lock",
    type: "Launch",
    id: launchUUID
)
```

**Alternatives Considered**:
1. **Console only**: Rejected because:
   - Console output lost after process exits
   - Hard to correlate across workers
   - CI/CD logs may truncate

2. **Remote logging service**: Rejected because:
   - Additional dependency
   - Network required
   - Increases coordination complexity

**References**:
- Structured Logging: https://www.structlog.org/en/stable/why.html

---

## Summary of Key Decisions

| Area | Decision | Rationale |
|------|----------|-----------|
| **Coordination** | POSIX flock + NSFileCoordinator | Reliable cross-process locking on macOS |
| **API Version** | v2 for parallel, v1 for sequential | Best of both worlds (features + compatibility) |
| **Worker Count** | Env var + timeout fallback | Deterministic with graceful fallback |
| **Concurrency** | Swift actors | Compile-time safety, clean async/await |
| **Error Handling** | Retry + graceful fallback | Reliability without blocking tests |
| **Logging** | FileLogger + main Logger | Persistent debugging + user feedback |

## Implementation Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| File locking fails on CI | Low | High | Retry logic + fallback to separate launches |
| Workers start >30s apart | Low | Medium | Allow env var override + timeout extension |
| ReportPortal v2 unavailable | Low | Medium | Detect API version, fallback to v1 |
| Simulator /tmp not shared | Very Low | High | Document limitation, provide detection |
| Race condition in file ops | Low | High | NSFileCoordinator + flock ensures atomicity |

## Next Steps

Phase 1 deliverables:
1. ✅ `data-model.md` - Entity definitions and state machines
2. ✅ `contracts/` - API contracts (v2 endpoints, file formats)
3. ✅ `quickstart.md` - Setup guide for developers
4. ✅ Update agent context with new technologies

---

**Research Complete** | Ready for Phase 1 Design
