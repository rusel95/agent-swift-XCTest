//
//  Listener.swift
//  com.oxagile.automation.RPAgentSwiftXCTest
//
//  Created by Windmill Smart Solutions on 5/12/17.
//  Copyright © 2017 Oxagile. All rights reserved.
//

import Foundation
import XCTest

/// Thread-safe storage for root suite ID across parallel test bundles
/// Uses efficient polling with short delays for waiting
private actor RootSuiteIDManager {
    private var rootSuiteID: String?

    func setRootSuiteID(_ id: String) {
        rootSuiteID = id
    }

    func getRootSuiteID() -> String? {
        return rootSuiteID
    }

    /// Wait for root suite ID to become available (efficient polling with short delays)
    /// - Parameter timeout: Maximum wait time in seconds
    /// - Returns: Root suite ID when available
    /// - Throws: RootSuiteIDError.timeout if ID not set within timeout
    func waitForRootSuiteID(timeout: TimeInterval = 10) async throws -> String {
        // Check if already available
        if let id = rootSuiteID {
            Logger.shared.info("✅ Root suite ID already available")
            return id
        }

        // Wait for it using efficient polling (20ms intervals)
        Logger.shared.info("⏳ Waiting for root suite ID...")

        let startTime = Date()
        let maxAttempts = Int(timeout / 0.02) // 20ms per attempt

        for attempt in 0..<maxAttempts {
            if let id = rootSuiteID {
                let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
                Logger.shared.info("✅ Root suite ID found after \(elapsedMs)ms (\(attempt) polls)")
                return id
            }

            try await Task.sleep(nanoseconds: 20_000_000) // 20ms

            // Check for task cancellation
            try Task.checkCancellation()
        }

        throw RootSuiteIDError.timeout(seconds: timeout)
    }

    func reset() {
        rootSuiteID = nil
    }

    enum RootSuiteIDError: LocalizedError {
        case timeout(seconds: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .timeout(let seconds):
                return "Root suite ID not set after \(seconds) seconds timeout"
            }
        }
    }
}

open class RPListener: NSObject, XCTestObservation {

    private var reportingService: ReportingService?

    // Shared actors for parallel execution
    private let launchManager = LaunchManager.shared
    private let operationTracker = OperationTracker.shared
    private let rootSuiteIDManager = RootSuiteIDManager()
    
    // Suite coordination for file-based deduplication (simulators only)
    private var suiteCoordinator: SuiteCoordinator?
    
    // Suite counter coordination for cross-worker suite tracking (simulators only)
    private var suiteCounterCoordinator: SuiteCounterCoordinator?
    
    // Worker and finish coordination for parallel execution (simulators only)
    private var workerTracker: WorkerTracker?
    private var finishCoordinator: FinishCoordinator?
    private var workerID: String?  // Current worker identifier (PID or PGID)

    /// Enhanced launch name (used for coordination file cleanup)
    private var enhancedLaunchName: String?
    
