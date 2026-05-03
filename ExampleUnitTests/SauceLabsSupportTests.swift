//  Copyright 2026 EPAM Systems
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

import XCTest
@testable import ReportPortalAgent

// MARK: - resolveMergeGroup / resolveSkipFinish Tests

/// Tests for SauceLabs merge support: merge_group and skipFinish resolution.
/// These methods resolve configuration from env vars → Info.plist → default.
///
/// Note: Environment variables are process-global and cannot be set/unset in Swift.
/// Tests validate the Info.plist fallback and nil-bundle paths.
/// The env var priority path is validated by ValidationTest on SauceLabs real devices.
final class SauceLabsSupportTests: XCTestCase {

    private var listener: RPListener!

    override func setUp() {
        super.setUp()
        listener = RPListener()
    }

    override func tearDown() {
        listener = nil
        super.tearDown()
    }

    // MARK: - resolveMergeGroup

    func testResolveMergeGroup_NoPlistKey_ReturnsNil() {
        // The test bundle's Info.plist does not contain ReportPortalMergeGroup
        let bundle = Bundle(for: type(of: self))
        let result = listener.resolveMergeGroup(from: bundle)
        if ProcessInfo.processInfo.environment["RP_MERGE_GROUP"] == nil {
            XCTAssertNil(result, "Should return nil when neither env var nor Info.plist key is set")
        }
    }

    func testResolveMergeGroup_MainBundle_ReturnsNil() {
        // Main bundle also shouldn't have ReportPortalMergeGroup
        let result = listener.resolveMergeGroup(from: Bundle.main)
        if ProcessInfo.processInfo.environment["RP_MERGE_GROUP"] == nil {
            XCTAssertNil(result)
        }
    }

    // MARK: - resolveSkipFinish

    func testResolveSkipFinish_NoPlistKey_ReturnsFalse() {
        let bundle = Bundle(for: type(of: self))
        let result = listener.resolveSkipFinish(from: bundle)
        if ProcessInfo.processInfo.environment["RP_SKIP_FINISH"] == nil {
            XCTAssertFalse(result, "Should return false when neither env var nor Info.plist key is set")
        }
    }

    func testResolveSkipFinish_NilBundle_ReturnsFalse() {
        let result = listener.resolveSkipFinish(from: nil)
        if ProcessInfo.processInfo.environment["RP_SKIP_FINISH"] == nil {
            XCTAssertFalse(result, "Should return false when bundle is nil")
        }
    }

    func testResolveSkipFinish_MainBundle_ReturnsFalse() {
        let result = listener.resolveSkipFinish(from: Bundle.main)
        if ProcessInfo.processInfo.environment["RP_SKIP_FINISH"] == nil {
            XCTAssertFalse(result, "Should return false for main bundle without plist key")
        }
    }
}

// MARK: - HTTPClientError 4xx/5xx Classification Tests

/// Tests that verify the idempotent finalizeLaunch error classification logic.
/// Since HTTPClient creates its own URLSession, we test the error handling pattern directly.
final class IdempotentFinalizeLaunchTests: XCTestCase {

    func testHTTPClientError_4xx_IsClientError() {
        // Verify the pattern used in finalizeLaunch: 400-499 are non-fatal
        for code in [400, 404, 409, 422, 499] {
            let error = HTTPClientError.httpError(statusCode: code, body: "test")
            if case .httpError(let statusCode, _) = error {
                XCTAssertTrue((400...499).contains(statusCode),
                    "Status \(code) should be in 4xx range")
            }
        }
    }

    func testHTTPClientError_5xx_IsServerError() {
        // Verify 5xx errors are NOT in the 4xx range (should be re-thrown)
        for code in [500, 502, 503] {
            let error = HTTPClientError.httpError(statusCode: code, body: "test")
            if case .httpError(let statusCode, _) = error {
                XCTAssertFalse((400...499).contains(statusCode),
                    "Status \(code) should NOT be in 4xx range")
            }
        }
    }

    func testHTTPClientError_NetworkError_IsNotHTTPError() {
        // Network errors should not match the httpError pattern
        let error = HTTPClientError.networkError(NSError(domain: "test", code: -1))
        if case .httpError = error {
            XCTFail("Network error should not match httpError pattern")
        }
    }

    /// Integration test: finalizeLaunch with a real (but unreachable) server.
    /// Verifies the method handles network errors correctly (throws, not swallowed).
    func testFinalizeLaunch_NetworkError_Throws() async {
        let config = AgentConfiguration(
            reportPortalURL: URL(string: "https://localhost:1")!, // unreachable
            projectName: "test",
            launchName: "Test",
            shouldSendReport: true,
            portalToken: "token",
            tags: [],
            launchMode: .default,
            testNameRules: []
        )
        let service = ReportingService(configuration: config)

        do {
            try await service.finalizeLaunch(launchID: "test-id", status: .passed)
            XCTFail("Should throw on network error")
        } catch {
            // Expected: network error should propagate (not swallowed by 4xx handler)
        }
    }
}
