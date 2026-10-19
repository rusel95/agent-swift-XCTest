//  Copyright 2025 EPAM Systems
//  
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//  
//      https://www.apache.org/licenses/LICENSE-2.0
//  
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import XCTest
@testable import ReportPortalAgent

/// Unit tests for OperationTracker actor
/// Tests thread-safe operation registry for concurrent test/suite operations
final class OperationTrackerTests: XCTestCase {

    // MARK: - Test Lifecycle

    override func setUp() async throws {
        // Reset OperationTracker state before each test
        await OperationTracker.shared.reset()
    }

    // MARK: - Test Operation Management

    func testRegisterTest() async {
        // Given: Test operation
        let operation = TestOperation(
            correlationID: UUID(),
            testID: "test-001",
            suiteID: "suite-001",
            testName: "testExample"
        )

        // When: Register test
        await OperationTracker.shared.registerTest(operation, identifier: "MyTestClass.testExample")

        // Then: Test should be retrievable
        let retrieved = await OperationTracker.shared.getTest(identifier: "MyTestClass.testExample")
        XCTAssertNotNil(retrieved, "Test should be registered")
        XCTAssertEqual(retrieved?.testID, "test-001", "Test ID should match")
        XCTAssertEqual(retrieved?.testName, "testExample", "Test name should match")
    }

    func testGetTest_ReturnsNilForUnregistered() async {
        // Given: No test registered

        // When: Get non-existent test
        let retrieved = await OperationTracker.shared.getTest(identifier: "NonExistent.test")

        // Then: Should return nil
        XCTAssertNil(retrieved, "Should return nil for unregistered test")
    }

    func testUpdateTest() async {
        // Given: Registered test
        var operation = TestOperation(
            correlationID: UUID(),
            testID: "test-002",
            suiteID: "suite-001",
            testName: "testUpdate",
            status: .passed
        )
        await OperationTracker.shared.registerTest(operation, identifier: "UpdateTestClass.testUpdate")

        // When: Update test status
        operation.status = .failed
        await OperationTracker.shared.updateTest(operation, identifier: "UpdateTestClass.testUpdate")

        // Then: Updated test should be retrievable
        let retrieved = await OperationTracker.shared.getTest(identifier: "UpdateTestClass.testUpdate")
        XCTAssertEqual(retrieved?.status, .failed, "Status should be updated to failed")
    }

    func testUnregisterTest() async {
        // Given: Registered test
        let operation = TestOperation(
            correlationID: UUID(),
            testID: "test-003",
            suiteID: "suite-001",
            testName: "testUnregister"
        )
        await OperationTracker.shared.registerTest(operation, identifier: "UnregisterTestClass.testUnregister")

        // When: Unregister test
        await OperationTracker.shared.unregisterTest(identifier: "UnregisterTestClass.testUnregister")

        // Then: Test should no longer be retrievable
        let retrieved = await OperationTracker.shared.getTest(identifier: "UnregisterTestClass.testUnregister")
        XCTAssertNil(retrieved, "Test should be unregistered")
    }

    // MARK: - Suite Operation Management

    func testRegisterSuite() async {
        // Given: Suite operation
        let operation = SuiteOperation(
            correlationID: UUID(),
            suiteID: "suite-001",
            suiteName: "MySuiteClass",
            status: .passed
        )

        // When: Register suite
        await OperationTracker.shared.registerSuite(operation, identifier: "MySuiteClass")

        // Then: Suite should be retrievable
        let retrieved = await OperationTracker.shared.getSuite(identifier: "MySuiteClass")
        XCTAssertNotNil(retrieved, "Suite should be registered")
        XCTAssertEqual(retrieved?.suiteID, "suite-001", "Suite ID should match")
        XCTAssertEqual(retrieved?.suiteName, "MySuiteClass", "Suite name should match")
    }

    func testGetSuite_ReturnsNilForUnregistered() async {
        // Given: No suite registered

        // When: Get non-existent suite
        let retrieved = await OperationTracker.shared.getSuite(identifier: "NonExistentSuite")

        // Then: Should return nil
        XCTAssertNil(retrieved, "Should return nil for unregistered suite")
    }

    func testUpdateSuite() async {
        // Given: Registered suite
        var operation = SuiteOperation(
            correlationID: UUID(),
            suiteID: "suite-002",
            suiteName: "UpdateSuite",
            status: .passed
        )
        await OperationTracker.shared.registerSuite(operation, identifier: "UpdateSuite")

        // When: Update suite status
        operation.status = .failed
        await OperationTracker.shared.updateSuite(operation, identifier: "UpdateSuite")

        // Then: Updated suite should be retrievable
        let retrieved = await OperationTracker.shared.getSuite(identifier: "UpdateSuite")
        XCTAssertEqual(retrieved?.status, .failed, "Status should be updated to failed")
    }

