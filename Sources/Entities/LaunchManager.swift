//
//  LaunchManager.swift
//  ReportPortalAgent
//
//  Created by Ruslan Popesku on 10/22/25.
//  Copyright © 2025 ReportPortal. All rights reserved.
//

import Foundation

/// Errors that can occur during launch management
enum LaunchManagerError: LocalizedError {
    case timeout(seconds: TimeInterval)
    case launchNotStarted
    case taskCancelled

    var errorDescription: String? {
        switch self {
        case .timeout(let seconds):
            return "Launch ID not available after \(seconds) seconds timeout"
        case .launchNotStarted:
            return "Launch creation has not been initiated yet"
        case .taskCancelled:
            return "Launch creation task was cancelled"
        }
    }
}

/// Thread-safe launch-level state management with reference counting.
/// Manages launch lifecycle across multiple concurrent test bundles.
actor LaunchManager {
    /// Shared singleton instance
    static let shared = LaunchManager()

    /// Private initializer ensures singleton pattern
    private init() {}

    // MARK: - Private State

    /// ReportPortal launch ID (shared across all bundles)
    private var launchID: String?

    /// Shared Task for launch creation (allows multiple bundles to await same operation)
    private var launchCreationTask: Task<String, Error>?

    /// Number of active test bundles (for reference counting)
    private var activeBundleCount: Int = 0

    /// Overall launch status (worst of all tests)
    private var aggregatedStatus: TestStatus = .passed

    /// Whether launch has been finalized
    private var isFinalized: Bool = false

    /// Launch start timestamp
    private var launchStartTime: Date?

    /// Cached launch UUID for coordination
    private var launchUUID: String?

    // MARK: - UUID Generation

    /// Get or create launch UUID with file-based coordination
    /// Priority 1: Use RP_LAUNCH_UUID environment variable if set
    /// Priority 2: Use file-based coordination to share UUID across workers (simulators only)
    /// - Returns: Launch UUID to use for this test run
    func getOrCreateLaunchUUID() -> String {
        // Return cached UUID if already created
        if let existingUUID = launchUUID {
            return existingUUID
        }

        // Priority 1: Check environment variable (explicit coordination)
        if let envUUID = ProcessInfo.processInfo.environment["RP_LAUNCH_UUID"],
           !envUUID.isEmpty {
            launchUUID = envUUID
            print("🌍 [ReportPortal] UUID from environment: \(envUUID)")
            Logger.shared.info("Using launch UUID from environment variable: \(envUUID)")
            return envUUID
        }

        // Priority 2: File-based UUID coordination (simulators only)
        // Similar to suite coordination - first worker creates UUID, others read it
        let pid = getpid()
        let pgid = getpgid(pid)
        print("⚙️ [ReportPortal] No RP_LAUNCH_UUID env var, using file-based UUID coordination (PID: \(pid), PGID: \(pgid))")
        Logger.shared.info("Using file-based UUID coordination (PID: \(pid), PGID: \(pgid))")

        let coordinatedUUID = getOrCreateCoordinatedUUID()
        launchUUID = coordinatedUUID
        print("🔧 [ReportPortal] Coordinated UUID: \(coordinatedUUID)")
        Logger.shared.info("Coordinated launch UUID: \(coordinatedUUID)")
        return coordinatedUUID
    }
    
    /// Get or create launch UUID using file-based coordination
    /// First worker generates UUID and writes to file, others read from file
    /// - Returns: Shared launch UUID for all workers
    private func getOrCreateCoordinatedUUID() -> String {
        let syncFilePath = "/tmp/reportportal/launch_uuid.txt"
        
        // Try to read existing UUID from file
        if let existingUUID = try? String(contentsOfFile: syncFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existingUUID.isEmpty {
            Logger.shared.info("📖 Read shared launch UUID from file: \(existingUUID)")
            return existingUUID
        }
        
        // No existing UUID - we're the first worker, generate and write
        let newUUID = UUID().uuidString
        
        // Create directory if needed
        let directory = (syncFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        
        // Write UUID to file (atomic write)
        do {
            try newUUID.write(toFile: syncFilePath, atomically: true, encoding: .utf8)
            Logger.shared.info("✍️ First worker - wrote launch UUID to file: \(newUUID)")
        } catch {
            Logger.shared.warning("⚠️ Failed to write launch UUID to file (will use generated UUID): \(error)")
        }
        
        return newUUID
    }
    
    // MARK: - Configuration Validation
    
    /// Validate configuration and log warnings for potential issues
    func validateConfiguration() {
        // Check if RP_LAUNCH_UUID is set and validate format
        if let envUUID = ProcessInfo.processInfo.environment["RP_LAUNCH_UUID"],
           !envUUID.isEmpty {
            // Validate UUID format (RFC 4122: 8-4-4-4-12 hex digits)
            let uuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
            let uuidRegex = try? NSRegularExpression(pattern: uuidPattern)
            let range = NSRange(envUUID.startIndex..., in: envUUID)
            
            if uuidRegex?.firstMatch(in: envUUID, range: range) == nil {
                Logger.shared.warning("[WARNING] RP_LAUNCH_UUID has invalid format: '\(envUUID)'. Expected RFC 4122 UUID format (e.g., 550e8400-e29b-41d4-a716-446655440000)")
                print("⚠️ [ReportPortal] Invalid RP_LAUNCH_UUID format: '\(envUUID)'")
            } else {
                Logger.shared.info("✅ RP_LAUNCH_UUID format valid: \(envUUID)")
            }
        } else {
            #if targetEnvironment(simulator)
            Logger.shared.info("[INFO] RP_LAUNCH_UUID not set. Using file-based UUID coordination (single launch guaranteed on simulators).")
            print("ℹ️  [ReportPortal] Using file-based UUID coordination (/tmp/reportportal/launch_uuid.txt)")
            #else
            Logger.shared.warning("[WARNING] RP_LAUNCH_UUID not set on real device. Each test bundle will create separate launch. Set RP_LAUNCH_UUID in pre-action script for single launch.")
            print("⚠️ [ReportPortal] RP_LAUNCH_UUID not set - real device will create separate launches")
            #endif
        }
        
        // Log platform detection
        #if targetEnvironment(simulator)
        Logger.shared.info("✅ Platform: iOS Simulator - Full coordination enabled (launch + suite + finish)")
        print("📱 [ReportPortal] Running on Simulator - file-based coordination available")
        
        // Validate /tmp/reportportal/ directory is writable
        let coordinationDir = "/tmp/reportportal"
        let fileManager = FileManager.default
        
        if fileManager.fileExists(atPath: coordinationDir) {
            if fileManager.isWritableFile(atPath: coordinationDir) {
                Logger.shared.info("✅ Coordination directory writable: \(coordinationDir)")
            } else {
                Logger.shared.error("[ERROR] Coordination directory not writable: \(coordinationDir)")
                print("🚨 [ReportPortal] Cannot write to \(coordinationDir) - coordination may fail")
            }
        } else {
            // Directory doesn't exist yet, will be created on first use
            Logger.shared.info("Coordination directory will be created: \(coordinationDir)")
        }
        #else
        Logger.shared.info("📱 Platform: Real Device - Launch coordination only (suite/finish coordination disabled)")
        print("📱 [ReportPortal] Running on Real Device - limited coordination")
        #endif
    }

    // MARK: - Bundle Lifecycle

    /// Increment active bundle counter when test bundle starts
    func incrementBundleCount() {
        activeBundleCount += 1
    }

    /// Decrement active bundle counter when test bundle finishes
    /// - Returns: `true` if count reached zero (should finalize launch), `false` otherwise
    func decrementBundleCount() -> Bool {
        activeBundleCount -= 1
        return activeBundleCount == 0
    }

    /// Get current active bundle count (for diagnostics)
    /// - Returns: Current value of activeBundleCount
    func getActiveBundleCount() -> Int {
        return activeBundleCount
    }

    // MARK: - Launch Management

    /// Get or await launch ID
    /// Multiple bundles calling this will await the same launch creation
    /// - Parameter launchTask: Task that creates the launch (passed from caller)
    /// - Returns: Launch ID (either existing or from task)
    func getOrAwaitLaunchID(launchTask: Task<String, Error>) async throws -> String {
        // If launch already exists, return it immediately
        if let existingID = launchID {
            // Cancel the new task since we don't need it
            launchTask.cancel()
            return existingID
        }

        // If launch creation is in progress, await the existing task
        if let existingTask = launchCreationTask {
            // Cancel the new task since we already have one
            launchTask.cancel()
            return try await existingTask.value
        }

        // Store the task so other bundles can await it
        launchCreationTask = launchTask

        // Await the result
        do {
            let id = try await launchTask.value
            self.launchID = id
            if self.launchStartTime == nil {
                self.launchStartTime = Date()
            }
            return id
        } catch {
            // Clear task on failure so another bundle can retry
            launchCreationTask = nil
            throw error
        }
    }

    /// Retrieve current launch ID (non-blocking check)
    /// - Returns: Launch ID if set, `nil` if launch not yet started
    func getLaunchID() -> String? {
        return launchID
    }

    /// Set launch ID directly (used with LaunchCoordinator for multi-process coordination)
    /// - Parameter id: The coordinated launch ID from LaunchCoordinator
    func setLaunchID(_ id: String) {
        self.launchID = id
        if self.launchStartTime == nil {
            self.launchStartTime = Date()
        }
    }

    /// Wait for launch ID to become available (Swift-like async/await approach)
    /// Instead of polling, this properly awaits the launch creation task
    /// - Parameter timeout: Maximum time to wait in seconds (default: 30)
    /// - Returns: Launch ID when available
    /// - Throws: LaunchManagerError if launch creation fails or times out
    func waitForLaunchID(timeout: TimeInterval = 30) async throws -> String {
        // Fast path: launch already created
        if let id = launchID {
            return id
        }

        // If launch creation is in progress, await it with timeout
        guard let task = launchCreationTask else {
            throw LaunchManagerError.launchNotStarted
        }

        // Race the launch creation against a timeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            // Task 1: Await the actual launch creation
            group.addTask {
                try await task.value
            }

            // Task 2: Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LaunchManagerError.timeout(seconds: timeout)
            }

            // Return first result (either launch ID or timeout error)
            guard let result = try await group.next() else {
                throw LaunchManagerError.taskCancelled
            }

            group.cancelAll() // Cancel timeout if launch succeeds, or vice versa
            return result
        }
    }

    // MARK: - Status Aggregation

    /// Update aggregated launch status (worst status wins)
    /// - Parameter newStatus: Status from completed test
    /// Status priority: .failed > .skipped > .passed
    func updateStatus(_ newStatus: TestStatus) {
        // Convert status to severity for comparison
        let currentSeverity = statusSeverity(aggregatedStatus)
        let newSeverity = statusSeverity(newStatus)

        if newSeverity > currentSeverity {
            aggregatedStatus = newStatus
        }
    }

    /// Get debug state for troubleshooting
    /// - Returns: Description of current launch state
    func getDebugState() -> String {
        if let id = launchID {
            return "LaunchID: \(id)"
        } else if launchCreationTask != nil {
            return "Launch creation in progress"
        } else {
            return "Launch not started"
        }
    }

    /// Get current aggregated launch status
    /// - Returns: Worst status seen across all completed tests
    func getAggregatedStatus() -> TestStatus {
        return aggregatedStatus
    }

    // MARK: - Finalization

    /// Mark launch as finalized (prevent duplicate finalization)
    func markFinalized() {
        isFinalized = true
    }

    /// Check if launch has been finalized
    /// - Returns: `true` if finalized, `false` otherwise
    func isLaunchFinalized() -> Bool {
        return isFinalized
    }

    /// Reset state for next launch (if agent is reused)
    func reset() {
        launchID = nil
        launchCreationTask = nil
        activeBundleCount = 0
        aggregatedStatus = .passed
        isFinalized = false
        launchStartTime = nil
    }

    // MARK: - Private Helpers

    /// Convert status to severity level for comparison
    /// - Parameter status: Test status
    /// - Returns: Severity level (higher = worse)
    private func statusSeverity(_ status: TestStatus) -> Int {
        switch status {
        case .failed:
            return 3
        case .stopped, .cancelled:
            return 2
        case .skipped:
            return 1
        case .passed, .reseted:
            return 0
        }
    }
}
