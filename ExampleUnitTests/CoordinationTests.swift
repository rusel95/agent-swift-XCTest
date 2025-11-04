//
//  CoordinationTests.swift
//  ExampleUnitTests
//
//  Created for ReportPortal Agent v4.0 - UUID Coordination
//  Copyright © 2025 ReportPortal. All rights reserved.
//

import XCTest
@testable import ReportPortalAgent

/// Unit tests for UUID-based coordination
/// Tests 409 Conflict and 404 Not Found handling in parallel execution
final class CoordinationTests: XCTestCase {

    // MARK: - Test Configuration

    var mockConfiguration: AgentConfiguration!

    override func setUp() async throws {
        // Create mock configuration for testing
        mockConfiguration = AgentConfiguration(
            reportPortalURL: URL(string: "https://reportportal.example.com/api/v1/")!,
            projectName: "test-project",
            launchName: "Test Launch",
            shouldSendReport: true,
            portalToken: "test-token",
            tags: [],
            shouldFinishLaunch: true,
            launchMode: .default,
            testNameRules: []
        )
    }

    // MARK: - 409 Conflict Handling Tests (T011)

    func testStartLaunchV2_Handles409Conflict_ExtractsLaunchID() async throws {
        // Given: Mock HTTP client that returns 409 with launch ID in body
        let mock409Response = """
        {
            "error_code": 4091,
            "message": "Launch with UUID 'TestLaunch_1234567890_999' already exists",
            "id": "existing-launch-uuid-123"
        }
        """

        let mockClient = Mock409HTTPClient(
            responseBody: mock409Response,
            statusCode: 409
        )

        let service = ReportingService(
            configuration: mockConfiguration,
            httpClient: mockClient
        )

        // When: Try to start launch with UUID that already exists
        let launchID = try await service.startLaunchV2(
            name: "Test Launch",
            uuid: "TestLaunch_1234567890_999",
            tags: [],
            attributes: []
        )

        // Then: Should extract and return launch ID from 409 response
        XCTAssertEqual(launchID, "existing-launch-uuid-123", "Should extract launch ID from 409 response")
    }

    func testStartLaunchV2_Handles409Conflict_FallsBackToProvidedUUID() async throws {
        // Given: Mock HTTP client that returns 409 without id in body
        let mock409Response = """
        {
            "error_code": 4091,
            "message": "Launch already exists"
        }
        """

        let mockClient = Mock409HTTPClient(
            responseBody: mock409Response,
            statusCode: 409
        )

        let service = ReportingService(
            configuration: mockConfiguration,
            httpClient: mockClient
        )

        // When: Try to start launch with UUID that already exists
        let providedUUID = "TestLaunch_1234567890_888"
        let launchID = try await service.startLaunchV2(
            name: "Test Launch",
            uuid: providedUUID,
            tags: [],
            attributes: []
        )

        // Then: Should fall back to provided UUID
        XCTAssertEqual(launchID, providedUUID, "Should use provided UUID as fallback")
    }

    func testStartLaunchV2_Handles409Conflict_LogsInfo() async throws {
        // Given: Mock HTTP client that returns 409
        let mock409Response = """
        {
            "id": "existing-launch-123"
        }
        """

        let mockClient = Mock409HTTPClient(
            responseBody: mock409Response,
            statusCode: 409
        )

        let service = ReportingService(
            configuration: mockConfiguration,
            httpClient: mockClient
        )

        // When: Start launch that already exists
        _ = try await service.startLaunchV2(
            name: "Test Launch",
            uuid: "TestLaunch_1234567890_777",
            tags: [],
            attributes: []
        )

        // Then: Should NOT throw error (409 is expected and handled)
        // Test passes if no exception thrown
    }

    // MARK: - 404 Finish Handling Tests (T015)

    func testFinalizeLaunchV2_Handles404_NotFound() async throws {
        // Given: Mock HTTP client that returns 404
        let mockClient = Mock404HTTPClient(statusCode: 404)

        let service = ReportingService(
            configuration: mockConfiguration,
            httpClient: mockClient
        )

        // When: Try to finish launch that's already finished
        try await service.finalizeLaunchV2(
            launchID: "already-finished-launch",
            status: .passed
        )

        // Then: Should NOT throw error (404 means already finished by another worker)
        // Test passes if no exception thrown
    }

    func testFinalizeLaunchV2_Handles409_Conflict() async throws {
        // Given: Mock HTTP client that returns 409
        let mockClient = Mock404HTTPClient(statusCode: 409)

        let service = ReportingService(
            configuration: mockConfiguration,
            httpClient: mockClient
        )

        // When: Try to finish launch with conflict
        try await service.finalizeLaunchV2(
            launchID: "conflicted-launch",
            status: .failed
        )

        // Then: Should NOT throw error (409 is acceptable for finish)
        // Test passes if no exception thrown
    }

