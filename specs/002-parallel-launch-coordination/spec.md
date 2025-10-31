# Feature Specification: Parallel Launch Coordination

**Feature Branch**: `002-parallel-launch-coordination`
**Created**: 2025-01-30
**Status**: Draft
**Input**: User description: "Multi-process launch coordination for parallel test execution in iOS XCTest framework to ensure single unified ReportPortal launch across multiple simulator processes"

---

## ⚠️ Important Platform Scope

**This feature provides parallel test coordination for iOS Simulators ONLY.**

| Test Mode | Platform | Local Mac | CI/CD | Coordination | Status |
|-----------|----------|-----------|-------|--------------|--------|
| **Sequential** (1 worker) | Simulators | ✅ Works | ✅ Works | No coordination needed | Fully supported |
| **Sequential** (1 worker) | Real Devices | ✅ Works | ✅ Works | No coordination needed | Fully supported |
| **Parallel** (2+ workers) | **Simulators** | ✅ Works | ✅ Works | UUID-based (file lock fallback) | **Supported** |
| **Parallel** (2+ workers) | **Real Devices** | ✅ Works | ✅ Works | UUID-based via env var | **Supported** |

**Why simulator-only for parallel?**
- **Primary coordination**: UUID-based via `RP_LAUNCH_UUID` environment variable (works everywhere)
- **Fallback coordination**: File-based locking via POSIX flock (simulators only)
- iOS Simulators share host Mac's `/tmp` directory (file lock fallback works)
- Real devices have isolated sandboxes with NO shared storage (file lock fallback doesn't work)
- Real devices CAN use UUID-based coordination via environment variable

**What this means for you:**
- ✅ **Sequential tests work everywhere** - Simulators, real devices, local, CI/CD
- ✅ **Parallel tests work on simulators** - UUID coordination (preferred) or file lock (fallback)
- ✅ **Parallel tests work on real devices** - UUID coordination via `RP_LAUNCH_UUID` environment variable
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
  - **Recommended Strategy**: UUID-based coordination with tolerant finish:
    1. **Pre-create shared UUID** via environment variable `RP_LAUNCH_UUID` (set in Xcode pre-action or CI/CD)
    2. **All workers use same UUID** when creating launch (first succeeds, others get 409 Conflict)
    3. **Workers handle 409 gracefully** (launch already exists → use it)
    4. **All workers report tests** to shared UUID throughout execution
    5. **Tolerant finish**: All workers call finish, accept 404/409 as success (launch already finished)
  - **Benefits**:
    - **Zero coordination overhead**: No file locks, no polling, no sync files
    - **Works cross-platform**: Simulators AND real devices (shared UUID via env var)
    - **Race condition free**: UUID pre-created before workers start
    - **Multiple finish calls safe**: HTTP 404/409 indicate already finished (not errors)
    - **Backward compatible**: Falls back to file lock if no UUID provided
  - **Implementation Priority**:
    - **Priority 1 (UUID-based)**: Check `RP_LAUNCH_UUID` env var → create launch with custom UUID → tolerant finish
    - **Priority 2 (File lock fallback)**: If no env var, use file lock coordination (simulators only)
    - **Priority 3 (Degraded)**: If file lock fails, create separate launch with warning

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

**Acceptance Scenarios**:

1. **Given** primary worker creates a Launch, **When** secondary workers need the Launch ID, **Then** they retrieve it within 5 seconds
2. **Given** a Launch ID is available, **When** a secondary worker starts, **Then** it discovers the Launch ID before executing its first test
3. **Given** multiple workers requesting Launch ID simultaneously, **When** all workers attempt to read, **Then** all workers successfully receive the correct Launch ID
4. **Given** Launch ID distribution fails, **When** timeout expires, **Then** worker either retries or fails gracefully with clear error message

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

- What happens when a worker crashes mid-execution? (Other workers continue, call finish with tolerant handling)
- What happens when Xcode is force-quit during test execution? (Launch remains open, can be manually closed or auto-timeout)
- What happens when workers start with significant time delays? (All use same UUID, late workers get 409 Conflict and proceed)
- What happens when running parallel tests on **real devices**? (Works with `RP_LAUNCH_UUID` coordination, no file locks needed)
- What happens when running sequential tests on **real devices**? (Works perfectly - single device, no coordination needed)
- What happens when network connectivity to ReportPortal is intermittent? (Retries with exponential backoff, degrades to separate launches if fails)
- What happens when two separate test runs start simultaneously? (Each run has unique UUID via timestamp+PGID, separate launches)
- What happens when worker count exceeds expected maximum? (UUID approach scales to any worker count)
- What happens when `RP_LAUNCH_UUID` not provided? (System generates UUID or falls back to file lock on simulators)
- What happens when all workers call finish simultaneously? (First succeeds with 200, others get 404/409 - all acceptable)
- What happens when 409 Conflict response has no Launch ID? (Use the custom UUID as Launch ID)
- What happens when finish is called but launch doesn't exist? (404 response treated as success - already finished or never created)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST ensure exactly one Launch is created per test run regardless of number of parallel workers
- **FR-002**: System MUST distribute the shared Launch ID to all workers within 5 seconds of Launch creation
- **FR-003**: System MUST track completion status of all workers participating in the test run
- **FR-004**: System MUST finalize Launch exactly once only after all workers have completed their tests
- **FR-005**: System MUST aggregate test status across all workers (if any test fails, Launch status is FAILED)
- **FR-006**: System MUST work from Xcode without requiring external scripts or manual pre-configuration
- **FR-007**: System MUST handle unknown worker counts determined dynamically by Xcode
- **FR-008**: System MUST coordinate across multiple independent processes with no shared memory, using UUID-based coordination (priority 1) or file-based coordination (priority 2 fallback for simulators)
- **FR-009**: System MUST work on iOS Simulators (local Mac and CI/CD) using UUID coordination or file lock fallback via shared `/tmp` directory
- **FR-010**: System MUST work on iOS Real Devices in both sequential mode (single worker) and parallel mode (multiple devices with `RP_LAUNCH_UUID` coordination)
- **FR-011**: System MUST isolate coordination between different test runs (separate Launch UUIDs per run)
- **FR-012**: System MUST complete coordination handshake (Launch creation + ID distribution) within 10 seconds
- **FR-013**: System MUST provide clear logging of coordination events for debugging
- **FR-014**: System MUST handle workers starting with time delays (late joiners can use shared Launch UUID)
- **FR-015**: System MUST support UUID-based coordination as priority 1 mechanism via `RP_LAUNCH_UUID` environment variable for cross-platform parallel testing
- **FR-015a**: System MUST generate unique Launch UUID if `RP_LAUNCH_UUID` not provided (format: `{launchName}_{timestamp}_{PGID}`)
- **FR-015b**: System MUST use file-based coordination with POSIX flock as priority 2 fallback for simulators when UUID not pre-created
- **FR-016**: System MUST handle 409 Conflict responses when multiple workers create launch with same UUID (indicates launch already created by another worker)
- **FR-017**: Workers MUST be able to report test results continuously throughout execution without blocking coordination
- **FR-018**: System MUST prevent race conditions when multiple workers attempt to create Launch simultaneously by using custom UUID (first creation succeeds, others get 409 Conflict)
- **FR-019**: System MUST prevent premature Launch finalization using tolerant finish logic (all workers call finish, first succeeds, others get 404/409 which is acceptable)
- **FR-020**: System MUST clean up coordination resources after Launch finalization (lock file and sync file for file-based fallback only)
- **FR-021**: System MUST detect parallel execution mode and use appropriate API: v2 async API for parallel runs (launches, logs) for non-blocking operations, v1 sync API for sequential runs for simplicity and backward compatibility
- **FR-022**: System MUST detect parallel execution mode by checking for multiple active bundles in same process group (via PGID or RP_SESSION_ID)
- **FR-023**: For UUID-based coordination: All workers MUST call `POST /v2/{projectName}/launch` with same custom UUID, handling 409 Conflict as "launch already exists"
- **FR-024**: For UUID-based coordination: Workers MUST extract Launch ID from successful creation response OR from 409 error response body
- **FR-025**: For file-based fallback: Primary worker MUST obtain POSIX flock, create launch, write UUID to sync file, secondary workers poll sync file
- **FR-026**: For parallel runs: All workers MUST call `PUT /v2/{projectName}/launch/{launchId}/finish` with aggregated status, treating 404/409 as success (already finished)
- **FR-027**: For SEQUENTIAL runs (single worker, any platform): System MAY continue using existing v1 API (`POST /v1/{projectName}/launch`, `PUT /v1/{projectName}/launch/{launchId}/finish`) without coordination overhead
- **FR-028**: System MUST use v1 force finish API (`PUT /v1/{projectName}/launch/{launchId}/stop`) for cleanup when worker crashes or coordination fails (if needed)
- **FR-029**: For file-based fallback: System MUST use session-based file naming with PGID for coordination files to isolate different test runs
- **FR-030**: System MUST track active bundle count in LaunchManager to determine aggregated status across all workers
- **FR-031**: Launch MUST aggregate status across all workers following severity hierarchy: FAILED > STOPPED > PASSED
- **FR-032**: For PARALLEL/SIMULATOR runs: System MUST use `POST /v2/{projectName}/log` for batch log creation to ensure non-blocking async log reporting
- **FR-033**: For PARALLEL/SIMULATOR runs: System MUST use `POST /v2/{projectName}/log/entry` for single log entry creation when immediate log reporting is needed
- **FR-034**: For SEQUENTIAL runs (single worker, any platform): System MAY continue using v1 log API (`POST /v1/{projectName}/log`, `POST /v1/{projectName}/log/entry`) without requiring v2 async
- **FR-035**: System MAY use v1 log API (`GET /v1/{projectName}/log`) for reading/querying logs in both parallel and sequential modes

### Key Entities

- **Launch**: Represents a single test execution session in ReportPortal containing all test results from all workers. Has unique ID, status (PASSED/FAILED), start/end timestamps.
- **Worker**: Represents a single test process/simulator executing a subset of tests. Has unique identifier, completion status, and reports to a shared Launch.
- **Coordination Session**: Represents the coordination state for a test run. Tracks Launch ID, participating workers, completion status, and synchronization metadata.
- **Test Result**: Individual test outcome reported by a worker. Contains test name, status, timestamps, and belongs to a Launch.

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

**Note**: This coordination flow applies ONLY to parallel test runs with multiple workers. Sequential runs (single worker) bypass coordination and use existing v1 API for simplicity.

### High-Level Flow Using UUID-Based Coordination (Parallel Runs)

**Priority 1: UUID-Based Coordination (Preferred)**

**Phase 1: UUID Generation (Before Workers Start)**
1. Xcode Pre-Action or CI/CD script generates unique UUID:
   ```bash
   export RP_LAUNCH_UUID="MyApp_$(date +%Y%m%d_%H%M%S)_$(ps -o pgid= -p $$)"
   ```
2. OR: First worker generates UUID if not provided: `{launchName}_{timestamp}_{PGID}`
3. All workers inherit `RP_LAUNCH_UUID` environment variable

**Phase 2: Launch Creation (All Workers Attempt)**
1. **All Workers** (simultaneously or with delays):
   - Read `RP_LAUNCH_UUID` from environment
   - Call `POST /v2/{projectName}/launch` with `uuid: RP_LAUNCH_UUID`
   - **First worker**: Gets 200 OK with Launch ID
   - **Other workers**: Get 409 Conflict (launch already exists)
   - Both extract Launch ID from response and proceed

2. **Handling 409 Conflict**:
   ```swift
   do {
       let response = try await httpClient.post("/v2/\(project)/launch", body: [
           "uuid": launchUUID,
           "name": launchName,
           "mode": "DEFAULT"
       ])
       launchID = response.id
   } catch let error as HTTPError where error.statusCode == 409 {
       // Launch already created by another worker - extract ID from error
       launchID = error.responseBody?.id ?? launchUUID
       logger.info("Using existing launch created by another worker")
   }
   ```

**Phase 3: Test Execution (All Workers in Parallel)**
- All workers execute their assigned tests
- All workers report test results to the SAME Launch UUID
- Test items (suites/tests) created via standard item API
- Logs reported via `POST /v2/{projectName}/log` (batch) or `POST /v2/{projectName}/log/entry` (single)
- All v2 async APIs used for non-blocking operation

**Phase 4: Launch Finalization (All Workers Call Finish)**
1. Each worker completes its tests
2. Each worker updates aggregated status in LaunchManager
3. **All Workers** call finish (no coordination needed):
   ```swift
   do {
       try await httpClient.put("/v2/\(project)/launch/\(launchID)/finish", body: [
           "status": aggregatedStatus
       ])
       logger.info("Successfully finished launch")
   } catch let error as HTTPError where error.statusCode == 404 || error.statusCode == 409 {
       // Launch already finished by another worker - this is OK
       logger.info("Launch already finished by another worker")
   }
   ```
4. **First worker to finish**: Gets 200 OK (launch closed)
5. **Other workers**: Get 404 Not Found or 409 Conflict (already finished) - treated as success

**Result**: Single unified Launch in ReportPortal with all test results from all workers

**Key Benefits**: 
- Zero coordination overhead (no file locks, no polling)
- Works on simulators AND real devices
- Race condition free (UUID pre-created)
- Multiple finish calls safe (tolerant error handling)

---

**Priority 2: File-Based Fallback (Simulators Only)**

If `RP_LAUNCH_UUID` not provided, fall back to file-based coordination:

**Phase 1: Worker Initialization (Parallel)**
1. Each worker starts independently (Worker 1, 2, 3, 4, 5)
2. Each worker generates session ID (based on PGID - Process Group ID)
3. Workers attempt to obtain lock on coordination file

**Phase 2: Launch Creation (Primary Worker Only)**
1. **Primary Worker** (first to obtain lock):
   - Obtains exclusive POSIX flock on `/tmp/reportportal_coordination/launch_{name}_{session}.lock`
   - Generates Launch UUID: `{launchName}_{timestamp}_{PGID}`
   - Calls `POST /v2/{projectName}/launch` with custom UUID
   - Receives Launch ID from ReportPortal
   - Writes Launch UUID to sync file: `/tmp/reportportal_coordination/launch_{name}_{session}.sync`
   - Releases lock
   - Starts executing tests, reporting to the Launch

2. **Secondary Workers** (failed to obtain lock):
   - Poll sync file `/tmp/reportportal_coordination/launch_{name}_{session}.sync` 
   - Read shared Launch UUID from sync file (typically within 100-500ms)
   - Start executing tests, reporting to the SAME Launch

**Phase 3 & 4**: Same as UUID-based coordination (test execution + tolerant finish)

**Result**: Single unified Launch in ReportPortal with all test results from all workers

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

**Parallel Coordination (All Platforms with UUID):**
- ✅ UUID-based coordination via `RP_LAUNCH_UUID` environment variable (works everywhere)
- ✅ Coordinating Launch creation across multiple parallel workers via shared UUID
- ✅ Zero-configuration coordination when UUID pre-created in Xcode pre-action
- ✅ Tolerant finish handling (all workers call finish, accept 404/409 as success)
- ✅ iOS Simulator support (local Mac and CI/CD)
- ✅ iOS Real Device support (local Mac and CI/CD with UUID coordination)
- ✅ Coordination for 1-20 workers (simulators or real devices)
- ✅ Handling workers with variable test counts and finish times
- ✅ Graceful handling of worker crashes
- ✅ File-based fallback coordination using host's `/tmp` directory (simulators only)
- ✅ POSIX flock for exclusive lock acquisition in fallback mode (simulators)

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
- Suite-level coordination (feature focuses on Launch-level)
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
