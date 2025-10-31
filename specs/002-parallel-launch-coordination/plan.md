````markdown
# Implementation Plan: UUID-Based Launch Coordination

**Branch**: `002-parallel-launch-coordination` | **Date**: 2025-01-31 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/002-parallel-launch-coordination/spec.md`

**Note**: This plan implements UUID-based coordination ONLY. File lock fallback approach is REMOVED.

## Summary

Implement UUID-based launch coordination for parallel test execution in iOS XCTest framework. All workers use a shared UUID (from `RP_LAUNCH_UUID` environment variable or auto-generated) to create a single ReportPortal launch. First worker succeeds (200 OK), others get 409 Conflict (acceptable). All workers report tests to the same launch. On finish, all workers call the finish endpoint - first succeeds (200 OK), others get 404 Not Found (acceptable, treated as success). This approach works cross-platform (simulators + real devices) with zero coordination overhead.

## Technical Context

**Language/Version**: Swift 5.5+ (async/await, Actor model required)  
**Primary Dependencies**: Foundation, XCTest (system frameworks), Swift Concurrency runtime  
**Storage**: N/A (coordination via ReportPortal API only, NO file-based coordination)  
**Testing**: XCTest for unit/integration tests, parallel test runs for validation  
**Target Platform**: iOS 13+, macOS 10.15+ (Swift Concurrency requirements)  
**Project Type**: iOS framework/library (Swift Package + CocoaPods)  
**Performance Goals**: <10 seconds coordination handshake, <5 seconds overhead vs sequential  
**Constraints**: No shared memory between workers, no file locks, environment variables read-only  
**Scale/Scope**: 1-20 parallel workers, works on simulators + real devices

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Status**: Constitution file is template-only, no project-specific rules enforced.

**Key Architectural Decisions**:
- ✅ **No external coordination service** - Uses ReportPortal API native 409 Conflict handling
- ✅ **No file locks** - Eliminates simulator-only limitation, works on real devices
- ✅ **Actor-based state management** - Swift Concurrency for thread-safe coordination
- ✅ **Tolerant error handling** - 409/404 treated as success, not errors
- ✅ **Zero configuration** - Auto-generates UUID if not provided
- ✅ **Backward compatible** - Existing v1 API usage for sequential mode unchanged

## Project Structure

### Documentation (this feature)

```text
specs/002-parallel-launch-coordination/
├── plan.md                         # This file (implementation plan)
├── spec.md                         # Feature specification (DONE)
├── implementation-plan.md          # Detailed task breakdown (DONE)
├── uuid-coordination-summary.md    # Decision rationale (DONE)
├── research.md                     # Phase 0 output (will create)
├── data-model.md                   # Phase 1 output (will create)
├── contracts/                      # Phase 1 output (will create)
│   ├── launch-api.yaml            # ReportPortal Launch API contract
│   └── coordination-flow.yaml     # Worker coordination flow
└── tasks.md                        # Phase 2 output (NOT created by this command)
```

### Source Code (repository root)

```text
Sources/
├── RPListener.swift                # [MODIFY] Update for UUID coordination
├── ReportingService.swift          # [MODIFY] Add UUID support, tolerant finish
├── LaunchMode.swift                # [KEEP] Existing
├── TestStatus.swift                # [KEEP] Existing
├── TestType.swift                  # [KEEP] Existing
├── EndPoints/
│   ├── StartLaunchV2EndPoint.swift    # [MODIFY] Add optional uuid field
│   ├── FinishLaunchV2EndPoint.swift   # [KEEP] Existing
│   └── [other endpoints]              # [KEEP] Existing
├── Entities/
│   ├── LaunchManager.swift            # [MODIFY] UUID generation/reading
│   ├── LaunchCoordinator.swift        # [DELETE] File lock logic removed
│   ├── LaunchIdLock.swift             # [DELETE] File lock primitives removed
│   ├── SuiteOperation.swift           # [KEEP] Existing
│   ├── TestOperation.swift            # [KEEP] Existing
│   └── [other entities]               # [KEEP] Existing
└── Utilities/
    └── [all utilities]                # [KEEP] Existing

Tests/
├── ExampleUnitTests/
│   ├── LaunchManagerTests.swift       # [ADD] UUID generation tests
│   ├── CoordinationTests.swift        # [ADD] 409/404 handling tests
│   └── [existing tests]               # [KEEP] Existing
└── ExampleUITests/
    └── [existing UI tests]            # [KEEP] Existing

