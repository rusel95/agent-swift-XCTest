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
| **Parallel** (2+ workers) | **Simulators** | ✅ Works | ✅ Works | File-based coordination | **Supported** |
| **Parallel** (2+ workers) | **Real Devices** | ❌ Not supported | ❌ Not supported | No shared file system | **Out of scope** |

**Why simulator-only for parallel?**
- Parallel coordination requires shared file system for worker communication
- iOS Simulators share host Mac's `/tmp` directory (works)
- Real devices have isolated sandboxes with NO shared storage (doesn't work)
- Future versions may add network-based coordination for real devices

**What this means for you:**
- ✅ **Sequential tests work everywhere** - Simulators, real devices, local, CI/CD
- ✅ **Parallel tests work on simulators** - Multiple simulators coordinate via shared files
- ❌ **Parallel tests DON'T work on real devices** - Each device creates separate launch (no coordination)
- 📝 **Workaround for real devices**: Use external scripts to pre-create launch and merge results (see Out of Scope)

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

- Q: Can ReportPortal API query existing IN_PROGRESS launches to avoid file-based coordination? → A: Yes, but with caveats (Hybrid approach recommended)
  - **API Discovery**: ReportPortal supports filtering launches by status via `GET /v1/{projectKey}/launch?filter.eq.status=IN_PROGRESS&filter.eq.name={launchName}`
  - **Race Condition Risk**: Two devices querying simultaneously can both see "no launch exists" and create duplicates (no atomic get-or-create)
  - **Recommended Strategy**: Hybrid approach:
    1. **Query API first** for existing IN_PROGRESS launch (eliminates coordination when workers start with time delay)
    2. **Fall back to file lock** if no launch found AND on simulators (prevents race conditions)
    3. **Accept duplication** if on real devices (simpler than network coordination, can merge later)
  - **Benefits**:
    - Optimizes common case (workers start 20s apart → 2nd worker finds 1st worker's launch via API)
    - Eliminates file coordination overhead when API query succeeds
    - Works cross-platform (real devices can query API even without shared files)
    - Maintains race condition prevention on simulators via file lock fallback
  - **Implementation Options**:
    - **Option 1 (Hybrid)**: Try API query → if found use it, if not found use file lock (simulators) or create new (devices)
    - **Option 2 (API-only + duplication)**: Try API query → if not found create new, accept multiple launches on real devices
    - **Option 3 (Current)**: File lock only (simulators work, real devices create separate launches)

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

- What happens when a worker crashes mid-execution? (Should not prevent Launch finalization)
- What happens when Xcode is force-quit during test execution? (Launch should auto-close or be cleanable)
- What happens when **simulator** workers start with significant time delays? (Late workers should still join the same Launch)
- What happens when running parallel tests on **real devices** instead of simulators? (**NO coordination** - each device creates separate launch, users must use external scripts or sequential mode)
- What happens when running sequential tests on **real devices**? (Works perfectly - single device, no coordination needed)
- What happens when network connectivity to ReportPortal is intermittent? (Coordination should handle API failures gracefully)
- What happens when two separate test runs start simultaneously? (Each run should have its own isolated Launch)
- What happens when worker count exceeds expected maximum? (System should handle unbounded worker counts)
- What happens when parallel mode detection fails? (System should default to sequential mode to avoid coordination overhead)
- What happens when a single worker is detected but parallel testing is enabled? (Treat as sequential run, no coordination needed)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST ensure exactly one Launch is created per test run regardless of number of parallel workers
- **FR-002**: System MUST distribute the shared Launch ID to all workers within 5 seconds of Launch creation
- **FR-003**: System MUST track completion status of all workers participating in the test run
- **FR-004**: System MUST finalize Launch exactly once only after all workers have completed their tests
- **FR-005**: System MUST aggregate test status across all workers (if any test fails, Launch status is FAILED)
- **FR-006**: System MUST work from Xcode without requiring external scripts or manual pre-configuration
- **FR-007**: System MUST handle unknown worker counts determined dynamically by Xcode
- **FR-008**: System MUST coordinate across multiple independent simulator processes with no shared memory but shared file system access
- **FR-009**: System MUST work on iOS Simulators (local Mac and CI/CD) for parallel coordination via shared `/tmp` directory
- **FR-010**: System MUST work on iOS Real Devices in sequential mode (single worker, no coordination needed)
- **FR-011**: System MUST isolate coordination between different test runs (separate Launches per run)
- **FR-012**: System MUST complete coordination handshake (Launch creation + ID distribution) within 10 seconds
- **FR-013**: System MUST provide clear logging of coordination events for debugging
- **FR-014**: System MUST handle workers starting with time delays (late joiners can use shared Launch)
- **FR-015**: For PARALLEL/SIMULATOR mode: System MUST use file-based coordination with POSIX flock to ensure only ONE Launch is created, with primary worker creating Launch and secondary workers discovering shared Launch ID from sync file
- **FR-016**: System MUST support manual Launch pre-creation via environment variable `RP_LAUNCH_ID` as escape hatch for CI/CD or advanced users (takes priority over file-based coordination)
- **FR-017**: Workers MUST be able to report test results continuously throughout execution without blocking coordination
- **FR-018**: System MUST prevent race conditions when multiple simulators attempt to create Launch simultaneously using POSIX flock (LOCK_EX | LOCK_NB)
- **FR-019**: System MUST prevent premature Launch finalization when fast workers complete before slow workers using bundle reference counting in LaunchManager
- **FR-020**: System MUST clean up coordination resources after Launch finalization (lock file and sync file)
- **FR-021**: System MUST detect parallel execution mode and use appropriate API: v2 async API for parallel/simulator runs (launches, logs) for non-blocking operations, v1 sync API for sequential runs for simplicity and backward compatibility
- **FR-022**: System MUST detect parallel execution mode by checking for multiple active bundles in same process group (via PGID or RP_SESSION_ID)
- **FR-023**: For PARALLEL/SIMULATOR runs: Primary worker MUST call `POST /v2/{projectName}/launch` to create ONE shared Launch
- **FR-024**: For PARALLEL/SIMULATOR runs: Primary worker MUST write Launch ID to sync file `/tmp/reportportal_coordination/launch_{name}_{session}.sync` immediately after creation
- **FR-025**: For PARALLEL/SIMULATOR runs: Secondary workers MUST poll sync file (100ms intervals, 60s timeout) to discover shared Launch ID
- **FR-026**: For PARALLEL/SIMULATOR runs: Last worker MUST call `PUT /v2/{projectName}/launch/{launchId}/finish` with aggregated status only after all workers complete
- **FR-027**: For SEQUENTIAL runs (single worker, any platform): System MAY continue using existing v1 API (`POST /v1/{projectName}/launch`, `PUT /v1/{projectName}/launch/{launchId}/finish`) without coordination overhead
- **FR-028**: System MUST use v1 force finish API (`PUT /v1/{projectName}/launch/{launchId}/stop`) for cleanup when worker crashes or coordination fails (if needed)
- **FR-029**: For PARALLEL/SIMULATOR runs: System MUST use session-based file naming with PGID for coordination files to isolate different test runs
- **FR-030**: For PARALLEL/SIMULATOR runs: LaunchManager MUST track active bundle count to determine when last worker completes
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

### High-Level Flow Using Shared Launch ID (Parallel Runs Only)

**Phase 1: Worker Initialization (Parallel)**
1. Each worker starts independently (Worker 1, 2, 3, 4, 5)
2. Each worker generates session ID (based on PGID - Process Group ID)
3. Workers attempt to obtain lock on coordination file

**Phase 2: Launch Creation (Primary Worker Only)**
1. **Primary Worker** (first to obtain lock):
   - Obtains exclusive POSIX flock on `/tmp/reportportal_coordination/launch_{name}_{session}.lock`
   - Calls `POST /v2/{projectName}/launch` to create ONE Launch
   - Receives Launch ID from ReportPortal
   - Writes Launch ID to sync file: `/tmp/reportportal_coordination/launch_{name}_{session}.sync`
   - Releases lock
   - Starts executing tests, reporting to the Launch

2. **Secondary Workers** (failed to obtain lock):
   - Poll sync file `/tmp/reportportal_coordination/launch_{name}_{session}.sync` 
   - Read shared Launch ID from sync file (typically within 100-500ms)
   - Start executing tests, reporting to the SAME Launch

**Phase 3: Test Execution (All Workers in Parallel)**
- All workers execute their assigned tests
- All workers report test results to the SAME Launch ID
- Test items (suites/tests) created via standard item API
- Logs reported via `POST /v2/{projectName}/log` (batch) or `POST /v2/{projectName}/log/entry` (single)
- All v2 async APIs used for non-blocking operation

**Phase 4: Launch Finalization (Last Worker Only)**
1. Each worker completes its tests
2. Each worker decrements active bundle count in LaunchManager
3. **Last Worker** (when count reaches zero):
   - Calls `PUT /v2/{projectName}/launch/{launchId}/finish` with aggregated status
   - Cleans up coordination files (lock and sync files)

**Result**: Single unified Launch in ReportPortal with all test results from all workers

**Key Difference from Merge Approach**: This approach uses a single shared Launch from the start. Workers coordinate via file-based locking to ensure only one Launch is created, then all workers report to it. No merge operation is needed.

### Error Handling Flow

**If Worker Crashes:**
1. Other workers continue normally
2. All workers continue reporting to the shared Launch
3. Last surviving worker finalizes Launch with aggregated status
4. Coordination files cleaned up after finalization

**If Lock File Acquisition Fails:**
1. Worker retries with exponential backoff (1s, 2s, 4s, 8s)
2. If all retries fail, worker creates separate Launch and logs warning
3. Tests continue to execute and report (degraded mode)

**If Sync File Read Fails:**
1. Secondary worker polls sync file with 100ms intervals
2. If timeout (60 seconds) expires without Launch ID, worker creates separate Launch
3. Tests continue to execute and report (degraded mode)
4. Log warning about coordination failure

**If Coordination Directory Unavailable:**
1. Worker falls back to creating individual Launch (no coordination)
2. Log warning about file system access issue
3. Tests continue to execute and report (degraded mode)

## Scope *(mandatory)*

### In Scope

**Parallel Coordination (iOS Simulators ONLY):**
- ✅ Coordinating Launch creation across multiple parallel **simulator** workers via file-based locking
- ✅ Distributing shared Launch ID to all **simulator** workers via sync file
- ✅ Tracking **simulator** worker completion status via LaunchManager bundle counting
- ✅ Coordinating Launch finalization after all **simulator** workers complete
- ✅ Zero-configuration Xcode integration for **simulators**
- ✅ iOS Simulator support (local Mac and CI/CD on single VM)
- ✅ Coordination for 1-20 **simulator** workers
- ✅ Handling **simulator** workers with variable test counts and finish times
- ✅ Graceful handling of **simulator** worker crashes
- ✅ File-based coordination using host's `/tmp` directory (**simulators** share this)
- ✅ POSIX flock for exclusive lock acquisition (primary/secondary worker roles)

**Sequential Mode (All Platforms):**
- ✅ Single worker execution on iOS Simulators (no coordination needed)
- ✅ Single worker execution on Real Devices (no coordination needed)
- ✅ Works everywhere: local Mac, CI/CD, real devices, simulators
- ✅ Uses existing v1 API (simple, synchronous)

**General:**
- ✅ Clear logging and debugging support
- ✅ API version detection (v1 for sequential, v2 for parallel)
- ✅ Environment variable support (`RP_LAUNCH_ID`, `RP_PARALLEL_WORKERS`)

### Out of Scope

**Real Device Parallel Coordination (Future Phase):**
- ❌ Coordinating Launch creation across multiple parallel **real devices**
- ❌ File-based coordination for **real devices** (no shared file system)
- ❌ Real device testing in parallel mode (each device creates separate launch)
- ❌ CI/CD device farms (AWS Device Farm, BrowserStack, Firebase Test Lab) in parallel mode
- ❌ Network-based coordination server (future v2 feature)
- ❌ Mixed simulator + real device parallel runs

**Workaround for Real Devices (Documented):**
Users needing parallel coordination on real devices must use external scripts to:
1. Pre-create launch via API before tests
2. Set `RP_LAUNCH_ID` environment variable
3. Post-merge launches via API after tests (if multiple devices)
Example scripts will be provided in documentation.

**Other Out of Scope:**
- Coordination across multiple machines/hosts (single-machine only)
- Backward compatibility with existing broken NSFileCoordinator-based code (will replace)
- Suite-level coordination (feature focuses on Launch-level)
- Automatic retry of failed tests
- Test result filtering or transformation
- ReportPortal server configuration or setup
- CI/CD-specific optimizations beyond parallel coordination

## Dependencies & Assumptions *(mandatory)*

### Dependencies

- ReportPortal server API availability for Launch creation and finalization
- Xcode parallel testing infrastructure (`-parallel-testing-enabled YES`)
- iOS Simulator environment with accessible shared resources
- Swift concurrency features (async/await, actors)

### Assumptions

**For Parallel/Simulator Coordination:**
- **Simulator workers** are spawned by the same `xcodebuild` command on same host machine (share process group PGID)
- **Simulator workers** start within reasonable time window (< 30 seconds between first and last)
- **Simulator workers** share host Mac's `/tmp` directory via `NSTemporaryDirectory()` (current iOS Simulator behavior)
- **Simulator workers** can read/write files to `/tmp/reportportal_launches_{PGID}.txt` without sandboxing restrictions
- **Simulator workers** fail independently (one worker crash doesn't crash others)
- File system on host Mac supports POSIX file locking (`flock`) for coordination
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

1. **Timeout Values**: What specific timeout values should be used for:
   - Sync file read timeout (default: 60 seconds for secondary workers)
   - Launch ID polling interval (default: 100ms)
   - Lock acquisition timeout (default: immediate LOCK_NB non-blocking)
   - Retry delays for coordination failures (default: exponential backoff 1s, 2s, 4s, 8s)

2. **Coordination State Cleanup**: Should coordination files be cleaned up immediately after Launch finalization or persist for debugging?
   - Option A: Immediate cleanup (cleaner, but harder to debug)
   - Option B: Time-based cleanup (keep for 1 hour, then auto-delete)
   - Option C: Manual cleanup command for developers

3. **Partial Failure Handling**: When a worker crashes mid-execution, should the system:
   - Wait for all bundles to complete then finalize normally (may delay results if worker is stuck)
   - Detect crash via timeout and finalize with remaining workers (faster but may miss slow workers)
   - Use force finish API on remaining tests

4. **Launch Naming Strategy**: How should Launch be named in parallel mode?
   - Include worker count: "Test Run [5 Workers]"
   - Include device info: "Test Run [iPhone 15 Pro Simulators]"
   - Include PGID: "Test Run [PGID:12345]"
   - Keep simple: Just use base launch name
