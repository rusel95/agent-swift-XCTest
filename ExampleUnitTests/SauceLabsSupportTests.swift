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
/// These are pure *static* resolvers (env var → Info.plist → default), so they are
/// exercised without instantiating `RPListener` — instantiating it would register a
/// process-global `XCTestObservation` observer that never gets removed.
///
/// Environment variables are process-global and cannot be set/unset from Swift, so the
/// env-var priority path is exercised only in real CI/device runs; here we cover the
/// Info.plist fallback, nil-bundle, and value-parsing paths.
final class SauceLabsSupportTests: XCTestCase {

    // MARK: - resolveMergeGroup

    func testResolveMergeGroup_NoPlistKey_ReturnsNil() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RP_MERGE_GROUP"] != nil,
                      "RP_MERGE_GROUP env var is set; env-var path tested on SauceLabs real devices")
        let bundle = Bundle(for: type(of: self))
        XCTAssertNil(RPListener.resolveMergeGroup(from: bundle),
                     "Should return nil when neither env var nor Info.plist key is set")
    }

    func testResolveMergeGroup_MainBundle_ReturnsNil() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RP_MERGE_GROUP"] != nil,
                      "RP_MERGE_GROUP env var is set; env-var path tested on SauceLabs real devices")
        XCTAssertNil(RPListener.resolveMergeGroup(from: Bundle.main))
    }

    func testResolveMergeGroup_NilBundle_ReturnsNil() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RP_MERGE_GROUP"] != nil,
                      "RP_MERGE_GROUP env var is set; env-var path tested on SauceLabs real devices")
        XCTAssertNil(RPListener.resolveMergeGroup(from: nil))
    }

    // MARK: - resolveSkipFinish

    func testResolveSkipFinish_NoPlistKey_ReturnsFalse() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RP_SKIP_FINISH"] != nil,
                      "RP_SKIP_FINISH env var is set; env-var path tested on SauceLabs real devices")
        let bundle = Bundle(for: type(of: self))
        XCTAssertFalse(RPListener.resolveSkipFinish(from: bundle),
                       "Should return false when neither env var nor Info.plist key is set")
    }

    func testResolveSkipFinish_NilBundle_ReturnsFalse() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RP_SKIP_FINISH"] != nil,
                      "RP_SKIP_FINISH env var is set; env-var path tested on SauceLabs real devices")
        XCTAssertFalse(RPListener.resolveSkipFinish(from: nil), "Should return false when bundle is nil")
    }

    func testResolveSkipFinish_MainBundle_ReturnsFalse() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RP_SKIP_FINISH"] != nil,
                      "RP_SKIP_FINISH env var is set; env-var path tested on SauceLabs real devices")
        XCTAssertFalse(RPListener.resolveSkipFinish(from: Bundle.main),
                       "Should return false for main bundle without plist key")
    }

    // MARK: - parseBoolFlag (String/Bool tolerance — the core of the skipFinish fix)

    func testParseBoolFlag_TruthyStrings() {
        for value in ["true", "TRUE", "Yes", "yes", "1", " true "] {
            XCTAssertEqual(RPListener.parseBoolFlag(value), true, "\"\(value)\" should parse as true")
        }
    }

    func testParseBoolFlag_FalsyStrings() {
        // The regression this guards: "false"/"no"/"0" must NOT be treated as true.
        for value in ["false", "FALSE", "No", "no", "0", " false "] {
            XCTAssertEqual(RPListener.parseBoolFlag(value), false, "\"\(value)\" should parse as false")
        }
    }

    func testParseBoolFlag_BoolValues() {
        XCTAssertEqual(RPListener.parseBoolFlag(true), true)
        XCTAssertEqual(RPListener.parseBoolFlag(false), false)
    }

    func testParseBoolFlag_UnrecognizedReturnsNil() {
        XCTAssertNil(RPListener.parseBoolFlag("maybe"))
        XCTAssertNil(RPListener.parseBoolFlag(""))
        XCTAssertNil(RPListener.parseBoolFlag(nil))
    }
}

// MARK: - finalizeLaunch 409-only Non-Fatal Tests

/// Verifies the predicate that `ReportingService.finalizeLaunch` uses: only HTTP 409
/// (launch already finished) is non-fatal; every other HTTP status and every non-HTTP
/// error is fatal and must propagate.
final class IdempotentFinalizeLaunchTests: XCTestCase {

    func testHTTPClientError_409_IsNonFatal() {
        XCTAssertTrue(HTTPClientError.httpError(statusCode: 409, body: "already finished").isLaunchAlreadyFinished,
                      "409 is the only non-fatal finalize status")
    }

    func testHTTPClientError_OtherClientErrors_AreFatal() {
        for code in [400, 401, 403, 404, 422] {
            XCTAssertFalse(HTTPClientError.httpError(statusCode: code, body: "error").isLaunchAlreadyFinished,
                           "Status \(code) must be fatal (only 409 is non-fatal)")
        }
    }

    func testHTTPClientError_5xx_AreFatal() {
        for code in [500, 502, 503] {
            XCTAssertFalse(HTTPClientError.httpError(statusCode: code, body: "server error").isLaunchAlreadyFinished,
                           "Status \(code) must be fatal")
        }
    }

    func testHTTPClientError_NetworkError_IsFatal() {
        XCTAssertFalse(HTTPClientError.networkError(NSError(domain: "test", code: -1)).isLaunchAlreadyFinished,
                       "Network errors must propagate")
    }

    func testHTTPClientError_DecodingError_IsFatal() {
        XCTAssertFalse(HTTPClientError.decodingError("bad json").isLaunchAlreadyFinished,
                       "Decoding errors must propagate")
    }
}