docs/
├── xcode-pre-action-setup.md          # [DONE] Quick start guide
└── [other docs]                       # [KEEP] Existing
```

**Structure Decision**: UUID-based coordination eliminates need for LaunchCoordinator and LaunchIdLock classes. All coordination logic moves to LaunchManager (UUID generation) and ReportingService (409/404 handling). This simplifies the architecture significantly.

## Complexity Tracking

> **No constitution violations - this section documents simplification decisions**

| Decision | Simplification Achieved | Complexity Removed |
|----------|------------------------|-------------------|
| **Remove file locks** | No POSIX flock, no file I/O, no sync files | LaunchCoordinator (150+ lines), LaunchIdLock (100+ lines), file polling logic |
| **UUID-based coordination** | ReportPortal API handles conflicts natively | Custom primary/secondary worker detection, lock acquisition retries |
| **Tolerant finish** | All workers call finish, API handles duplicates | "Last worker" detection, bundle reference counting for finish timing |
| **Environment variable only** | Single source of truth for UUID | Sync file creation, polling, timeout logic |
| **Cross-platform by default** | Works on simulators + real devices | No platform-specific coordination paths |

**Net Result**: ~300 lines of coordination code removed, architecture simplified from 4 coordination classes to 1.

---

## Phase 0: Research & Clarifications

### Research Tasks

All technical unknowns have been resolved via prior investigation:

#### ✅ RESOLVED: ReportPortal Custom UUID Support
- **Question**: Does ReportPortal API accept custom UUIDs in launch creation?
- **Answer**: YES - `POST /v2/{project}/launch` accepts optional `uuid` field
- **Evidence**: GitHub source code analysis of `reportportal/service-api`
  ```java
  // LaunchBuilder.java
  launch.setUuid(Optional.ofNullable(request.getUuid())
      .orElse(UUID.randomUUID().toString()));
  ```
- **Implication**: No coordination overhead needed, UUID pre-created before workers start

#### ✅ RESOLVED: 409 Conflict Handling
- **Question**: What happens when multiple workers create launch with same UUID?
- **Answer**: First worker gets 200 OK, others get 409 Conflict (launch already exists)
- **Evidence**: ReportPortal API behavior + error response includes launch ID
- **Implication**: 409 Conflict is acceptable, extract UUID from response and proceed

#### ✅ RESOLVED: Multiple Finish Calls
- **Question**: What happens when all workers call finish on same launch?
- **Answer**: First worker gets 200 OK, others get 404 Not Found (already finished)
- **Evidence**: `PUT /v2/{project}/launch/{uuid}/finish` returns 404 if already closed
- **Implication**: 404 response treated as success (not error), tests already reported

#### ✅ RESOLVED: Test Result Safety
- **Question**: Are test results lost if finish call fails with 404?
- **Answer**: NO - test results reported during execution, finish only closes container
- **Evidence**: Test items created via separate `POST /v2/{project}/item` calls
- **Implication**: Multiple finish calls are safe, no data loss

#### ✅ RESOLVED: UUID Generation Strategy
- **Question**: How to generate unique UUID when not provided via environment?
- **Answer**: `{launchName}_{timestamp}_{PGID}` for simulators, `{launchName}_{timestamp}_{randomUUID}` for devices
- **Evidence**: PGID groups workers in same xcodebuild session (simulators), random UUID for cross-device
- **Implication**: Auto-generation works, but manual `RP_LAUNCH_UUID` preferred for control

#### ✅ RESOLVED: Environment Variable Distribution
- **Question**: Can all workers access same environment variable?
- **Answer**: YES - child processes inherit parent environment, read-only access
- **Evidence**: macOS process model, XCTest worker spawning
- **Implication**: Single `export RP_LAUNCH_UUID` in Xcode pre-action reaches all workers

### Best Practices Research

#### Swift Concurrency for Coordination
- **Pattern**: Actor-based state management for LaunchManager
- **Rationale**: Thread-safe access to shared launch state without locks
- **Reference**: Swift Concurrency documentation, Actor isolation model
- **Application**: LaunchManager tracks aggregated status across workers using Actor

#### Tolerant Error Handling
- **Pattern**: HTTP 409/404 treated as success for coordination endpoints
- **Rationale**: Idempotent operations, eventual consistency model
- **Reference**: REST API best practices, distributed systems patterns
- **Application**: `catch HTTPError where statusCode == 409 || statusCode == 404`

#### Zero Configuration
- **Pattern**: Convention over configuration, auto-generate defaults
- **Rationale**: Reduces friction, works out-of-box for 90% use cases
- **Reference**: Apple framework design (XCTest), Rails conventions
- **Application**: Auto-generate UUID if `RP_LAUNCH_UUID` not set

### Design Decisions

| Decision | Rationale | Alternative Rejected |
|----------|-----------|---------------------|
| **UUID-only coordination** | Works cross-platform, zero overhead | File locks (simulator-only) |
| **All workers call finish** | Simpler than "last worker" detection | Reference counting + sync |
| **Environment variable** | Standard Unix pattern, inherited by children | File-based UUID distribution |
| **Auto-generate UUID** | Zero config for simulators | Require manual setup |
| **Tolerant 409/404** | Idempotent, handles race conditions | Coordination to prevent duplicates |

**Output**: research.md (to be created)

---

## Phase 1: Design & Contracts

### Data Model (data-model.md)

#### Core Entities

**Launch** (ReportPortal concept, not a Swift class)
- `uuid: String` - Unique identifier (custom or generated)
- `name: String` - Launch name from configuration
- `mode: String` - "DEFAULT" for standard runs
- `startTime: Date` - When first worker started
- `status: TestStatus` - PASSED | FAILED | STOPPED (aggregated)
- `endTime: Date?` - When last worker finished

**LaunchManager** (Swift Actor - existing, modified)
- State:
  - `launchID: String?` - Current launch UUID
  - `activeBundles: [String: BundleInfo]` - Tracking worker bundles
  - `aggregatedStatus: TestStatus` - Worst status across all bundles
- Operations:
  - `getOrGenerateLaunchUUID() async -> String` - Read env var or generate
  - `setLaunchID(_ id: String) async` - Store launch UUID
  - `getLaunchID() async -> String?` - Retrieve launch UUID
  - `registerBundle(_ bundleID: String) async` - Track new worker
  - `updateBundleStatus(_ bundleID: String, status: TestStatus) async` - Update status
  - `getAggregatedStatus() async -> TestStatus` - Get worst status

**ReportingService** (Swift class - existing, modified)
- Methods:
  - `startLaunch(uuid: String?, name: String, ...) async throws -> String`
    - Accepts optional UUID
    - Handles 409 Conflict gracefully
    - Returns launch ID (from success or error)
  - `finishLaunch(launchID: String, status: TestStatus) async throws`
    - Calls finish endpoint
    - Treats 404/409 as success (not error)
    - Logs informational message

**StartLaunchV2EndPoint** (Swift struct - existing, modified)
- Fields:
  - `uuid: String?` - NEW: Optional custom UUID
  - `name: String` - Launch name
  - `mode: String` - Launch mode
  - `startTime: Date` - Start timestamp
- Body encoding: Include uuid only if non-nil

#### State Transitions

**Launch UUID Resolution**:
```
┌─────────────────┐
│ Worker Starts   │
└────────┬────────┘
         │
         ▼
