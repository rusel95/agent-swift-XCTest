//
//  EndToEndCoordinationTests.swift
//  ExampleUnitTests
//
//  Created by Ruslan Popesku on 11/04/25.
//  Copyright © 2025 ReportPortal. All rights reserved.
//
//  End-to-end integration tests for hybrid coordination system
//

import XCTest
@testable import ReportPortalAgent

/// End-to-end integration tests for complete coordination flow
/// Validates launch + suite + finish coordination working together
final class EndToEndCoordinationTests: XCTestCase {
    
    // MARK: - Test Configuration
    
    let coordinationDir = "/tmp/reportportal"
    var testLaunchUUID: String!
    
    override func setUp() async throws {
        // Generate unique UUID for this test
        testLaunchUUID = UUID().uuidString
        
        // Clean up any leftover files from previous runs
        cleanupCoordinationFiles()
    }
    
    override func tearDown() async throws {
        // Clean up coordination files after test
        cleanupCoordinationFiles()
    }
    
    // MARK: - End-to-End Tests
    
    func testFullCoordinationFlow_SingleWorker() async throws {
        #if targetEnvironment(simulator)
        // Given: Single worker with full coordination
        let workerID = "worker_1"
        let suiteCoordinator = SuiteCoordinator()
        let workerTracker = WorkerTracker()
        let finishCoordinator = FinishCoordinator()
        
        // When: Worker registers
        try await workerTracker.registerWorker(uuid: testLaunchUUID, workerID: workerID)
        
        // Then: Worker count should be 1
        let workerCount = try await workerTracker.getWorkerCount(uuid: testLaunchUUID)
        XCTAssertEqual(workerCount, 1, "Should have 1 registered worker")
        
        // When: Worker creates suite
        let suiteName = "TestSuite"
        let suiteID1 = try await suiteCoordinator.getOrCreateSuite(
            name: suiteName,
            launchID: testLaunchUUID,
            createSuite: { UUID().uuidString }
        )
        
        // Then: Suite ID should be returned
        XCTAssertFalse(suiteID1.isEmpty, "Suite ID should not be empty")
        
        // When: Same worker requests same suite again
        let suiteID2 = try await suiteCoordinator.getOrCreateSuite(
            name: suiteName,
            launchID: testLaunchUUID,
            createSuite: { UUID().uuidString }
        )
        
        // Then: Should return same suite ID (from cache)
        XCTAssertEqual(suiteID1, suiteID2, "Should reuse suite from cache")
        
        // When: Worker records status and checks if should finish
        try await finishCoordinator.recordStatus(uuid: testLaunchUUID, workerID: workerID, status: .passed)
        let (shouldFinish, finalStatus) = try await finishCoordinator.shouldFinishLaunch(
            uuid: testLaunchUUID,
            workerID: workerID,
            workerTracker: workerTracker
        )
        
        // Then: Should finish (last worker) with passed status
        XCTAssertTrue(shouldFinish, "Single worker should trigger finish")
        XCTAssertEqual(finalStatus, .passed, "Final status should be passed")
        
        // When: Cleanup is performed
        await suiteCoordinator.cleanupSyncFiles(launchID: testLaunchUUID)
        await finishCoordinator.cleanupStatusFiles(uuid: testLaunchUUID)
        
        // Then: Files should be cleaned up (verified in tearDown)
        #else
        throw XCTSkip("File-based coordination only available on simulators")
        #endif
    }
    