    func testFinalizeLaunchV2_ThrowsOtherErrors() async throws {
        // Given: Mock HTTP client that returns 500 (server error)
        let mockClient = Mock404HTTPClient(statusCode: 500)

        let service = ReportingService(
            configuration: mockConfiguration,
            httpClient: mockClient
        )

        // When/Then: Should throw error for non-404/409 status codes
        do {
            try await service.finalizeLaunchV2(
                launchID: "error-launch",
                status: .passed
            )
            XCTFail("Should throw error for 500 status code")
        } catch let error as HTTPClientError {
            if case .httpError(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 500, "Should propagate 500 error")
            } else {
                XCTFail("Wrong error type")
            }
        }
    }

    // MARK: - Integration: Full Coordination Flow

    func testFullCoordinationFlow_MultipleWorkers() async throws {
        // Simulate 3 workers trying to create and finish same launch

        // Worker 1: Creates launch successfully (200 OK)
        let successClient = MockSuccessHTTPClient()
        let service1 = ReportingService(
            configuration: mockConfiguration,
            httpClient: successClient
        )

        let uuid = "TestLaunch_\(Int(Date().timeIntervalSince1970))_999"

        let launchID1 = try await service1.startLaunchV2(
            name: "Test Launch",
            uuid: uuid,
            tags: [],
            attributes: []
        )
        XCTAssertFalse(launchID1.isEmpty, "Worker 1 should create launch")

        // Worker 2: Gets 409 Conflict (launch already exists)
        let conflict409Client = Mock409HTTPClient(
            responseBody: """
            {
                "id": "\(launchID1)"
            }
            """,
            statusCode: 409
        )
        let service2 = ReportingService(
            configuration: mockConfiguration,
            httpClient: conflict409Client
        )

        let launchID2 = try await service2.startLaunchV2(
            name: "Test Launch",
            uuid: uuid,
            tags: [],
            attributes: []
        )
        XCTAssertEqual(launchID2, launchID1, "Worker 2 should join existing launch")

        // Worker 3: Also gets 409 Conflict
        let launchID3 = try await service2.startLaunchV2(
            name: "Test Launch",
            uuid: uuid,
            tags: [],
            attributes: []
        )
        XCTAssertEqual(launchID3, launchID1, "Worker 3 should join existing launch")

        // Finish: Worker 1 finishes successfully
        try await service1.finalizeLaunchV2(launchID: launchID1, status: .passed)

        // Worker 2 and 3 get 404 (already finished)
        let finish404Client = Mock404HTTPClient(statusCode: 404)
        let finishService = ReportingService(
            configuration: mockConfiguration,
            httpClient: finish404Client
        )

        try await finishService.finalizeLaunchV2(launchID: launchID1, status: .passed)
        try await finishService.finalizeLaunchV2(launchID: launchID1, status: .passed)

        // Test passes if all finish calls succeed (no exceptions)
    }
}

// MARK: - Mock HTTP Clients

/// Mock HTTP client that always returns 409 Conflict
class Mock409HTTPClient: HTTPClient {
    let responseBody: String
    let statusCode: Int

    init(responseBody: String, statusCode: Int) {
        self.responseBody = responseBody
        self.statusCode = statusCode
        super.init(baseURL: URL(string: "https://example.com")!, plugins: [])
    }

    override func callEndPoint<T: Decodable>(_ endPoint: EndPoint) async throws -> T {
        // Throw HTTP error with specified status code
        throw HTTPClientError.httpError(statusCode: statusCode, body: responseBody)
    }
}

/// Mock HTTP client that always returns 404 or other status codes
class Mock404HTTPClient: HTTPClient {
    let statusCode: Int

    init(statusCode: Int) {
        self.statusCode = statusCode
        super.init(baseURL: URL(string: "https://example.com")!, plugins: [])
    }

    override func callEndPoint<T: Decodable>(_ endPoint: EndPoint) async throws -> T {
        throw HTTPClientError.httpError(statusCode: statusCode, body: nil)
    }
}

/// Mock HTTP client that returns success responses
class MockSuccessHTTPClient: HTTPClient {
    private var launchCounter = 0

    init() {
        super.init(baseURL: URL(string: "https://example.com")!, plugins: [])
    }

    override func callEndPoint<T: Decodable>(_ endPoint: EndPoint) async throws -> T {
        // Return mock success responses
        if endPoint.relativePath.contains("launch") && endPoint.method == .post {
            // Start launch - return LaunchV2Response
            launchCounter += 1
            let response = """
            {
                "id": "mock-launch-\(launchCounter)"
            }
            """
            let data = response.data(using: .utf8)!
            return try JSONDecoder().decode(T.self, from: data)
        } else if endPoint.method == .put {
            // Finish launch - return LaunchFinish
            let response = """
            {
                "message": "success"
            }
            """
            let data = response.data(using: .utf8)!
            return try JSONDecoder().decode(T.self, from: data)
        }

        throw HTTPClientError.decodingError("Unsupported endpoint")
    }
}