┌─────────────────────────┐
│ Check RP_LAUNCH_UUID    │
│ environment variable    │
└────────┬────────────────┘
         │
    ┌────┴────┐
    │ Set?    │
    └────┬────┘
    YES  │  NO
    ▼    │  ▼
 ┌──────┴───────────────┐
 │ Use env value        │  Generate:
 │                      │  {name}_{time}_{PGID}
 └──────┬───────────────┘
        │
        ▼
┌─────────────────────────┐
│ Call POST /launch       │
│ with UUID               │
└────────┬────────────────┘
         │
    ┌────┴────┐
    │ Result? │
    └────┬────┘
    200  │  409
    │    │
    ▼    ▼
 ┌──────┴────────┐
 │ Extract UUID  │
 │ from response │
 └───────┬───────┘
         │
         ▼
┌─────────────────┐
│ Report tests    │
│ to launch UUID  │
└─────────────────┘
```

**Launch Finish Flow**:
```
┌─────────────────┐
│ Worker Finishes │
│ Tests           │
└────────┬────────┘
         │
         ▼
┌─────────────────────────┐
│ Update aggregated       │
│ status in LaunchManager │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ Call PUT /launch/finish │
│ with aggregated status  │
└────────┬────────────────┘
         │
    ┌────┴────┐
    │ Result? │
    └────┬────┘
    200  │  404/409
    │    │
    ▼    ▼
 ┌──────┴────────────┐
 │ Log success       │
 │ (first vs already │
 │  finished)        │
 └───────┬───────────┘
         │
         ▼
┌─────────────────┐
│ Worker exits    │
└─────────────────┘
```

### API Contracts (contracts/)

#### launch-api.yaml (ReportPortal Launch API)

```yaml
openapi: 3.0.0
info:
  title: ReportPortal Launch API (v2 Async)
  version: 2.0.0
  description: Subset relevant to UUID-based coordination

