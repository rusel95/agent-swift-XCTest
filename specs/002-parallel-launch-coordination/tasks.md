# Implementation Tasks: UUID-Based Launch Coordination

**Feature**: 002-parallel-launch-coordination  
**Branch**: `002-parallel-launch-coordination`  
**Date**: 2025-01-31  
**Approach**: UUID-only coordination (NO file lock fallback)

---

## Task Summary

- **Total Tasks**: 24
- **Setup Tasks**: 2
- **Foundational Tasks**: 5
- **User Story Tasks**: 15 (across 3 P1 stories)
- **Polish Tasks**: 2
- **Parallelizable Tasks**: 8
- **Estimated Time**: 10-13 hours

---

## Implementation Strategy

### MVP Scope (User Story 1 Only)
**Goal**: Single launch creation across parallel workers  
**Deliverable**: 5 workers create exactly 1 launch, all report to it  
**Validation**: Run parallel tests, verify 1 launch in ReportPortal

### Incremental Delivery
1. **Phase 3**: User Story 1 (P1) - Single Launch Creation → MVP Ready
2. **Phase 4**: User Story 2 (P1) - Coordinated Finish → Production Ready  
3. **Phase 5**: User Story 3 (P1) - Zero Config → User Ready
4. **Phase 6**: Polish → Release Ready

### Parallel Execution Opportunities
- Tasks marked [P] can run in parallel (different files, no dependencies)
- Within each user story: Tests → Models → Services → Endpoints (sequential)
- Across user stories: US1, US2, US3 can be developed in parallel after Foundational phase

---

## Phase 1: Setup & Cleanup

**Goal**: Remove obsolete file lock code, prepare codebase for UUID approach

- [X] T001 Delete LaunchCoordinator.swift (file lock logic obsolete) in Sources/Entities/LaunchCoordinator.swift
- [X] T002 Delete LaunchIdLock.swift (POSIX flock wrapper obsolete) in Sources/Entities/LaunchIdLock.swift

**Completion Criteria**:
- ✅ LaunchCoordinator.swift removed from project
- ✅ LaunchIdLock.swift removed from project
- ✅ Project compiles without these files (may have compile errors in RPListener - will fix in Phase 2)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Goal**: Core UUID infrastructure that all user stories depend on

- [X] T003 Add UUID generation logic to LaunchManager in Sources/Entities/LaunchManager.swift
  - Implement `getOrGenerateLaunchUUID() async -> String`
  - Read `RP_LAUNCH_UUID` from ProcessInfo.processInfo.environment
  - If not set: Generate `{launchName}_{timestamp}_{PGID}`
  - Return UUID for coordination

- [X] T004 [P] Add optional uuid parameter to StartLaunchV2EndPoint in Sources/EndPoints/StartLaunchV2EndPoint.swift
  - Add `uuid: String?` property
  - Update body encoding: Include uuid only if non-nil
  - Keep existing fields (name, mode, startTime)

- [ ] T005 Update ReportingService.startLaunch to accept custom UUID in Sources/ReportingService.swift
  - Add `uuid: String?` parameter to startLaunch method
  - Pass uuid to StartLaunchV2EndPoint
  - Return launch ID from response

- [ ] T006 Implement 409 Conflict handling in ReportingService.startLaunch in Sources/ReportingService.swift
  - Catch HTTPError where statusCode == 409
  - Extract launch ID from error response or use uuid
  - Log as INFO: "Launch already created by another worker"
  - Return launch ID, do not throw error

- [ ] T007 Implement tolerant finish logic in ReportingService.finishLaunch in Sources/ReportingService.swift
  - Catch HTTPError where statusCode == 404 || statusCode == 409
  - Log as INFO: "Launch already finished by another worker"
  - Return success (do not throw error)
  - Other errors still propagate

