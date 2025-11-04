//
//  FinishCoordinator.swift
//  ReportPortalAgent
//
//  Created by Ruslan Popesku on 11/04/25.
//  Copyright © 2025 ReportPortal. All rights reserved.
//
//  Finish coordination to ensure single launch finish with aggregated status
//

import Foundation

/// Actor for coordinating launch finish across multiple test workers
/// Ensures only last worker calls finish API with correct aggregated status
actor FinishCoordinator {
    
    /// Worker status aggregator (worker ID → status)
    private var workerStatuses: [String: TestStatus] = [:]
    
    /// Base directory for finish coordination files
    private let baseDirectory = "/tmp/reportportal"
    
    /// Correlation ID for logging
    private let correlationID: UUID
    
    init(correlationID: UUID = UUID()) {
        self.correlationID = correlationID
    }
    
    /// Record worker's final status
    /// - Parameters:
    ///   - uuid: Launch UUID
    ///   - workerID: Worker identifier
    ///   - status: Worker's final test status
    /// - Throws: FileCoordinationError if status recording fails
    func recordStatus(uuid: String, workerID: String, status: TestStatus) async throws {
        let filePath = "\(baseDirectory)/launch_\(uuid)_statuses.txt"
        
        print("[\(correlationID)] Recording status for worker '\(workerID)': \(status.rawValue)")
        
        // Store in memory
        workerStatuses[workerID] = status
        
        // Acquire lock for exclusive access
        let lockHandle = try await FileCoordination.acquireLock(path: filePath, timeout: 10.0)
        defer { FileCoordination.releaseLock(lockHandle) }
        
        // Read existing statuses
        var statuses: [String: String] = [:]
        if FileManager.default.fileExists(atPath: filePath) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
               let content = String(data: data, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
                for line in lines {
                    let parts = line.components(separatedBy: "|")
                    if parts.count == 2 {
                        statuses[parts[0]] = parts[1]
                    }
                }
            }
        }
        
        // Update this worker's status
        statuses[workerID] = status.rawValue
        
        // Write back to file
        let entries = statuses.map { "\($0.key)|\($0.value)" }.sorted()
        let newContent = entries.joined(separator: "\n") + "\n"
        try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
        
        print("[\(correlationID)] Status recorded successfully. Total workers: \(statuses.count)")
    }
    
    /// Check if worker should finish launch and get aggregated status
    /// - Parameters:
    ///   - uuid: Launch UUID
    ///   - workerID: Worker identifier
    ///   - workerTracker: WorkerTracker to check if last worker
    /// - Returns: Tuple (shouldFinish, aggregatedStatus)
    /// - Throws: FileCoordinationError if check fails
    func shouldFinishLaunch(
        uuid: String,
        workerID: String,
        workerTracker: WorkerTracker
    ) async throws -> (shouldFinish: Bool, aggregatedStatus: TestStatus?) {
        // Check if this is the last worker
        let isLastWorker = try await workerTracker.unregisterWorker(uuid: uuid, workerID: workerID)
        
        guard isLastWorker else {
            let remainingCount = await workerTracker.getWorkerCount(uuid: uuid)
            print("[\(correlationID)] ⏭️  Worker '\(workerID)' is NOT last worker. Remaining: \(remainingCount)")
            print("[\(correlationID)] Skipping finish API call")
            return (shouldFinish: false, aggregatedStatus: nil)
        }
        
        // This is the last worker - aggregate statuses
        print("[\(correlationID)] ✅ Worker '\(workerID)' is LAST WORKER")
        print("[\(correlationID)] Aggregating statuses from all workers...")
        
        let aggregated = try await aggregateStatuses(uuid: uuid)
        
        print("[\(correlationID)] Final aggregated status: \(aggregated.rawValue)")
        print("[\(correlationID)] Calling finish API as last worker")
        
        return (shouldFinish: true, aggregatedStatus: aggregated)
    }
    
    /// Aggregate statuses from all workers using priority hierarchy
    /// FAILED (highest) > STOPPED > SKIPPED > PASSED (lowest)
    /// - Parameter uuid: Launch UUID
    /// - Returns: Aggregated status
    /// - Throws: FileCoordinationError if aggregation fails
    private func aggregateStatuses(uuid: String) async throws -> TestStatus {
        let filePath = "\(baseDirectory)/launch_\(uuid)_statuses.txt"
        
        // Read status file
        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let content = String(data: data, encoding: .utf8) else {
            print("[\(correlationID)] ⚠️ Status file not found or unreadable, defaulting to PASSED")
            return .passed
        }
        
        // Parse statuses
        var allStatuses: [TestStatus] = []
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        
        for line in lines {
            let parts = line.components(separatedBy: "|")
            if parts.count == 2,
               let status = TestStatus(rawValue: parts[1]) {
                allStatuses.append(status)
                print("[\(correlationID)]   Worker '\(parts[0])': \(status.rawValue)")
            }
        }
        
        // If no statuses found, default to PASSED
        guard !allStatuses.isEmpty else {
            print("[\(correlationID)] No worker statuses found, defaulting to PASSED")
            return .passed
        }
        
        // Apply priority hierarchy: FAILED > STOPPED > SKIPPED > PASSED
        if allStatuses.contains(.failed) {
            return .failed
        }
        if allStatuses.contains(.stopped) {
            return .stopped
        }
        if allStatuses.contains(.skipped) {
            return .skipped
        }
        return .passed
    }
    
    /// Clean up status files after finish
    /// - Parameter uuid: Launch UUID
    func cleanupStatusFiles(uuid: String) async {
        let statusFilePath = "\(baseDirectory)/launch_\(uuid)_statuses.txt"
        let finishLockPath = "\(baseDirectory)/launch_\(uuid)_finish.lock"
        let launchUUIDPath = "\(baseDirectory)/launch_uuid.txt"
        
        for filePath in [statusFilePath, finishLockPath, launchUUIDPath] {
            do {
                try FileManager.default.removeItem(atPath: filePath)
                print("[\(correlationID)] Cleaned up finish coordination file: \(filePath)")
            } catch {
                Logger.shared.error("[ERROR] Failed to delete '\(filePath)': \(error.localizedDescription)", correlationID: correlationID)
                print("[\(correlationID)] ⚠️ Failed to delete '\(filePath)': \(error.localizedDescription)")
            }
        }
    }
}
