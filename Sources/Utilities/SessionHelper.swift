//
//  SessionHelper.swift
//  ReportPortalAgent
//
//  Created for parallel execution coordination
//  Copyright © 2025 ReportPortal. All rights reserved.
//

import Foundation

/// Utility for generating and managing coordination session IDs
/// Session ID uniquely identifies a test run and is used for coordination file naming
enum SessionHelper {

    /// Generate a unique session ID for coordinating parallel workers
    ///
    /// Priority:
    /// 1. RP_SESSION_ID environment variable (user-provided)
    /// 2. Process Group ID (PGID) for tests started by same xcodebuild command
    ///
    /// - Returns: Session ID string
    static func generateSessionID() -> String {
        // Priority 1: Check for explicit session ID from environment
        if let sessionID = ProcessInfo.processInfo.environment["RP_SESSION_ID"],
           !sessionID.isEmpty {
            print("📋 Session ID from RP_SESSION_ID: \(sessionID)")
            return sessionID
        }

        // Priority 2: Use Process Group ID (shared by all workers from same xcodebuild)
        let pgid = getProcessGroupID()
        let sessionID = "pgid-\(pgid)"
        print("📋 Session ID from PGID: \(sessionID)")
        return sessionID
    }

    /// Get Process Group ID (PGID) using system call
    ///
    /// Process Group ID is shared by all processes started by the same parent.
    /// For parallel tests, all worker processes share the same PGID since they're
    /// spawned by the same xcodebuild command.
    ///
    /// - Returns: Process Group ID
    static func getProcessGroupID() -> pid_t {
        return getpgid(getpid())
    }

    /// Get current Process ID (PID)
    ///
    /// - Returns: Current process ID
    static func getProcessID() -> pid_t {
        return getpid()
    }

    /// Check if RP_PARALLEL_WORKERS environment variable is set
    ///
    /// This environment variable explicitly declares the expected number of parallel workers,
    /// allowing deterministic coordination without timeout-based detection.
    ///
    /// - Returns: Number of expected workers, or nil if not set
    static func getParallelWorkerCount() -> Int? {
        guard let value = ProcessInfo.processInfo.environment["RP_PARALLEL_WORKERS"],
              let count = Int(value),
              count > 0 else {
            return nil
        }
        return count
    }

    /// Get device/simulator identifier
    ///
    /// - Returns: Device name for simulators, "Physical Device" for real devices
    static func getDeviceIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] {
            return deviceName
        } else {
            return "Unknown Simulator"
        }
        #else
        return "Physical Device"
        #endif
    }

    /// Check if running in a CI/CD environment
    ///
    /// Detects common CI environment variables
    ///
    /// - Returns: true if running in CI, false otherwise
    static func isRunningInCI() -> Bool {
        let ciEnvVars = ["CI", "CONTINUOUS_INTEGRATION", "GITHUB_ACTIONS", "GITLAB_CI", "JENKINS_URL"]

        for envVar in ciEnvVars {
            if ProcessInfo.processInfo.environment[envVar] != nil {
                return true
            }
        }

        return false
    }
}