**Completion Criteria**:
- ✅ LaunchManager can generate UUID (env var or auto-generate)
- ✅ StartLaunchV2EndPoint includes optional uuid field
- ✅ ReportingService handles 409 Conflict gracefully (not as error)
- ✅ ReportingService handles 404/409 on finish gracefully (not as error)
- ✅ All logging uses INFO level for expected coordination outcomes

---

## Phase 3: User Story 1 - Single Launch Creation (P1)

**User Story**: As a test developer, when I run parallel tests from Xcode with 5 iOS simulators, I want all test workers to coordinate and report to a single Launch in ReportPortal, so that I see one unified test report instead of 5 separate reports.

**Goal**: Exactly 1 launch created regardless of worker count

### Implementation Tasks

- [ ] T008 [US1] Update RPListener.testBundleWillStart for UUID coordination in Sources/RPListener.swift
  - Call `await launchManager.getOrGenerateLaunchUUID()` to get shared UUID
  - Pass UUID to `reportingService.startLaunch(uuid: uuid, ...)`
  - Handle 409 response (expected, not error)
  - Store launch ID from response

- [ ] T009 [US1] Remove file lock coordination references from RPListener in Sources/RPListener.swift
  - Remove any LaunchCoordinator usage (file deleted in T001)
  - Remove any LaunchIdLock usage (file deleted in T002)
  - Simplify to pure UUID-based flow

### Testing Tasks

- [ ] T010 [P] [US1] Create LaunchManagerTests for UUID generation in ExampleUnitTests/LaunchManagerTests.swift
  - Test environment variable reading (RP_LAUNCH_UUID)
  - Test auto-generation format: `{name}_{timestamp}_{PGID}`
  - Test PGID-based uniqueness
  - Test timestamp-based uniqueness

- [ ] T011 [P] [US1] Create CoordinationTests for 409 handling in ExampleUnitTests/CoordinationTests.swift
  - Mock 409 response from ReportPortal API
  - Verify no exception thrown
  - Verify launch ID extracted correctly
  - Verify INFO-level logging (not ERROR)

### Integration Test

- [ ] T012 [US1] Run parallel test with 5 simulators, verify exactly 1 launch created
  - Execute: `xcodebuild test -scheme agent-swift-XCTest -parallel-testing-enabled YES -maximum-parallel-testing-workers 5`
  - Verify in ReportPortal: Exactly 1 launch exists
  - Verify: All 5 workers reported test results to that launch
  - Verify logs: No errors, only INFO messages for 409 conflicts

**Independent Test Criteria**:
- ✅ Run parallel tests with 2+ workers
- ✅ Verify only 1 Launch appears in ReportPortal
- ✅ Verify all test results included in single launch
- ✅ Logs show INFO messages for coordination (not errors)

---

## Phase 4: User Story 2 - Coordinated Launch Finish (P1)

**User Story**: As a test developer, when parallel tests complete at different times, I want the Launch to finish only after ALL workers have completed their tests, so that no test results are lost due to premature Launch closure.

**Goal**: All workers call finish, first succeeds, others get 404 (acceptable)

### Implementation Tasks

- [ ] T013 [US2] Update RPListener.testBundleDidFinish for tolerant finish in Sources/RPListener.swift
  - Get aggregated status from LaunchManager
  - All workers call `reportingService.finishLaunch(launchID, status)`
  - Handle 404/409 responses (expected, not error)
  - Log as INFO: "Launch finished" or "Already finished by another worker"

- [ ] T014 [US2] Update LaunchManager to calculate aggregated status in Sources/Entities/LaunchManager.swift
  - Track bundle statuses as they update
  - Implement status hierarchy: FAILED > STOPPED > PASSED
  - Return worst status across all bundles
  - All workers use same hierarchy before calling finish

### Testing Tasks

- [ ] T015 [P] [US2] Add tests for 404 finish handling in ExampleUnitTests/CoordinationTests.swift
  - Mock 404 response on finish call
  - Verify no exception thrown
  - Verify treated as success
  - Verify INFO-level logging

