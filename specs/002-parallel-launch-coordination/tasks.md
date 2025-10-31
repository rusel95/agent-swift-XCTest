# Tasks: Parallel Launch Coordination

**Input**: Design documents from `/specs/002-parallel-launch-coordination/`
**Prerequisites**: plan.md, spec.md, data-model.md, contracts/, research.md, quickstart.md

**Tests**: Not explicitly requested in spec - implementation tasks only.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [ ] T001 Verify Swift Package Manager configuration in Package.swift includes required dependencies (Foundation, XCTest)
- [ ] T002 Create coordination directory structure /tmp/reportportal_coordination/ with proper permissions
- [ ] T003 [P] Add LaunchCoordinator.swift, LaunchIdLock.swift, FileLogger.swift to Xcode project targets

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T004 [P] Complete FileLogger actor implementation in Sources/Utilities/FileLogger.swift with JSON Lines format logging to /tmp/reportportal_coordination/events_{pgid}.log
- [X] T005 [P] Implement POSIX file locking wrapper functions in Sources/Entities/LaunchIdLock.swift (flock with LOCK_EX | LOCK_NB)
- [X] T006 Implement LaunchIdLock actor methods: obtainLaunchUuid, getLiveInstanceUuids, finishInstanceUuid, reset in Sources/Entities/LaunchIdLock.swift
- [X] T007 [P] Update LaunchManager actor in Sources/Entities/LaunchManager.swift to add reference counting (activeBundleCount), status aggregation (aggregatedStatus), and finalization tracking (isFinalized)
- [X] T008 Create session ID generation utility function in Sources/Utilities/SessionHelper.swift using PGID or RP_SESSION_ID environment variable
- [X] T009 Implement coordination file path generation utility in Sources/Utilities/CoordinationPaths.swift for lock, sync, and event log files

**Checkpoint**: ✅ Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Single Launch Creation Across Simulator Workers (Priority: P1) 🎯 MVP

**Goal**: Ensure exactly one Launch is created in ReportPortal regardless of number of parallel workers

**Independent Test**: Run parallel tests with 2+ workers and verify only one Launch appears in ReportPortal with all test results

### Implementation for User Story 1

- [X] T010 [P] [US1] Implement lock file acquisition logic in LaunchCoordinator.swift method getOrCreateLaunchID with POSIX flock via LaunchIdLock
- [X] T011 [P] [US1] Implement primary worker role determination in LaunchCoordinator.swift when lock is successfully acquired
- [X] T012 [P] [US1] Implement secondary worker role determination in LaunchCoordinator.swift when lock acquisition fails
- [X] T013 [US1] Create ReportPortal v2 Launch creation endpoint in Sources/EndPoints/StartLaunchV2EndPoint.swift with POST /v2/{project}/launch
- [X] T014 [US1] Implement Launch creation call for primary worker in LaunchCoordinator.swift using StartLaunchV2EndPoint
- [X] T015 [US1] Implement Launch ID writing to sync file in LaunchCoordinator.swift using NSFileCoordinator for atomic write to /tmp/reportportal_coordination/launch_{name}_{session}.sync
- [X] T016 [US1] Add coordination event logging in LaunchCoordinator.swift for PRIMARY_LOCK_ACQUIRED, LAUNCH_CREATED, LAUNCH_ID_WRITTEN events
- [X] T017 [US1] Integrate parallel mode detection in Sources/RPListener.swift testBundleWillStart method to call LaunchCoordinator instead of direct launch creation

**Checkpoint**: ✅ At this point, primary worker can create Launch and write Launch ID to sync file

---

## Phase 4: User Story 4 - Launch ID Distribution (Priority: P2)

**Goal**: Enable secondary workers to discover and use the shared Launch ID quickly (within 5 seconds)

**Independent Test**: Measure time from Launch creation to when all workers have Launch ID, verify < 5 seconds

### Implementation for User Story 4

