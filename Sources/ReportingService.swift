//
//  ReportingService.swift
//  ReportPortalAgent
//
//  Created by Ruslan Popesku on 10/22/25.
//  Copyright © 2025 ReportPortal. All rights reserved.
//

import Foundation
@preconcurrency import XCTest

/// Async/await API for ReportPortal communication (stateless)
/// Uses LaunchManager and OperationTracker for state management
public final class ReportingService: Sendable {

    // MARK: - Properties

    private let httpClient: HTTPClient
    private let httpClientV2: HTTPClient  // v2 API client with corrected base URL
    private let configuration: AgentConfiguration
    private let launchManager: LaunchManager
    private let operationTracker: OperationTracker

    // MARK: - Initialization

    init(
        configuration: AgentConfiguration,
        httpClient: HTTPClient? = nil,
        launchManager: LaunchManager = LaunchManager.shared,
        operationTracker: OperationTracker = OperationTracker.shared
    ) {
        self.configuration = configuration
        self.launchManager = launchManager
        self.operationTracker = operationTracker

        let authPlugin = AuthorizationPlugin(token: configuration.portalToken)

        // If httpClient is provided (for testing), use it for v1 API
        if let client = httpClient {
            self.httpClient = client
        } else {
            // Create v1 client: /api/v1/{projectName}
            let baseURL = configuration.reportPortalURL.appendingPathComponent(configuration.projectName)
            self.httpClient = HTTPClient(baseURL: baseURL, plugins: [authPlugin])
        }

        // Always create v2 client from configuration (for both production and test)
        // Replace /v1 with /v2 in reportPortalURL
        let v2URLString = configuration.reportPortalURL.absoluteString.replacingOccurrences(of: "/v1", with: "/v2")
        guard let v2URL = URL(string: v2URLString) else {
            fatalError("Failed to construct v2 API URL from: \(configuration.reportPortalURL)")
        }
        let baseURLV2 = v2URL.appendingPathComponent(configuration.projectName)
        self.httpClientV2 = HTTPClient(baseURL: baseURLV2, plugins: [authPlugin])
    }

    // MARK: - Launch Management

    /// Create new launch in ReportPortal (v1 API)
    /// - Parameters:
    ///   - name: Launch name (may include test plan name)
    ///   - tags: Tags from configuration
    ///   - attributes: Metadata (device info, OS version, etc.)
    /// - Returns: Launch ID (UUID string from ReportPortal)
    func startLaunch(name: String, tags: [String], attributes: [[String: String]]) async throws -> String {
        let endPoint = StartLaunchEndPoint(
            launchName: name,
            tags: tags,
            mode: configuration.launchMode,
            attributes: attributes
        )

        let result: FirstLaunch = try await httpClient.callEndPoint(endPoint)

        Logger.shared.info("Launch created (v1): \(result.id)")
        return result.id
    }

    /// Create new launch in ReportPortal (v2 async API)
    /// Used for parallel test execution with UUID coordination
    /// - Parameters:
    ///   - name: Launch name (may include test plan name)
    ///   - uuid: Optional custom UUID for coordination (if nil, server generates one)
    ///   - tags: Tags from configuration
    ///   - attributes: Metadata (device info, OS version, etc.)
    /// - Returns: Launch ID (UUID string from ReportPortal)
    func startLaunchV2(name: String, uuid: String? = nil, tags: [String], attributes: [[String: String]]) async throws -> String {
        let endPoint = StartLaunchV2EndPoint(
            launchName: name,
            uuid: uuid,
            tags: tags,
            mode: configuration.launchMode,
            attributes: attributes
        )

        do {
            let result: LaunchV2Response = try await httpClientV2.callEndPoint(endPoint)
            print("✅ [ReportPortal] Launch created successfully - ID: \(result.id)")
            Logger.shared.info("✅ Launch created successfully (v2) - Launch ID: \(result.id), UUID: \(uuid ?? "server-generated")")
            return result.id
        } catch let error as HTTPClientError {
            // Handle 409 Conflict - launch already exists (expected in parallel mode)
            if case .httpError(let statusCode, let body) = error, statusCode == 409 {
                print("⚡️ [ReportPortal] 409 Conflict - Worker joining existing launch")
                Logger.shared.info("⚡️ 409 Conflict - Launch already exists (UUID: \(uuid ?? "none")). Worker joining existing launch...")

                // Try to extract launch ID from error response
                if let body = body, let data = body.data(using: .utf8) {
                    Logger.shared.debug("409 Response body: \(body)")
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let launchID = json["id"] as? String {
                        print("✅ [ReportPortal] Extracted launch ID from 409 response: \(launchID)")
                        Logger.shared.info("✅ Extracted launch ID from 409 response: \(launchID)")
                        return launchID
                    }
                }

                // Fallback: use the provided UUID
                if let uuid = uuid {
                    print("⚠️ [ReportPortal] Using UUID as launch ID: \(uuid)")
                    Logger.shared.info("⚠️ Could not extract ID from 409 response, using provided UUID as launch ID: \(uuid)")
                    return uuid
                }

                // Last resort: throw the original error if we can't determine the launch ID
                print("❌ [ReportPortal] 409 Conflict but cannot determine launch ID")
                Logger.shared.error("❌ 409 Conflict but cannot determine launch ID (no ID in response, no UUID provided)")
                throw error
            }

            // Re-throw other HTTP errors
            if case .httpError(let statusCode, _) = error {
                Logger.shared.error("❌ HTTP error \(statusCode) during launch creation")
            } else {
                Logger.shared.error("❌ Network error during launch creation: \(error)")
            }
            throw error
        }
    }

