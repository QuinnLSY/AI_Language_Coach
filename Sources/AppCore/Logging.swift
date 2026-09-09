import Foundation
import os

// MARK: - Log level

public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug
    case info
    case warning
    case error

    private var order: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.order < rhs.order }
}

// MARK: - Entry

public struct LogEntry: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, category: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

// MARK: - Bus

/// 进程内日志总线。
/// 硬约束：日志**禁止**记录转写文本、用户发言、Prompt 正文、音色参考路径等敏感内容（见 AGENTS.md §7）。
public actor LogBus {
    public static let shared = LogBus()

    private let osLogger = Logger(subsystem: "com.ailanguagecoach.app", category: "core")
    private var entries: [LogEntry] = []
    private let capacity = 500
    private var minimumLevel: LogLevel = .debug

    public func setMinimumLevel(_ level: LogLevel) { minimumLevel = level }

    public func log(_ level: LogLevel, category: String, message: String) {
        guard level >= minimumLevel else { return }
        let entry = LogEntry(level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        switch level {
        case .debug: osLogger.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .info: osLogger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .warning: osLogger.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error: osLogger.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
    }

    public func recent(limit: Int = 200) -> [LogEntry] {
        Array(entries.suffix(limit))
    }

    public func clear() { entries.removeAll() }
}

// MARK: - Convenience

public enum AppLog {
    public static func debug(_ message: String, category: String = "app") {
        Task.detached { await LogBus.shared.log(.debug, category: category, message: message) }
    }
    public static func info(_ message: String, category: String = "app") {
        Task.detached { await LogBus.shared.log(.info, category: category, message: message) }
    }
    public static func warning(_ message: String, category: String = "app") {
        Task.detached { await LogBus.shared.log(.warning, category: category, message: message) }
    }
    public static func error(_ message: String, category: String = "app") {
        Task.detached { await LogBus.shared.log(.error, category: category, message: message) }
    }
}