    func testFullCoordinationFlow_MultipleWorkers() async throws {
        #if targetEnvironment(simulator)
        // Given: 5 workers simulating parallel execution
        let workerIDs = ["worker_1", "worker_2", "worker_3", "worker_4", "worker_5"]
        let suiteCoordinator = SuiteCoordinator()
        let workerTracker = WorkerTracker()
        let finishCoordinator = FinishCoordinator()
        
        // When: All workers register
        for workerID in workerIDs {
            try await workerTracker.registerWorker(uuid: testLaunchUUID, workerID: workerID)
        }
        
        // Then: Worker count should be 5
        let workerCount = try await workerTracker.getWorkerCount(uuid: testLaunchUUID)
        XCTAssertEqual(workerCount, 5, "Should have 5 registered workers")
        
        // When: Multiple workers try to create same suite concurrently
        let suiteName = "ParallelTestSuite"
        let suiteIDs = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in workerIDs {
                group.addTask {
                    try await suiteCoordinator.getOrCreateSuite(
                        name: suiteName,
                        launchID: self.testLaunchUUID,
                        createSuite: { UUID().uuidString }
                    )
                }
            }
            
            var ids: [String] = []
            for try await suiteID in group {
                ids.append(suiteID)
            }
            return ids
        }
        
        // Then: All workers should get the same suite ID (deduplication works)
        let uniqueSuiteIDs = Set(suiteIDs)
        XCTAssertEqual(uniqueSuiteIDs.count, 1, "Should have exactly 1 unique suite ID (deduplication)")
        XCTAssertEqual(suiteIDs.count, 5, "All 5 workers should get a suite ID")
        
        // When: Workers record different statuses
        try await finishCoordinator.recordStatus(uuid: testLaunchUUID, workerID: workerIDs[0], status: .passed)
        try await finishCoordinator.recordStatus(uuid: testLaunchUUID, workerID: workerIDs[1], status: .passed)
        try await finishCoordinator.recordStatus(uuid: testLaunchUUID, workerID: workerIDs[2], status: .failed) // Failed!
        try await finishCoordinator.recordStatus(uuid: testLaunchUUID, workerID: workerIDs[3], status: .passed)
        try await finishCoordinator.recordStatus(uuid: testLaunchUUID, workerID: workerIDs[4], status: .skipped)
        
        // Then: First 4 workers should NOT trigger finish
        for i in 0..<4 {
            let (shouldFinish, _) = try await finishCoordinator.shouldFinishLaunch(
                uuid: testLaunchUUID,
                workerID: workerIDs[i],
                workerTracker: workerTracker
            )
            XCTAssertFalse(shouldFinish, "Worker \(i+1) should not trigger finish (not last)")
        }
        
        // Then: Last worker (5th) should trigger finish with FAILED status (worst status wins)
        let (shouldFinish, finalStatus) = try await finishCoordinator.shouldFinishLaunch(
            uuid: testLaunchUUID,
            workerID: workerIDs[4],
            workerTracker: workerTracker
        )
        XCTAssertTrue(shouldFinish, "Last worker should trigger finish")
        XCTAssertEqual(finalStatus, .failed, "Final status should be FAILED (worst status)")
        
        // When: Cleanup is performed
        await suiteCoordinator.cleanupSyncFiles(launchID: testLaunchUUID)
        await finishCoordinator.cleanupStatusFiles(uuid: testLaunchUUID)
        