paths:
  /v2/{projectName}/launch:
    post:
      summary: Create or join launch with custom UUID
      operationId: startLaunch
      parameters:
        - name: projectName
          in: path
          required: true
          schema:
            type: string
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required:
                - name
                - startTime
              properties:
                uuid:
                  type: string
                  description: Optional custom UUID. If provided, creates launch with this UUID. If launch exists, returns 409 Conflict.
                  example: "MyTests_20251031_143022_12345"
                name:
                  type: string
                  example: "iOS Parallel Tests"
                mode:
                  type: string
                  default: "DEFAULT"
                  enum: [DEFAULT, DEBUG]
                startTime:
                  type: integer
                  format: int64
                  description: Unix timestamp in milliseconds
      responses:
        '200':
          description: Launch created successfully
          content:
            application/json:
              schema:
                type: object
                properties:
                  id:
                    type: string
                    description: Launch UUID (same as request uuid if provided)
        '409':
          description: Launch with this UUID already exists (acceptable for coordination)
          content:
            application/json:
              schema:
                type: object
                properties:
                  error_code:
                    type: integer
                  message:
                    type: string
                  id:
                    type: string
                    description: Existing launch UUID

  /v2/{projectName}/launch/{launchId}/finish:
    put:
      summary: Finish launch (idempotent, first call wins)
      operationId: finishLaunch
      parameters:
        - name: projectName
          in: path
          required: true
          schema:
            type: string
        - name: launchId
          in: path
          required: true
          schema:
            type: string
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                endTime:
                  type: integer
                  format: int64
                status:
                  type: string
                  enum: [PASSED, FAILED, STOPPED]
      responses:
        '200':
          description: Launch finished successfully (first worker)
          content:
            application/json:
              schema:
                type: object
                properties:
                  message:
                    type: string
        '404':
          description: Launch already finished (subsequent workers - treat as success)
        '409':
          description: Launch finish conflict (subsequent workers - treat as success)
```

#### coordination-flow.yaml (Worker Coordination Sequence)

```yaml
name: UUID-Based Parallel Test Coordination
description: Sequence diagram for multi-worker coordination without file locks

actors:
  - Xcode: CI/CD or manual test execution
  - Worker1: First test worker process
  - Worker2: Second test worker process
  - WorkerN: Additional workers
  - LaunchManager: Actor managing shared state
  - ReportPortal: Backend API

sequences:
  setup:
    - step: 1
      actor: Xcode
      action: Set RP_LAUNCH_UUID environment variable (optional)
      notes: "export RP_LAUNCH_UUID='MyTests_$(date +%s)_$(ps -o pgid= -p $$)'"
    
  parallel_start:
    - step: 2
      actor: Worker1
      action: Call LaunchManager.getOrGenerateLaunchUUID()
      result: Returns UUID from env or generates new one
    
    - step: 3
      actor: Worker1
      action: POST /v2/{project}/launch with uuid
      result: 200 OK - Launch created
    
    - step: 4
      actor: Worker2
      action: Call LaunchManager.getOrGenerateLaunchUUID()
      result: Returns same UUID (from env or shared generation)
    
    - step: 5
      actor: Worker2
      action: POST /v2/{project}/launch with same uuid
      result: 409 Conflict - Launch already exists
      notes: Extract UUID from error, proceed normally
    
    - step: 6
      actor: WorkerN
      action: Repeat steps 4-5
      result: All workers have launch UUID, start reporting tests
  
  test_execution:
    - step: 7
      actor: All Workers
      action: Execute tests, report via POST /v2/{project}/item
      notes: Parallel execution, no coordination needed
    
    - step: 8
      actor: All Workers
      action: Update LaunchManager with bundle status
      notes: LaunchManager.updateBundleStatus(bundleID, status)
  
  parallel_finish:
    - step: 9
      actor: Worker2
      action: Finishes first, calls LaunchManager.getAggregatedStatus()
      result: Returns aggregated status across all workers
    
    - step: 10
      actor: Worker2
      action: PUT /v2/{project}/launch/{uuid}/finish
      result: 200 OK - Launch finished
    
    - step: 11
      actor: Worker1
      action: Finishes second, calls PUT /v2/{project}/launch/{uuid}/finish
      result: 404 Not Found - Already finished
      notes: Treated as success, log info message
    
    - step: 12
      actor: WorkerN
      action: All remaining workers call finish
      result: All get 404 - All treated as success

  result:
    - Single launch in ReportPortal
    - All test results present
    - Aggregated status correct
    - No coordination overhead
