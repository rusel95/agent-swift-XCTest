//
//  SyncLogger.swift
//  ReportPortalAgent
//
//  Created on 11/06/25.
//  Copyright © 2025 ReportPortal. All rights reserved.
//
//  Centralized synchronization logger for multi-device coordination debugging
//

import Foundation

/// Categories for synchronization logging
enum SyncLogCategory: String {
    case launch = "LAUNCH"
    case suite = "SUITE"
    case worker = "WORKER"
    case finish = "FINISH"
    case uuid = "UUID"
    case file = "FILE"
    case bundle = "BUNDLE"
}

/// Centralized logger for synchronization events across all devices
/// Writes to a shared file with thread-safe locking
actor SyncLogger {
    
    /// Shared singleton instance
    static let shared = SyncLogger()
    
    /// Log file path (on desktop for easy access)
    private let logFilePath = "/Users/Ruslan_Popesku/Desktop/reportportal_sync.log"
    
    /// Process ID (unique per device/simulator)
    private let processID: Int32
    
    /// Device identifier (PID_PGID format)
    private let deviceID: String
    
    /// File handle for logging
    private var fileHandle: FileHandle?
    
    /// Lock file path for thread-safe writes
    private let lockFilePath: String
    
    /// Date formatter for timestamps
    private let dateFormatter: DateFormatter
    
    private init() {
        self.processID = getpid()
        let pgid = getpgid(processID)
        self.deviceID = "\(processID)_\(pgid)"
        self.lockFilePath = "\(logFilePath).lock"
        
        // Setup date formatter
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.dateFormatter.timeZone = TimeZone.current
        
        // Initialize log file
        Task {
            await initializeLogFile()
        }
    }
    
    /// Initialize the log file
    private func initializeLogFile() {
        let fileManager = FileManager.default
        
        // Create log file if doesn't exist
        if !fileManager.fileExists(atPath: logFilePath) {
            let header = """
            ================================================================================
            ReportPortal Synchronization Log
            Started: \(dateFormatter.string(from: Date()))
            Format: [timestamp] [PID] [device_id] [category] message
            ================================================================================
            
            """
            
            do {
                try header.write(toFile: logFilePath, atomically: true, encoding: .utf8)
                print("📝 [SyncLogger] Log file created: \(logFilePath)")
            } catch {
                print("❌ [SyncLogger] Failed to create log file: \(error)")
            }
        } else {
            // Append separator for new session
            let separator = """
            
            ================================================================================
            New Session: \(dateFormatter.string(from: Date()))
            ================================================================================
            
            """
            appendToFile(separator)
            print("📝 [SyncLogger] Appending to existing log: \(logFilePath)")
        }
    }
    
    /// Log a synchronization event
    /// - Parameters:
    ///   - category: Category of the log (LAUNCH, SUITE, WORKER, etc.)
    ///   - message: Log message
    func log(_ category: SyncLogCategory, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let logLine = "[\(timestamp)] [\(processID)] [\(deviceID)] [\(category.rawValue)] \(message)\n"
        
        // Append to file with locking
        appendToFile(logLine)
        
        // Keep console prints for now (as requested)
        print("🔄 [SYNC] [\(category.rawValue)] \(message)")
    }
    
    /// Thread-safe append to file using file locking
    /// - Parameter content: Content to append
    private func appendToFile(_ content: String) {
        let fileManager = FileManager.default
        
        // Acquire lock
        let lockHandle = acquireLock()
        defer {
            releaseLock(lockHandle)
        }
        
        // Append to file
        if let fileHandle = FileHandle(forWritingAtPath: logFilePath) {
            fileHandle.seekToEndOfFile()
            if let data = content.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        } else {
            // File doesn't exist, create it
            do {
                try content.write(toFile: logFilePath, atomically: true, encoding: .utf8)
            } catch {
                // Fallback to console only
                print("❌ [SyncLogger] Failed to write to file: \(error)")
            }
        }
    }
    
    /// Acquire exclusive lock for file writing
    /// - Returns: Lock file handle (to be released after writing)
    private func acquireLock() -> FileHandle? {
        let fileManager = FileManager.default
        var attempts = 0
        let maxAttempts = 100
        
        while attempts < maxAttempts {
            // Try to create lock file exclusively
            if !fileManager.fileExists(atPath: lockFilePath) {
                do {
                    // Create lock file
                    try "locked".write(toFile: lockFilePath, atomically: true, encoding: .utf8)
                    return FileHandle(forWritingAtPath: lockFilePath)
                } catch {
                    // Lock acquisition failed, retry
                }
            }
            
            // Wait a bit before retry (1ms)
            usleep(1000)
            attempts += 1
        }
        
        // Timeout - force release old lock
        try? fileManager.removeItem(atPath: lockFilePath)
        return nil
    }
    
    /// Release lock file
    /// - Parameter lockHandle: Lock file handle to release
    private func releaseLock(_ lockHandle: FileHandle?) {
        lockHandle?.closeFile()
        try? FileManager.default.removeItem(atPath: lockFilePath)
    }
    
    // MARK: - Convenience Methods
    
    /// Log launch-related event
    func logLaunch(_ message: String) {
        log(.launch, message)
    }
    
    /// Log suite-related event
    func logSuite(_ message: String) {
        log(.suite, message)
    }
    
    /// Log worker-related event
    func logWorker(_ message: String) {
        log(.worker, message)
    }
    
    /// Log finish/finalization event
    func logFinish(_ message: String) {
        log(.finish, message)
    }
    
    /// Log UUID coordination event
    func logUUID(_ message: String) {
        log(.uuid, message)
    }
    
    /// Log file coordination event
    func logFile(_ message: String) {
        log(.file, message)
    }
    
    /// Log bundle lifecycle event
    func logBundle(_ message: String) {
        log(.bundle, message)
    }
}
