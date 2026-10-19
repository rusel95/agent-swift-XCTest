//  Created by Ruslan Popesku on 10/22/25.
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

import Foundation

/// Thread-safe registry for active test and suite operations.
actor OperationTracker {
    /// Shared singleton instance
    static let shared = OperationTracker()

    /// Private initializer ensures singleton pattern
    private init() {}

    // MARK: - Private State

    /// Active test operations (key: XCTest identifier)
    private var testOperations: [String: TestOperation] = [:]

    /// Active suite operations (key: suite identifier)
    private var suiteOperations: [String: SuiteOperation] = [:]

    // MARK: - Test Operation Management

    /// Register a test operation at test start
    /// - Parameters:
    ///   - operation: TestOperation struct with correlation ID and test ID
    ///   - identifier: Unique XCTest identifier (format: "Bundle.Class.testMethod")
    func registerTest(_ operation: TestOperation, identifier: String) {
        testOperations[identifier] = operation
    }

    /// Retrieve test operation for given identifier
    /// - Parameter identifier: XCTest identifier
    /// - Returns: TestOperation if found, `nil` if not registered
    func getTest(identifier: String) -> TestOperation? {
        return testOperations[identifier]
    }

    /// Update existing test operation (e.g., status change, test ID)
    /// - Parameters:
    ///   - operation: Updated TestOperation struct
    ///   - identifier: XCTest identifier
    func updateTest(_ operation: TestOperation, identifier: String) {
        testOperations[identifier] = operation
    }

    /// Remove test operation after reporting complete
    /// - Parameter identifier: XCTest identifier
    func unregisterTest(identifier: String) {
        testOperations.removeValue(forKey: identifier)
    }

    // MARK: - Suite Operation Management

    /// Register a suite operation at suite start
    /// - Parameters:
    ///   - operation: SuiteOperation struct with correlation ID and suite ID
    ///   - identifier: Unique XCTest suite identifier (format: "Bundle.Class")
    func registerSuite(_ operation: SuiteOperation, identifier: String) {
        suiteOperations[identifier] = operation
    }

    /// Retrieve suite operation for given identifier
    /// - Parameter identifier: XCTest suite identifier
    /// - Returns: SuiteOperation if found, `nil` if not registered
    func getSuite(identifier: String) -> SuiteOperation? {
        return suiteOperations[identifier]
    }

    /// Update existing suite operation (e.g., suite ID)
    /// - Parameters:
    ///   - operation: Updated SuiteOperation struct
    ///   - identifier: XCTest suite identifier
    func updateSuite(_ operation: SuiteOperation, identifier: String) {
        suiteOperations[identifier] = operation
    }

    /// Remove suite operation after reporting complete
    /// - Parameter identifier: XCTest suite identifier
    func unregisterSuite(identifier: String) {
        suiteOperations.removeValue(forKey: identifier)
    }

    // MARK: - Diagnostics

    /// Get all active suite identifiers (for debugging)
    /// - Returns: Array of suite identifier strings
    func getAllSuiteIdentifiers() -> [String] {
        return Array(suiteOperations.keys)
    }

    /// Clear all operations (for testing)
    func reset() {
        testOperations.removeAll()
        suiteOperations.removeAll()
    }
}
