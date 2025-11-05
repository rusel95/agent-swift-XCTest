//
//  SuiteCounterCoordinator.swift
//  ReportPortalAgent
//
//  Created by Ruslan Popesku on 11/04/25.
//  Copyright © 2025 ReportPortal. All rights reserved.
//
//  File-based suite ID registry to track active suites across all workers
//

import Foundation

/// Actor for tracking active suites across multiple test workers
/// Uses a single file to store suite IDs (suite name → suite ID mapping)
/// File format: One entry per line: "suiteName|suiteID"
actor SuiteCounterCoordinator {
    
    /// Base directory for coordination files
    private let baseDirectory = "/tmp/reportportal"
    
    /// Correlation ID for logging
    private let correlationID: UUID
    
    init(correlationID: UUID = UUID()) {
        self.correlationID = correlationID
    }
    
    /// Register suite ID (called when a suite starts)
    /// - Parameters:
    ///   - uuid: Launch UUID
    ///   - suiteName: Suite name (e.g., "LoginTests")
    ///   - suiteID: Suite ID from ReportPortal API
    /// - Returns: Total suite count after registration
    /// - Throws: FileCoordinationError if operation fails
    func registerSuite(uuid: String, suiteName: String, suiteID: String) async throws -> Int {
        let filePath = "\(baseDirectory)/launch_\(uuid)_active_suites.txt"
        
        // Acquire lock for exclusive access
        let lockHandle = try await FileCoordination.acquireLock(path: filePath, timeout: 10.0)
        defer { FileCoordination.releaseLock(lockHandle) }
        
        // Read existing suite registry
        var suites: [String: String] = [:] // suiteName → suiteID
        if FileManager.default.fileExists(atPath: filePath) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
               let content = String(data: data, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
                for line in lines {
                    let parts = line.components(separatedBy: "|")
                    if parts.count == 2 {
                        suites[parts[0]] = parts[1]
                    }
                }
            }
        }
        
        // Check if suite already registered
        if let existingID = suites[suiteName] {
            print("[\(correlationID)] ⚠️ Suite '\(suiteName)' already registered with ID: \(existingID)")
            return suites.count
        }
        
        // Add new suite
        suites[suiteName] = suiteID
        
        // Write back to file
        let entries = suites.map { "\($0.key)|\($0.value)" }.sorted()
        let newContent = entries.joined(separator: "\n") + "\n"
        try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
        
        print("[\(correlationID)] 📈 Suite registered: '\(suiteName)' → \(suiteID) (Total: \(suites.count))")
        
        return suites.count
    }
    
    /// Unregister suite ID (called when a suite finishes)
    /// - Parameters:
    ///   - uuid: Launch UUID
    ///   - suiteName: Suite name
    /// - Returns: Remaining suite count (0 means no more active suites)
    /// - Throws: FileCoordinationError if operation fails
    func unregisterSuite(uuid: String, suiteName: String) async throws -> Int {
        let filePath = "\(baseDirectory)/launch_\(uuid)_active_suites.txt"
        
        // Acquire lock for exclusive access
        let lockHandle = try await FileCoordination.acquireLock(path: filePath, timeout: 10.0)
        defer { FileCoordination.releaseLock(lockHandle) }
        
        // Read existing suite registry
        var suites: [String: String] = [:]
        if FileManager.default.fileExists(atPath: filePath) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
               let content = String(data: data, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
                for line in lines {
                    let parts = line.components(separatedBy: "|")
                    if parts.count == 2 {
                        suites[parts[0]] = parts[1]
                    }
                }
            }
        }
        
        // Remove suite
        let removed = suites.removeValue(forKey: suiteName)
        let remainingCount = suites.count
        
        if let removedID = removed {
            print("[\(correlationID)] 📉 Suite unregistered: '\(suiteName)' (ID: \(removedID), Remaining: \(remainingCount))")
        } else {
            print("[\(correlationID)] ⚠️ Suite '\(suiteName)' not found in registry")
        }
        
        // Write back to file (or delete if empty)
        if remainingCount > 0 {
            let entries = suites.map { "\($0.key)|\($0.value)" }.sorted()
            let newContent = entries.joined(separator: "\n") + "\n"
            try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
        } else {
            // Delete file when no more suites
            try? FileManager.default.removeItem(atPath: filePath)
            print("[\(correlationID)] �️  All suites finished - registry file deleted")
        }
        
        return remainingCount
    }
    
    /// Check if suite is already registered
    /// - Parameters:
    ///   - uuid: Launch UUID
    ///   - suiteName: Suite name
    /// - Returns: Suite ID if registered, nil otherwise
    func getSuiteID(uuid: String, suiteName: String) async -> String? {
        let filePath = "\(baseDirectory)/launch_\(uuid)_active_suites.txt"
        
        guard FileManager.default.fileExists(atPath: filePath) else {
            return nil
        }
        
        if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
           let content = String(data: data, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            for line in lines {
                let parts = line.components(separatedBy: "|")
                if parts.count == 2 && parts[0] == suiteName {
                    return parts[1]
                }
            }
        }
        
        return nil
    }
    
    /// Get current suite count without modifying it
    /// - Parameter uuid: Launch UUID
    /// - Returns: Current suite count
    func getSuiteCount(uuid: String) async -> Int {
        let filePath = "\(baseDirectory)/launch_\(uuid)_active_suites.txt"
        
        guard FileManager.default.fileExists(atPath: filePath) else {
            return 0
        }
        
        if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
           let content = String(data: data, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            return lines.count
        }
        
        return 0
    }
    
    /// Get all registered suite names
    /// - Parameter uuid: Launch UUID
    /// - Returns: Array of suite names
    func getActiveSuiteNames(uuid: String) async -> [String] {
        let filePath = "\(baseDirectory)/launch_\(uuid)_active_suites.txt"
        
        guard FileManager.default.fileExists(atPath: filePath) else {
            return []
        }
        
        if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
           let content = String(data: data, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            return lines.compactMap { line in
                let parts = line.components(separatedBy: "|")
                return parts.count == 2 ? parts[0] : nil
            }
        }
        
        return []
    }
    
    /// Clean up suite registry file
    /// - Parameter uuid: Launch UUID
    func cleanupRegistryFile(uuid: String) async {
        let filePath = "\(baseDirectory)/launch_\(uuid)_active_suites.txt"
        let lockFilePath = "\(baseDirectory)/launch_\(uuid)_active_suites.lock"
        
        do {
            try? FileManager.default.removeItem(atPath: filePath)
            try? FileManager.default.removeItem(atPath: lockFilePath)
            print("[\(correlationID)] 🧹 Cleaned up suite registry files for UUID: \(uuid)")
        }
    }
}
