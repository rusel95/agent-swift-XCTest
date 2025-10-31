//
//  FileLogger.swift
//  ReportPortalAgent
//
//  Created for parallel execution coordination debugging
//  Copyright © 2025 ReportPortal. All rights reserved.
//

import Foundation

/// Centralized file logger for coordination events across parallel workers
/// Writes coordination events to /tmp/reportportal_coordination/events_{pgid}.log in JSON Lines format
/// Thread-safe for concurrent writes from multiple workers
actor FileLogger {

    static let shared = FileLogger()

    private init() {
        // Initialize process info
        let pid = getpid()
        let pgid = getpgid(getpid())
        self.processID = pid
        self.processGroupID = pgid
        self.workerID = UUID().uuidString

        // Get device info
        #if targetEnvironment(simulator)
        if let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] {
            self.deviceInfo = deviceName
        } else {
            self.deviceInfo = "Unknown Device"
        }
        #else
        self.deviceInfo = "Physical Device"
        #endif

        // Setup log file
        setupLogFile()
    }

    // MARK: - Configuration

    /// Log file location - coordination directory shared across simulators
    /// Path: /tmp/reportportal_coordination/events_{pgid}.log
    private nonisolated var logFilePath: URL {
        let coordinationDir = URL(fileURLWithPath: "/tmp/reportportal_coordination")
        return coordinationDir.appendingPathComponent("events_\(getpgid(getpid())).log")
    }

    /// Unique worker identifier
    private let workerID: String

    /// Process ID
    private let processID: pid_t

    /// Process group ID
    private let processGroupID: pid_t

    /// Device/simulator identifier
    private let deviceInfo: String

    // MARK: - Setup

    private nonisolated func setupLogFile() {
        do {
            let fileManager = FileManager.default
            let coordinationDir = logFilePath.deletingLastPathComponent()

            // Ensure coordination directory exists
            if !fileManager.fileExists(atPath: coordinationDir.path) {
                try fileManager.createDirectory(at: coordinationDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            }

            // Create log file if doesn't exist
            if !fileManager.fileExists(atPath: logFilePath.path) {
                fileManager.createFile(atPath: logFilePath.path, contents: nil, attributes: [.posixPermissions: 0o644])
            }

            print("📁 FileLogger initialized: \(logFilePath.path) (Worker: \(workerID), PGID: \(getpgid(getpid())))")

        } catch {
            print("⚠️ FileLogger failed to setup: \(error.localizedDescription)")
        }
    }

    // MARK: - JSON Lines Logging

    /// Log a coordination event in JSON Lines format
    /// - Parameters:
    ///   - message: Event message
    ///   - type: Event type (Launch, Worker, Session, Error)
    ///   - event: Event name (e.g., PRIMARY_LOCK_ACQUIRED, LAUNCH_CREATED)
    ///   - launchID: Optional Launch ID
    ///   - additionalFields: Additional fields to include in JSON
    func logCoordinationEvent(
        _ message: String,
        type: EventType,
        event: String,
        launchID: String? = nil,
        additionalFields: [String: Any] = [:]
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())

        var json: [String: Any] = [
            "timestamp": timestamp,
            "type": type.rawValue,
            "event": event,
            "workerID": workerID,
            "processID": processID,
            "processGroupID": processGroupID,
            "device": deviceInfo,
            "message": message
        ]

        // Add optional launchID
        if let launchID = launchID {
            json["launchID"] = launchID
        }

        // Merge additional fields
        for (key, value) in additionalFields {
            json[key] = value
        }

        // Convert to JSON string
        if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            writeToLogFile(jsonString + "\n")
        }
    }

    /// Thread-safe write to log file (handles multiple workers writing to same file)
    private nonisolated func writeToLogFile(_ content: String) {
        guard let data = content.data(using: .utf8) else { return }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?

        coordinator.coordinate(writingItemAt: logFilePath, options: .forMerging, error: &error) { url in
            do {
                // Ensure coordination directory exists
                let parentDir = url.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                }

                // Append to existing file
                if FileManager.default.fileExists(atPath: url.path) {
                    let fileHandle = try FileHandle(forWritingTo: url)
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    try fileHandle.close()
                } else {
                    // File doesn't exist, create it
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                print("⚠️ FileLogger write failed: \(error.localizedDescription)")
            }
        }

        if let error = error {
            print("⚠️ FileLogger coordination failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Convenience Methods

    /// Log SESSION_STARTED event
    func logSessionStarted(sessionID: String, launchName: String) {
        logCoordinationEvent(
            "Coordination session started",
            type: .session,
            event: "SESSION_STARTED",
            additionalFields: ["sessionID": sessionID, "launchName": launchName]
        )
    }

    /// Log WORKER_REGISTERED event
    func logWorkerRegistered() {
        logCoordinationEvent(
            "Worker registered with session",
            type: .worker,
            event: "WORKER_REGISTERED"
        )
    }

    /// Log PRIMARY_LOCK_ACQUIRED event
    func logPrimaryLockAcquired(lockFile: String) {
        logCoordinationEvent(
            "Primary worker obtained main lock",
            type: .launch,
            event: "PRIMARY_LOCK_ACQUIRED",
            additionalFields: ["lockFile": lockFile]
        )
    }

    /// Log LAUNCH_CREATED event
    func logLaunchCreated(launchID: String, launchName: String) {
        logCoordinationEvent(
            "Launch created on ReportPortal",
            type: .launch,
            event: "LAUNCH_CREATED",
            launchID: launchID,
            additionalFields: ["launchName": launchName]
        )
    }

    /// Log LAUNCH_ID_WRITTEN event
    func logLaunchIDWritten(launchID: String, syncFile: String) {
        logCoordinationEvent(
            "Launch ID written to sync file",
            type: .launch,
            event: "LAUNCH_ID_WRITTEN",
            launchID: launchID,
            additionalFields: ["syncFile": syncFile]
        )
    }

    /// Log SECONDARY_JOINED event
    func logSecondaryJoined(launchID: String) {
        logCoordinationEvent(
            "Secondary worker joined with shared Launch ID",
            type: .launch,
            event: "SECONDARY_JOINED",
            launchID: launchID
        )
    }

    /// Log LAUNCH_ID_READ event
    func logLaunchIDRead(launchID: String, syncFile: String) {
        logCoordinationEvent(
            "Secondary worker read Launch ID from sync file",
            type: .launch,
            event: "LAUNCH_ID_READ",
            launchID: launchID,
            additionalFields: ["syncFile": syncFile]
        )
    }

    /// Log WORKER_COMPLETED event
    func logWorkerCompleted(testCount: Int) {
        logCoordinationEvent(
            "Worker finished all tests",
            type: .worker,
            event: "WORKER_COMPLETED",
            additionalFields: ["testCount": testCount]
        )
    }

    /// Log LAUNCH_FINALIZED event
    func logLaunchFinalized(launchID: String, totalTests: Int) {
        logCoordinationEvent(
            "Launch finalized on ReportPortal",
            type: .launch,
            event: "LAUNCH_FINALIZED",
            launchID: launchID,
            additionalFields: ["totalTests": totalTests]
        )
    }

    /// Log COORDINATION_ERROR event
    func logCoordinationError(errorType: String, errorMessage: String, details: [String: Any] = [:]) {
        var fields = details
        fields["errorType"] = errorType
        fields["errorMessage"] = errorMessage

        logCoordinationEvent(
            "Coordination failure: \(errorType)",
            type: .error,
            event: "COORDINATION_ERROR",
            additionalFields: fields
        )
    }

    /// Log CLEANUP_STARTED event
    func logCleanupStarted(sessionID: String) {
        logCoordinationEvent(
            "Cleanup of coordination files started",
            type: .session,
            event: "CLEANUP_STARTED",
            additionalFields: ["sessionID": sessionID]
        )
    }

    /// Log CLEANUP_COMPLETED event
    func logCleanupCompleted(filesRemoved: [String]) {
        logCoordinationEvent(
            "Cleanup successful",
            type: .session,
            event: "CLEANUP_COMPLETED",
            additionalFields: ["filesRemoved": filesRemoved]
        )
    }

    // MARK: - Backward Compatibility (General Logging)

    /// Log a general message (backward compatibility with old FileLogger)
    func log(_ message: String, level: LogLevel = .info, context: String? = nil) {
        // For coordination-focused logging, we just print to console
        // The coordination events use the JSON Lines format above
        let contextStr = context.map { "[\($0)]" } ?? ""
        print("[\(level.rawValue)]\(contextStr) \(message)")
    }

    /// Log separator (backward compatibility)
    func logSeparator(_ title: String? = nil) {
        if let title = title {
            print("━━━━━━━━━━━━━━━━━━━━━━ \(title) ━━━━━━━━━━━━━━━━━━━━━━")
        } else {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        }
    }

    /// Log launch event (backward compatibility)
    func logLaunchEvent(_ event: String, launchID: String? = nil) {
        let details = launchID.map { " (ID: \($0))" } ?? ""
        log("🚀 LAUNCH: \(event)\(details)", level: .info, context: "Launch")
    }

    /// Log suite event (backward compatibility)
    func logSuiteEvent(_ event: String, suiteName: String, suiteID: String? = nil, correlationID: UUID? = nil) {
        let details = suiteID.map { " (ID: \($0))" } ?? ""
        log("📦 SUITE: \(event) - \(suiteName)\(details)", level: .info, context: "Suite")
    }

    /// Log test event (backward compatibility)
    func logTestEvent(_ event: String, testName: String, testID: String? = nil, correlationID: UUID? = nil) {
        let details = testID.map { " (ID: \($0))" } ?? ""
        log("🧪 TEST: \(event) - \(testName)\(details)", level: .info, context: "Test")
    }

    /// Log error (backward compatibility)
    func logError(_ error: Error, context: String, details: [String: String] = [:]) {
        var message = "Error: \(error.localizedDescription)"
        if !details.isEmpty {
            let detailsStr = details.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            message += " | Details: \(detailsStr)"
        }
        log(message, level: .error, context: context)
    }

    // MARK: - Helper Types

    enum EventType: String {
        case launch = "Launch"
        case worker = "Worker"
        case session = "Session"
        case error = "Error"
    }

    enum LogLevel: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }
}

// MARK: - Global Helper Functions

/// Log coordination event to file (convenience wrapper)
func fileLog(
    _ message: String,
    type: FileLogger.EventType,
    event: String,
    launchID: String? = nil,
    additionalFields: [String: Any] = [:]
) {
    Task {
        await FileLogger.shared.logCoordinationEvent(
            message,
            type: type,
            event: event,
            launchID: launchID,
            additionalFields: additionalFields
        )
    }
}
