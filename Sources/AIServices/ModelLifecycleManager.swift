import AIInfrastructure
import Foundation

/// 模型生命周期管理器（Implementation Plan §29：ModelLifecycleManager）。
///
/// 职责单一：**周期性巡检**内存压力与各模型的空闲时长，把「该挂起谁」的决策交给
/// `ResourcePolicy`（纯函数），把「怎么挂起」交给 `CoachServices.suspendModel`。
/// 它自己不做任何策略判断，也不直接碰 Provider。
///
/// 挂起 ≠ 用户关闭：被挂起的模型在下次被使用时会**自动恢复**（对用户透明）；
/// 用户在设置里点「关闭」的模型永远不会被本管理器触碰，也不会被自动拉起。
public actor ModelLifecycleManager {

    private weak var services: CoachServices?
    private let monitor: any MemoryPressureMonitoring
    private var tickTask: Task<Void, Never>?
    /// 每次巡检结束后回调（供 UI 把「启动 / 关闭」状态对齐真源——巡检可能刚挂起了模型）。
    private let onTickFinished: (@Sendable () async -> Void)?

    public init(services: CoachServices,
                monitor: any MemoryPressureMonitoring = OSMemoryPressureMonitor(),
                onTickFinished: (@Sendable () async -> Void)? = nil) {
        self.services = services
        self.monitor = monitor
        self.onTickFinished = onTickFinished
    }

    /// 启动周期巡检（幂等：已在跑则不动）。
    public func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // ⚠️ `nil` = 拥有者（`CoachServices`）已经没了 → **收工**（#S3-9）。
                // 原来是「这一轮什么都不做、照常返回一个间隔」，于是任务一辈子每 60 秒空醒一次，
                // 而 `stop()` 在生产代码里零调用 —— 没有任何人能停它。
                guard let interval = await self.runOnce() else { return }
                // 下次巡检间隔由配置决定；设 1s 下限防止配置错误导致忙转。
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
        }
    }

    /// 停止巡检（测试与降级用）。
    public func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// 执行一次巡检。返回下次巡检建议间隔（秒，来自配置）；**`nil` = 拥有者已经不在，该收工了**。
    ///
    /// ⚠️ 巡检会**真的挂起模型**（停掉本地服务）。真源在 `CoachServices`，而界面读的是它
    /// 自己那份快照缓存 —— 不回调刷新，设置页与使用处就会继续显示「运行中」
    /// （2026-09-19 语音识别「设置里明明开着、一用就连接失败」的放大器）。
    @discardableResult
    public func runOnce() async -> Double? {
        guard let services else { return nil }
        let interval = await services.runResourceTick(monitor: monitor)
        await onTickFinished?()
        return interval
    }
}