```

### Output Artifacts

1. **data-model.md**: Entity definitions, state transitions, validation rules
2. **contracts/launch-api.yaml**: ReportPortal API contract (subset)
3. **contracts/coordination-flow.yaml**: Worker coordination sequence
4. **Updated copilot-instructions.md**: Add UUID coordination patterns

---

## Phase 2: Implementation Tasks

**Note**: Detailed task breakdown already exists in `implementation-plan.md`. This section provides high-level overview.

### Task Groups

**Group 1: Core UUID Support (P0)**
- Task 1.1: Update LaunchManager for UUID generation/reading
- Task 1.2: Update ReportingService for custom UUID parameter
- Task 1.3: Implement tolerant finish logic (404/409 as success)
- Task 1.4: Update StartLaunchV2EndPoint with optional uuid field

**Group 2: Integration (P0)**
- Task 2.1: Update RPListener for UUID coordination flow
- Task 2.2: Remove LaunchCoordinator class (file lock logic)
- Task 2.3: Remove LaunchIdLock class (file lock primitives)
- Task 2.4: Clean up unused coordination files/utilities

**Group 3: Testing (P1)**
- Task 3.1: Unit tests for UUID generation logic
- Task 3.2: Unit tests for 409/404 handling
- Task 3.3: Integration tests with parallel workers
- Task 3.4: CI/CD pipeline validation

**Group 4: Documentation (P1)**
- Task 4.1: Update README with UUID coordination setup
- Task 4.2: Xcode pre-action guide (already done)
- Task 4.3: Migration guide from file lock approach
- Task 4.4: Troubleshooting guide

### Files to DELETE

```text
Sources/Entities/LaunchCoordinator.swift    # File lock coordination (obsolete)
Sources/Entities/LaunchIdLock.swift         # POSIX flock wrapper (obsolete)
```

### Files to MODIFY

```text
Sources/RPListener.swift                    # UUID coordination flow
Sources/ReportingService.swift              # UUID param, tolerant finish
Sources/EndPoints/StartLaunchV2EndPoint.swift  # Optional uuid field
Sources/Entities/LaunchManager.swift        # UUID generation/reading
```

### Files to ADD

```text
ExampleUnitTests/LaunchManagerTests.swift   # UUID generation tests
ExampleUnitTests/CoordinationTests.swift    # 409/404 handling tests
docs/migration-from-filelock.md             # Migration guide
```

---

## Timeline & Milestones

**Phase 0: Research** - COMPLETE (already done)
- All technical unknowns resolved
- Design decisions documented

**Phase 1: Design & Contracts** - 2-3 hours
- Create data-model.md
- Create API contracts (YAML)
- Update copilot-instructions.md

**Phase 2: Implementation** - 8-10 hours
- Core UUID support: 4 hours
- Integration & cleanup: 2 hours
- Testing: 2-3 hours
- Documentation: 1-2 hours

**Total Estimate**: 10-13 hours

---

## Success Criteria

### Phase 1 Completion
- ✅ data-model.md created with all entities and state transitions
- ✅ API contracts created (launch-api.yaml, coordination-flow.yaml)
- ✅ copilot-instructions.md updated with UUID patterns
- ✅ All NEEDS CLARIFICATION items resolved

### Phase 2 Completion (from spec.md)
- ✅ SC-001: Exactly 1 launch created with 5 parallel workers
- ✅ SC-002: All test results in single launch (zero data loss)
- ✅ SC-003: Launch finishes after last worker completes
- ✅ SC-004: Aggregated status correct (FAILED if any worker failed)
- ✅ SC-005: Coordination completes within 10 seconds
- ✅ SC-006: Works from Xcode without manual steps
- ✅ SC-007: Handles 1-20 workers without config changes
- ✅ SC-008: 100% of runs result in single launch
- ✅ SC-009: Zero test results lost vs current file lock approach
- ✅ SC-010: <5 seconds coordination overhead

---

## Next Steps

1. **Run `/speckit.plan` completion**:
   - Generate research.md (consolidate resolved items)
   - Generate data-model.md (entity definitions)
   - Generate contracts/ (API contracts)
   - Update copilot-instructions.md

2. **Run `/speckit.tasks`**:
   - Break down Phase 2 into actionable tasks
   - Generate tasks.md with priorities and dependencies

3. **Implementation**:
   - Execute tasks in priority order
   - Validate with integration tests
   - Update documentation

4. **Validation**:
   - Run parallel tests on simulators (5 workers)
   - Run parallel tests on real devices (if available)
   - Verify success criteria met

````
