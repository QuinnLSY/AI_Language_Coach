import AppCore
import Foundation

/// 本进程**亲手拉起**的本地服务登记簿（自停的台账）。
///
/// 语义（退出自停的判定依据）：
/// - 只有走过 `LocalServiceControl.start` 并且启动成功的服务才在册 —— 那意味着命令是
///   **本应用**执行的；
/// - 启动前就在跑的服务（用户自己拉的、上一次退出残留的）不在册，退出时不碰；
/// - Ollama 的 `keep_alive` 载入不走 `LocalServiceControl.start`，也就不会被误停。
///
/// 进程级单例（`shared`）：登记发生在 `LocalServiceControl` 这个静态入口里，
/// 不随 `CoachServices` 实例走，退出收尾才能在拿不到 AppState 时也读得到。
public actor LaunchedLocalServices {

    public static let shared = LaunchedLocalServices()

    /// 按 Provider id 去重在册服务（同一 Provider 重复启动只留最后一次配置）。
    private var launched: [String: ProviderConfig] = [:]

    private init() {}

    /// 登记一个由本应用拉起的服务。
    public func record(_ config: ProviderConfig) {
        launched[config.id] = config
    }

    /// 注销一个服务（停止成功时调用；失败不注销，下次退出重试）。
    public func remove(id: String) {
        launched[id] = nil
    }

    /// 在册服务快照，按 id 排序保证顺序确定（日志与测试可比对）。
    public func snapshot() -> [ProviderConfig] {
        launched.values.sorted { $0.id < $1.id }
    }

    /// 仅供测试：清空进程级登记簿。
    /// ⚠️ 登记簿是进程全局的，`ModelControlTests` 里真跑启动命令的用例会留下记录，
    /// 污染后续断言 —— 各用例体内 `await LaunchedLocalServices.shared.resetForTesting()`
    /// （不能放 `setUp/tearDown`：那是 nonisolated 同步上下文，碰不了 actor）。
    public func resetForTesting() {
        launched.removeAll()
    }
}