    public override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }
    
    private func readConfiguration(from testBundle: Bundle) -> AgentConfiguration {
        guard
            let bundlePath = testBundle.path(forResource: "Info", ofType: "plist"),
            let bundleProperties = NSDictionary(contentsOfFile: bundlePath) as? [String: Any],
            let portalPath = bundleProperties["ReportPortalURL"] as? String,
            let portalURL = URL(string: portalPath),
            let projectName = bundleProperties["ReportPortalProjectName"] as? String,
            let token = bundleProperties["ReportPortalToken"] as? String,
            let shouldFinishLaunch = bundleProperties["IsFinalTestBundle"] as? Bool,
            let launchName = bundleProperties["ReportPortalLaunchName"] as? String else
        {
            fatalError("Configure properties for report portal in the Info.plist")
        }
        
        let shouldReport: Bool
        if let pushTestDataString = bundleProperties["PushTestDataToReportPortal"] as? String {
            let normalized = pushTestDataString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            shouldReport = ["true", "yes", "1"].contains(normalized)
        } else if let pushTestDataBool = bundleProperties["PushTestDataToReportPortal"] as? Bool {
            shouldReport = pushTestDataBool
        } else {
            fatalError("PushTestDataToReportPortal must be either a string or a boolean in the Info.plist")
        }
        
        var tags: [String] = []
        if let tagString = bundleProperties["ReportPortalTags"] as? String {
            tags = tagString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        var launchMode: LaunchMode = .default
        if let isDebug = bundleProperties["IsDebugLaunchMode"] as? Bool, isDebug == true {
            launchMode = .debug
        }
        
        var testNameRules: NameRules = []
        if let rules = bundleProperties["TestNameRules"] as? [String: Bool] {
            if rules["StripTestPrefix"] == true {
                testNameRules.update(with: .stripTestPrefix)
            }
            if rules["WhiteSpaceOnUnderscore"] == true {
                testNameRules.update(with: .whiteSpaceOnUnderscore)
            }
            if rules["WhiteSpaceOnCamelCase"] == true {
                testNameRules.update(with: .whiteSpaceOnCamelCase)
            }
        }
        
        return AgentConfiguration(
            reportPortalURL: portalURL,
            projectName: projectName,
            launchName: launchName,
            shouldSendReport: shouldReport,
            portalToken: token,
            tags: tags,
            shouldFinishLaunch: shouldFinishLaunch,
            launchMode: launchMode,
            testNameRules: testNameRules
        )
    }
    
    public func testBundleWillStart(_ testBundle: Bundle) {
        let configuration = readConfiguration(from: testBundle)

        guard configuration.shouldSendReport else {
            print("Set 'YES' for 'PushTestDataToReportPortal' property in Info.plist if you want to put data to report portal")
            return
        }
        
        // Create service for v4.0.0 async/await parallel execution
        let reportingService = ReportingService(configuration: configuration)
        self.reportingService = reportingService
        
        // Initialize suite coordinator for file-based deduplication (simulators only)
        self.suiteCoordinator = SuiteCoordinator()
        
        // Initialize suite counter coordinator for cross-worker suite tracking (simulators only)
        self.suiteCounterCoordinator = SuiteCounterCoordinator()
        
        // Initialize finish coordination actors (simulators only)
        self.workerTracker = WorkerTracker()
        self.finishCoordinator = FinishCoordinator()
        
        // Generate worker ID from process identifiers
        let pid = getpid()
        let pgid = getpgid(pid)
        self.workerID = "\(pid)_\(pgid)"

        print("🟢 [SYNC] [BUNDLE] Started (Worker: \(self.workerID!))")
        Task {
            await SyncLogger.shared.logBundle("Started - Worker: \(self.workerID!)")
        }

        // Increment bundle count and create launch if needed
        // For Unit test support: Use semaphore to ensure launch is created BEFORE tests start
        // This prevents race conditions with fast-running unit tests (1-10ms execution time)
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached(priority: .high) {
            defer { semaphore.signal() }
            
            // Validate configuration before launch creation
            await self.launchManager.validateConfiguration()

            await self.launchManager.incrementBundleCount()

            do {
                // Collect metadata attributes
                let attributes: [[String: String]]
                if let bundle = testBundle as Bundle? {
                    attributes = MetadataCollector.collectAllAttributes(from: bundle, tags: configuration.tags)
                } else {
                    attributes = MetadataCollector.collectDeviceAttributes()
                }

                // Get test plan name for launch name enhancement
                let testPlanName = MetadataCollector.getTestPlanName()
                let enhancedLaunchName = self.buildEnhancedLaunchName(
                    baseLaunchName: configuration.launchName,
                    testPlanName: testPlanName
                )

                // Store for cleanup later
                self.enhancedLaunchName = enhancedLaunchName

                // UUID-based coordination with file-based fallback
                let launchUUID = await self.launchManager.getOrCreateLaunchUUID()
                // LAUNCH COORDINATION
                await SyncLogger.shared.logLaunch("Creating/joining with UUID: \(launchUUID)")
                print("🚀 [SYNC] [LAUNCH] Creating/joining with UUID: \(launchUUID)")
                let launchID = try await reportingService.startLaunchV2(
                    name: enhancedLaunchName,
                    uuid: launchUUID,
                    tags: configuration.tags,
                    attributes: attributes
                )
                await self.launchManager.setLaunchID(launchID)
                await SyncLogger.shared.logLaunch("Launch created - ID: \(launchID)")
                print("✅ [SYNC] [LAUNCH] Ready - ID: \(launchID)")
                
                // WORKER REGISTRATION
                if let tracker = self.workerTracker, let workerID = self.workerID {
                    do {
                        try await tracker.registerWorker(uuid: launchUUID, workerID: workerID)
                        await SyncLogger.shared.logWorker("Registered: \(workerID) for UUID: \(launchUUID)")
                        print("👷 [SYNC] [WORKER] Registered: \(workerID)")
                    } catch {
                        await SyncLogger.shared.logWorker("Registration failed: \(error.localizedDescription)")
                        print("❌ [SYNC] [WORKER] Registration failed: \(error.localizedDescription)")
                    }
                }
            } catch {
                await SyncLogger.shared.logLaunch("Creation failed: \(error.localizedDescription)")
                print("❌ [SYNC] [LAUNCH] Creation failed: \(error.localizedDescription)")
            }
        }

        // Wait for launch creation to complete (max 10 seconds)
        // This ensures launch exists before any suites/tests start
        let waitResult = semaphore.wait(timeout: .now() + 10)
        if waitResult == .timedOut {
            Logger.shared.warning("Launch creation timed out after 10 seconds. Tests will continue but may not be tracked.")
        }
    }
    
    /// Wait for launch ID to become available (Swift async/await approach)
    /// This properly awaits the launch creation task instead of polling
    /// - Returns: Launch ID if available
    /// - Throws: Error if launch creation fails or times out
    private func waitForLaunchID() async throws -> String {
        do {
            // Use LaunchManager's proper async waiting (30 second timeout)
            return try await launchManager.waitForLaunchID(timeout: 30)
        } catch let error as LaunchManagerError {
            // Convert LaunchManager errors to detailed logging
            switch error {
            case .timeout(let seconds):
                Logger.shared.error("""
                    Launch ID timeout after \(seconds) seconds.
                    Possible causes:
                    - Launch creation failed (check logs for startLaunch errors)
                    - ReportPortal API is unreachable or slow
                    - Network connectivity issues
                    Tests may fail to report to ReportPortal.
                    """)
            case .launchNotStarted:
                Logger.shared.error("Launch creation has not been initiated. This is a programming error.")
            case .taskCancelled:
                Logger.shared.error("Launch creation task was cancelled unexpectedly.")
            }
            throw error
        }
    }
    
    private func buildEnhancedLaunchName(baseLaunchName: String, testPlanName: String?) -> String {
        if let testPlan = testPlanName, !testPlan.isEmpty {
            let sanitizedTestPlan = testPlan.replacingOccurrences(of: " ", with: "_")
            return "\(baseLaunchName): \(sanitizedTestPlan)"
        }
        return baseLaunchName
    }
    
    public func testSuiteWillStart(_ testSuite: XCTestSuite) {
        guard let asyncService = reportingService else {
            print("🚨 RPListener Configuration Error: Reporting is disabled (PushTestDataToReportPortal=false). Test suite '\(testSuite.name)' will not be reported to ReportPortal.")
            return
        }
        
        guard
            !testSuite.name.contains("All tests"),
            !testSuite.name.contains("Selected tests") else
        {
            return
        }

        // Skip framework's own unit test suites (they test RPListener itself and create mock launch IDs)
        if testSuite.name == "LaunchManagerTests" || testSuite.name == "OperationTrackerTests" {
            Logger.shared.info("⚠️ Skipping framework unit test suite: \(testSuite.name)")
            return
        }

        // Detect if this is a unit test suite (fast tests that need synchronization)
        // Unit tests can complete in 1-11ms, while API calls take 200-500ms
        // UI tests take 7-14 seconds, so they don't need blocking
        let isUnitTestSuite = testSuite.name.contains("UnitTests") && !testSuite.name.contains("UITests")
        
        // For unit tests: Use semaphore to ensure suite is created BEFORE tests start
        // This prevents race conditions with fast-running unit tests
        let semaphore: DispatchSemaphore? = isUnitTestSuite ? DispatchSemaphore(value: 0) : nil

        // T015: Register suite with OperationTracker for parallel execution
        Task.detached(priority: .high) {
            defer {
                // Signal completion for unit tests
                semaphore?.signal()
            }

            // Wait for launch ID (properly awaits task, no polling)
            let launchID: String
            do {
                launchID = try await self.waitForLaunchID()
            } catch {
                let bundleCount = await self.launchManager.getActiveBundleCount()
                Logger.shared.error("""
                    ❌ SUITE REGISTRATION FAILED: '\(testSuite.name)'
                    Reason: \(error.localizedDescription)
                    Active bundles: \(bundleCount)
                    Impact: This suite will NOT be reported to ReportPortal
                    Action: Check launch creation logs and ReportPortal connectivity
                    """)
                return
            }

            do {
                let correlationID = UUID()
                let isRootSuite = testSuite.name.contains(".xctest")

                // Build consistent identifier: use suite name as-is
                // For test class suites, XCTest provides the class name
                // For root suites, it's the bundle name with .xctest extension
                let identifier = testSuite.name

                // DIAGNOSTIC: Log suite details to understand naming
                Logger.shared.info("""
                    📦 SUITE STARTING:
                    - testSuite.name: '\(testSuite.name)'
                    - identifier: '\(identifier)'
                    - isRoot: \(isRootSuite)
                    - testCount: \(testSuite.testCaseCount)
                    """, correlationID: correlationID)

                // For test class suites, wait for root suite ID to be available
                let rootSuiteID: String?
                if !isRootSuite {
                    // Wait for root suite to be created (short timeout - if not created quickly, skip it)
                    Logger.shared.info("⏳ Waiting for root suite to be created...", correlationID: correlationID)
                    do {
                        let id = try await self.rootSuiteIDManager.waitForRootSuiteID(timeout: 3) // Reduced from 30s to 3s
                        rootSuiteID = id
                        Logger.shared.info("✅ Root suite ID found: \(id)", correlationID: correlationID)
                    } catch {
                        // Root suite not created - this can happen in parallel execution
                        // when XCTest skips bundle-level suite callbacks
                        // Solution: Make this a root-level suite instead
                        rootSuiteID = nil
                        Logger.shared.info("""
                            [PARALLEL] ℹ️  ROOT SUITE SKIPPED (creating standalone suite):
                            - Test class suite: '\(testSuite.name)'
                            - Reason: \(error.localizedDescription)
                            - This is NORMAL in parallel execution when XCTest skips bundle callbacks
                            - Solution: Creating suite at root level (no parent hierarchy)
                            """, correlationID: correlationID)
                    }
                } else {
                    rootSuiteID = nil
                    Logger.shared.info("📦 Creating ROOT SUITE...", correlationID: correlationID)
                }

                // Create suite operation
                var operation = SuiteOperation(
                    correlationID: correlationID,
                    suiteID: "", // Will be set after API call
                    rootSuiteID: rootSuiteID,
                    suiteName: testSuite.name,
                    status: .passed,
                    startTime: Date(),
                    childTestIDs: [],
                    metadata: [:]
                )

                // Register suite in tracker with consistent identifier
                await self.operationTracker.registerSuite(operation, identifier: identifier)

                Logger.shared.info("✅ Suite registered: '\(identifier)' → ID: pending", correlationID: correlationID)

                // Start suite in ReportPortal
                let apiStartTime = Date()
                Logger.shared.info("📡 Calling ReportPortal API to create suite...", correlationID: correlationID)

                // Use suite coordinator for file-based deduplication (if available)
                let suiteID = try await asyncService.startSuite(
                    operation: operation,
                    launchID: launchID,
                    coordinator: self.suiteCoordinator
                )

                let apiDuration = Date().timeIntervalSince(apiStartTime)
                Logger.shared.info("📡 API call completed in \(Int(apiDuration * 1000))ms", correlationID: correlationID)

                // Update operation with suite ID
                operation.suiteID = suiteID
                await self.operationTracker.updateSuite(operation, identifier: identifier)

                // Register suite in global registry (file-based coordination across all workers)
                if let counterCoordinator = self.suiteCounterCoordinator {
                    do {
                        let launchUUID = await self.launchManager.getOrCreateLaunchUUID()
                        let totalCount = try await counterCoordinator.registerSuite(
                            uuid: launchUUID,
                            suiteName: testSuite.name,
                            suiteID: suiteID
                        )
                        await SyncLogger.shared.logSuite("Registered '\(testSuite.name)' - UUID: \(launchUUID), Total active: \(totalCount)")
                        print("📊 [SYNC] [SUITE] Registered '\(testSuite.name)' (Total active: \(totalCount))")
                    } catch {
                        await SyncLogger.shared.logSuite("Registration failed: \(error.localizedDescription)")
                        print("❌ [SYNC] [SUITE] Registration failed: \(error.localizedDescription)")
                    }
                }

                // Store root suite ID if this is root
                if isRootSuite {
                    await self.rootSuiteIDManager.setRootSuiteID(suiteID)
                    Logger.shared.info("🎯 Root suite ID stored: \(suiteID)", correlationID: correlationID)
                }

                Logger.shared.info("✅ Suite started: \(suiteID)", correlationID: correlationID)
            } catch {
                Logger.shared.error("Failed to start suite '\(testSuite.name)': \(error.localizedDescription)")
            }
        }
        
        // For unit tests: Wait for suite creation to complete before tests start
        // This prevents race conditions with fast tests (1-11ms) finishing before API calls (200-500ms)
        // UI tests don't need this - they're slow enough (7-14s) that async creation completes in time
        if let semaphore = semaphore {
            let waitResult = semaphore.wait(timeout: .now() + 10)
            if waitResult == .timedOut {
                Logger.shared.warning("⚠️ Suite creation timed out after 10 seconds for: \(testSuite.name)")
            }
        }
    }
    
    
    public func testCaseWillStart(_ testCase: XCTestCase) {
        guard let asyncService = reportingService else {
            print("🚨 RPListener Configuration Error: Reporting is disabled (PushTestDataToReportPortal=false). Test case '\(testCase.name)' will not be reported to ReportPortal.")
            return
        }

        // Skip framework's own unit tests (they test RPListener itself)
        let className = String(describing: type(of: testCase))
        if className == "LaunchManagerTests" || className == "OperationTrackerTests" {
            return
        }

        // T019: Register test case with OperationTracker for parallel execution
        // Note: Test tracking is async (best effort) - no semaphore synchronization here
        // Rationale:
        // - Bundle and Suite are already synchronized (critical points)
        // - Tests run inside Suite, so Suite already exists
        // - Synchronizing every test would slow down test execution significantly
        // - For very fast tests (1-10ms), async tracking is acceptable trade-off
        
        // CRITICAL FIX: Tests can fail VERY quickly (before async registration completes).
        // Register a placeholder synchronously to ensure test can be found by didRecord:issue callbacks.
        let testName = extractTestName(from: testCase)
        let identifier = "\(className).\(testName)"
        let correlationID = UUID()
        
        // Create placeholder operation (will be updated asynchronously)
        let placeholderOperation = TestOperation(
            correlationID: correlationID,
            testID: "", // Will be set after API call
            suiteID: "", // Will be set after suite lookup
            testName: testName,
            className: className,
            status: .passed,
            startTime: Date(),
            metadata: [:],
            attachments: []
        )
        
        // Register immediately with high priority (non-blocking but executes ASAP)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await self.operationTracker.registerTest(placeholderOperation, identifier: identifier)
        }
        
        // ASYNC: Complete registration with ReportPortal API
        Task {
            // Wait for launch ID (properly awaits task, no polling)
            let launchID: String
            do {
                launchID = try await waitForLaunchID()
            } catch {
                let bundleCount = await launchManager.getActiveBundleCount()
                Logger.shared.error("""
                    ❌ TEST REGISTRATION FAILED: '\(className).\(testName)'
                    Reason: \(error.localizedDescription)
                    Active bundles: \(bundleCount)
                    Impact: This test will NOT be reported to ReportPortal (but will still execute locally)
                    Action: Check launch creation logs and ReportPortal connectivity
                    """)
                return
            }
            
            do {

                // DIAGNOSTIC: Log test details
                Logger.shared.info("""
                    🧪 TEST STARTING:
                    - testCase.name: '\(testCase.name)'
                    - testName: '\(testName)'
                    - className: '\(className)'
                    - Looking for suite: '\(className)'
                    """, correlationID: correlationID)

                // Get parent suite ID (from current suite context)
                guard let suiteID = await getCurrentSuiteID(for: className) else {
                    let activeSuites = await operationTracker.getAllSuiteIdentifiers()
                    Logger.shared.error("""
                        ❌ TEST REGISTRATION FAILED: '\(className).\(testName)'
                        Reason: Parent suite ID not found for class '\(className)'
                        Active suites: \(activeSuites.joined(separator: ", "))
                        Impact: Cannot establish test hierarchy in ReportPortal
                        Hint: Suite may have failed to start or identifier mismatch
                        """)
                    return
                }
                
                // Collect metadata
                let metadata = collectTestMetadata()
                
                // Update placeholder operation with full details
                var operation = TestOperation(
                    correlationID: correlationID,
                    testID: "", // Will be set after API call
                    suiteID: suiteID,
                    testName: testName,
                    className: className,
                    status: .passed,
                    startTime: Date(),
                    metadata: metadata,
                    attachments: []
                )
                
                // Update test in tracker (replace placeholder)
                await operationTracker.updateTest(operation, identifier: identifier)
                
                // Start test in ReportPortal
                let testID = try await asyncService.startTest(operation: operation, launchID: launchID)
                
                // Update operation with test ID
                operation.testID = testID
                await operationTracker.updateTest(operation, identifier: identifier)
                
                Logger.shared.info("Test started: \(testID)", correlationID: correlationID)
            } catch {
                Logger.shared.error("Failed to start test '\(testCase.name)': \(error.localizedDescription)")
            }
        }
    }
    
    // Helper to extract test name from XCTestCase
    private func extractTestName(from testCase: XCTestCase) -> String {
        let fullName = testCase.name
        // XCTest name format: "-[ClassName testMethodName]"
        let components = fullName.components(separatedBy: " ")
        if components.count > 1 {
            return components[1].replacingOccurrences(of: "]", with: "")
        }
        return fullName
    }
    
    // Helper to get current suite ID for a test class
    // XCTest suite names should match the class name for test class suites
    // Uses event-driven waiting (continuations) to handle async suite registration
    private func getCurrentSuiteID(for className: String) async -> String? {
        // Try waiting for suite to be registered (handles async registration race)
        // This uses continuations - test will pause until suite registers or timeout occurs
        do {
            let suiteOp = try await operationTracker.waitForSuite(identifier: className, timeout: 10)
            Logger.shared.debug("Found suite for class '\(className)' via event-driven wait")
            return suiteOp.suiteID
        } catch {
            Logger.shared.warning("Suite '\(className)' not registered after waiting: \(error.localizedDescription)")
        }

        // If exact match failed after waiting, check all registered suites for potential matches
        // This handles edge cases where XCTest might provide different naming
        let allSuites = await operationTracker.getAllSuiteIdentifiers()
        Logger.shared.debug("Searching for suite matching class '\(className)' in: [\(allSuites.joined(separator: ", "))]")

        // Try to find a suite that contains the class name
        for suiteIdentifier in allSuites {
            if suiteIdentifier.contains(className) || className.contains(suiteIdentifier) {
                if let suiteOp = await operationTracker.getSuite(identifier: suiteIdentifier) {
                    Logger.shared.info("Found suite '\(suiteIdentifier)' for class '\(className)' via partial match")
                    return suiteOp.suiteID
                }
            }
        }

        // Last resort: use root suite ID if available
        // This happens when test class suite failed to start but root suite exists
        if let rootSuiteID = await rootSuiteIDManager.getRootSuiteID() {
            Logger.shared.error("""
                ❌ SUITE LOOKUP FAILED - USING FALLBACK:
                - Searching for: '\(className)'
                - Registered suites: [\(allSuites.joined(separator: ", "))]
                - Using root suite as fallback
                - Impact: Test will appear at root level instead of under class suite
                - Likely cause: testSuite.name != className (identifier mismatch)
                - Action: Check logs above to see suite registration names vs test class names
                """)
            return rootSuiteID
        }

        Logger.shared.error("""
            ❌ CRITICAL: No suite found for class '\(className)' and no root suite available.
            Tests cannot be reported to ReportPortal.
            """)
        return nil
    }
    
    // Helper to collect test metadata
    private func collectTestMetadata() -> [String: String] {
        var metadata: [String: String] = [:]
        
        // Add test plan name if available
        if let testPlanName = MetadataCollector.getTestPlanName() {
            metadata["testPlan"] = testPlanName
        }
        
        // Add device info
        metadata["os"] = DeviceHelper.osNameAndVersion()
        
        return metadata
    }
    
    @available(*, deprecated, message: "Use fun public func testCase(_ testCase: XCTestCase, didFailWithDescription description: String, inFile filePath: String?, atLine lineNumber: Int) for iOs 17+")
    public func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssueReference) {
        guard let asyncService = reportingService else {
            print("🚨 RPListener Configuration Error: Reporting is disabled (PushTestDataToReportPortal=false). Test issue for '\(testCase.name)' will not be reported to ReportPortal.")
            return
        }

        // Skip framework's own unit tests (they test RPListener itself)
        let className = String(describing: type(of: testCase))
        if className == "LaunchManagerTests" || className == "OperationTrackerTests" {
            return
        }

        // T022: Async attachment upload for concurrent execution
        Task {
            // Wait for launch ID (don't drop early failures)
            let launchID: String
            do {
                launchID = try await waitForLaunchID()
            } catch {
                let testName = extractTestName(from: testCase)
                let className = String(describing: type(of: testCase))
                Logger.shared.warning("""
                    ⚠️ Cannot report test issue to ReportPortal: '\(className).\(testName)'
                    Reason: Launch ID not available - \(error.localizedDescription)
                    Impact: Test failure will not be visible in ReportPortal
                    """)
                return
            }

            // Validate launch ID is not empty
            guard !launchID.isEmpty else {
                let testName = extractTestName(from: testCase)
                let className = String(describing: type(of: testCase))
                Logger.shared.error("""
                    ❌ Cannot report test issue: '\(className).\(testName)'
                    Reason: Launch ID is empty (race condition - launch not initialized yet)
                    Launch State: \(await launchManager.getDebugState())
                    Impact: Screenshot and error log will not be uploaded
                    Note: Test result will still be recorded in testCaseDidFinish
                    """)
                return
            }

            // Build identifier to get test operation
            let testName = extractTestName(from: testCase)
            let className = String(describing: type(of: testCase))
            let identifier = "\(className).\(testName)"

            guard let operation = await operationTracker.getTest(identifier: identifier) else {
                Logger.shared.info("""
                    ℹ️  Test issue reported before registration completed: '\(identifier)'
                    Reason: Test failed extremely fast (< 1ms) before async registration finished
                    Impact: Test failure will be recorded when test finishes (in testCaseDidFinish)
                    Action: No action needed - this is rare but harmless for very fast failing tests
                    """)
                return
            }

            // Check if test has been fully registered with ReportPortal (has testID)
            guard !operation.testID.isEmpty else {
                // Test operation exists but testID is pending - retry after delay
                Logger.shared.info("""
                    ℹ️  Test issue reported before ReportPortal API completed: '\(identifier)'
                    Reason: Test failed before async startTest API call completed
                    Action: Retrying in 3 seconds...
                    """, correlationID: operation.correlationID)
                
                // Capture issue data before async retry
                let lineNumberString = issue.sourceCodeContext.location?.lineNumber != nil
                    ? " on line \(issue.sourceCodeContext.location!.lineNumber)"
                    : ""
                let errorMessage = "Test '\(String(describing: issue.description))' failed\(lineNumberString), \(issue.description)"
                
                // Capture screenshot immediately (before it's lost)
                #if canImport(UIKit)
                let screenshot = XCUIScreen.main.screenshot()
                let screenshotData = screenshot.pngRepresentation
                let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                let filename = "failure_screenshot_\(timestamp).png"
                #endif
                
                // Retry after 3 seconds (gives API time to complete)
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                    
                    // Retry: Get operation again (should have testID now)
                    guard let updatedOperation = await self.operationTracker.getTest(identifier: identifier),
                          !updatedOperation.testID.isEmpty else {
                        Logger.shared.warning("""
                            ⚠️ Retry failed: Test '\(identifier)' still has no testID after 3s delay
                            Impact: Screenshot/error log will be skipped for this test failure
                            Note: Test result will still be recorded in testCaseDidFinish
                            """)
                        return
                    }
                    
                    // Now we have testID - proceed with posting failure
                    Logger.shared.info("✅ Retry successful: Test '\(identifier)' now has testID: \(updatedOperation.testID)", correlationID: updatedOperation.correlationID)
                    
                    do {
                        // Post error log
                        Logger.shared.debug("Posting error log for test \(updatedOperation.testID) with launch \(launchID)", correlationID: updatedOperation.correlationID)
                        try await asyncService.postLog(
                            message: errorMessage,
                            level: "error",
                            itemID: updatedOperation.testID,
                            launchID: launchID,
                            correlationID: updatedOperation.correlationID
                        )
                        
                        // Upload screenshot
                        #if canImport(UIKit)
                        do {
                            Logger.shared.debug("Uploading screenshot for test \(updatedOperation.testID) with launch \(launchID)", correlationID: updatedOperation.correlationID)
                            try await asyncService.postScreenshot(
                                screenshotData: screenshotData,
                                filename: filename,
                                itemID: updatedOperation.testID,
                                launchID: launchID,
                                correlationID: updatedOperation.correlationID
                            )
                            Logger.shared.info("📸 Screenshot uploaded successfully (after retry)", correlationID: updatedOperation.correlationID)
                        } catch {
                            Logger.shared.warning("Failed to upload screenshot after retry: \(error.localizedDescription)", correlationID: updatedOperation.correlationID)
                        }
                        #endif
                        
                        Logger.shared.info("TEST FAIL reported (after retry)", correlationID: updatedOperation.correlationID)
                    } catch {
                        Logger.shared.error("Failed to report TEST FAIL after retry: \(error.localizedDescription)", correlationID: updatedOperation.correlationID)
                    }
                }
                return
            }

            // Test has testID - proceed immediately
            do {
                let lineNumberString = issue.sourceCodeContext.location?.lineNumber != nil
                ? " on line \(issue.sourceCodeContext.location!.lineNumber)"
                : ""
                let errorMessage = "Test '\(String(describing: issue.description))' failed\(lineNumberString), \(issue.description)"

                // Post error log with async API (non-blocking)
                Logger.shared.debug("Posting error log for test \(operation.testID) with launch \(launchID)", correlationID: operation.correlationID)
                try await asyncService.postLog(
                    message: errorMessage,
                    level: "error",
                    itemID: operation.testID,
                    launchID: launchID,
                    correlationID: operation.correlationID
                )

                // Capture and upload screenshot directly (v3.x approach)
                #if canImport(UIKit)
                do {
                    let screenshot = XCUIScreen.main.screenshot()
                    let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                    let filename = "failure_screenshot_\(timestamp).png"

                    Logger.shared.debug("Uploading screenshot for test \(operation.testID) with launch \(launchID)", correlationID: operation.correlationID)
                    try await asyncService.postScreenshot(
                        screenshotData: screenshot.pngRepresentation,
                        filename: filename,
                        itemID: operation.testID,
                        launchID: launchID,
                        correlationID: operation.correlationID
                    )
                    Logger.shared.info("📸 Screenshot uploaded successfully", correlationID: operation.correlationID)
                } catch {
                    Logger.shared.warning("Failed to upload screenshot: \(error.localizedDescription) (Launch: \(launchID), Test: \(operation.testID))", correlationID: operation.correlationID)
                }
                #endif

                Logger.shared.info("TEST FAIL reported", correlationID: operation.correlationID)
            } catch {
                Logger.shared.error("Failed to report TEST FAIL: \(error.localizedDescription) (Launch: \(launchID), Test: \(operation.testID))", correlationID: operation.correlationID)
            }
        }
    }
    
    // For iOs 17+
    public func testCase(_ testCase: XCTestCase, didFailWithDescription description: String, inFile filePath: String?, atLine lineNumber: Int) {
        guard let asyncService = reportingService else {
            print("🚨 RPListener Configuration Error: Reporting is disabled (PushTestDataToReportPortal=false). Test failure for '\(testCase.name)' will not be reported to ReportPortal.")
            return
        }

        // Skip framework's own unit tests (they test RPListener itself)
        let className = String(describing: type(of: testCase))
        if className == "LaunchManagerTests" || className == "OperationTrackerTests" {
            return
        }

        // T022: Async attachment upload for concurrent execution
        Task {
            // Wait for launch ID (don't drop early failures)
            let launchID: String
            do {
                launchID = try await waitForLaunchID()
            } catch {
                let testName = extractTestName(from: testCase)
                let className = String(describing: type(of: testCase))
                Logger.shared.warning("""
                    ⚠️ Cannot report test failure to ReportPortal: '\(className).\(testName)'
                    Reason: Launch ID not available - \(error.localizedDescription)
                    Impact: Test failure will not be visible in ReportPortal
                    """)
                return
            }

            // Build identifier to get test operation
            let testName = extractTestName(from: testCase)
            let className = String(describing: type(of: testCase))
            let identifier = "\(className).\(testName)"

            guard var operation = await operationTracker.getTest(identifier: identifier) else {
                Logger.shared.warning("""
                    ⚠️ Cannot report test failure: Test operation not found for '\(identifier)'
                    Reason: Test may not have been registered successfully
                    Impact: Test failure details will not be visible in ReportPortal
                    """)
                return
            }

            do {
                let fileInfo = filePath != nil ? " in \(URL(fileURLWithPath: filePath!).lastPathComponent)" : ""
                let errorMessage = "Test failed on line \(lineNumber)\(fileInfo): \(description)"

                // Post error log with async API (non-blocking)
                try await asyncService.postLog(
                    message: errorMessage,
                    level: "error",
                    itemID: operation.testID,
                    launchID: launchID,
                    correlationID: operation.correlationID
                )

                // Capture and upload screenshot directly (v3.x approach, works on iOS 17+)
                #if canImport(UIKit)
                do {
                    let screenshot = XCUIScreen.main.screenshot()
                    let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                    let filename = "failure_screenshot_\(timestamp).png"

                    try await asyncService.postScreenshot(
                        screenshotData: screenshot.pngRepresentation,
                        filename: filename,
                        itemID: operation.testID,
                        launchID: launchID,
                        correlationID: operation.correlationID
                    )
                    Logger.shared.info("📸 Screenshot uploaded successfully", correlationID: operation.correlationID)
                } catch {
                    Logger.shared.warning("Failed to upload screenshot: \(error.localizedDescription)", correlationID: operation.correlationID)
                }
                #endif

                Logger.shared.info("Failure reported", correlationID: operation.correlationID)
            } catch {
                Logger.shared.error("Failed to report failure: \(error.localizedDescription)", correlationID: operation.correlationID)
            }
        }
    }
    
    public func testCaseDidFinish(_ testCase: XCTestCase) {
        guard let asyncService = reportingService else {
            print("🚨 RPListener Configuration Error: Reporting is disabled (PushTestDataToReportPortal=false). Test completion for '\(testCase.name)' will not be reported to ReportPortal.")
            return
        }

        // Skip framework's own unit tests (they test RPListener itself)
        let className = String(describing: type(of: testCase))
        if className == "LaunchManagerTests" || className == "OperationTrackerTests" {
            return
        }

        // T020: Finalize test with status update and cleanup
        Task {
            // Build identifier
            let testName = extractTestName(from: testCase)
            let className = String(describing: type(of: testCase))
            let identifier = "\(className).\(testName)"
            
            // Retrieve test operation from tracker
            guard var operation = await operationTracker.getTest(identifier: identifier) else {
                Logger.shared.error("Test operation not found in tracker: \(identifier)")
                return
            }

            do {
                // Update status based on test result
                let hasSucceeded = testCase.testRun?.hasSucceeded ?? false
                operation.status = hasSucceeded ? .passed : .failed

                // Finish test in ReportPortal
                // Note: Screenshots are uploaded directly in failure methods, not here
                try await asyncService.finishTest(operation: operation)

                // Update aggregated launch status
                await launchManager.updateStatus(operation.status)

                // Unregister test from tracker (cleanup)
                await operationTracker.unregisterTest(identifier: identifier)

                Logger.shared.info("Test finished: \(operation.testID) with status: \(operation.status.rawValue)", correlationID: operation.correlationID)
            } catch {
                Logger.shared.error("Failed to finish test '\(testCase.name)': \(error.localizedDescription)", correlationID: operation.correlationID)
            }
        }
    }
    
    public func testSuiteDidFinish(_ testSuite: XCTestSuite) {
        guard let asyncService = reportingService else {
            print("🚨 RPListener Configuration Error: Reporting is disabled (PushTestDataToReportPortal=false). Test suite completion for '\(testSuite.name)' will not be reported to ReportPortal.")
            return
        }
        
        guard
            !testSuite.name.contains("All tests"),
            !testSuite.name.contains("Selected tests") else
        {
            return
        }

        // Skip framework's own unit test suites (they test RPListener itself)
        if testSuite.name == "LaunchManagerTests" || testSuite.name == "OperationTrackerTests" {
            return
        }

        // T016: Finalize suite with OperationTracker
        Task {
            let identifier = testSuite.name
            
            // Retrieve suite operation from tracker
            guard let operation = await operationTracker.getSuite(identifier: identifier) else {
                Logger.shared.error("Suite operation not found in tracker: \(identifier)")
                return
            }
            
            // Finish suite in ReportPortal (may fail, but cleanup must still happen)
            do {
                try await asyncService.finishSuite(operation: operation)
                Logger.shared.info("Suite finished: \(operation.suiteID)", correlationID: operation.correlationID)
            } catch {
                Logger.shared.error("Failed to finish suite '\(testSuite.name)': \(error.localizedDescription)", correlationID: operation.correlationID)
            }
            
            // ⚠️ CRITICAL: ALWAYS unregister suite - even if finish failed above
            // This MUST happen to prevent infinite loops
            await operationTracker.unregisterSuite(identifier: identifier)
            
            // Unregister suite from global registry (file-based coordination across all workers)
            if let counterCoordinator = self.suiteCounterCoordinator {
                do {
                    let launchUUID = await self.launchManager.getOrCreateLaunchUUID()
                    let remainingCount = try await counterCoordinator.unregisterSuite(
                        uuid: launchUUID,
                        suiteName: testSuite.name
                    )
                    await SyncLogger.shared.logSuite("Unregistered '\(testSuite.name)' - UUID: \(launchUUID), Remaining: \(remainingCount)")
                    print("📊 [SYNC] [SUITE] Unregistered '\(testSuite.name)' (Remaining: \(remainingCount))")
                } catch {
                    await SyncLogger.shared.logSuite("Unregistration failed: \(error.localizedDescription)")
                    print("❌ [SYNC] [SUITE] Unregistration failed: \(error.localizedDescription)")
                }
            }
            
            // 🔥 CRITICAL: Trigger launch finalization check after suite cleanup
            await self.checkAndFinalizeLaunchIfNeeded()
        }
    }
    
    /// Check if all suites are finished and finalize launch if needed
    /// Called after each suite finish in parallel execution mode
    /// Uses GLOBAL file-based suite counter to check if ALL workers are done
    private func checkAndFinalizeLaunchIfNeeded() async {
        // Get launch UUID for coordination
        let launchUUID = await launchManager.getOrCreateLaunchUUID()
        
        // Check GLOBAL suite count across ALL workers (file-based coordination)
        let globalSuiteCount: Int
        if let counterCoordinator = suiteCounterCoordinator {
            globalSuiteCount = await counterCoordinator.getSuiteCount(uuid: launchUUID)
        } else {
            globalSuiteCount = await operationTracker.getActiveSuiteCount()
        }
        
        guard globalSuiteCount == 0 else {
            await SyncLogger.shared.logFinish("Waiting - \(globalSuiteCount) suites still active - UUID: \(launchUUID)")
            print("⏳ [SYNC] [FINISH] Waiting... \(globalSuiteCount) suites still active")
            return
        }
        
        await SyncLogger.shared.logFinish("All suites done! Checking finalization - UUID: \(launchUUID)")
        print("🎯 [SYNC] [FINISH] All suites done! Checking finalization...")
        
        // Check if launch already finalized
        let isFinalized = await launchManager.isLaunchFinalized()
        guard !isFinalized else {
            await SyncLogger.shared.logFinish("Already finalized by another worker - UUID: \(launchUUID)")
            print("✅ [SYNC] [FINISH] Already finalized by another worker")
            return
        }
        
        guard let launchID = await launchManager.getLaunchID() else {
            print("❌ [SYNC] [FINISH] No launch ID found")
            await SyncLogger.shared.logFinish("ERROR - No launch ID found")
            return
        }
        
        guard let tracker = workerTracker,
              let coordinator = finishCoordinator,
              let workerID = workerID else {
            Logger.shared.error("❌ Cannot finalize: missing coordination components")
            await SyncLogger.shared.logFinish("Missing coordination components - UUID: \(launchUUID)")
            print("❌ [ReportPortal] Missing coordination components (tracker/coordinator/workerID)")
            return
        }
        
        let status = await launchManager.getAggregatedStatus()
        
        await SyncLogger.shared.logFinish("Worker \(workerID) attempting finalization - UUID: \(launchUUID), Status: \(status.rawValue), LaunchID: \(launchID)")
        print("🔄 [SYNC] [FINISH] Worker \(workerID) attempting finalization (status: \(status.rawValue))")
        
        do {
            if let asyncService = reportingService {
                try await asyncService.finalizeLaunchV2(
                    launchID: launchID,
                    status: status,
                    coordinator: coordinator,
                    tracker: tracker,
                    uuid: launchUUID,
                    workerID: workerID,
                    suiteCounterCoordinator: suiteCounterCoordinator
                )
                
                await SyncLogger.shared.logFinish("Worker \(workerID) finalization complete - UUID: \(launchUUID)")
                print("✅ [SYNC] [FINISH] Worker \(workerID) finalization complete")
            }
        } catch {
            await SyncLogger.shared.logFinish("Worker \(workerID) error: \(error.localizedDescription) - UUID: \(launchUUID)")
            print("❌ [SYNC] [FINISH] Worker \(workerID) error: \(error.localizedDescription)")
        }
    }
    
    public func testBundleDidFinish(_ testBundle: Bundle) {
        guard reportingService != nil else {
            print("🚨 RPListener Configuration Error: Reporting is disabled (PushTestDataToReportPortal=false). Test bundle completion will not be reported to ReportPortal.")
            return
        }

        print("🔔 [SYNC] [BUNDLE] testBundleDidFinish called")
        
        // Decrement bundle count (for diagnostics only)
        // Finalization is handled by checkAndFinalizeLaunchIfNeeded() after each suite finishes
        Task {
            Logger.shared.info("Test bundle finishing...")
            let shouldFinalize = await launchManager.decrementBundleCount()
            let activeCount = await launchManager.getActiveBundleCount()
            
            Logger.shared.info("Bundle count decremented. Active bundles: \(activeCount), Should finalize: \(shouldFinalize)")
            print("📊 [SYNC] [BUNDLE] Active bundles: \(activeCount), Should finalize: \(shouldFinalize)")
            
            // Note: Launch finalization is handled by checkAndFinalizeLaunchIfNeeded()
            // which is called after each suite finishes. This ensures proper coordination
            // even when workers start at different times (e.g., 5 devices with staggered starts)
        }
    }
}