    func testUnregisterSuite() async {
        // Given: Registered suite
        let operation = SuiteOperation(
            correlationID: UUID(),
            suiteID: "suite-003",
            suiteName: "UnregisterSuite",
            status: .passed
        )
        await OperationTracker.shared.registerSuite(operation, identifier: "UnregisterSuite")

        // When: Unregister suite
        await OperationTracker.shared.unregisterSuite(identifier: "UnregisterSuite")

        // Then: Suite should no longer be retrievable
        let retrieved = await OperationTracker.shared.getSuite(identifier: "UnregisterSuite")
        XCTAssertNil(retrieved, "Suite should be unregistered")
    }

    func testGetAllSuiteIdentifiers() async {
        // Given: Multiple suites registered
        let identifiers = ["Suite1", "Suite2", "Suite3"]
        for (index, identifier) in identifiers.enumerated() {
            let operation = SuiteOperation(
                correlationID: UUID(),
                suiteID: "suite-\(index + 1)",
                suiteName: identifier,
                status: .passed
            )
            await OperationTracker.shared.registerSuite(operation, identifier: identifier)
        }

        // When: Get all identifiers
        let allIdentifiers = await OperationTracker.shared.getAllSuiteIdentifiers()

        // Then: Should contain all registered identifiers
        XCTAssertEqual(Set(allIdentifiers), Set(identifiers), "Should return all registered suite identifiers")
    }

    // MARK: - Concurrency Tests

    func testConcurrentTestRegistration() async {
        // Given: Multiple concurrent test registrations
        let testCount = 20

        // When: Register tests concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<testCount {
                group.addTask {
                    let operation = TestOperation(
                        correlationID: UUID(),
                        testID: "test-\(i)",
                        suiteID: "suite-001",
                        testName: "test\(i)"
                    )
                    await OperationTracker.shared.registerTest(operation, identifier: "ConcurrentTestClass.test\(i)")
                }
            }
        }

        // Then: All tests should be registered (no race conditions)
        for i in 0..<testCount {
            let registered = await OperationTracker.shared.getTest(identifier: "ConcurrentTestClass.test\(i)")
            XCTAssertNotNil(registered, "All concurrent registrations should succeed")
        }
    }

    func testConcurrentSuiteRegistration() async {
        // Given: Multiple concurrent suite registrations
        let suiteCount = 10

        // When: Register suites concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<suiteCount {
                group.addTask {
                    let operation = SuiteOperation(
                        correlationID: UUID(),
                        suiteID: "suite-\(i)",
                        suiteName: "ConcurrentSuite\(i)",
                        status: .passed
                    )
                    await OperationTracker.shared.registerSuite(operation, identifier: "ConcurrentSuite\(i)")
                }
            }
        }

        // Then: All suites should be registered (no race conditions)
        let count = await OperationTracker.shared.getAllSuiteIdentifiers().count
        XCTAssertEqual(count, suiteCount, "All concurrent registrations should succeed")
    }

    func testConcurrentReadWrite() async {
        // Given: Test registered
        let operation = TestOperation(
            correlationID: UUID(),
            testID: "test-rw",
            suiteID: "suite-001",
            testName: "testReadWrite",
            status: .passed
        )
        await OperationTracker.shared.registerTest(operation, identifier: "ReadWriteClass.testReadWrite")

        // When: Concurrent reads and writes
        await withTaskGroup(of: Void.self) { group in
            // 10 readers
            for _ in 0..<10 {
                group.addTask {
                    _ = await OperationTracker.shared.getTest(identifier: "ReadWriteClass.testReadWrite")
                }
            }

            // 5 writers
            for i in 0..<5 {
                group.addTask {
                    var op = operation
                    op.status = i % 2 == 0 ? .passed : .failed
                    await OperationTracker.shared.updateTest(op, identifier: "ReadWriteClass.testReadWrite")
                }
            }
        }

        // Then: Should complete without crashes (actor serializes access)
        let retrieved = await OperationTracker.shared.getTest(identifier: "ReadWriteClass.testReadWrite")
        XCTAssertNotNil(retrieved, "Test should still be accessible after concurrent access")
    }

    // MARK: - Reset Tests

    func testReset_ClearsAllState() async {
        // Given: Operations registered
        let testOp = TestOperation(
            correlationID: UUID(),
            testID: "test-reset",
            suiteID: "suite-001",
            testName: "testReset"
        )
        await OperationTracker.shared.registerTest(testOp, identifier: "ResetClass.testReset")

        let suiteOp = SuiteOperation(
            correlationID: UUID(),
            suiteID: "suite-reset",
            suiteName: "ResetSuite",
            status: .passed
        )
        await OperationTracker.shared.registerSuite(suiteOp, identifier: "ResetSuite")

        // When: Reset
        await OperationTracker.shared.reset()

        // Then: All state should be cleared
        let test = await OperationTracker.shared.getTest(identifier: "ResetClass.testReset")
        let suites = await OperationTracker.shared.getAllSuiteIdentifiers()

        XCTAssertNil(test, "Tests should be cleared after reset")
        XCTAssertTrue(suites.isEmpty, "Suites should be cleared after reset")
    }

}
