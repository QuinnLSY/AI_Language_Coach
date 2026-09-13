import AIInfrastructure
import Foundation

/// 备份记录在 UI 层的形态。
///
/// UI **不许**直接依赖 AIInfrastructure 的类型（架构红线），所以导出到这里时换一层壳：
/// 只带界面要显示的字段，把所有 IO 类型留在服务层里面。
public struct BackupRecord: Sendable, Identifiable, Equatable {

    public let url: URL
    public let createdAt: Date
    /// 已经格式化好的体积（避免 UI 里再做一次换算）。
    public let sizeDisplay: String
    /// 文件名（`AI_Language_Coach_备份_20260914-010000.zip`）。
    public let fileName: String

    public init(url: URL, createdAt: Date, sizeDisplay: String, fileName: String) {
        self.url = url
        self.createdAt = createdAt
        self.sizeDisplay = sizeDisplay
        self.fileName = fileName
    }

    init(_ snapshot: DataBackup.Snapshot) {
        self.init(
            url: snapshot.url,
            createdAt: snapshot.createdAt,
            sizeDisplay: snapshot.sizeDisplay,
            fileName: snapshot.url.lastPathComponent
        )
    }

    public var id: String { url.path }
}