- [X] T018 [P] [US4] Implement sync file polling logic in LaunchCoordinator.swift for secondary workers with 100ms interval, 60 second timeout
- [X] T019 [P] [US4] Implement Launch ID reading from sync file in LaunchCoordinator.swift using NSFileCoordinator for coordinated read
- [X] T020 [P] [US4] Implement Launch ID validation in LaunchCoordinator.swift to parse UUID from line 1 of sync file
- [X] T021 [US4] Add retry logic in LaunchCoordinator.swift for sync file read failures with exponential backoff (1s, 2s, 4s, 8s)
- [X] T022 [US4] Add coordination event logging for SECONDARY_JOINED, LAUNCH_ID_READ events in LaunchCoordinator.swift
- [X] T023 [US4] Update RPListener.swift testBundleWillStart to await Launch ID from LaunchCoordinator for secondary workers

**Checkpoint**: At this point, secondary workers can discover and use shared Launch ID

---

## Phase 5: User Story 5 - Worker Completion Tracking (Priority: P2)

**Goal**: Track which workers have completed to determine when it's safe to finalize Launch

**Independent Test**: Run parallel tests and log worker registration/completion events, verify all workers tracked correctly

### Implementation for User Story 5

- [X] T024 [P] [US5] Implement worker registration in LaunchIdLock.swift method registerWorker to track liveInstances set
- [X] T025 [P] [US5] Implement worker completion marking in LaunchIdLock.swift method finishInstanceUuid returning true if last worker
- [X] T026 [P] [US5] Implement worker count detection in LaunchCoordinator.swift: read RP_PARALLEL_WORKERS environment variable or use timeout-based detection (30 seconds)
- [X] T027 [US5] Implement last worker detection logic in LaunchCoordinator.swift comparing completed count vs expected worker count
- [X] T028 [US5] Add coordination event logging for WORKER_REGISTERED, WORKER_COMPLETED events in LaunchCoordinator.swift
- [X] T029 [US5] Update LaunchManager.swift decrementBundleCount method to return true when last bundle completes

**Checkpoint**: ✅ At this point, system can track all workers and detect when last worker completes

---

## Phase 6: User Story 2 - Coordinated Launch Finish (Priority: P1)

**Goal**: Ensure Launch finishes only after ALL workers complete, preventing premature closure

**Independent Test**: Run parallel tests with uneven test distribution, verify Launch remains open until last worker finishes

### Implementation for User Story 2

- [X] T030 [US2] Create ReportPortal v2 Launch finish endpoint in Sources/EndPoints/FinishLaunchV2EndPoint.swift with PUT /v2/{project}/launch/{id}/finish
- [X] T031 [US2] Implement status aggregation logic in LaunchManager.swift updateStatus method following FAILED > STOPPED > PASSED hierarchy
- [X] T032 [US2] Implement launch finalization check in RPListener.swift testBundleDidFinish to only call finish when last worker completes
- [X] T033 [US2] Implement Launch finish call in LaunchCoordinator.swift using FinishLaunchV2EndPoint with aggregated status
- [X] T034 [US2] Implement coordination file cleanup in LaunchCoordinator.swift cleanupCoordinationFile method to remove lock and sync files
- [X] T035 [US2] Add coordination event logging for LAUNCH_FINALIZED, CLEANUP_STARTED, CLEANUP_COMPLETED events
- [X] T036 [US2] Add markFinalized method in LaunchManager.swift to prevent duplicate finalization

**Checkpoint**: ✅ At this point, Launch coordination is fully functional with proper finish coordination

---

## Phase 7: User Story 3 - Zero-Configuration Xcode Integration (Priority: P1)

**Goal**: Enable parallel coordination to work automatically when running tests from Xcode without manual configuration

**Independent Test**: Run parallel tests directly from Xcode without pre-execution steps, verify single Launch creation

### Implementation for User Story 3