- [ ] T016 [P] [US2] Add tests for aggregated status calculation in ExampleUnitTests/LaunchManagerTests.swift
  - Test status hierarchy: FAILED > STOPPED > PASSED
  - Test multiple bundles with different statuses
  - Verify correct aggregated result

### Integration Test

- [ ] T017 [US2] Run parallel test with uneven distribution, verify finish timing
  - Worker 1: Assign 5 quick tests
  - Worker 2: Assign 50 slow tests
  - Verify: Worker 1 finishes first, gets 200 OK
  - Verify: Worker 2 finishes later, gets 404 Not Found
  - Verify: Launch status reflects aggregated result (FAILED if any failed)
  - Verify: All test results present (zero data loss)

**Independent Test Criteria**:
- ✅ Run parallel tests with uneven test distribution
- ✅ Verify launch remains open until last worker finishes
- ✅ Verify all test results recorded successfully
- ✅ Verify launch status reflects aggregated results (FAILED if any worker failed)

---

## Phase 5: User Story 3 - Zero-Configuration Xcode Integration (P1)

**User Story**: As a test developer, when I press "Run" in Xcode to execute parallel tests, I want the coordination to work automatically without requiring me to run scripts or pre-create launches, so that I can use parallel testing with minimal setup.

**Goal**: Auto-generate UUID when environment variable not set, works out-of-box

### Implementation Tasks

- [ ] T018 [US3] Verify auto-generation works without RP_LAUNCH_UUID in Sources/Entities/LaunchManager.swift
  - Ensure getOrGenerateLaunchUUID generates UUID if env var not set
  - Format: `{launchName}_{timestamp}_{PGID}`
  - All workers in same process group generate identical UUID (PGID shared)

- [ ] T019 [US3] Add logging for UUID source (env var vs auto-generated) in Sources/Entities/LaunchManager.swift
  - Log INFO: "Using UUID from RP_LAUNCH_UUID: {uuid}" if env var set
  - Log INFO: "Auto-generated UUID: {uuid}" if not set
  - Helps debugging coordination issues

### Documentation Tasks

- [ ] T020 [P] [US3] Update README with zero-config usage in README.md
  - Document: "Just enable parallel testing in Xcode, coordination works automatically"
  - Explain: Auto-generated UUID uses PGID (all workers in same xcodebuild session)
  - Note: Optional `RP_LAUNCH_UUID` for advanced use cases (CI/CD, real devices)

- [ ] T021 [P] [US3] Update xcode-pre-action-setup.md for optional setup in docs/xcode-pre-action-setup.md
  - Clarify: Pre-action is OPTIONAL (for advanced users)
  - Benefits of manual UUID: Explicit control, CI/CD integration, real devices
  - Zero config works for 90% of simulator use cases

### Integration Test

- [ ] T022 [US3] Run parallel tests WITHOUT setting RP_LAUNCH_UUID, verify coordination
  - Do NOT set environment variable
  - Run: `xcodebuild test -scheme agent-swift-XCTest -parallel-testing-enabled YES`
  - Verify: Coordination still works (auto-generated UUID)
  - Verify: Exactly 1 launch created
  - Verify logs: "Auto-generated UUID: ..." message appears

**Independent Test Criteria**:
- ✅ Run parallel tests directly from Xcode without any pre-configuration
- ✅ Verify single launch created automatically
- ✅ Verify coordination adapts to dynamic worker count
- ✅ Verify multiple test runs create separate launches (unique UUIDs)

---

## Phase 6: Polish & Cross-Cutting Concerns

**Goal**: Production readiness, documentation, migration guide

- [ ] T023 [P] Create migration guide from file lock approach in docs/migration-from-filelock.md
  - Document removed classes: LaunchCoordinator, LaunchIdLock
  - Explain new UUID-based flow
  - Migration steps: Update to new version, remove any file lock workarounds
  - Benefits: Works on real devices, simpler architecture, zero overhead