        #else
        throw XCTSkip("File-based coordination only available on simulators")
        #endif
    }
    
    func testStatusAggregation_PriorityHierarchy() async throws {
        #if targetEnvironment(simulator)
        // Given: Workers with different status combinations
        let testCases: [(statuses: [TestStatus], expected: TestStatus, description: String)] = [
            ([.passed, .passed, .passed], .passed, "All passed → PASSED"),
            ([.passed, .skipped, .passed], .skipped, "Has skipped → SKIPPED"),
            ([.passed, .stopped, .passed], .stopped, "Has stopped → STOPPED"),
            ([.passed, .failed, .passed], .failed, "Has failed → FAILED"),
            ([.failed, .stopped, .skipped, .passed], .failed, "FAILED > STOPPED > SKIPPED > PASSED"),
            ([.stopped, .skipped, .passed], .stopped, "STOPPED > SKIPPED > PASSED"),
            ([.skipped, .passed], .skipped, "SKIPPED > PASSED"),
        ]
        
        for (index, testCase) in testCases.enumerated() {
            let testUUID = UUID().uuidString
            let finishCoordinator = FinishCoordinator()
            let workerTracker = WorkerTracker()
            
            // Register workers
            for (i, _) in testCase.statuses.enumerated() {
                let workerID = "worker_\(i+1)"
                try await workerTracker.registerWorker(uuid: testUUID, workerID: workerID)
            }
            
            // Record statuses
            for (i, status) in testCase.statuses.enumerated() {
                let workerID = "worker_\(i+1)"
                try await finishCoordinator.recordStatus(uuid: testUUID, workerID: workerID, status: status)
            }
            
            // Check final status (last worker)
            let lastWorkerID = "worker_\(testCase.statuses.count)"
            let (_, finalStatus) = try await finishCoordinator.shouldFinishLaunch(
                uuid: testUUID,
                workerID: lastWorkerID,
                workerTracker: workerTracker
            )
            
            XCTAssertEqual(
                finalStatus, testCase.expected,
                "Test case \(index + 1): \(testCase.description)"
            )
            
            // Cleanup
            await finishCoordinator.cleanupStatusFiles(uuid: testUUID)
        }
        #else
        throw XCTSkip("File-based coordination only available on simulators")
        #endif
    }
    
    func testCoordinationFiles_CreatedAndCleaned() async throws {
        #if targetEnvironment(simulator)
        // Given: Coordination setup
        let suiteCoordinator = SuiteCoordinator()
        let finishCoordinator = FinishCoordinator()
        let workerTracker = WorkerTracker()
        let workerID = "test_worker"
        
        // When: Create suite
        _ = try await suiteCoordinator.getOrCreateSuite(
            name: "TestSuite",
            launchID: testLaunchUUID,
            createSuite: { UUID().uuidString }
        )
        
        // Then: Suite sync files should exist
        let suiteIDFile = "\(coordinationDir)/suite_TestSuite_\(testLaunchUUID!).id"
        let suiteLockFile = "\(coordinationDir)/suite_TestSuite_\(testLaunchUUID!).lock"
        XCTAssertTrue(FileManager.default.fileExists(atPath: suiteIDFile), "Suite ID file should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: suiteLockFile), "Suite lock file should exist")
        
        // When: Register worker and record status
        try await workerTracker.registerWorker(uuid: testLaunchUUID, workerID: workerID)
        try await finishCoordinator.recordStatus(uuid: testLaunchUUID, workerID: workerID, status: .passed)
        
        // Then: Worker and status files should exist
        let workerFile = "\(coordinationDir)/launch_\(testLaunchUUID!)_workers.txt"
        let statusFile = "\(coordinationDir)/launch_\(testLaunchUUID!)_statuses.txt"
        XCTAssertTrue(FileManager.default.fileExists(atPath: workerFile), "Worker file should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: statusFile), "Status file should exist")
        
        // When: Cleanup is performed
        await suiteCoordinator.cleanupSyncFiles(launchID: testLaunchUUID)
        await finishCoordinator.cleanupStatusFiles(uuid: testLaunchUUID)
        
        // Then: Files should be removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: suiteIDFile), "Suite ID file should be cleaned up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: suiteLockFile), "Suite lock file should be cleaned up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusFile), "Status file should be cleaned up")
        
        #else
        throw XCTSkip("File-based coordination only available on simulators")
        #endif
    }
    
    // MARK: - Helper Methods
    
    private func cleanupCoordinationFiles() {
        guard let uuid = testLaunchUUID else { return }
        
        let fileManager = FileManager.default
        
        // List all files in coordination directory
        guard let files = try? fileManager.contentsOfDirectory(atPath: coordinationDir) else {
            return
        }
        
        // Remove files related to this test's UUID
        for file in files {
            if file.contains(uuid) {
                let filePath = "\(coordinationDir)/\(file)"
                try? fileManager.removeItem(atPath: filePath)
            }
        }
    }
}
