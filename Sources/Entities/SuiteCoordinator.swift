//
//  SuiteCoordinator.swift
//  ReportPortalAgent
//
//  Created by agent-swift-XCTest on 2025-11-04.
//  Copyright © 2025 EPAM Systems. All rights reserved.
//
//  File-based suite coordination to prevent duplicate suites across workers
//

import Foundation

/// Actor for coordinating suite creation across multiple test workers
/// Uses file-based synchronization to ensure only one suite is created per test class
actor SuiteCoordinator {
    
    /// In-memory cache of suite IDs (suite name → suite ID)
    private var suiteRegistry: [String: String] = [:]
    
    /// Base directory for suite sync files
    private let baseDirectory = "/tmp/reportportal"
    
    /// Correlation ID for logging
    private let correlationID: UUID
    
    /// Platform support flag (simulators only)
    private let isPlatformSupported: Bool
    
    init(correlationID: UUID = UUID()) {
        self.correlationID = correlationID
        self.isPlatformSupported = Self.checkPlatformSupport()
        
        if isPlatformSupported {
            print("[\(correlationID)] SuiteCoordinator initialized for simulator (file-based coordination enabled)")
        } else {
            print("[\(correlationID)] SuiteCoordinator initialized for real device (file-based coordination DISABLED)")
        }
    }
    
    /// Get existing suite ID or create new suite with coordination
    /// - Parameters:
    ///   - name: Suite name (e.g., "LoginTests")
    ///   - launchID: Launch UUID
    ///   - createSuite: Async closure to create suite via API
    /// - Returns: Suite ID (from cache, sync file, or newly created)
    /// - Throws: Error if suite creation fails
    func getOrCreateSuite(
        name: String,
        launchID: String,
        createSuite: () async throws -> String
    ) async throws -> String {
        // Check in-memory cache first
        if let cachedID = suiteRegistry[name] {
            print("[\(correlationID)] Suite '\(name)' found in cache: \(cachedID)")
            return cachedID
        }
        
        // If platform doesn't support file coordination, create directly
        guard isPlatformSupported else {
            print("[\(correlationID)] Platform doesn't support file coordination, creating suite '\(name)' directly")
            let suiteID = try await createSuite()
            suiteRegistry[name] = suiteID
            return suiteID
        }
        
        // File-based coordination
        let sanitizedName = sanitizeSuiteName(name)
        let syncFilePath = "\(baseDirectory)/suite_\(sanitizedName)_\(launchID).id"
        let lockFilePath = "\(baseDirectory)/suite_\(sanitizedName)_\(launchID).lock"
        
        // Try to acquire lock
        do {
            let lockHandle = try await FileCoordination.acquireLock(path: lockFilePath, timeout: 10.0)
            defer { FileCoordination.releaseLock(lockHandle) }
            
            // Check if sync file exists
            if FileManager.default.fileExists(atPath: syncFilePath) {
                do {
                    let suiteID = try String(contentsOfFile: syncFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Validate suite ID format
                    guard !suiteID.isEmpty, suiteID.count < 200 else {
                        print("[\(correlationID)] ⚠️ Invalid suite ID in sync file '\(syncFilePath)': '\(suiteID)'")
                        throw FileCoordinationError.fileOperationFailed(
                            path: syncFilePath,
                            operation: "validate",
                            error: NSError(domain: "SuiteCoordinator", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid suite ID format"])
                        )
                    }
                    
                    print("[\(correlationID)] Suite '\(name)' found in sync file: \(suiteID)")
                    suiteRegistry[name] = suiteID
                    return suiteID
                } catch {
                    // Sync file corrupted, fall back to creating new suite
                    print("[\(correlationID)] ⚠️ Corrupted sync file '\(syncFilePath)': \(error.localizedDescription)")
                }
            }
            
            // Sync file doesn't exist or is corrupted, create new suite
            print("[\(correlationID)] Creating new suite '\(name)' (first worker)")
            let suiteID = try await createSuite()
            
            // Write suite ID to sync file
            do {
                try suiteID.write(toFile: syncFilePath, atomically: true, encoding: .utf8)
                print("[\(correlationID)] Wrote suite ID to sync file: \(syncFilePath)")
            } catch {
                print("[\(correlationID)] ⚠️ Failed to write sync file '\(syncFilePath)': \(error.localizedDescription)")
                // Continue anyway, suite was created successfully
            }
            
            suiteRegistry[name] = suiteID
            return suiteID
            
        } catch let error as FileCoordinationError {
            // Lock timeout or acquisition failed, fall back to direct creation
            print("[\(correlationID)] ⚠️ File coordination failed for suite '\(name)': \(error)")
            print("[\(correlationID)] Falling back to direct suite creation (may result in duplicates)")
            
            let suiteID = try await createSuite()
            suiteRegistry[name] = suiteID
            return suiteID
        }
    }
    
    /// Clean up all suite sync files for a launch
    /// - Parameter launchID: Launch UUID
    func cleanupSyncFiles(launchID: String) async {
        let fileManager = FileManager.default
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: baseDirectory)
            let pattern = "suite_.*_\(launchID)\\.(id|lock)"
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            
            for file in files {
                let range = NSRange(file.startIndex..<file.endIndex, in: file)
                if regex.firstMatch(in: file, options: [], range: range) != nil {
                    let filePath = "\(baseDirectory)/\(file)"
                    do {
                        try fileManager.removeItem(atPath: filePath)
                        print("[\(correlationID)] Cleaned up sync file: \(filePath)")
                    } catch {
                        print("[\(correlationID)] ⚠️ Failed to delete sync file '\(filePath)': \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            print("[\(correlationID)] ⚠️ Failed to list files in '\(baseDirectory)': \(error.localizedDescription)")
        }
    }
    
    /// Sanitize suite name for use in file path (alphanumeric + underscore only)
    /// - Parameter name: Original suite name
    /// - Returns: Sanitized name
    private func sanitizeSuiteName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return name.unicodeScalars
            .filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
    }
    
    /// Check if current platform supports file-based coordination
    /// - Returns: true for iOS Simulator, false for real devices
    private static func checkPlatformSupport() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}