    /// Finish launch in ReportPortal (v1 API)
    /// - Parameters:
    ///   - launchID: Launch ID from LaunchManager
    ///   - status: Aggregated status from LaunchManager
    func finalizeLaunch(launchID: String, status: TestStatus) async throws {
        let endPoint = FinishLaunchEndPoint(launchID: launchID, status: status)

        let _: LaunchFinish = try await httpClient.callEndPoint(endPoint)

        // Mark as finalized in LaunchManager
        await launchManager.markFinalized()

        Logger.shared.info("Launch finalized (v1): \(launchID) with status: \(status.rawValue)")
    }

    /// Finish launch in ReportPortal (v2 async API)
    /// Used for parallel test execution with file-based finish coordination (single finish call)
    /// - Parameters:
    ///   - launchID: Launch ID from LaunchManager
    ///   - status: Worker's local status
    ///   - coordinator: Optional FinishCoordinator for parallel coordination (simulators only)
    ///   - tracker: Optional WorkerTracker for last-worker detection (simulators only)
    ///   - uuid: Launch UUID for coordination
    ///   - workerID: Current worker identifier
    func finalizeLaunchV2(
        launchID: String,
        status: TestStatus,
        coordinator: FinishCoordinator? = nil,
        tracker: WorkerTracker? = nil,
        uuid: String? = nil,
        workerID: String? = nil
    ) async throws {
        Logger.shared.info("Attempting to finalize launch: \(launchID) with status: \(status.rawValue)")

        // If coordinator is provided, use file-based coordination (simulator mode)
        if let coordinator = coordinator,
           let tracker = tracker,
           let uuid = uuid,
           let workerID = workerID {
            
            // Record this worker's status
            try await coordinator.recordStatus(uuid: uuid, workerID: workerID, status: status)
            
            // Check if we should finish the launch (last worker)
            let (shouldFinish, aggregatedStatus) = try await coordinator.shouldFinishLaunch(
                uuid: uuid,
                workerID: workerID,
                workerTracker: tracker
            )
            
            guard shouldFinish, let finalStatus = aggregatedStatus else {
                Logger.shared.info("⚡️ Not last worker - skipping finish API call. Another worker will finish the launch.")
                
                // Mark as finalized locally even though we didn't make the API call
                await launchManager.markFinalized()
                return
            }
            
            // Last worker makes the API call with aggregated status
            Logger.shared.info("✅ Last worker detected - finishing launch with aggregated status: \(finalStatus.rawValue)")
            
            let endPoint = FinishLaunchV2EndPoint(
                launchID: launchID,
                status: finalStatus
            )
            
            let _: LaunchFinish = try await httpClientV2.callEndPoint(endPoint)
            
            // Mark as finalized in LaunchManager
            await launchManager.markFinalized()
            
            // Cleanup coordination files
            await coordinator.cleanupStatusFiles(uuid: uuid)
            
            Logger.shared.info("✅ Launch finalized successfully (v2): \(launchID) with status: \(finalStatus.rawValue)")
        } else {
            // No coordinator - direct API call (backward compatibility or real devices)
            let endPoint = FinishLaunchV2EndPoint(
                launchID: launchID,
                status: status
            )
            
            let _: LaunchFinish = try await httpClientV2.callEndPoint(endPoint)
            
            // Mark as finalized in LaunchManager
            await launchManager.markFinalized()
            
            Logger.shared.info("✅ Launch finalized successfully (v2 - direct): \(launchID) with status: \(status.rawValue)")
        }
    }

    // MARK: - Suite Management

