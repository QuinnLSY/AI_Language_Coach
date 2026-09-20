import AIInfrastructure
import Foundation

/// 备份导入校验结果在 UI 层的形态（与 `BackupRecord` 同理：UI 不直接依赖 AIInfrastructure 类型）。
///
/// 只带确认框要展示的字段：替换范围与是否有调用留痕，校验细节（zip 完整性、SQLite 头、
/// JSON 合法性）都留在服务层里。
public struct BackupImportPlan: Sendable, Equatable {

    /// 替换范围说明：`学习库、配置`。
    public let scopeDescription: String
    /// 是否连调用留痕一起替换（展示用）。
    public let includesCallLog: Bool

    public init(scopeDescription: String, includesCallLog: Bool) {
        self.scopeDescription = scopeDescription
        self.includesCallLog = includesCallLog
    }

    public init(_ plan: DataBackup.ImportPlan) {
        self.init(
            scopeDescription: plan.scopeDescription,
            includesCallLog: plan.includesCallLog
        )
    }
}