- [ ] T024 [P] Update CHANGELOG with breaking changes in CHANGELOG.md
  - Version bump: 3.x.x → 4.0.0 (MAJOR - file lock removal is breaking)
  - Breaking: LaunchCoordinator and LaunchIdLock removed
  - New: UUID-based coordination via RP_LAUNCH_UUID or auto-generation
  - New: Real device parallel testing support
  - Improved: Tolerant 409/404 handling (no more coordination errors)

**Completion Criteria**:
- ✅ Migration guide complete and clear
- ✅ CHANGELOG documents breaking changes
- ✅ All documentation references updated
- ✅ Version bumped to 4.0.0

---

## Dependencies & Execution Order

### Critical Path
```
Phase 1 (Setup) → Phase 2 (Foundational) → Phase 3 (US1) → Phase 4 (US2) → Phase 5 (US3) → Phase 6 (Polish)
```

### Story Dependencies
- **US1 (Single Launch Creation)**: No dependencies (can start after Foundational)
- **US2 (Coordinated Finish)**: Depends on US1 (needs launch creation working)
- **US3 (Zero Config)**: Depends on US1 (needs UUID generation working)

### Parallel Opportunities

**Within Foundational Phase**:
- T004 (StartLaunchV2EndPoint) can run parallel with T003 (LaunchManager)
- T005-T007 (ReportingService) must be sequential

**Within User Story Phases**:
- Tests (T010, T011, T015, T016) can run in parallel (different files)
- Documentation (T020, T021, T023, T024) can run in parallel

**Across User Stories** (after Foundational complete):
- US1, US2, US3 can be developed in parallel by different developers
- Each story is independently testable
- Integration tests should run sequentially (share test infrastructure)

---

## Validation Checklist

### Success Criteria (from spec.md)

**User Story 1 - Single Launch Creation**:
- [ ] SC-001: 5 parallel workers create exactly 1 launch (not 5)
- [ ] SC-002: All test results appear in single launch (zero data loss)
- [ ] SC-008: 100% of parallel test runs result in single unified launch

**User Story 2 - Coordinated Finish**:
- [ ] SC-003: Launch finishes only after last worker completes
- [ ] SC-004: Launch status reflects aggregated results (FAILED if any failed)
- [ ] SC-009: Zero test results lost due to premature closure

**User Story 3 - Zero Config**:
- [ ] SC-006: Parallel tests run from Xcode without pre-execution steps
- [ ] SC-007: Handles 1-20 workers without configuration changes

**Performance**:
- [ ] SC-005: Coordination completes within 10 seconds
- [ ] SC-010: Coordination overhead < 5 seconds vs sequential

**Platform Support**:
- [ ] SC-011: Sequential mode works on simulators and real devices
- [ ] SC-012: Sequential mode on real devices produces 1 launch
- [ ] SC-013: Sequential mode has zero coordination overhead

---

## Notes

### Removed from Scope (UUID-Only Approach)
- ❌ File-based coordination (LaunchCoordinator, LaunchIdLock)
- ❌ POSIX flock usage
- ❌ Sync file creation/polling
- ❌ Primary/secondary worker detection
- ❌ "Last worker" finish detection (all workers call finish)

### Key Simplifications
- **~300 lines removed**: LaunchCoordinator + LaunchIdLock + polling logic
- **Cross-platform**: Works on simulators AND real devices (vs simulator-only)
- **Zero overhead**: No file I/O, no polling, no locks
- **Simpler error handling**: 409/404 treated as success, not errors

### Testing Philosophy
- **Unit tests**: UUID generation, 409/404 handling
- **Integration tests**: Real parallel execution with 5 workers
- **No mocking ReportPortal**: Use real API for integration tests (or test instance)
- **Validate independently**: Each user story testable without others

---

**Generated**: 2025-01-31  
**Next Step**: Execute Phase 1 (T001-T002) to remove obsolete code  
**Estimated Completion**: 10-13 hours total
