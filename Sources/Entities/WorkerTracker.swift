//
//  WorkerTracker.swift
//  ReportPortalAgent
//
//  Created by Ruslan Popesku on 11/04/25.
//  Copyright © 2025 ReportPortal. All rights reserved.
//
//  Worker registration and last-worker detection for launch finish coordination
//

import Foundation

/// Actor for tracking worker registration and detecting last worker
/// Uses file-based tracking to coordinate launch finish across multiple test workers
actor WorkerTracker {
    
    /// Base directory for worker tracking files
    private let baseDirectory = "/tmp/reportportal"
    
    /// Correlation ID for logging
    private let correlationID: UUID
    
    init(correlationID: UUID = UUID()) {
        self.correlationID = correlationID
    }
    
    /// Register worker in tracking file
    /// - Parameters:
    ///   - uuid: Launch UUID
    ///   - workerID: Unique worker identifier (PID or bundle ID)
    /// - Throws: FileCoordinationError if registration fails
    func registerWorker(uuid: String, workerID: String) async throws {
        let filePath = "\(baseDirectory)/launch_\(uuid)_workers.txt"
        
        print("[\(correlationID)] Registering worker '\(workerID)' for launch '\(uuid)'")
        
        // Acquire lock for exclusive access
        let lockHandle = try await FileCoordination.acquireLock(path: filePath, timeout: 10.0)
        defer { FileCoordination.releaseLock(lockHandle) }
        
        // Read existing workers
        var workers = [String]()
        if FileManager.default.fileExists(atPath: filePath) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
               let content = String(data: data, encoding: .utf8) {
                workers = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            }
        }
        
        // Check if already registered
        guard !workers.contains(workerID) else {
            print("[\(correlationID)] Worker '\(workerID)' already registered")
            return
        }
        
        // Append worker with timestamp and status
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(workerID)|\(timestamp)|ACTIVE"
        workers.append(entry)
        
        // Write back to file
        let newContent = workers.joined(separator: "\n") + "\n"
        try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
        
        print("[\(correlationID)] Worker '\(workerID)' registered successfully (\(workers.count) total workers)")
    }
    
    /// Unregister worker and check if this is the last worker
    /// - Parameters:
    ///   - uuid: Launch UUID
    ///   - workerID: Unique worker identifier
    /// - Returns: true if this is the last worker (worker count = 0 after removal)
    /// - Throws: FileCoordinationError if unregistration fails
    func unregisterWorker(uuid: String, workerID: String) async throws -> Bool {
        let filePath = "\(baseDirectory)/launch_\(uuid)_workers.txt"
        
        print("[\(correlationID)] Unregistering worker '\(workerID)' for launch '\(uuid)'")
        
        // Acquire lock for exclusive access
        let lockHandle = try await FileCoordination.acquireLock(path: filePath, timeout: 10.0)
        defer { FileCoordination.releaseLock(lockHandle) }
        
        // Read existing workers
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[\(correlationID)] ⚠️ Worker tracking file not found: '\(filePath)'")
            // File doesn't exist, assume this is the last worker (graceful degradation)
            return true
        }
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let content = String(data: data, encoding: .utf8) else {
            print("[\(correlationID)] ⚠️ Failed to read worker tracking file: '\(filePath)'")
            // File unreadable, assume this is the last worker (graceful degradation)
            return true
        }
        
        var workers = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let originalCount = workers.count
        
        // Remove this worker (atomic read-modify-write)
        workers.removeAll { line in
            line.hasPrefix("\(workerID)|")
        }
        
        let remainingCount = workers.count
        let isLastWorker = remainingCount == 0
        
        print("[\(correlationID)] Worker '\(workerID)' unregistered. Remaining workers: \(remainingCount) (was: \(originalCount))")
        
        if isLastWorker {
            // Delete file if no workers remain
            try? FileManager.default.removeItem(atPath: filePath)
            print("[\(correlationID)] ✅ Last worker detected! Worker tracking file deleted.")
        } else {
            // Write updated worker list back to file
            let newContent = workers.joined(separator: "\n") + "\n"
            try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
        }
        
        return isLastWorker
    }
    
    /// Get current worker count (for debugging)
    /// - Parameter uuid: Launch UUID
    /// - Returns: Number of active workers
    func getWorkerCount(uuid: String) async -> Int {
        let filePath = "\(baseDirectory)/launch_\(uuid)_workers.txt"
        
        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let content = String(data: data, encoding: .utf8) else {
            return 0
        }
        
        return content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    }
}