    /// Create suite item in ReportPortal with optional coordination
    /// - Parameters:
    ///   - operation: SuiteOperation with metadata
    ///   - launchID: Parent launch ID
    ///   - coordinator: Optional SuiteCoordinator for file-based deduplication
    /// - Returns: Suite item ID (UUID string)
    func startSuite(operation: SuiteOperation, launchID: String, coordinator: SuiteCoordinator? = nil) async throws -> String {
        // If coordinator provided, use file-based coordination
        if let coordinator = coordinator {
            Logger.shared.debug("Using suite coordinator for '\(operation.suiteName)'", correlationID: operation.correlationID)
            
            return try await coordinator.getOrCreateSuite(
                name: operation.suiteName,
                launchID: launchID
            ) {
                // This closure is called only if suite doesn't exist yet
                Logger.shared.info("Creating suite via API (first worker): '\(operation.suiteName)'", correlationID: operation.correlationID)
                return try await self.createSuiteDirectly(operation: operation, launchID: launchID)
            }
        }
        
        // No coordinator, create suite directly (real devices or backward compat)
        Logger.shared.debug("Creating suite directly (no coordination): '\(operation.suiteName)'", correlationID: operation.correlationID)
        return try await createSuiteDirectly(operation: operation, launchID: launchID)
    }
    
    /// Create suite via ReportPortal API (internal helper)
    private func createSuiteDirectly(operation: SuiteOperation, launchID: String) async throws -> String {
        let endPoint: StartItemEndPoint

        if let rootSuiteID = operation.rootSuiteID {
            // This is a test class suite (child of root suite)
            // It should be .suite, not .test (test classes are suites, not individual tests)
            endPoint = StartItemEndPoint(
                itemName: operation.suiteName,
                parentID: rootSuiteID,
                launchID: launchID,
                type: .suite  // Fixed: was .test, should be .suite
            )
        } else {
            // This is a root suite (bundle)
            endPoint = StartItemEndPoint(
                itemName: operation.suiteName,
                launchID: launchID,
                type: .suite
            )
        }

        let result: Item = try await httpClient.callEndPoint(endPoint)

        Logger.shared.info("Suite started: \(result.id)", correlationID: operation.correlationID)
        return result.id
    }

    /// Finish suite item in ReportPortal
    /// - Parameter operation: SuiteOperation with suite ID and final status
    func finishSuite(operation: SuiteOperation) async throws {
        guard let launchID = await launchManager.getLaunchID() else {
            throw ReportingServiceError.launchIdNotFound
        }

        let endPoint = try FinishItemEndPoint(
            itemID: operation.suiteID,
            status: operation.status,
            launchID: launchID
        )

        let _: Finish = try await httpClient.callEndPoint(endPoint)

        Logger.shared.info("Suite finished: \(operation.suiteID)", correlationID: operation.correlationID)
    }

    // MARK: - Test Management

    /// Create test item in ReportPortal
    /// - Parameters:
    ///   - operation: TestOperation with metadata
    ///   - launchID: Parent launch ID
    /// - Returns: Test item ID (UUID string)
    func startTest(operation: TestOperation, launchID: String) async throws -> String {
        let endPoint = StartItemEndPoint(
            itemName: operation.testName,
            parentID: operation.suiteID,
            launchID: launchID,
            type: .step
        )

        let result: Item = try await httpClient.callEndPoint(endPoint)

        Logger.shared.info("Test started: \(result.id)", correlationID: operation.correlationID)
        return result.id
    }

    /// Finish test item in ReportPortal
    /// - Parameter operation: TestOperation with test ID and final status
    func finishTest(operation: TestOperation) async throws {
        guard let launchID = await launchManager.getLaunchID() else {
            throw ReportingServiceError.launchIdNotFound
        }

        let endPoint = try FinishItemEndPoint(
            itemID: operation.testID,
            status: operation.status,
            launchID: launchID
        )

        let _: Finish = try await httpClient.callEndPoint(endPoint)

        // Update aggregated status in LaunchManager
        await launchManager.updateStatus(operation.status)

        Logger.shared.info("Test finished: \(operation.testID) with status: \(operation.status.rawValue)", correlationID: operation.correlationID)
    }

    // MARK: - Logging & Attachments

    /// Send log entry to ReportPortal
    /// - Parameters:
    ///   - message: Log message text
    ///   - level: Log level (info, warn, error, etc.)
    ///   - itemID: Test or suite item ID
    ///   - launchID: Launch ID
    ///   - correlationID: Optional correlation ID for tracing
    func postLog(
        message: String,
        level: String = "info",
        itemID: String,
        launchID: String,
        correlationID: UUID? = nil
    ) async throws {
        let endPoint = PostLogEndPoint(
            itemUuid: itemID,
            launchUuid: launchID,
            level: level,
            message: message,
            attachments: []
        )

        let _: LogResponse = try await httpClient.callEndPoint(endPoint)

        Logger.shared.debug("Log posted to item: \(itemID)", correlationID: correlationID)
    }

