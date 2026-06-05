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

final class SauceLabsValidationTest: XCTestCase {
    func testEnvironmentVariableInjection() {
        let envVars = ["RP_VALIDATION_TOKEN", "RP_LAUNCH_UUID", "RP_MERGE_GROUP", "RP_SKIP_FINISH"]
        var results: [String: String] = [:]
        for key in envVars {
            let value = ProcessInfo.processInfo.environment[key] ?? "<NOT SET>"
            results[key] = value
            print("🔍 ENV[\(key)] = \(value)")
        }
        let resultString = results.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        let attachment = XCTAttachment(string: resultString)
        attachment.name = "environment_variables"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Test passes regardless — collecting data, not asserting
    }
}
