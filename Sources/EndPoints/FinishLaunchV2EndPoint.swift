//
//  FinishLaunchV2EndPoint.swift
//  ReportPortalAgent
//
//  Created for parallel execution support
//  Copyright © 2025 ReportPortal. All rights reserved.
//

import Foundation

/// ReportPortal v2 async API endpoint for Launch finalization
/// Used for parallel test execution to finish shared Launch
///
/// API: PUT /v2/{projectName}/launch/{launchId}/finish
struct FinishLaunchV2EndPoint: EndPoint {

    let method: HTTPMethod = .put
    let relativePath: String
    let parameters: [String : Any]

    /// Initialize v2 Launch finish endpoint
    ///
    /// - Parameters:
    ///   - projectName: ReportPortal project name
    ///   - launchID: Launch ID to finish
    ///   - status: Final launch status
    init(projectName: String, launchID: String, status: TestStatus) {
        // V2 API path: /v2/{projectName}/launch/{launchId}/finish
        self.relativePath = "v2/\(projectName)/launch/\(launchID)/finish"

        // V2 API uses camelCase (not snake_case like v1)
        self.parameters = [
            "endTime": TimeHelper.currentTimeAsString(),
            "status": status.rawValue
        ]
    }
}
