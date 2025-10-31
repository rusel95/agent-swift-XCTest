//
//  Logger.swift
//  ReportPortalAgent
//
//  Created by Ruslan Popesku on 10/22/25.
//  Copyright © 2025 ReportPortal. All rights reserved.
//

import Foundation

// Conditionally import Sentry if available
#if canImport(Sentry)
import Sentry
#endif

/// Log level severity
enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    var description: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

/// Structured logging utility with correlation ID support for debugging parallel execution.
struct Logger {
    /// Shared singleton instance
    static let shared = Logger()

    /// Whether logging is enabled (from environment variable or default)
    let enabled: Bool

    /// Minimum log level to output
    let minLevel: LogLevel

    private init() {
        // Check environment variable RP_LOG_ENABLED
        if let envValue = ProcessInfo.processInfo.environment["RP_LOG_ENABLED"],
           envValue.lowercased() == "true" || envValue == "1" {
            self.enabled = true
        } else {
            self.enabled = false
        }

        // Check environment variable RP_LOG_LEVEL
        if let envLevel = ProcessInfo.processInfo.environment["RP_LOG_LEVEL"] {
            switch envLevel.uppercased() {
            case "DEBUG":
                self.minLevel = .debug
            case "INFO":
                self.minLevel = .info
            case "WARNING", "WARN":
                self.minLevel = .warning
            case "ERROR":
                self.minLevel = .error
            default:
                self.minLevel = .info
            }
        } else {
            self.minLevel = .info
        }
    }

    /// Log a message with specified level and optional correlation ID
    /// - Parameters:
    ///   - message: Log message
    ///   - level: Log level (default: .info)
    ///   - correlationID: Optional correlation ID for tracing
    ///   - file: Source file (auto-populated)
    ///   - line: Source line (auto-populated)
    func log(
        _ message: String,
        level: LogLevel = .info,
        correlationID: UUID? = nil,
        file: String = #file,
        line: Int = #line
    ) {
        guard enabled else { return }
        guard level >= minLevel else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let thread = Thread.current.name ?? Thread.current.description
        let fileName = (file as NSString).lastPathComponent

        var logMessage = "[\(timestamp)]"
        logMessage += " [\(thread)]"
        if let corID = correlationID {
            logMessage += " [\(corID.uuidString.prefix(8))]"
        }
        logMessage += " [\(level.description)]"
        logMessage += " [\(fileName):\(line)]"
        logMessage += " \(message)"

        print(logMessage)

        // Send warnings and errors to Sentry for distributed logging
        #if canImport(Sentry)
        if level == .warning || level == .error {
            sendToSentry(message: message, level: level, correlationID: correlationID, file: fileName, line: line)
        }
        #endif
    }

    #if canImport(Sentry)
    /// Send log event to Sentry with context
    /// - Parameters:
    ///   - message: Log message
    ///   - level: Log level
    ///   - correlationID: Optional correlation ID
    ///   - file: Source file name
    ///   - line: Source line number
    private func sendToSentry(
        message: String,
        level: LogLevel,
        correlationID: UUID?,
        file: String,
        line: Int
    ) {
        // Add breadcrumb for all warnings/errors
        let breadcrumb = Breadcrumb(level: level == .error ? .error : .warning, category: "agent")
        breadcrumb.message = message
        breadcrumb.data = [
            "file": file,
            "line": line,
            "thread": Thread.current.name ?? Thread.current.description
        ]
        if let corID = correlationID {
            breadcrumb.data?["correlationID"] = corID.uuidString
        }
        SentrySDK.addBreadcrumb(breadcrumb)

        // For errors, also capture as an event
        if level == .error {
            let event = Event(level: .error)
            event.message = SentryMessage(formatted: message)
            event.tags = [
                "component": "ReportPortalAgent",
                "file": file
            ]
            if let corID = correlationID {
                event.tags?["correlationID"] = corID.uuidString
            }

            // Add context
            event.extra = [
                "line": line,
                "thread": Thread.current.name ?? Thread.current.description,
                "pid": getpid(),
                "pgid": getpgid(getpid())
            ]

            SentrySDK.capture(event: event)
        }
    }
    #endif

    /// Log a debug message
    /// - Parameters:
    ///   - message: Log message
    ///   - correlationID: Optional correlation ID
    func debug(_ message: String, correlationID: UUID? = nil, file: String = #file, line: Int = #line) {
        log(message, level: .debug, correlationID: correlationID, file: file, line: line)
    }

    /// Log an info message
    /// - Parameters:
    ///   - message: Log message
    ///   - correlationID: Optional correlation ID
    func info(_ message: String, correlationID: UUID? = nil, file: String = #file, line: Int = #line) {
        log(message, level: .info, correlationID: correlationID, file: file, line: line)
    }

    /// Log a warning message
    /// - Parameters:
    ///   - message: Log message
    ///   - correlationID: Optional correlation ID
    func warning(_ message: String, correlationID: UUID? = nil, file: String = #file, line: Int = #line) {
        log(message, level: .warning, correlationID: correlationID, file: file, line: line)
    }

    /// Log an error message
    /// - Parameters:
    ///   - message: Log message
    ///   - correlationID: Optional correlation ID
    func error(_ message: String, correlationID: UUID? = nil, file: String = #file, line: Int = #line) {
        log(message, level: .error, correlationID: correlationID, file: file, line: line)
    }
}
