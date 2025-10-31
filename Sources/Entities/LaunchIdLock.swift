//
//  LaunchIdLock.swift
//  ReportPortalAgent
//
//  Created for Unit Test Support v4.0.0
//  Copyright © 2025 ReportPortal. All rights reserved.
//
//  Pattern based on ReportPortal Java client:
//  https://github.com/reportportal/client-java/tree/main/src/main/java/com/epam/reportportal/service/launch/lock
//

import Foundation

/// A service to perform blocking I/O operations on '.lock' and '.sync' files to get single launch UUID for multiple clients on a machine.
/// This actor uses local storage disk, therefore applicable in scope of a single hardware machine.
///
/// **Simulator Filesystem Notes**:
/// - Each simulator has its own sandbox/container for app data
/// - BUT: NSTemporaryDirectory() in simulator points to HOST machine's /tmp
/// - Result: All simulators share the same /tmp/reportportal_coordination/ directory
/// - This allows cross-process/cross-simulator coordination via file locking
///
/// **Coordination Flow**:
/// 1. Device 1 acquires .lock file → becomes Primary → creates Launch
/// 2. Device 1 writes Launch UUID to .sync file
/// 3. Devices 2-5 wait for .lock, then read UUID from .sync file
/// 4. All devices report to same Launch using coordinated UUID
///
/// Based on Java implementation: LaunchIdLockFile.java
actor LaunchIdLock {
    
    // MARK: - Properties
    
    /// Path to main lock file (prevents race conditions)
    private let lockFile: URL
    
    /// Path to sync file (stores Launch UUID for reading)
    private let syncFile: URL
    
    /// Maximum time to wait for file lock (milliseconds)
    private let fileWaitTimeout: TimeInterval
    
    /// UUID of this instance (worker/device)
    private let instanceUuid: String
    
    /// Launch UUID if this instance obtained the main lock (Primary Launch)
    private var lockUuid: String?
    
    /// Main lock file handle (non-nil means this is Primary Launch)
    private var mainLock: FileHandle?
    
    /// Set of all live instance UUIDs (for tracking which workers are active)
    private var liveInstances: Set<String> = []
    
    // MARK: - Initialization
    
    /// Creates a LaunchIdLock for coordinating Launch UUID across multiple workers
    ///
    /// - Parameters:
    ///   - lockFileName: Name of lock file (e.g., "launch_MyLaunch.lock")
    ///   - syncFileName: Name of sync file (e.g., "launch_MyLaunch.sync")
    ///   - timeout: Maximum wait time for file operations (default: 60 seconds)
    init(lockFileName: String, syncFileName: String, timeout: TimeInterval = 60.0) {
        // Use host's /tmp directory (shared across all simulators)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let coordinationDir = tempDir.appendingPathComponent("reportportal_coordination")
        
        self.lockFile = coordinationDir.appendingPathComponent(lockFileName)
        self.syncFile = coordinationDir.appendingPathComponent(syncFileName)
        self.fileWaitTimeout = timeout
        self.instanceUuid = UUID().uuidString
        
        // Ensure coordination directory exists
        try? FileManager.default.createDirectory(
            at: coordinationDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
    
    // MARK: - Public API
    
    /// Obtain or create Launch UUID with proper coordination
    /// Returns UUID if this instance is Primary (obtained main lock) or reads existing UUID
    ///
    /// **Java equivalent**: `LaunchIdLockFile.obtainLaunchUuid()`
    ///
    /// - Returns: Launch UUID (either newly created or read from sync file)
    func obtainLaunchUuid() async throws -> (uuid: String, isPrimary: Bool) {
        // If we already have main lock, we're Primary
        if let existingUuid = lockUuid, mainLock != nil {
            liveInstances.insert(instanceUuid)
            return (existingUuid, true)
        }
        
        // Try to acquire main lock
        if let lock = try await obtainLock(at: lockFile) {
            // SUCCESS! We obtained main lock → This is PRIMARY LAUNCH
            lockUuid = UUID().uuidString
            mainLock = lock
            liveInstances.insert(instanceUuid)
            
            Logger.shared.info("""
                🔐 PRIMARY LAUNCH: Obtained main lock
                - Instance UUID: \(instanceUuid)
                - Launch UUID: \(lockUuid!)
                - Lock File: \(lockFile.lastPathComponent)
                - Role: Primary (will create Launch on ReportPortal)
                """)
            
            // Write Launch UUID to sync file for other workers
            try await writeLaunchUuidToSyncFile(lockUuid!)
            
            return (lockUuid!, true)
        } else {
            // FAILED to get main lock → This is SECONDARY LAUNCH
            Logger.shared.info("""
                📖 SECONDARY LAUNCH: Main lock already held by another worker
                - Instance UUID: \(instanceUuid)
                - Lock File: \(lockFile.lastPathComponent)
                - Role: Secondary (will read existing Launch UUID)
                """)
            
            // Read Launch UUID from sync file
            let uuid = try await readLaunchUuidFromSyncFile()
            liveInstances.insert(instanceUuid)
            
            return (uuid, false)
        }
    }
    
    /// Returns list of all live instance UUIDs (workers that haven't finished yet)
    ///
    /// **Java equivalent**: `LaunchIdLockFile.getLiveInstanceUuids()`
    func getLiveInstanceUuids() -> [String] {
        return Array(liveInstances)
    }
    
    /// Mark instance as finished and remove from live instances
    ///
    /// **Java equivalent**: `LaunchIdLockFile.finishInstanceUuid()`
    ///
    /// - Parameter uuid: Instance UUID to mark as finished
    /// - Returns: True if this was the last instance (time to finish Launch)
    func finishInstanceUuid(_ uuid: String) -> Bool {
        liveInstances.remove(uuid)
        
        Logger.shared.info("""
            ✅ Instance finished
            - Instance UUID: \(uuid)
            - Remaining instances: \(liveInstances.count)
            """)
        
        return liveInstances.isEmpty
    }
    
    /// Reset lock state (for cleanup or testing)
    ///
    /// **Java equivalent**: `LaunchIdLockFile.reset()`
    func reset() {
        if let lock = mainLock {
            try? lock.close()
            mainLock = nil
        }
        lockUuid = nil
        liveInstances.removeAll()
        
        // Remove lock and sync files
        try? FileManager.default.removeItem(at: lockFile)
        try? FileManager.default.removeItem(at: syncFile)
    }
    
    // MARK: - Private File Operations
    
    /// Try to acquire exclusive lock on file
    /// Returns FileHandle if lock obtained, nil if file already locked
    ///
    /// **Java equivalent**: `LaunchIdLockFile.obtainLock(File file)`
    private func obtainLock(at url: URL) async throws -> FileHandle? {
        let fileManager = FileManager.default
        
        // Create empty file if doesn't exist
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        
        // Try to open for writing (exclusive access)
        guard let fileHandle = FileHandle(forWritingAtPath: url.path) else {
            return nil
        }
        
        // Try to acquire exclusive lock using flock (POSIX file locking)
        // LOCK_EX = exclusive lock, LOCK_NB = non-blocking
        let result = flock(fileHandle.fileDescriptor, LOCK_EX | LOCK_NB)
        
        if result == 0 {
            // Lock acquired successfully!
            return fileHandle
        } else {
            // Lock failed (another process holds it)
            try? fileHandle.close()
            return nil
        }
    }
    
    /// Write Launch UUID to sync file
    ///
    /// **Java equivalent**: `LaunchIdLockFile.writeLaunchUuid()`
    private func writeLaunchUuidToSyncFile(_ uuid: String) async throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var nsError: NSError?
        var writeError: Error?
        
        coordinator.coordinate(
            writingItemAt: syncFile,
            options: .forReplacing,
            error: &nsError
        ) { url in
            do {
                // Write format: "<UUID>\n<instanceUuid>:<timestamp>\n"
                // This matches Java's format for compatibility
                let timestamp = Date().timeIntervalSince1970
                let content = "\(uuid)\n\(instanceUuid):\(timestamp)\n"
                try content.write(to: url, atomically: true, encoding: .utf8)
                
                Logger.shared.info("""
                    📝 Wrote Launch UUID to sync file
                    - Launch UUID: \(uuid)
                    - Sync File: \(url.lastPathComponent)
                    - Instance: \(instanceUuid)
                    """)
            } catch {
                writeError = error
            }
        }
        
        if let error = nsError ?? writeError {
            throw LaunchIdLockError.syncFileWriteFailed(error)
        }
    }
    
    /// Read Launch UUID from sync file with retry logic and exponential backoff
    ///
    /// **Java equivalent**: `LaunchIdLockFile.readLaunchUuid()`
    private func readLaunchUuidFromSyncFile() async throws -> String {
        // Wait for sync file to exist (Primary Launch must create it first)
        let startTime = Date()
        while !FileManager.default.fileExists(atPath: syncFile.path) {
            if Date().timeIntervalSince(startTime) > fileWaitTimeout {
                throw LaunchIdLockError.syncFileTimeout
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // Retry logic with exponential backoff (1s, 2s, 4s, 8s)
        let retryDelays: [TimeInterval] = [1, 2, 4, 8]
        var lastError: Error?

        for (attempt, delay) in retryDelays.enumerated() {
            do {
                return try await attemptReadLaunchUuid()
            } catch {
                lastError = error
                Logger.shared.warning("""
                    ⚠️ Sync file read failed (attempt \(attempt + 1)/\(retryDelays.count))
                    - Error: \(error.localizedDescription)
                    - Retrying in \(delay)s...
                    """)

                if attempt < retryDelays.count - 1 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // All retries exhausted
        throw LaunchIdLockError.syncFileReadFailed(lastError ?? LaunchIdLockError.syncFileEmpty)
    }

    /// Attempt to read Launch UUID from sync file (single attempt)
    private func attemptReadLaunchUuid() async throws -> String {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var nsError: NSError?
        var uuid: String?
        var readError: Error?

        coordinator.coordinate(
            readingItemAt: syncFile,
            options: [],
            error: &nsError
        ) { url in
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                // First line contains Launch UUID
                let lines = content.components(separatedBy: "\n")
                if let firstLine = lines.first, !firstLine.isEmpty {
                    uuid = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)

                    Logger.shared.info("""
                        📖 Read Launch UUID from sync file
                        - Launch UUID: \(uuid!)
                        - Sync File: \(url.lastPathComponent)
                        - Instance: \(instanceUuid)
                        """)
                } else {
                    readError = LaunchIdLockError.syncFileEmpty
                }
            } catch {
                readError = error
            }
        }

        if let error = nsError ?? readError {
            throw LaunchIdLockError.syncFileReadFailed(error)
        }

        guard let launchUuid = uuid else {
            throw LaunchIdLockError.syncFileEmpty
        }

        return launchUuid
    }
}

// MARK: - Errors

enum LaunchIdLockError: LocalizedError {
    case syncFileWriteFailed(Error)
    case syncFileReadFailed(Error)
    case syncFileEmpty
    case syncFileTimeout
    
    var errorDescription: String? {
        switch self {
        case .syncFileWriteFailed(let error):
            return "Failed to write Launch UUID to sync file: \(error.localizedDescription)"
        case .syncFileReadFailed(let error):
            return "Failed to read Launch UUID from sync file: \(error.localizedDescription)"
        case .syncFileEmpty:
            return "Sync file exists but is empty"
        case .syncFileTimeout:
            return "Timeout waiting for sync file to be created by Primary Launch"
        }
    }
}
