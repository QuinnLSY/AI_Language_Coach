import AppCore
import Foundation

/// 落库失败的唯一记账处（#静默失败批次）。
///
/// 为什么不能再「各服务自己吞掉」：星星、关卡进度、复盘、复习调度、跟读成绩这些
/// **不可逆的学习成果**分散在好几个服务里写入。谁写失败都只是自己 `try?` 一下的话，
/// 结果就是设置页那条「学习记录有 N 次没保存成功」永远显示 0 次 —— 用户以为都存住了，
/// 其实一分没进库。
///
/// 用法与 `LearningEventBus` 同一套路：唯一实例由 `CoachServices` 持有并注入子服务，
/// UI 只从 `services.persistenceFailureCount` 读。
///
/// ⚠️ 注入时**不给默认值**：默认一个新实例会让子服务记在自己那份里、UI 看不到，
/// 那正是本批次要修的「失败无声」形态 —— 漏了注入就让编译器报错带路。
public actor PersistenceFailureRecorder {

    /// 累计失败次数（UI 据此决定要不要挂横幅）。
    public private(set) var count = 0
    /// 最近一次失败的「动作 + 原因」。
    public private(set) var lastDescription: String?

    public init() {}

    /// 记一笔落库失败。
    ///
    /// - Parameters:
    ///   - action: 用户在做什么（如「保存这段对话」）—— 文案面向用户，不要写技术名词。
    ///   - error: 底层错误；nil 表示「库根本不可用」（连错误都拿不到）。
    public func record(_ action: String, _ error: Error?) {
        count += 1
        let reason = error.map { Self.describe($0) } ?? "学习记录库不可用"
        lastDescription = "\(action)：\(reason)"
        AppLog.error("落库失败（第 \(count) 次）\(action)：\(reason)", category: "database")
    }

    /// 错误文案取 `LocalizedError.errorDescription`（`AppError` 六档都实现了），
    /// 系统错误退到 `localizedDescription` —— 一律不加品类前缀（前缀让消息看着像片段，
    /// 还会和动作名叠成三冒号，见 `AppErrorTextTests`）。
    public static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
