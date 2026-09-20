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

// MARK: - 用户可调项（设置页）

/// 运行日志的**用户可调**选项：级别与清空。
///
/// 为什么落 `UserDefaults` 而不是设置页用 `@AppStorage`：级别必须在**启动那一刻**就生效，
/// 而启动路径（`AppState.start()`）拿不到视图的 `@AppStorage`。
///
/// ⚠️ 默认保持 `.debug`（= 全收，与历史行为一致）：项目里不少「写配置失败」的提示
/// 走的是 `AppLog.debug`，默认抬高门槛会让这些刚接上的留痕又看不见。
/// 抬高门槛是用户主动选择，不是我们替他决定的。
public enum LogOptions {

    private static let minimumLevelKey = "logging.minimumLevel"

    /// 生效中的最低级别（默认全收）。
    public static var minimumLevel: LogLevel {
        get {
            guard let raw = UserDefaults.standard.string(forKey: minimumLevelKey),
                  let level = LogLevel(rawValue: raw) else { return .debug }
            return level
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: minimumLevelKey)
            apply(newValue)
        }
    }

    /// 启动时调用一次，把用户上次选的级别装进日志总线。
    public static func applyPersistedLevel() {
        apply(minimumLevel)
    }

    /// 清空内存里的日志（os_log 那边的历史清不掉，这里只清设置页展示的这一份）。
    public static func clear() {
        Task.detached { await LogBus.shared.clear() }
    }

    private static func apply(_ level: LogLevel) {
        Task.detached {
            await LogBus.shared.setMinimumLevel(level)
            await LogBus.shared.log(.info, category: "log", message: "日志级别已设为 \(level.rawValue)")
        }
    }
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