- [X] T037 [P] [US3] Implement PGID (process group ID) extraction in Sources/Utilities/SessionHelper.swift using getpgid() system call
- [X] T038 [P] [US3] Implement RP_SESSION_ID environment variable reading in SessionHelper.swift with PGID fallback
- [X] T039 [P] [US3] Implement RP_PARALLEL_WORKERS environment variable reading in LaunchCoordinator.swift for explicit worker count
- [X] T040 [US3] Implement automatic parallel mode detection in RPListener.swift by checking for multiple workers in same session
- [X] T041 [US3] Update LaunchCoordinator.swift initialization in RPListener.swift to use session ID from SessionHelper
- [X] T042 [US3] Implement API version selection logic in RPListener.swift: use v2 endpoints for parallel mode, v1 for sequential
- [X] T043 [US3] Add console logging in RPListener.swift for parallel mode detection and coordination initialization

**Checkpoint**: ✅ At this point, zero-configuration Xcode integration is complete

---

## Phase 8: User Story 6 - Graceful Degradation (Priority: P3)

**Goal**: Provide fallback behavior when coordination fails, ensuring tests still execute and produce results

**Independent Test**: Simulate coordination failures (block file access), verify tests still execute with appropriate warnings

### Implementation for User Story 6

- [ ] T044 [P] [US6] Implement exponential backoff retry logic in LaunchCoordinator.swift for lock acquisition failures (1s, 2s, 4s, 8s, max 4 retries)
- [ ] T045 [P] [US6] Implement exponential backoff retry logic in LaunchCoordinator.swift for sync file read failures (1s, 2s, 4s, 8s, max 4 retries)
- [ ] T046 [P] [US6] Implement fallback to separate launch creation in LaunchCoordinator.swift when coordination fails after all retries
- [ ] T047 [US6] Add comprehensive error logging in LaunchCoordinator.swift for all coordination failure scenarios with actionable error messages
- [ ] T048 [US6] Implement coordination timeout detection in LaunchCoordinator.swift for workers starting >30 seconds apart
- [ ] T049 [US6] Add COORDINATION_ERROR event logging in FileLogger.swift with error type and message details
- [ ] T050 [US6] Implement stale lock detection in LaunchIdLock.swift for primary worker crash scenarios (future enhancement placeholder)

**Checkpoint**: All user stories should now be independently functional with proper error handling

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories and final validation

- [ ] T051 [P] Update README.md with parallel coordination feature documentation and basic usage
- [ ] T052 [P] Add inline code documentation in LaunchCoordinator.swift with method descriptions and parameter explanations
- [ ] T053 [P] Add inline code documentation in LaunchManager.swift with actor state management details
- [ ] T054 [P] Add inline code documentation in LaunchIdLock.swift with POSIX file locking details
- [ ] T055 [P] Add inline code documentation in FileLogger.swift with JSON Lines format specification
- [ ] T056 Create integration test scenario in ExampleUITests/ParallelCoordinationTests.swift for 2 workers (if tests requested)
- [ ] T057 Create integration test scenario in ExampleUITests/ParallelCoordinationTests.swift for 5 workers (if tests requested)
- [ ] T058 Validate quickstart.md instructions by running through setup steps manually
- [ ] T059 Performance validation: measure coordination overhead and verify < 5 seconds target
- [ ] T060 Security review: verify no sensitive data logged to coordination files
- [ ] T061 [P] Code cleanup: remove any debug logging and commented code
- [ ] T062 Final git commit with all changes and comprehensive commit message

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational (Phase 2) - Creates core launch coordination
- **User Story 4 (Phase 4)**: Depends on User Story 1 (Phase 3) - Launch ID must exist before distribution
- **User Story 5 (Phase 5)**: Depends on Foundational (Phase 2) - Can run parallel with US1/US4
- **User Story 2 (Phase 6)**: Depends on US1, US4, US5 - Needs all coordination pieces working
- **User Story 3 (Phase 7)**: Depends on US1, US4, US5, US2 - Integration of all pieces
- **User Story 6 (Phase 8)**: Can enhance any completed story - Adds error handling
- **Polish (Phase 9)**: Depends on all desired user stories being complete

### User Story Dependencies