    /// Post attachments to ReportPortal (async, non-blocking)
    /// - Parameters:
    ///   - attachments: Array of XCTAttachment from test
    ///   - itemID: Test item ID to attach to
    ///   - launchID: Launch ID
    ///   - correlationID: Optional correlation ID for tracing
    /// Post screenshot directly to ReportPortal (simpler than postAttachments)
    func postScreenshot(
        screenshotData: Data,
        filename: String,
        itemID: String,
        launchID: String,
        correlationID: UUID? = nil
    ) async throws {
        let fileAttachment = FileAttachment(
            data: screenshotData,
            filename: filename,
            mimeType: "image/png",
            fieldName: "binary_part"
        )

        let endPoint = PostLogEndPoint(
            itemUuid: itemID,
            launchUuid: launchID,
            level: "info",
            message: "Failure screenshot",
            attachments: [fileAttachment]
        )

        let _: LogResponse = try await httpClient.callEndPoint(endPoint)

        Logger.shared.debug("Posted screenshot: \(filename)", correlationID: correlationID)
    }

    func postAttachments(
        attachments: [XCTAttachment],
        itemID: String,
        launchID: String,
        correlationID: UUID? = nil
    ) async throws {
        guard !attachments.isEmpty else {
            Logger.shared.debug("No attachments to upload", correlationID: correlationID)
            return
        }

        var fileAttachments: [FileAttachment] = []

        // Extract attachment data
        for (index, attachment) in attachments.enumerated() {
            // Generate safe filename from attachment name or use timestamp
            let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
            let baseName = attachment.name ?? "attachment_\(index)"
            let sanitizedName = baseName.replacingOccurrences(of: " ", with: "_")

            // Determine MIME type and extension based on uniformTypeIdentifier
            let uti = attachment.uniformTypeIdentifier
            let fileExtension: String
            let mimeType: String

            // Common attachment types
            if uti.contains("image") || uti.contains("png") {
                fileExtension = "png"
                mimeType = "image/png"
            } else if uti.contains("jpeg") || uti.contains("jpg") {
                fileExtension = "jpg"
                mimeType = "image/jpeg"
            } else if uti.contains("text") {
                fileExtension = "txt"
                mimeType = "text/plain"
            } else if uti.contains("json") {
                fileExtension = "json"
                mimeType = "application/json"
            } else if uti.contains("xml") {
                fileExtension = "xml"
                mimeType = "application/xml"
            } else {
                fileExtension = "bin"
                mimeType = "application/octet-stream"
            }

            // Build filename with timestamp and extension
            let filename = "\(sanitizedName)_\(timestamp).\(fileExtension)"

            // Extract data from XCTAttachment
            // For screenshots created with XCTAttachment(screenshot:), extract PNG data
            var data: Data? = nil

            // Try to get screenshot data if available
            if uti.contains("image") {
                // For screenshot attachments, try getting the XCUIScreenshot directly
                if let screenshot = attachment.value(forKey: "screenshot") as? XCUIScreenshot {
                    data = screenshot.pngRepresentation
                } else if let image = attachment.value(forKey: "image") as? XCUIScreenshot {
                    data = image.pngRepresentation
                }
            }

            // Fallback: try to get attachment contents using lifetime accessor
            if data == nil {
                // Try userInfo which might contain the data
                if let userInfo = attachment.value(forKey: "userInfo") as? [String: Any],
                   let payloadData = userInfo["data"] as? Data {
                    data = payloadData
                }
            }

            guard let attachmentData = data else {
                Logger.shared.warning("Could not extract data from attachment: \(attachment.name ?? "unknown"), UTI: \(uti)", correlationID: correlationID)
                continue
            }

            // Create FileAttachment and add to array
            let fileAttachment = FileAttachment(
                data: attachmentData,
                filename: filename,
                mimeType: mimeType,
                fieldName: "binary_part"
            )
            fileAttachments.append(fileAttachment)
        }

        guard !fileAttachments.isEmpty else {
            Logger.shared.debug("No processable attachments after extraction", correlationID: correlationID)
            return
        }

        // Upload all attachments in a single API call
        let endPoint = PostLogEndPoint(
            itemUuid: itemID,
            launchUuid: launchID,
            level: "info",
            message: "Test attachments",
            attachments: fileAttachments
        )

        let _: LogResponse = try await httpClient.callEndPoint(endPoint)

        Logger.shared.info("Uploaded \(fileAttachments.count) attachments to item: \(itemID)", correlationID: correlationID)
    }
}
