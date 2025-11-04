# Implementation Tasks: Hybrid Launch Coordination

**Feature**: 002-parallel-launch-coordination  
**Branch**: `002-parallel-launch-coordination`  
**Date**: 2025-11-04  
**Approach**: Hybrid coordination - UUID for launches + file-based for suites/finish

---

## Task Summary

- **Total Tasks**: 35
- **Setup Tasks**: 2 (cleanup old files)
- **Launch Coordination Tasks**: 7 (UUID-based, already implemented)
- **Suite Coordination Tasks**: 8 (file-based, NEW)
- **Finish Coordination Tasks**: 6 (file-based, NEW)
- **Integration Tasks**: 8 (wire everything together)
- **Testing Tasks**: 4 (validation)
- **Parallelizable Tasks**: 12
- **Estimated Time**: 18-22 hours

---

## Implementation Strategy

### Hybrid Coordination Approach
**Launch Level**: UUID-based (cross-platform, low overhead)  
**Suite Level**: File-based (scalable to 100+ suites)  
**Finish Level**: File-based (single API call, correct status)

### MVP Scope
**Goal**: Complete hybrid coordination for simulators  
**Deliverable**: 5 workers create exactly 1 launch + 1 suite per test class + single finish call  
**Validation**: Run parallel tests, verify clean hierarchy in ReportPortal

### Incremental Delivery
1. **Phase 1-2**: Launch coordination (UUID-based) → ✅ DONE
2. **Phase 3**: Suite coordination (file-based) → NEW
3. **Phase 4**: Finish coordination (file-based) → NEW  
4. **Phase 5**: Integration & testing → NEW
5. **Phase 6**: Polish & documentation → NEW

### Parallel Execution Opportunities
- Tasks marked [P] can run in parallel (different files, no dependencies)
- Suite coordination and finish coordination can be developed in parallel
- Tests can be written in parallel with implementation

---

## Phase 1: Setup & Cleanup ✅ COMPLETED

**Goal**: Remove obsolete file lock code, prepare codebase for hybrid approach

- [X] T001 Delete LaunchCoordinator.swift (file lock logic obsolete) in Sources/Entities/LaunchCoordinator.swift
- [X] T002 Delete LaunchIdLock.swift (POSIX flock wrapper obsolete) in Sources/Entities/LaunchIdLock.swift

**Completion Criteria**:
- ✅ LaunchCoordinator.swift removed from project
- ✅ LaunchIdLock.swift removed from project
- ✅ Project compiles without these files

---

## Phase 2: Launch Coordination (UUID-based) ✅ COMPLETED

**Goal**: Core UUID infrastructure for launch-level coordination

- [X] T003 Add UUID generation logic to LaunchManager in Sources/Entities/LaunchManager.swift
- [X] T004 [P] Add optional uuid parameter to StartLaunchV2EndPoint in Sources/EndPoints/StartLaunchV2EndPoint.swift
- [X] T005 Update ReportingService.startLaunch to accept custom UUID in Sources/ReportingService.swift
- [X] T006 Implement 409 Conflict handling in ReportingService.startLaunch in Sources/ReportingService.swift
- [X] T007 Update RPListener.testBundleWillStart for UUID coordination in Sources/RPListener.swift
- [X] T008 [P] Create LaunchManagerTests for UUID generation in ExampleUnitTests/LaunchManagerTests.swift
- [X] T009 [P] Create CoordinationTests for 409 handling in ExampleUnitTests/CoordinationTests.swift

**Completion Criteria**:
- ✅ LaunchManager can generate UUID (env var or auto-generate)
- ✅ StartLaunchV2EndPoint includes optional uuid field
- ✅ ReportingService handles 409 Conflict gracefully
- ✅ All workers create single launch successfully

---

## Phase 3: Suite Coordination (File-based) 🆕 NEW

**Goal**: Prevent duplicate suites in ReportPortal hierarchy
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
