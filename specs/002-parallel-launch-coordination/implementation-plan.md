# Implementation Plan: UUID-Based Coordination

## Strategy Overview

**Primary Approach**: UUID-based coordination with tolerant finish handling
**Fallback**: File-based coordination for simulators (existing logic)
**Benefit**: Works cross-platform (simulators + real devices), zero coordination overhead

---

## Implementation Phases

### Phase 1: Core UUID Support (P0 - Critical)

**Goal**: Enable UUID-based launch creation and tolerant finish handling

#### Task 1.1: Update LaunchManager for UUID Support
**File**: `Sources/Entities/LaunchManager.swift`

**Changes**:
```swift
// Add UUID generation
func generateLaunchUUID(launchName: String, sessionID: String) -> String {
    "\(launchName)_\(Date().timeIntervalSince1970)_\(sessionID)"
}

// Check for RP_LAUNCH_UUID environment variable
func getOrGenerateLaunchUUID() -> String? {
    if let envUUID = ProcessInfo.processInfo.environment["RP_LAUNCH_UUID"] {
        return envUUID
    }
    // Generate if in parallel mode
    return generateLaunchUUID(...)
}
```

**Acceptance**: 
- ✅ LaunchManager can read `RP_LAUNCH_UUID` from environment
- ✅ LaunchManager can generate UUID if not provided
- ✅ UUID format is human-readable and unique per test run

---

#### Task 1.2: Update ReportingService for Custom UUID
**File**: `Sources/ReportingService.swift`

**Changes**:
```swift
// Update startLaunch to accept custom UUID
func startLaunch(uuid: String?, name: String, ...) async throws -> String {
    let endpoint = StartLaunchV2EndPoint(
        uuid: uuid,  // NEW: optional UUID parameter
        name: name,
        ...
    )
    
    do {
        let response = try await httpClient.post(endpoint)
        return response.id
    } catch let error as HTTPError where error.statusCode == 409 {
        // Launch already exists - extract ID from error or use UUID
        logger.info("Launch already created by another worker (409 Conflict)")
        return uuid ?? error.extractLaunchID()
    }
}
```

**Acceptance**:
- ✅ startLaunch accepts optional `uuid` parameter
- ✅ 409 Conflict handled gracefully (not thrown as error)
- ✅ Launch ID extracted from success response or 409 error
- ✅ Logs informational message on 409 (not error)

---

#### Task 1.3: Implement Tolerant Finish Logic
**File**: `Sources/ReportingService.swift`

**Changes**:
```swift
func finishLaunch(launchId: String, status: TestStatus) async throws {
    let endpoint = FinishLaunchV2EndPoint(...)
    
    do {
        try await httpClient.put(endpoint)
        logger.info("Successfully finished launch", launchID: launchId)
    } catch let error as HTTPError where error.statusCode == 404 || error.statusCode == 409 {
        // Launch already finished by another worker - this is OK
        logger.info("Launch already finished by another worker", 
                   statusCode: error.statusCode,
                   launchID: launchId)
        return  // Treat as success
    }
    // Other errors still throw
}
```

**Acceptance**:
- ✅ finishLaunch treats 404/409 as success (no throw)
- ✅ Logs informational message (not error) on 404/409
- ✅ Other HTTP errors still propagate
- ✅ Multiple workers can call finish safely

---

#### Task 1.4: Update StartLaunchV2EndPoint
**File**: `Sources/EndPoints/StartLaunchV2EndPoint.swift`

**Changes**:
```swift
struct StartLaunchV2EndPoint: EndPoint {
    let uuid: String?  // NEW: optional custom UUID
    let name: String
    let mode: String
    let startTime: Date
    
    var body: [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "mode": mode,
            "startTime": startTime.timeIntervalSince1970 * 1000
        ]
        
        if let uuid = uuid {
            dict["uuid"] = uuid  // Include if provided
        }
        
        return dict
    }
}
```

**Acceptance**:
- ✅ EndPoint includes optional `uuid` field
- ✅ UUID only included in request body if provided
- ✅ Request format matches ReportPortal API expectations

---

### Phase 2: Integration with RPListener (P0 - Critical)

#### Task 2.1: Update RPListener for UUID Coordination
**File**: `Sources/RPListener.swift`

**Changes**:
```swift
func testBundleWillStart(_ testBundle: Bundle) {
    Task {
        // Check for UUID-based coordination
        let launchUUID = await launchManager.getOrGenerateLaunchUUID()
        
        // Start launch with custom UUID
        let launchID = try await reportingService.startLaunch(
            uuid: launchUUID,
            name: launchName,
            ...
        )
        
        await launchManager.setLaunchID(launchID)
    }
}

func testBundleDidFinish(_ testBundle: Bundle) {
    Task {
        let aggregatedStatus = await launchManager.getAggregatedStatus()
        let launchID = await launchManager.getLaunchID()
        
        // All workers call finish (tolerant handling inside)
        try await reportingService.finishLaunch(
            launchId: launchID,
            status: aggregatedStatus
        )
    }
}
```

**Acceptance**:
- ✅ RPListener uses UUID coordination in parallel mode
- ✅ All workers attempt to create launch (409 handled gracefully)
- ✅ All workers call finish (404/409 handled gracefully)
- ✅ No "last worker" detection needed (tolerant finish handles it)

---

### Phase 3: Documentation & Examples (P1 - High)

#### Task 3.1: Xcode Pre-Action Script Template
**File**: `docs/xcode-pre-action-script.md`

