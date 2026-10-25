import Foundation

// MARK: - 缓存快照值类型（AIInfrastructure.CacheManager 产出，UI 经 AIServices 消费）

/// 一个条目在数据目录里扮演的角色。
///
/// 为什么不是一堆 Bool：面板要给每一行配图标、配色和「能不能清」的结论，
/// 三个独立布尔（`isLearningData` / `isCallLog` / `isDirectory`…）能组合出
/// 「既是资产又是留痕」这种不存在的形态，UI 里就得写优先级去压 ——
/// 单一枚举让**不可能的组合无法被构造出来**。
public enum CacheItemKind: String, Sendable, Equatable, CaseIterable {
    /// 学习记忆本体（库 / 配置）：清除缓存时**绝不触碰**。
    case learningData
    /// 对外调用留痕：**可以清**（清的时候进废纸篓），但它是用户跟服务商账单对账的证据，
    /// 界面上必须点名说清它是谁，不能混在普通文件里被顺手扫掉（#S3-5）。
    case callLog
    /// 用户发过的聊天素材（图片 / 文件原档）：是**资产**，清理缓存时不碰。
    case attachments
    /// 被隔离的坏库副本：留着是为了「有据可查」，可以由保留策略回收。
    case quarantine
    /// 其余条目（课程、材料、情景……）。
    case other

    /// 界面上的性质标签（nil = 这一行不打标签）。
    public var badge: String? {
        switch self {
        case .learningData: "学习记忆"
        case .callLog: "对账留痕"
        case .attachments: "用户素材"
        case .quarantine: "坏库隔离"
        case .other: nil
        }
    }
}

/// 数据目录中一个条目的空间占用。
public struct CacheItemInfo: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// 显示名（如「学习数据库」）。
    public var name: String
    /// 相对数据目录的文件名（如 learning.db；目录条目就是目录名）。
    public var fileName: String
    public var bytes: Int64
    /// 这个条目在数据目录里扮演的角色。
    public var kind: CacheItemKind
    /// 这是一个**目录**的合计行：子目录里的文件已递归汇总进 `bytes`。
    public var isDirectory: Bool
    /// 汇总进来多少个文件（目录条目才有意义；单文件条目恒为 1）。
    public var fileCount: Int

    /// 属于学习记忆本体（清除缓存时必须保留）。
    public var isLearningData: Bool { kind == .learningData }
    /// 对外调用留痕：可清，但清的是对账证据，界面要点名。
    public var isCallLog: Bool { kind == .callLog }

    public init(name: String,
                fileName: String,
                bytes: Int64,
                kind: CacheItemKind,
                isDirectory: Bool = false,
                fileCount: Int = 1) {
        self.name = name
        self.fileName = fileName
        self.bytes = bytes
        self.kind = kind
        self.isDirectory = isDirectory
        self.fileCount = fileCount
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
