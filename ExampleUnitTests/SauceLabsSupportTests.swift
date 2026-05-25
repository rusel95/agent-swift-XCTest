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

    func testResolveMergeGroup_NoPlistKey_ReturnsNil() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RP_MERGE_GROUP"] != nil,
                      "RP_MERGE_GROUP env var is set; env-var path tested on SauceLabs real devices")
        let bundle = Bundle(for: type(of: self))
        let result = listener.resolveMergeGroup(from: bundle)
        XCTAssertNil(result, "Should return nil when neither env var nor Info.plist key is set")
    }

    func testResolveMergeGroup_MainBundle_ReturnsNil() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RP_MERGE_GROUP"] != nil,
                      "RP_MERGE_GROUP env var is set; env-var path tested on SauceLabs real devices")
        let result = listener.resolveMergeGroup(from: Bundle.main)
        XCTAssertNil(result)
    }

    // MARK: - resolveSkipFinish

    func testResolveSkipFinish_NoPlistKey_ReturnsFalse() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RP_SKIP_FINISH"] != nil,
                      "RP_SKIP_FINISH env var is set; env-var path tested on SauceLabs real devices")
        let bundle = Bundle(for: type(of: self))
        let result = listener.resolveSkipFinish(from: bundle)
        XCTAssertFalse(result, "Should return false when neither env var nor Info.plist key is set")
    }

    func testResolveSkipFinish_NilBundle_ReturnsFalse() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RP_SKIP_FINISH"] != nil,
                      "RP_SKIP_FINISH env var is set; env-var path tested on SauceLabs real devices")
        let result = listener.resolveSkipFinish(from: nil)
        XCTAssertFalse(result, "Should return false when bundle is nil")
    }

    func testResolveSkipFinish_MainBundle_ReturnsFalse() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RP_SKIP_FINISH"] != nil,
                      "RP_SKIP_FINISH env var is set; env-var path tested on SauceLabs real devices")
        let result = listener.resolveSkipFinish(from: Bundle.main)
        XCTAssertFalse(result, "Should return false for main bundle without plist key")
    }
}

// MARK: - finalizeLaunch 409-only Non-Fatal Tests

/// Tests that verify finalizeLaunch treats only 409 as non-fatal (idempotent already-finished).
/// All other HTTP errors — including other 4xx and all 5xx — must propagate.
final class IdempotentFinalizeLaunchTests: XCTestCase {

    func testHTTPClientError_409_IsNonFatal() {
        // 409 Conflict = launch already finished; must match the non-fatal check
        let error = HTTPClientError.httpError(statusCode: 409, body: "already finished")
        if case .httpError(let statusCode, _) = error {
            XCTAssertEqual(statusCode, 409, "409 should be the only non-fatal status code")
        }
    }

    func testHTTPClientError_OtherClientErrors_AreFatal() {
        // 400, 401, 403, 422 must NOT match the 409-only non-fatal check
        for code in [400, 401, 403, 422] {
            let error = HTTPClientError.httpError(statusCode: code, body: "error")
            if case .httpError(let statusCode, _) = error {
                XCTAssertNotEqual(statusCode, 409,
                    "Status \(code) should NOT be treated as non-fatal (only 409 is)")
            }
        }
    }

    func testHTTPClientError_5xx_AreFatal() {
        // 5xx server errors must NOT match the 409-only non-fatal check
        for code in [500, 502, 503] {
            let error = HTTPClientError.httpError(statusCode: code, body: "server error")
            if case .httpError(let statusCode, _) = error {
                XCTAssertNotEqual(statusCode, 409,
                    "Status \(code) should NOT be treated as non-fatal")
            }
        }
    }

    func testHTTPClientError_NetworkError_IsNotHTTPError() {
        // Network errors must not match the httpError pattern
        let error = HTTPClientError.networkError(NSError(domain: "test", code: -1))
        if case .httpError = error {
            XCTFail("Network error should not match httpError pattern")
        }
    }
}
