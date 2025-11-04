//
//  FileCoordination.swift
//  ReportPortalAgent
//
//  Created by agent-swift-XCTest on 2025-11-04.
//  Copyright © 2025 EPAM Systems. All rights reserved.
//
//  POSIX file lock coordination for suite and finish synchronization
//

import Foundation

/// Errors that can occur during file coordination operations
enum FileCoordinationError: Error {
    case lockTimeout(path: String, duration: TimeInterval)
    case lockAcquisitionFailed(path: String, errno: Int32)
    case directoryCreationFailed(path: String, error: Error)
    case fileOperationFailed(path: String, operation: String, error: Error)
    case invalidFileHandle
}

/// Utility for POSIX file-based coordination using flock()
/// Provides exclusive lock acquisition with timeout and exponential backoff
actor FileCoordination {
    
    /// Acquire exclusive lock on file with timeout and exponential backoff
    /// - Parameters:
    ///   - path: Absolute path to lock file
    ///   - timeout: Maximum time to wait for lock (default: 10 seconds)
    /// - Returns: Open file handle with exclusive lock
    /// - Throws: FileCoordinationError if lock cannot be acquired
    static func acquireLock(path: String, timeout: TimeInterval = 10.0) async throws -> FileHandle {
        // Create parent directory if needed
        let directory = (path as NSString).deletingLastPathComponent
        try createDirectoryIfNeeded(at: directory)
        
        let startTime = Date()
        var retryInterval: TimeInterval = 0.1 // Start with 100ms
        let maxRetryInterval: TimeInterval = 1.6 // Cap at 1600ms
        
        while Date().timeIntervalSince(startTime) < timeout {
            // Open or create lock file
            let fd = open(path, O_RDWR | O_CREAT, 0o644)
            guard fd >= 0 else {
                throw FileCoordinationError.lockAcquisitionFailed(path: path, errno: errno)
            }
            
            // Try to acquire exclusive lock (non-blocking)
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                // Lock acquired successfully
                return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            }
            
            // Lock acquisition failed
            let error = errno
            close(fd) // Close the file descriptor
            
            // Check if it's a "would block" error (someone else has the lock)
            if error == EWOULDBLOCK {
                // Exponential backoff with jitter
                let jitter = Double.random(in: 0.0...0.1)
                try? await Task.sleep(nanoseconds: UInt64((retryInterval + jitter) * 1_000_000_000))
                retryInterval = min(retryInterval * 2.0, maxRetryInterval)
                continue
            }
            
            // Other error
            throw FileCoordinationError.lockAcquisitionFailed(path: path, errno: error)
        }
        
        // Timeout exceeded
        throw FileCoordinationError.lockTimeout(path: path, duration: Date().timeIntervalSince(startTime))
    }
    
    /// Release lock on file handle
    /// - Parameter handle: File handle with lock to release
    static func releaseLock(_ handle: FileHandle) {
        let fd = handle.fileDescriptor
        flock(fd, LOCK_UN) // Release lock
        try? handle.close() // Close file
    }
    
    /// Create directory and all parent directories if they don't exist
    /// - Parameter path: Directory path to create
    /// - Throws: FileCoordinationError if directory creation fails
    private static func createDirectoryIfNeeded(at path: String) throws {
        let fileManager = FileManager.default
        
        guard !fileManager.fileExists(atPath: path) else {
            return // Directory already exists
        }
        
        do {
            try fileManager.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw FileCoordinationError.directoryCreationFailed(path: path, error: error)
        }
    }
    
    /// Read entire file contents atomically with lock
    /// - Parameter path: File path to read
    /// - Returns: File contents as string
    /// - Throws: FileCoordinationError if read fails
    static func readFile(at path: String) async throws -> String {
        let handle = try await acquireLock(path: path, timeout: 5.0)
        defer { releaseLock(handle) }
        
        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            throw FileCoordinationError.fileOperationFailed(
                path: path,
                operation: "read",
                error: NSError(domain: "FileCoordination", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to read file contents"])
            )
        }
        
        return content
    }
    
    /// Write entire file contents atomically with lock
    /// - Parameters:
    ///   - content: String content to write
    ///   - path: File path to write to
    /// - Throws: FileCoordinationError if write fails
    static func writeFile(content: String, to path: String) async throws {
        let handle = try await acquireLock(path: path, timeout: 5.0)
        defer { releaseLock(handle) }
        
        guard let data = content.data(using: .utf8) else {
            throw FileCoordinationError.fileOperationFailed(
                path: path,
                operation: "encode",
                error: NSError(domain: "FileCoordination", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode string to UTF-8"])
            )
        }
        
        do {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw FileCoordinationError.fileOperationFailed(
                path: path,
                operation: "write",
                error: error
            )
        }
    }
    
    /// Delete file if it exists
    /// - Parameter path: File path to delete
    static func deleteFile(at path: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            return // File doesn't exist, nothing to delete
        }
        
        do {
            try fileManager.removeItem(atPath: path)
        } catch {
            throw FileCoordinationError.fileOperationFailed(
                path: path,
                operation: "delete",
                error: error
            )
        }
    }
}
