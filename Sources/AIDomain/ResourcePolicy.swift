import AppCore
import Foundation

/// 第 27 步「资源管理」的决策层（Implementation Plan §29 / AGENTS §9，纯函数，脱机可测）。
///
/// 目标：16GB 统一内存上**不把所有大模型同时常驻**——
/// - 空闲的本地模型按各自超时自动挂起（把内存还给系统）；
/// - 内存吃紧时优先挂起「最久未用且不在对话活跃窗口内」的模型（MemoryBudget）；
/// - 用户显式关闭的、已挂起的、云端 Provider（本应用无法终止外部服务）永不触碰；
/// - 对话活跃窗口内的模型绝不动（用户正在用）。
///
/// 阈值全部由调用方注入（配置驱动），本层零字面量。
public enum ResourcePolicy {

    /// 一个能力在资源管理视角下的快照。
    public struct ModelState: Sendable, Equatable {
        public let kind: AIProviderKind
        /// 是否真的可被本应用挂起（本地且实现了真实服务控制；云端 / mock 不可）。
        public let isUnloadable: Bool
        public let isUserStopped: Bool
        public let isSuspended: Bool
        /// 距上次实际使用的秒数；nil = 装配后从未使用（按「最冷」处理）。
        public let idleSeconds: Double?

        public init(kind: AIProviderKind, isUnloadable: Bool, isUserStopped: Bool,
                    isSuspended: Bool, idleSeconds: Double?) {
            self.kind = kind
            self.isUnloadable = isUnloadable
            self.isUserStopped = isUserStopped
            self.isSuspended = isSuspended
            self.idleSeconds = idleSeconds
        }

        /// 距上次使用的秒数；从未使用视为无穷大（最冷）。
        public var effectiveIdleSeconds: Double { idleSeconds ?? .infinity }

        /// 是否处于「对话活跃窗口」内（用户正在用，绝不能挂起）。
        public func isActive(within activeWindowSeconds: Double) -> Bool {
            effectiveIdleSeconds < activeWindowSeconds
        }
    }

    /// 内存预算：可用内存低于下限即为「吃紧」。
    ///
    /// `availableMemoryBytes == nil`（系统不告知）时**保守地视为不紧张**——
    /// 宁可多留一会儿，也不在信息缺失时误杀模型。
    public struct MemoryBudget: Sendable, Equatable {
        public let minAvailableBytes: Double

        public init(minAvailableBytes: Double) {
            self.minAvailableBytes = max(0, minAvailableBytes)
        }

        public func isUnderPressure(availableMemoryBytes: Double?) -> Bool {
            guard let available = availableMemoryBytes else { return false }
            return available < minAvailableBytes
        }
    }

    /// 一次性给出本 tick 应当挂起的能力（有序：内存压力优先，其次空闲超时；都按最冷优先）。
    ///
    /// - Parameters:
    ///   - states: 各能力的资源快照（含启停意图与空闲时长）。
    ///   - idleTimeouts: 各能力的空闲卸载超时（秒）。**不在字典里的能力 = 永不按空闲卸载**
    ///     （例如 TTS：重启成本高，默认只在内存吃紧时才挂起）。
    ///   - activeWindowSeconds: 对话活跃窗口；窗口内的模型任何规则都不碰。
    ///   - budget: 内存预算（可用内存低于下限 = 压力卸载生效）。
    public static func suspendDecisions(
        states: [ModelState],
        idleTimeouts: [AIProviderKind: Double],
        activeWindowSeconds: Double,
        budget: MemoryBudget,
        availableMemoryBytes: Double?
    ) -> [AIProviderKind] {
        let eligible = states.filter {
            $0.isUnloadable && !$0.isUserStopped && !$0.isSuspended
        }
        let coldestFirst = { (a: ModelState, b: ModelState) in
            a.effectiveIdleSeconds > b.effectiveIdleSeconds
        }

        // 规则 A（内存压力）：可用内存低于预算下限 → 挂起活跃窗口之外的所有可挂起模型，
        // 最冷的先走。活跃窗口内的（正在对话 / 刚说完话）绝不动。
        var decisions: [AIProviderKind] = []
        if budget.isUnderPressure(availableMemoryBytes: availableMemoryBytes) {
            decisions.append(contentsOf:
                eligible.filter { !$0.isActive(within: activeWindowSeconds) }
                    .sorted(by: coldestFirst)
                    .map(\.kind))
        }

        // 规则 B（空闲超时）：只在配置了超时的能力上生效（TTS 等默认不在字典 → 永不）。
        let idleCandidates = eligible.filter { state in
            guard let timeout = idleTimeouts[state.kind] else { return false }
            return state.effectiveIdleSeconds > timeout
        }.sorted(by: coldestFirst).map(\.kind)

        for kind in idleCandidates where !decisions.contains(kind) {
            decisions.append(kind)
        }
        return decisions
    }
}