```
Setup (Phase 1)
    ↓
Foundational (Phase 2) ← CRITICAL BLOCKER
    ↓
    ├─→ User Story 1 (P1) - Single Launch Creation ← MVP START
    │       ↓
    │   User Story 4 (P2) - Launch ID Distribution
    │       ↓
    ├─→ User Story 5 (P2) - Worker Completion Tracking
    │       ↓
    └─→ User Story 2 (P1) - Coordinated Launch Finish
            ↓
        User Story 3 (P1) - Zero-Configuration Xcode
            ↓
        User Story 6 (P3) - Graceful Degradation
            ↓
        Polish (Phase 9)
```

### Within Each User Story

- Core coordination logic before integration
- File operations before API calls
- Primary worker logic before secondary worker logic
- Event logging after each major operation

### Parallel Opportunities

- All Setup tasks marked [P] can run in parallel
- All Foundational tasks marked [P] can run in parallel (FileLogger, LaunchIdLock, utilities)
- Within each user story, tasks marked [P] can run in parallel
- User Story 5 can be developed in parallel with US1/US4 (independent tracking logic)
- User Story 6 error handling can be added to any completed story in parallel

---

## Parallel Example: User Story 1

```bash
# Launch all parallel tasks for User Story 1 together:
Task T010: "Implement lock file acquisition logic in LaunchCoordinator.swift"
Task T011: "Implement primary worker role determination in LaunchCoordinator.swift"
Task T012: "Implement secondary worker role determination in LaunchCoordinator.swift"

# These can be done in parallel because they work on different logical sections
# of the same file (lock acquisition, primary role, secondary role)
```

---

## Implementation Strategy

### MVP First (User Stories 1, 4, 5, 2, 3 - All P1/P2)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1 (Single Launch Creation)
4. Complete Phase 4: User Story 4 (Launch ID Distribution)
5. Complete Phase 5: User Story 5 (Worker Completion Tracking)
6. Complete Phase 6: User Story 2 (Coordinated Launch Finish)
7. Complete Phase 7: User Story 3 (Zero-Configuration Xcode)
8. **STOP and VALIDATE**: Test parallel execution end-to-end
9. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 + 4 + 5 + 2 + 3 → Test end-to-end → Deploy/Demo (MVP!)
3. Add User Story 6 → Test error scenarios → Deploy/Demo
4. Add Polish → Final validation → Deploy/Demo

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: User Story 1 + User Story 4 (tightly coupled)
   - Developer B: User Story 5 (independent worker tracking)
   - Developer C: RPListener integration (User Story 3 prep)
3. Once US1, US4, US5 complete:
   - Developer A: User Story 2 (Launch finish coordination)
   - Developer B: User Story 3 (Zero-configuration integration)
4. Once all P1/P2 complete:
   - Any developer: User Story 6 (Error handling across all stories)

---

## Current State Analysis

Based on git status, the following files have been started:

**Modified (In Progress)**:
- ✏️ `Sources/Entities/LaunchManager.swift` - Partially modified
- ✏️ `Sources/RPListener.swift` - Integration started

**Created (Untracked)**:
- 📄 `Sources/Entities/LaunchCoordinator.swift` - File created, needs implementation
- 📄 `Sources/Entities/LaunchIdLock.swift` - File created, needs implementation
- 📄 `Sources/Utilities/FileLogger.swift` - File created, needs implementation

**Recommendation**: Start with Phase 2 (Foundational) to complete the core actors and utilities before moving to user story implementation.

---

## Notes

- [P] tasks = different files or independent sections, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Tests are NOT included per spec (not explicitly requested)
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Focus on coordination infrastructure first (Phase 2) before user story features
- Parallel mode is iOS Simulator-only; sequential mode works everywhere

---

**Total Tasks**: 62 tasks across 9 phases
**MVP Scope**: Phases 1-7 (Tasks T001-T043) - 43 tasks
**Estimated MVP Complexity**: Medium-High (core coordination + file I/O + actors)
**Parallel Opportunities**: 21 tasks marked [P] can run in parallel within their phase

---

**Tasks Generated** | Feature: 002-parallel-launch-coordination | Ready for `/speckit.implement`
