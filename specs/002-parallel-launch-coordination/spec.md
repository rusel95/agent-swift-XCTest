# Feature Specification: Parallel Launch Coordination

**Feature Branch**: `002-parallel-launch-coordination`
**Created**: 2025-01-30
**Status**: Draft
**Input**: User description: "Multi-process launch coordination for parallel test execution in iOS XCTest framework to ensure single unified ReportPortal launch across multiple simulator processes"

---

## ⚠️ Important Platform Scope

**This feature provides hybrid coordination: UUID-based for launches (cross-platform) + file-based for suites (simulators).**

| Test Mode | Platform | Local Mac | CI/CD | Launch Coordination | Suite Coordination | Status |
|-----------|----------|-----------|-------|---------------------|-------------------|--------|
| **Sequential** (1 worker) | Simulators | ✅ Works | ✅ Works | None needed | None needed | Fully supported |
| **Sequential** (1 worker) | Real Devices | ✅ Works | ✅ Works | None needed | None needed | Fully supported |
| **Parallel** (2+ workers) | **Simulators** | ✅ Works | ✅ Works | UUID-based | File-based | **Fully supported** |
| **Parallel** (2+ workers) | **Real Devices** | ✅ Works | ✅ Works | UUID-based via env var | ⚠️ Duplicate suites | **Launch-only** |

**Hybrid Coordination Strategy:**
- **Launch coordination**: UUID-based via `RP_LAUNCH_UUID` environment variable (works everywhere - simulators AND real devices)
- **Suite coordination**: File-based via shared `/tmp` directory (simulators only - real devices have isolated sandboxes)
- **Launch finish coordination**: File-based worker tracking via shared `/tmp` directory (simulators only - ensures only last worker calls finish API)
- **Test coordination**: None needed (XCTest distributes tests uniquely, no collisions)

