//
//  StartLaunchV2EndPoint.swift
//  ReportPortalAgent
//
//  Created for parallel execution support
//  Copyright © 2025 ReportPortal. All rights reserved.
//

import Foundation

/// ReportPortal v2 async API endpoint for Launch creation
/// Used for parallel test execution with multi-launch merge strategy
///
/// API: POST /v2/{projectName}/launch
struct StartLaunchV2EndPoint: EndPoint {

    let method: HTTPMethod = .post
    let relativePath: String
    let parameters: [String : Any]

    /// Initialize v2 Launch creation endpoint
    ///
    /// - Parameters:
    ///   - launchName: Launch name
    ///   - tags: Tags for the launch
    ///   - mode: Launch mode (DEFAULT or DEBUG)
    ///   - attributes: Custom attributes
    ///   - description: Launch description
    ///
    /// Note: Project name is already in the baseURL from httpClientV2
    init(
        launchName: String,
        tags: [String] = [],
        mode: LaunchMode = .default,
        attributes: [[String: String]] = [],
        description: String = ""
    ) {
        // V2 API path: launch (baseURL already has /v2/{projectName})
        self.relativePath = "launch"

        // V2 API uses camelCase (not snake_case like v1)
        self.parameters = [
            "name": launchName,
            "description": description,
            "startTime": TimeHelper.currentTimeAsString(),
            "mode": mode.rawValue,
            "attributes": StartLaunchV2EndPoint.formatAttributes(tags: tags, customAttributes: attributes)
        ]
    }

    /// Format attributes for v2 API
    ///
    /// V2 API expects attributes as array of objects: [{"key": "tag", "value": "value"}]
    ///
    /// - Parameters:
    ///   - tags: Tags to include
    ///   - customAttributes: Custom attributes
    /// - Returns: Formatted attributes array
    private static func formatAttributes(tags: [String], customAttributes: [[String: String]]) -> [[String: String]] {
        var attributes: [[String: String]] = []

        // Add default tags
        for tag in (TagHelper.defaultTags + tags) {
            attributes.append(["key": "tag", "value": tag])
        }

        // Add custom attributes
        attributes.append(contentsOf: customAttributes)

        return attributes
    }
}