**Content**:
```markdown
# Xcode Pre-Action Script for UUID Coordination

## Setup Instructions

1. Open your Xcode project
2. Select your test scheme → Edit Scheme
3. Go to Test → Pre-Actions → + → New Run Script Action
4. Add this script:

```bash
#!/bin/bash
# Generate unique launch UUID for parallel test coordination
export RP_LAUNCH_UUID="MyAppTests_$(date +%Y%m%d_%H%M%S)_$(ps -o pgid= -p $$)"
echo "Generated Launch UUID: $RP_LAUNCH_UUID"
```

5. Set "Provide build settings from" to your test target
6. Run tests - all workers will coordinate using the same UUID

## For Real Devices

Same script works for real devices! The UUID is inherited by all device workers.

## For CI/CD

Set `RP_LAUNCH_UUID` in your CI script before running tests:

```bash
export RP_LAUNCH_UUID="CI_MyAppTests_${BUILD_NUMBER}_$(date +%s)"
xcodebuild test -scheme MyApp -parallel-testing-enabled YES
```
```

**Acceptance**:
- ✅ Clear setup instructions for Xcode
- ✅ CI/CD examples provided
- ✅ Works for simulators and real devices

---

#### Task 3.2: Update README with UUID Coordination
**File**: `README.md`

**Add section**:
```markdown
## Parallel Testing Coordination

### Automatic (Zero Configuration)

For **simulators**: Just enable parallel testing in Xcode. The agent automatically coordinates using file-based locking.

### With UUID Pre-Creation (Recommended)

For **better performance** and **real device support**, pre-create a shared launch UUID:

**Xcode Setup** (Edit Scheme → Test → Pre-Actions):
```bash
export RP_LAUNCH_UUID="MyTests_$(date +%Y%m%d_%H%M%S)_$(ps -o pgid= -p $$)"
```

**Benefits**:
- ✅ Works on real devices (not just simulators)
- ✅ Zero coordination overhead (no file locks)
- ✅ Faster test startup (no polling/waiting)
- ✅ Same approach for CI/CD

**How It Works**:
1. All test workers read same `RP_LAUNCH_UUID` from environment
2. All workers try to create launch with same UUID
3. First worker succeeds, others get "already exists" (safe)
4. All workers report to same launch
5. All workers call finish (first succeeds, others get "already finished")
```

**Acceptance**:
- ✅ README documents both automatic and UUID approaches
- ✅ Benefits clearly explained
- ✅ Setup instructions for Xcode and CI/CD

---

### Phase 4: Testing & Validation (P1 - High)

#### Task 4.1: Add Unit Tests for UUID Logic
**File**: `ExampleUnitTests/LaunchCoordinationTests.swift`

**Test cases**:
```swift
func testUUIDGenerationFormat() {
    // Verify UUID format is correct
}

func testEnvironmentVariableReading() {
    // Verify RP_LAUNCH_UUID is read correctly
}

func test409ConflictHandling() {
    // Mock 409 response, verify graceful handling
}

func test404FinishHandling() {
    // Mock 404 response on finish, verify no error thrown
}

func testMultipleFinishCalls() {
    // Verify multiple finish calls don't cause errors
}
```

**Acceptance**:
- ✅ All UUID logic covered by unit tests
- ✅ Error handling scenarios tested
- ✅ Tests pass in isolation

---

#### Task 4.2: Integration Test with Real Parallel Workers
**File**: `test_parallel_uuid.sh`

**Test script**:
```bash
#!/bin/bash
# Test UUID coordination with real parallel workers

# Set shared UUID
export RP_LAUNCH_UUID="IntegrationTest_$(date +%s)"

# Run parallel tests
xcodebuild test \
  -scheme agent-swift-XCTest \
  -parallel-testing-enabled YES \
  -maximum-parallel-testing-workers 5

# Verify: Only 1 launch created in ReportPortal
# Verify: All test results in that launch
# Verify: No errors about 409 or 404 (info logs only)
```

**Acceptance**:
- ✅ Script runs parallel tests with UUID coordination
- ✅ Exactly 1 launch created in ReportPortal
- ✅ All test results appear in single launch
- ✅ Logs show informational messages (not errors) for 409/404

---

## Success Criteria

**Must Have** (Phase 1-2):
- ✅ UUID-based coordination implemented and working
- ✅ Tolerant finish handling (404/409 treated as success)
- ✅ Works with environment variable `RP_LAUNCH_UUID`
- ✅ Falls back to file lock if no UUID provided (simulators)
- ✅ All workers can create/finish launch safely

**Should Have** (Phase 3):
- ✅ Documentation for Xcode pre-action setup
- ✅ CI/CD examples
- ✅ README updated with UUID approach

**Nice to Have** (Phase 4):
- ✅ Comprehensive unit tests
- ✅ Integration test script
- ✅ Performance comparison (UUID vs file lock)

---

## Rollback Plan

If UUID approach doesn't work:
1. Keep UUID support code (it's additive, not breaking)
2. Continue using file lock fallback (already working for simulators)
3. Document limitations for real devices (as originally planned)
4. No breaking changes needed - UUID is optional enhancement

---

## Timeline Estimate

- **Phase 1**: 4-6 hours (core implementation)
- **Phase 2**: 2-3 hours (integration)
- **Phase 3**: 2-3 hours (documentation)
- **Phase 4**: 3-4 hours (testing)

**Total**: 11-16 hours for complete implementation and validation