**Platform-Specific Behaviors:**
- **iOS Simulators (parallel)**: Full coordination - Single launch + single suite per test class (clean hierarchy)
- **Real Devices (parallel)**: Launch coordination only - Single launch + duplicate suites per test class (acceptable for most use cases)
- iOS Simulators share host Mac's `/tmp` directory (file-based suite coordination works)
- Real devices have isolated sandboxes with NO shared storage (file-based suite coordination doesn't work)

**What this means for you:**
- ✅ **Sequential tests work everywhere** - Simulators, real devices, local, CI/CD (no coordination needed)
- ✅ **Parallel simulator tests** - Full coordination: UUID launch + file-based suites (perfect hierarchy)
- ✅ **Parallel real device tests** - Launch coordination only: UUID launch + duplicate suites (tests still report correctly)
- 📝 **Setup for parallel on real devices**: Set `RP_LAUNCH_UUID` in Xcode scheme pre-action or CI/CD script

---

---

## Clarifications

### Session 2025-01-31

- Q: Should we use Multi-Launch + Merge strategy (each worker creates its own launch, last worker merges) OR Single Shared Launch strategy (primary worker creates one launch, all workers share it)? → A: Single Shared Launch (Strategy B)
  - **Rationale**: Both strategies require sync file coordination, so complexity is similar. The Single Shared Launch approach is simpler because:
    - No merge API call needed (eliminates merge failure scenarios)
    - Fewer API calls overall (one launch creation vs N launches + merge)
    - Simpler error handling (no partial merge failures)
    - Faster coordination (workers can start reporting immediately after reading shared Launch ID)
    - Matches actual implementation in LaunchCoordinator.swift (already implemented this way)
  - **Implementation**: Primary worker obtains POSIX flock, creates ONE Launch, writes Launch ID to sync file. Secondary workers poll sync file, read shared Launch ID, report to same Launch. Last worker finalizes Launch.

- Q: Can ReportPortal API support custom Launch UUIDs to enable coordination without file locks? → A: Yes! ReportPortal accepts custom UUIDs (UUID-based coordination strategy)
  - **API Discovery**: ReportPortal API accepts optional `uuid` field in `POST /v2/{projectKey}/launch` request
    - If `uuid` provided: ReportPortal uses YOUR UUID (enables pre-coordination)
    - If `uuid` omitted: ReportPortal generates random UUID
    - Response returns the UUID that was used (yours or generated)
  - **Source Evidence**: From `reportportal/service-api` GitHub repository:
    ```java
    // LaunchBuilder.java:48-76
    launch.setUuid(Optional.ofNullable(request.getUuid())
        .orElse(UUID.randomUUID().toString()));
    
    // LaunchStartProducer.java:54-76
    if (!StringUtils.hasText(request.getUuid())) {
        request.setUuid(UUID.randomUUID().toString());
    }
    response.setId(request.getUuid()); // Returns YOUR UUID
    ```
  - **Recommended Strategy**: UUID-based launch coordination with file-based finish:
    1. **Pre-create shared UUID** via environment variable `RP_LAUNCH_UUID` (set in Xcode pre-action or CI/CD)
    2. **All workers use same UUID** when creating launch (first succeeds, others get 409 Conflict)
    3. **Workers handle 409 gracefully** (launch already exists → use it)
    4. **All workers report tests** to shared UUID throughout execution
    5. **File-based finish**: Last worker detection via worker tracking file, only last worker calls finish API (matches Android agent behavior)
  - **Benefits**:
    - **Zero launch coordination overhead**: No file locks for launch creation, no polling, no sync files
    - **Works cross-platform for launches**: Simulators AND real devices (shared UUID via env var)
    - **Race condition free for launch creation**: UUID pre-created before workers start
    - **Single finish API call**: File-based last worker detection ensures finish called exactly once (matches Android agent)
    - **Backward compatible**: Falls back to file lock if no UUID provided
  - **Implementation Priority**:
    - **Priority 1 (UUID-based launch)**: Check `RP_LAUNCH_UUID` env var → create launch with custom UUID → file-based finish coordination
    - **Priority 2 (File-based suites)**: Use file lock + sync files for suite coordination (simulators only)
    - **Priority 3 (Degraded)**: If file operations fail, create separate launches/suites with warning

### Session 2025-11-04

- Q: Should coordination apply to all hierarchy levels (Launch + Suites + Tests) OR selectively based on scalability needs? → A: Hybrid approach - UUID for Launches, File-based for Suites
  - **Rationale**: Different hierarchy levels have different coordination requirements:
    - **Launch level (1 per run)**: UUID-based coordination works perfectly. Zero overhead, cross-platform compatible, works on real devices
    - **Suite level (10-100 per run)**: File-based coordination scales better. Each suite has its own sync file, no API overhead for 409 conflicts on every suite creation
    - **Test level (1000+ per run)**: No coordination needed. XCTest distributes tests uniquely across workers, no collisions
  - **Implementation**: Hybrid coordination strategy:
    1. **Launch Coordination**: Use UUID-based approach (existing implementation) - `RP_LAUNCH_UUID` env var or auto-generate, all workers attempt creation, 409 Conflict = success
    2. **Suite Coordination**: Use file-based approach (NEW) - First worker creates suite, writes suite ID to `/tmp/reportportal/suite_{name}_{launchID}.sync`, other workers read from file
    3. **Launch Finish Coordination**: Use file-based approach (NEW) - Last worker detection via worker count tracking, only last worker calls finish API
    4. **Test Coordination**: None needed - Tests are unique per worker, no duplicate creation
  - **Benefits of Hybrid Approach**:
    - **Scalability**: File-based suite coordination scales to 100+ test classes without API overhead
    - **Clean hierarchy**: No duplicate suites in ReportPortal (single `LoginTests` suite instead of 4 duplicates from 4 workers)
    - **Cross-platform launch**: UUID launch coordination still works on real devices
    - **Coordinated finish**: File-based worker tracking ensures only last worker calls finish API (matches Android agent behavior)
    - **Best of both worlds**: UUID for low-frequency high-value coordination, file-based for high-frequency suite coordination and finish synchronization
  - **Scalability Analysis**:
    - UUID approach doesn't scale to 100 suites (100 API calls + 409 handling per worker = overhead)
    - File-based approach DOES scale (each suite has independent sync file, fast filesystem lookup)
    - Suite collisions less frequent than launch collisions (XCTest distributes test classes across workers)
    - Finish coordination MUST be file-based (tolerant 404/409 approach causes multiple finish API calls, file-based ensures single finish call like Android agent)

- Q: Should launch finish be coordinated to ensure only one worker calls the finish API? → A: Yes, use file-based "last worker" detection (matching Android implementation)
  - **Rationale**: Multiple workers calling finish simultaneously creates race conditions and potential data inconsistency:
    - All workers call finish with their local aggregated status → race condition on which status wins
    - Multiple finish API calls = unnecessary load on ReportPortal server
    - 404/409 tolerant approach still creates noise in logs and potential edge cases
  - **Android/Java Implementation Pattern**: File-based "last worker" detection using reference counting:
    1. Workers register themselves in shared file (increment counter)
    2. Workers mark completion in shared file (decrement counter)
    3. Last worker (counter = 0) obtains exclusive lock and calls finish API
    4. Other workers skip finish call entirely
  - **Benefits of File-Based Finish Coordination**:
    - **Single finish call**: Only one worker calls ReportPortal finish API (clean, deterministic)
    - **Correct status aggregation**: Last worker has visibility into all worker statuses before finishing
    - **No race conditions**: File lock ensures exclusive access to finish logic
    - **Consistent with Android**: Matches proven implementation pattern from agent-java-junit5
  - **Implementation**:
    1. Worker registration: Each worker writes entry to `/tmp/reportportal/launch_{uuid}_workers.txt` on start
    2. Worker completion: Each worker removes entry from file on finish
    3. Last worker detection: Worker checks if file is empty after removing self
    4. Exclusive finish: Last worker obtains lock, aggregates status, calls finish API once

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Single Launch Creation Across Simulator Workers (Priority: P1)

As a test developer, when I run parallel tests from Xcode with 5 iOS **simulators**, I want all test workers to coordinate and report to a single Launch in ReportPortal, so that I see one unified test report instead of 5 separate reports.

**Why this priority**: This is the core value of the feature. Without coordinated launch creation, the system creates duplicate reports making test results unusable. This must work before any other coordination features.

**Independent Test**: Can be fully tested by running parallel tests with 2+ workers and verifying only one Launch appears in ReportPortal with all test results included.

**Acceptance Scenarios**:

1. **Given** parallel testing enabled with 5 workers, **When** tests start execution, **Then** exactly one Launch is created in ReportPortal
2. **Given** multiple workers starting simultaneously, **When** all workers attempt to create a Launch, **Then** only the first worker succeeds and others use the shared Launch ID
3. **Given** a Launch has been created by worker 1, **When** workers 2-5 start their test execution, **Then** they discover and use the existing Launch ID
4. **Given** all workers are executing tests, **When** checking ReportPortal, **Then** only one Launch exists with test results from all workers

---

### User Story 2 - Coordinated Launch Finish (Priority: P1)

As a test developer, when parallel tests complete at different times, I want the Launch to finish only after ALL workers have completed their tests, so that no test results are lost due to premature Launch closure.

**Why this priority**: Without coordinated finish, the first worker to complete closes the Launch causing all remaining workers to lose their test data. This is equally critical as launch creation.

**Independent Test**: Can be fully tested by running parallel tests with uneven test distribution (worker 1 has 5 tests, worker 2 has 50 tests) and verifying the Launch remains open until the last worker finishes.

**Acceptance Scenarios**:

1. **Given** 5 workers running tests with different completion times, **When** the first worker finishes, **Then** the Launch remains open for remaining workers
2. **Given** 4 workers have finished and 1 worker is still executing, **When** the last worker completes, **Then** the Launch is finalized exactly once
3. **Given** a worker finishes early, **When** remaining workers submit test results, **Then** all results are successfully recorded in the Launch
4. **Given** all workers have finished, **When** checking ReportPortal, **Then** the Launch status reflects the aggregated results from all workers

---

### User Story 3 - Zero-Configuration Xcode Integration (Priority: P1)

As a test developer, when I press "Run" in Xcode to execute parallel tests, I want the coordination to work automatically without requiring me to run scripts or pre-create launches, so that I can use parallel testing with minimal setup.

**Why this priority**: The feature must integrate seamlessly with existing Xcode workflows. Requiring external scripts creates friction and reduces adoption.

**Independent Test**: Can be fully tested by running parallel tests directly from Xcode (Test navigator or scheme) without any pre-execution steps and verifying single Launch creation.

**Acceptance Scenarios**:

1. **Given** Xcode project with parallel testing enabled, **When** I click Run Tests in Xcode, **Then** coordination works automatically without manual intervention
2. **Given** no external scripts or pre-configuration, **When** tests execute in parallel, **Then** single Launch is created and properly coordinated
3. **Given** multiple test runs throughout the day, **When** I run tests multiple times, **Then** each run creates its own separate Launch with proper coordination
4. **Given** Xcode determines worker count dynamically, **When** tests run with unknown number of workers, **Then** coordination adapts to the actual worker count

---

### User Story 4 - Launch ID Distribution (Priority: P2)

As a worker process, when the primary worker creates a Launch, I want to discover and use the shared Launch ID quickly, so that I can start reporting test results without delay.

**Why this priority**: This enables the coordination mechanism but is secondary to the core create/finish coordination. Workers need efficient Launch ID distribution to minimize test execution delay.

**Independent Test**: Can be tested by measuring time from Launch creation to when all workers have the Launch ID, verifying it completes within acceptable timeout (e.g., 5 seconds).

**Note**: With UUID-based coordination via `RP_LAUNCH_UUID` environment variable, Launch ID distribution is **instant** (all workers read from environment, no delay). This user story is implicitly satisfied by the UUID approach - no explicit implementation or testing needed beyond verifying environment variable access.

**Acceptance Scenarios**:

1. **Given** UUID set in `RP_LAUNCH_UUID`, **When** workers start, **Then** all workers read the same UUID instantly from environment
2. **Given** no `RP_LAUNCH_UUID` set, **When** first worker generates UUID, **Then** UUID is available immediately (no distribution delay)
3. **Given** multiple workers starting simultaneously, **When** all workers read `RP_LAUNCH_UUID`, **Then** all workers receive identical UUID
4. **Given** environment variable access fails, **When** worker cannot read UUID, **Then** worker auto-generates fallback UUID with warning

---

### User Story 5 - Worker Completion Tracking (Priority: P2)

As the coordinator, when workers finish their tests at different times, I want to track which workers have completed, so that I know when it's safe to finalize the Launch.

**Why this priority**: Required for coordinated finish but not needed until coordination mechanism is established. This enables the "last worker" detection.

**Independent Test**: Can be tested by running parallel tests and logging worker registration/completion events, verifying all workers are tracked correctly.

**Acceptance Scenarios**:

1. **Given** 5 workers starting execution, **When** each worker begins, **Then** it registers itself in the worker tracking system
2. **Given** workers complete at different times, **When** each worker finishes, **Then** it marks itself as complete in the tracking system
3. **Given** 4 workers have finished, **When** checking worker status, **Then** system correctly identifies 1 worker still active
4. **Given** the last worker finishes, **When** marking itself complete, **Then** system correctly identifies all workers are done

---

### User Story 6 - Graceful Degradation (Priority: P3)

As a test developer, when coordination fails due to system limitations (network issues, file access problems), I want the system to fall back to a working mode (even if non-ideal), so that my tests still execute and produce results.

**Why this priority**: This is a safety net for edge cases. While important for robustness, it's less critical than core coordination features working in normal scenarios.

**Independent Test**: Can be tested by simulating coordination failures (block file access, network errors) and verifying tests still execute with appropriate warnings.

**Acceptance Scenarios**:

1. **Given** coordination mechanism fails during launch creation, **When** workers detect the failure, **Then** system attempts best-effort single launch with exponential backoff retry (matching Java client timeout-based behavior), and if all retries fail, creates separate launches with warning logged
2. **Given** Launch ID distribution times out, **When** worker cannot get Launch ID, **Then** worker either creates its own Launch or fails with clear error message
3. **Given** worker tracking fails, **When** system cannot determine completion status, **Then** system either uses timeout-based finish or fails gracefully
4. **Given** coordination failure occurred, **When** checking logs, **Then** clear error messages explain what failed and why

---

### Edge Cases

- What happens when a worker crashes mid-execution? (Other workers continue, last surviving worker calls finish with file-based coordination)
- What happens when Xcode is force-quit during test execution? (Worker tracking file may have stale entries, launch remains open, can be manually closed or auto-timeout)
- What happens when workers start with significant time delays? (All use same UUID, late workers get 409 Conflict and proceed, register in worker tracking file)
- What happens when running parallel tests on **real devices**? (UUID launch coordination works, suite coordination creates duplicates - acceptable)
- What happens when running sequential tests on **real devices**? (Works perfectly - single device, no coordination needed)
- What happens when network connectivity to ReportPortal is intermittent? (Retries with exponential backoff, degrades to separate launches if fails)
- What happens when two separate test runs start simultaneously? (Each run has unique UUID via timestamp+PGID, separate launches, isolated coordination files)
- What happens when worker count exceeds expected maximum? (Hybrid approach scales: UUID for 1 launch, file-based for N suites, file-based tracking for M workers)
- What happens when `RP_LAUNCH_UUID` not provided? (System auto-generates UUID using `UUID().uuidString`)
- What happens when a suite sync file is corrupted? (Worker retries, falls back to creating duplicate suite with warning)
- What happens when worker tracking file is corrupted? (Multiple workers may call finish, first succeeds, file lock prevents race condition)
- What happens when last worker crashes before calling finish? (Launch remains open, requires manual cleanup or timeout)
- What happens when multiple test suites have the same name? (Launch ID in filename prevents collision across test runs)
- What happens when `/tmp` directory is not writable? (Coordination fails, workers create separate launches/suites with error logging)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST ensure exactly one Launch is created per test run regardless of number of parallel workers. All workers MUST attempt launch creation with identical UUID (from `RP_LAUNCH_UUID` or auto-generated). First worker receives 200 OK with launch ID. Subsequent workers receive 409 Conflict and MUST extract launch ID from error response to proceed with shared launch
- **FR-002**: System MUST distribute the shared Launch ID to all workers instantly via `RP_LAUNCH_UUID` environment variable (UUID-based coordination eliminates distribution delay)
- **FR-003**: System MUST track completion status of all workers participating in the test run
- **FR-004**: System MUST finalize Launch exactly once only after all workers have completed their tests
- **FR-005**: System MUST aggregate test status across all workers using priority hierarchy: FAILED (highest) > STOPPED (medium) > PASSED (lowest). If any worker reports FAILED status, final launch status is FAILED. If all workers report PASSED status, final launch status is PASSED. Status aggregation happens in last worker before calling finish API
- **FR-006**: System MUST work from Xcode without requiring external scripts or manual pre-configuration
- **FR-007**: System MUST handle unknown worker counts determined dynamically by Xcode
- **FR-008**: System MUST use UUID-based coordination for launches (all platforms) AND file-based coordination for suites/finish (simulators only)
- **FR-009**: System MUST work on iOS Simulators (local Mac and CI/CD) using UUID coordination or file lock fallback via shared `/tmp` directory
- **FR-010**: System MUST work on iOS Real Devices in both sequential mode (single worker) and parallel mode (multiple devices with `RP_LAUNCH_UUID` coordination). Real devices get launch coordination ONLY (no suite/finish coordination due to isolated sandboxes). Parallel real device tests produce single launch with duplicate suites per test class (acceptable limitation)
- **FR-011**: System MUST isolate coordination between different test runs (separate Launch UUIDs per run)
- **FR-012**: System MUST complete coordination handshake (Launch creation + UUID distribution) within 10 seconds
- **FR-013**: System MUST provide clear logging of coordination events for debugging
- **FR-014**: System MUST handle workers starting with time delays (late joiners can use shared Launch UUID)
- **FR-015**: System MUST support UUID-based coordination as priority 1 mechanism via `RP_LAUNCH_UUID` environment variable for cross-platform parallel testing
- **FR-015a**: System MUST generate unique Launch UUID if `RP_LAUNCH_UUID` not provided using format: `UUID().uuidString` (standard Swift UUID with dashes, e.g., "550E8400-E29B-41D4-A716-446655440000"). UUID MUST be generated deterministically per test session (not per worker) to ensure all workers use identical UUID
- **FR-015b**: System MUST use file-based coordination with POSIX flock as priority 2 fallback for simulators when UUID not pre-created
- **FR-016**: System MUST handle 409 Conflict responses when multiple workers create launch with same UUID (indicates launch already created by another worker). Worker receiving 409 MUST extract launch ID from error response body field `id` or use UUID as launch ID if extraction fails
- **FR-017**: Workers MUST be able to report test results continuously throughout execution without blocking coordination
- **FR-018**: System MUST prevent race conditions when multiple workers attempt to create Launch simultaneously by using custom UUID (first creation succeeds, others get 409 Conflict)
- **FR-019**: System MUST use file-based "last worker" detection for launch finish coordination (only last worker calls finish API once)
- **FR-020**: System MUST clean up coordination resources after Launch finalization (worker tracking files, suite sync files, finish lock files)
- **FR-021**: System MUST detect parallel execution mode and use appropriate API: v2 async API for parallel runs (launches, logs) for non-blocking operations, v1 sync API for sequential runs for simplicity and backward compatibility
- **FR-022**: System MUST detect parallel execution mode by checking for multiple active bundles in same process group (via PGID or RP_SESSION_ID)
- **FR-023**: For launch creation: All workers MUST call `POST /v2/{projectName}/launch` with same custom UUID, handling 409 Conflict as "launch already exists"
- **FR-024**: For launch creation: Workers MUST extract Launch ID from successful creation response (field `id` in response body) OR from 409 error response body (field `id` if available, otherwise use UUID as launch ID)
- **FR-024a**: For launch creation: When first worker's launch creation fails (network error, timeout, 500 server error), worker MUST retry with exponential backoff (1s, 2s, 4s, 8s, maximum 5 retries). If all retries fail, worker MUST create separate launch with generated UUID and log warning "Launch creation failed after 5 retries, creating isolated launch". Tests continue in degraded mode (separate launches instead of unified launch)
- **FR-025**: For suite coordination: System MUST use file-based sync files (one per suite) to prevent duplicate suite creation across workers. Suite coordination applies ONLY to iOS simulators (not real devices due to isolated sandboxes)
- **FR-026**: For suite coordination: First worker creating a suite MUST write suite ID to `/tmp/reportportal/suite_{name}_{launchID}.sync`, other workers read from file. File naming format: suite name (sanitized, alphanumeric+underscore only), underscore separator, launch UUID (full UUID with dashes). Example: `/tmp/reportportal/suite_LoginTests_550E8400-E29B-41D4-A716-446655440000.sync`. Launch UUID in filename prevents collisions across different test runs with duplicate suite names
- **FR-027**: For suite coordination: Workers MUST poll suite sync file with 100ms intervals and 5-second timeout if suite not yet created. After timeout, worker MUST create separate suite instance with warning logged. Polling loop: check file existence → read suite ID → validate format → return ID OR sleep 100ms and retry
- **FR-028**: For launch finish: Workers MUST register themselves in `/tmp/reportportal/launch_{uuid}_workers.txt` on start
- **FR-029**: For launch finish: Workers MUST remove themselves from worker tracking file on completion
- **FR-030**: For launch finish: Last worker (worker count = 0 after self-removal) MUST obtain exclusive lock and call finish API exactly once
- **FR-031**: For launch finish: Last worker MUST aggregate status from all workers before calling finish (FAILED > STOPPED > PASSED hierarchy)
- **FR-032**: For launch finish: Non-last workers MUST skip finish API call entirely (file-based coordination ensures single finish call)
- **FR-033**: System MUST use session-based file naming with PGID or launch UUID for coordination files to isolate different test runs
- **FR-034**: For SEQUENTIAL runs (single worker, any platform): System MAY continue using existing v1 API (`POST /v1/{projectName}/launch`, `PUT /v1/{projectName}/launch/{launchId}/finish`) without coordination overhead
- **FR-035**: System MUST use v1 force finish API (`PUT /v1/{projectName}/launch/{launchId}/stop`) for cleanup when worker crashes or coordination fails (if needed)
- **FR-036**: System MUST track active bundle count in LaunchManager to determine aggregated status across all workers
- **FR-037**: For PARALLEL/SIMULATOR runs: System MUST use `POST /v2/{projectName}/log` for batch log creation to ensure non-blocking async log reporting
- **FR-038**: For PARALLEL/SIMULATOR runs: System MUST use `POST /v2/{projectName}/log/entry` for single log entry creation when immediate log reporting is needed
- **FR-039**: System MAY use v1 log API (`GET /v1/{projectName}/log`) for reading/querying logs in both parallel and sequential modes
- **FR-040**: For file-based coordination (simulators only): System MUST use POSIX flock() for exclusive access to coordination files (suite sync files, worker tracking files, finish lock files) with 10-second timeout and exponential backoff retry (100ms, 200ms, 400ms, 800ms, 1600ms intervals)
- **FR-044**: For worker tracking: System MUST perform atomic read-modify-write operations on worker tracking file to prevent race conditions during concurrent worker registration/unregistration (acquire lock → read count → modify count → write count → release lock as single atomic operation)
- **FR-047**: For suite coordination: System MUST handle corrupted or invalid sync files gracefully by falling back to direct suite creation (may result in duplicate suites). Worker MUST log warning about coordination failure with sync file path for debugging

### Key Entities

- **Launch**: Represents a single test execution session in ReportPortal containing all test results from all workers. Has unique ID, status (PASSED/FAILED), start/end timestamps.
- **Worker**: Represents a single test process/simulator executing a subset of tests. Has unique identifier, completion status, and reports to a shared Launch.
- **Coordination Session**: Represents the coordination state for a test run. Tracks Launch ID, participating workers, completion status, and synchronization metadata.
- **Test Result**: Individual test outcome reported by a worker. Contains test name, status, timestamps, and belongs to a Launch.

### Non-Functional Requirements

- **NFR-001**: Performance: Launch creation with UUID coordination MUST complete within 2 seconds per worker
- **NFR-002**: Performance: Suite sync file lookup MUST complete within 100ms per suite
- **NFR-003**: Scalability: System MUST maintain coordination correctness (single launch, deduplicated suites, single finish) regardless of test suite count or worker count within documented limits (1-20 workers, 1-100 suites)
- **NFR-004**: Reliability: File-based coordination MUST handle lock contention gracefully with timeout and retry mechanisms
- **NFR-005**: Observability: System MUST log all coordination events (UUID source, lock acquisition, worker registration, last-worker detection) with correlation IDs for debugging
- **NFR-006**: Maintainability: Coordination code MUST use Swift Concurrency (async/await, Actor model) for thread safety without manual locks

## Known Limitations

The following behaviors are known limitations of the current design and are NOT considered defects:

- **Worker crashes before finish**: If the last worker crashes before calling finish API, the Launch will remain open indefinitely with partial test results preserved. Manual cleanup required via ReportPortal UI or force-finish API (`PUT /v1/{projectName}/launch/{launchId}/stop`). Future enhancement: timeout-based auto-finish.
  
- **Stale worker tracking entries**: If a non-last worker crashes before removing itself from the worker tracking file, the file contains a stale entry. Other workers continue normally, but the orphaned launch may require external cleanup if the last worker also crashes.

- **Real device suite duplication**: Parallel tests on real devices create duplicate suites per test class (one per worker) because file-based coordination requires shared `/tmp` which real devices don't have. This is acceptable as tests still report correctly to a single launch via UUID coordination.

- **No automatic timeout**: There is no automatic timeout for incomplete launches. If all workers crash or coordination deadlocks, manual intervention is required.

## Success Criteria *(mandatory)*

### Measurable Outcomes

**For Parallel Simulator Tests:**
- **SC-001**: When running parallel tests with 5 **simulator** workers, exactly 1 Launch appears in ReportPortal (not 5 separate Launches)
- **SC-002**: All test results from all **simulator** workers appear in the single unified Launch (zero data loss)
- **SC-003**: Launch finalizes only after the last **simulator** worker completes, regardless of which worker finishes first
- **SC-004**: Launch status correctly reflects aggregated results across all **simulators** (FAILED if any worker had failures, PASSED if all passed)
- **SC-005**: **Simulator** coordination completes within 10 seconds from first worker start to all workers having Launch ID
- **SC-006**: **Simulator** parallel tests can be run directly from Xcode without any manual pre-execution steps or scripts
- **SC-007**: System handles test runs with 1-20 **simulator** workers without configuration changes
- **SC-008**: 100% of parallel **simulator** test runs result in single unified Launch (no duplicate reports)
- **SC-009**: Zero test results lost due to premature Launch closure in **simulator** parallel runs (compared to current 80% data loss when first worker finishes early)
- **SC-010**: **Simulator** coordination overhead adds less than 5 seconds to total test execution time

**For Sequential Tests (Any Platform):**
- **SC-011**: Single worker tests (sequential mode) work on both **simulators** and **real devices** without coordination
- **SC-012**: Sequential mode on **real devices** produces exactly 1 Launch with all test results
- **SC-013**: Sequential mode has zero coordination overhead (uses simple v1 API)

## Coordination Flow *(informational)*

**Note**: This coordination flow applies ONLY to parallel test runs with multiple workers on simulators. Sequential runs (single worker) bypass coordination and use existing v1 API for simplicity.

### High-Level Hybrid Coordination Flow (Parallel Simulator Runs)

**Hybrid Strategy: UUID for Launch Creation + File-based for Suite Coordination + File-based for Launch Finish**

**Phase 1: Worker Registration & Launch Creation**

1. **Worker Registration** (All workers, on start):
   ```swift
   // Each worker registers in worker tracking file
   let workerFile = "/tmp/reportportal/launch_\(launchUUID)_workers.txt"
   appendWorkerID(workerID, to: workerFile) // Thread-safe append
   ```

2. **Launch UUID Generation**:
   - Check `RP_LAUNCH_UUID` environment variable
   - If not set: Auto-generate using `UUID().uuidString`
   - All workers use same UUID (via env var or PGID-based coordination)

3. **Launch Creation** (All workers attempt, UUID-based):
   ```swift
   do {
       let launchID = try await reportingService.startLaunch(uuid: launchUUID, ...)
       // First worker: Gets 200 OK
   } catch HTTPError.conflict(409, let body) {
       // Other workers: Get 409 Conflict - extract launch ID from response
       launchID = body.id ?? launchUUID
   }
   ```

**Phase 2: Suite Coordination (File-based)**

For each test suite (e.g., `LoginTests`, `CheckoutTests`):

1. **Check for existing suite** (File-based lookup):
   ```swift
   let suiteFile = "/tmp/reportportal/suite_\(suiteName)_\(launchID).sync"
   if let existingSuiteID = readSuiteID(from: suiteFile) {
       return existingSuiteID // Suite already created by another worker
   }
   ```

2. **Create new suite** (First worker for this suite):
   ```swift
   // Obtain file lock
   let lockFD = open(suiteFile + ".lock", O_CREAT | O_EXCL)
   if lockFD >= 0 {
       // This worker is first - create suite
       let suiteID = try await reportingService.startSuite(name: suiteName, launchID: launchID)
       writeSuiteID(suiteID, to: suiteFile)
       close(lockFD)
       return suiteID
   } else {
       // Another worker is creating - poll for result
       return await pollSuiteID(from: suiteFile, timeout: 5)
   }
   ```

**Phase 3: Test Execution (All Workers in Parallel)**

- Each worker executes its assigned tests
- All workers report to SAME Launch (via UUID)
- All workers report to SAME Suite per test class (via file-based coordination)
- Tests are unique per worker (no coordination needed)
- Logs reported via `POST /v2/{projectName}/log`

**Phase 4: Launch Finalization (File-based "Last Worker" Detection)**

1. **Worker Completion** (Each worker, on finish):
   ```swift
   // Remove self from worker tracking file
   let workerFile = "/tmp/reportportal/launch_\(launchUUID)_workers.txt"
   removeWorkerID(workerID, from: workerFile)
   
   // Check if last worker
   let remainingWorkers = countWorkers(in: workerFile)
   if remainingWorkers == 0 {
       // This is the LAST worker - call finish API
       isLastWorker = true
   }
   ```

2. **Last Worker Finish** (Only one worker executes this):
   ```swift
   if isLastWorker {
       // Obtain exclusive lock
       let finishLockFD = flock("/tmp/reportportal/launch_\(launchUUID)_finish.lock")
       
       // Aggregate status from all workers
       let finalStatus = aggregateStatus() // FAILED > STOPPED > PASSED
       
       // Call finish API once
       try await reportingService.finishLaunch(launchID: launchID, status: finalStatus)
       
       // Cleanup coordination files
       cleanupCoordinationFiles(launchUUID)
   }
   ```

**Result**: 
- ✅ Single Launch in ReportPortal
- ✅ Single Suite per test class (no duplicates)
- ✅ All tests reported correctly
- ✅ Launch finished exactly once by last worker
- ✅ Clean coordination file cleanup

**Key Benefits of Hybrid Approach**:
- **Launch**: UUID-based (1 per run) - cross-platform, zero overhead
- **Suites**: File-based (10-100 per run) - scales well, no API overhead
- **Finish**: File-based (1 per run) - single finish call, correct status aggregation
- **Clean hierarchy**: No duplicate launches or suites in ReportPortal

### Error Handling Flow

**If Worker Crashes:**
1. Other workers continue normally
2. All workers continue reporting to the shared Launch UUID
3. All surviving workers call finish (tolerant finish handles multiple calls)
4. First finish call succeeds, others get 404 (acceptable)

**If Launch Creation Fails (Network Error):**
1. Worker retries with exponential backoff (1s, 2s, 4s, 8s)
2. If all retries fail, worker creates separate Launch with generated UUID and logs warning
3. Tests continue to execute and report (degraded mode)

**If 409 Conflict Error Has No Launch ID:**
1. Worker uses the custom UUID as Launch ID (UUID == Launch ID in v2 API)
2. Proceeds to report tests normally
3. Log informational message about conflict resolution

**If Multiple Finish Calls:**
1. First worker to finish: Gets 200 OK, launch status set to aggregated status
2. Other workers: Get 404 Not Found or 409 Conflict
3. Workers treat 404/409 as success (launch already finished)
4. No errors logged, coordination succeeds

**File-Based Fallback Errors (Simulators Only):**

**If Lock File Acquisition Fails:**
1. Worker retries with exponential backoff (1s, 2s, 4s, 8s)
2. If all retries fail, worker creates separate Launch and logs warning
3. Tests continue to execute and report (degraded mode)

**If Sync File Read Fails:**
1. Secondary worker polls sync file with 100ms intervals
2. If timeout (60 seconds) expires without Launch UUID, worker creates separate Launch
3. Tests continue to execute and report (degraded mode)
4. Log warning about coordination failure

**If Coordination Directory Unavailable:**
1. Worker falls back to creating individual Launch with generated UUID (no coordination)
2. Log warning about file system access issue
3. Tests continue to execute and report (degraded mode)

## Scope *(mandatory)*

### In Scope

**Parallel Coordination (Hybrid Approach):**
- ✅ UUID-based launch coordination via `RP_LAUNCH_UUID` environment variable (works everywhere)
- ✅ File-based suite coordination via shared `/tmp` directory (simulators only - prevents duplicate suites)
- ✅ File-based finish coordination via worker tracking (simulators only - ensures single finish API call)
- ✅ Zero-configuration coordination when UUID auto-generated (simulators)
- ✅ iOS Simulator support (local Mac and CI/CD) - full coordination (launch + suites + finish)
- ✅ iOS Real Device support (local Mac and CI/CD) - launch coordination only (UUID-based)
- ✅ Coordination for 1-20 workers (simulators or real devices)
- ✅ Handling workers with variable test counts and finish times
- ✅ Graceful handling of worker crashes
- ✅ POSIX flock for exclusive lock acquisition (simulators - suite creation, finish coordination)

**Sequential Mode (All Platforms):**
- ✅ Single worker execution on iOS Simulators (no coordination needed)
- ✅ Single worker execution on Real Devices (no coordination needed)
- ✅ Works everywhere: local Mac, CI/CD, real devices, simulators
- ✅ Uses existing v1 API (simple, synchronous)

**General:**
- ✅ Clear logging and debugging support
- ✅ API version detection (v1 for sequential, v2 for parallel)
- ✅ Environment variable support (`RP_LAUNCH_UUID` for coordination)
- ✅ Xcode pre-action script templates for UUID generation
- ✅ Cross-platform parallel testing (simulators + real devices)

### Out of Scope

**Advanced Coordination Features (Future Phases):**
- ❌ Network-based coordination server (not needed with UUID approach)
- ❌ Mixed simulator + real device parallel runs in single session
- ❌ Launch pre-creation via API (replaced by UUID-based coordination)
- ❌ Merge API usage (not needed with shared UUID approach)

**Other Out of Scope:**
- Coordination across multiple machines/hosts (UUID approach supports this if UUID shared via external means)
- Backward compatibility with existing broken NSFileCoordinator-based code (will replace)
- Automatic retry of failed tests
- Test result filtering or transformation
- ReportPortal server configuration or setup

## Dependencies & Assumptions *(mandatory)*

### Dependencies

- ReportPortal server API availability for Launch creation and finalization
- Xcode parallel testing infrastructure (`-parallel-testing-enabled YES`)
- iOS Simulator environment with accessible shared resources
- Swift concurrency features (async/await, actors)

### Assumptions

**For Parallel Coordination:**
- Workers use shared UUID from `RP_LAUNCH_UUID` environment variable
- Workers start within reasonable time window (< 5 minutes between first and last)
- First worker to create launch succeeds, others get 409 Conflict (acceptable)
- All workers can call finish, first succeeds, others get 404 (acceptable)
- **Simulator workers** share host Mac's `/tmp` directory for file-based fallback
- **Real device workers** use UUID coordination (no file access needed)
- Workers fail independently (one worker crash doesn't crash others)
- ReportPortal v2 async API is available for launches and logs
- v2 async APIs provide sufficient performance for non-blocking parallel test reporting

**For Sequential/Any Platform:**
- Single worker can execute on simulator or real device without coordination
- Test execution time is reasonable (< 30 minutes per worker)
- Workers can determine their own completion (XCTest framework callbacks work)

**General:**
- ReportPortal API is accessible and responsive (< 2 second response time)
- Test items (suites/tests) use existing API (v1 or v2 depending on availability during implementation)
- Xcode parallel testing infrastructure works as documented (`-parallel-testing-enabled YES`)

## Constraints *(optional)*

### Technical Constraints

- No shared memory between worker processes (each process is independent)
- File-based coordination using NSFileCoordinator is unreliable (documented as broken - will not use)
- iOS/macOS sandboxing limits inter-process file access (simulators exempt via shared `/tmp`)
- Workers don't know total worker count at start (Xcode determines dynamically)
- Cannot modify Xcode or XCTest framework behavior
- Must work within XCTest lifecycle callbacks (testBundleWillStart, testBundleDidFinish)

### Platform Constraints

**iOS Simulators (Parallel Supported):**
- ✅ Each simulator has sandboxed app container
- ✅ BUT: Simulators share host Mac's `/tmp` directory via `NSTemporaryDirectory()`
- ✅ File-based coordination works via shared `/tmp`
- ✅ POSIX `flock()` works for inter-process synchronization
- ✅ All workers on same host machine (local Mac or CI/CD VM)

**Real Devices (Parallel NOT Supported):**
- ❌ Each device has completely isolated sandbox
- ❌ NO shared file system between devices
- ❌ NO access to host Mac's `/tmp` directory
- ❌ File-based coordination impossible
- ⚠️ Sequential mode (1 device) works perfectly
- 📝 Workaround: External scripts with pre-created launch ID

**macOS:**
- Security restrictions on temp file access between processes
- POSIX file locking (`flock`) available and reliable

### User Experience Constraints

- Zero manual configuration required
- Works from Xcode "Run" button
- No external script execution
- Clear error messages when coordination fails
- Minimal impact on test execution time (< 5 second overhead)

## Open Questions *(optional)*

1. **UUID Generation Strategy**: How should Launch UUID be generated when not provided via `RP_LAUNCH_UUID`?
   - Option A: `{launchName}_{timestamp}_{PGID}` (unique per process group)
   - Option B: `{launchName}_{timestamp}_{randomUUID}` (globally unique)
   - Option C: Pure UUID v4 (most unique but less human-readable)
   - **Recommendation**: Option A for simulators (PGID groups workers), Option B for real devices

2. **Coordination State Cleanup**: Should coordination files be cleaned up immediately after Launch finalization?
   - Only applies to file-based fallback mode (simulators without UUID)
   - Option A: Immediate cleanup (cleaner, but harder to debug)
   - Option B: Time-based cleanup (keep for 1 hour, then auto-delete)
   - Option C: Manual cleanup command for developers
   - **Recommendation**: Option B (debugging-friendly)

3. **Finish Aggregation Logic**: When multiple workers call finish with different statuses, which status wins?
   - All workers calculate aggregated status before calling finish
   - First worker to finish sets final status
   - Question: Should we enforce status consistency checking?
   - **Recommendation**: Trust first worker's aggregated status (LaunchManager tracks all bundle statuses)

4. **Launch Naming Strategy**: How should Launch be named in parallel mode?
   - Option A: Include worker count: "Test Run [5 Workers]" (requires knowing total count)
   - Option B: Include device info: "Test Run [iPhone 15 Pro Simulators]"
   - Option C: Keep simple: Just use base launch name (recommended for UUID approach)
   - **Recommendation**: Option C (simpler, UUID already provides uniqueness)

5. **Fallback Priority**: When should system use file-based fallback vs failing fast?
   - UUID not provided → Generate UUID (no fallback needed)
   - UUID provided but launch creation fails → Retry then fail
   - File lock fails (simulators) → Retry then create separate launch with warning
   - **Recommendation**: Always try to create launch, accept degraded mode with separate launches

6. **Real Device UUID Distribution**: How should UUID be distributed to real devices in parallel?
   - Option A: Xcode pre-action sets `RP_LAUNCH_UUID` (works for local testing)
   - Option B: CI/CD script sets environment variable (works for CI)
   - Option C: External coordination service (complex, out of scope)
   - **Recommendation**: Options A+B (documentation + examples provided)
