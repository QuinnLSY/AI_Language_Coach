import Foundation

// MARK: - 缓存快照值类型（AIInfrastructure.CacheManager 产出，UI 经 AIServices 消费）

/// 数据目录中一个条目的空间占用。
public struct CacheItemInfo: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// 显示名（如「学习数据库」）。
    public var name: String
    /// 相对数据目录的文件名（如 learning.db）。
    public var fileName: String
    public var bytes: Int64
    /// 属于学习记忆本体（清除缓存时必须保留）。
    public var isLearningData: Bool

    public init(name: String, fileName: String, bytes: Int64, isLearningData: Bool) {
        self.name = name
        self.fileName = fileName
        self.bytes = bytes
        self.isLearningData = isLearningData
    }
}

/// 数据目录缓存快照（大小 / 目录 / 条目明细）。
public struct CacheSnapshot: Sendable, Equatable {
    public var directory: String
    public var totalBytes: Int64
    public var items: [CacheItemInfo]
    /// 上次清理时间（nil = 从未清理）。
    public var lastClearedAt: Date?

    public init(directory: String, totalBytes: Int64, items: [CacheItemInfo], lastClearedAt: Date? = nil) {
        self.directory = directory
        self.totalBytes = totalBytes
        self.items = items
        self.lastClearedAt = lastClearedAt
    }

    public static let empty = CacheSnapshot(directory: "", totalBytes: 0, items: [])

    /// 人类可读的大小（KB / MB）。
    public var totalDisplay: String { Self.byteCount(totalBytes) }

    public static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
