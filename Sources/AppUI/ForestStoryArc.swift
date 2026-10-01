import Foundation

// MARK: - 连续剧情（#418-C：动物会按「这一轮学习的故事」演戏，不再纯随机）

/// 一条史官记录：学习上发生的一件事（什么时候、什么类型）。
///
/// 与脉冲（`ForestStage` 的各种 tick）互补：脉冲只回答「又发生了一件什么事，
/// 演一遍」，不记历史；剧情要认出「一段时间里发生了**一组**什么事」，
/// 所以需要带时刻的历史。载荷（哪个词、哪一关）依然不进来 —— 树不演戏码内容，
/// 只演「该有的情绪」。
public struct ForestStoryBeat: Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        /// 练完一段 / 完成模块。
        case practiced
        /// 攒星。
        case starEarned
        /// 通关。
        case levelCleared
        /// 对话在场（学员或老师开口）。
        case spoke
        /// 被纠错。
        case stumbled
    }

    public let kind: Kind
    public let at: Date

    public init(kind: Kind, at: Date) {
        self.kind = kind
        self.at = at
    }
}

/// 幕判定（纯函数）：从事件历史里认出「值得演的一幕」。
///
/// 三幕都是会话级的 —— 每一幕整个会话最多演一次（`performedActs` 记账），
/// 幕与幕之间有冷却 —— 连着演就像放幻灯片，不成「剧情」了。
///
/// 为什么判据收在这里：树的心跳只管演，`ForestStage` 只管记账，
/// 「什么算专注、什么算收获」是一条断言就能钉死的事，不该散在视图里。
public enum ForestStoryArc {

    public enum Act: Equatable, Sendable, CaseIterable {
        /// 收获：攒到第二颗星 —— 枝头真的结果了，值得庆祝一下。
        case harvest
        /// 安可：通关之后还在练 ——「再来一段」的劲头要被看见。
        case encore
        /// 专注：十分钟里练满三段 —— 安静的认可，不吵。
        case focus
    }

    /// 「专注」幕的观察窗口（秒）与门槛（窗口内练满几段）。
    public static let focusWindow: TimeInterval = 600
    public static let focusThreshold = 3
    /// 「收获」幕的门槛：攒到第几颗星出幕。
    public static let harvestThreshold = 2
    /// 幕间冷却（秒）：上一幕演完这么久之内不出新幕。
    public static let cooldown: TimeInterval = 120

    /// 判定该不该出幕（纯函数）。
    ///
    /// - 优先级：收获 > 安可 > 专注（庆祝的事优先于安静的认可）；
    /// - 演过的幕不重演；冷却期内一律不出幕。
    public static func pendingAct(beats: [ForestStoryBeat], now: Date,
                                  performedActs: Set<Act>,
                                  lastActAt: Date?) -> Act? {
        if let lastActAt, now.timeIntervalSince(lastActAt) < cooldown { return nil }

        func count(_ kind: ForestStoryBeat.Kind) -> Int {
            beats.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
        }

        if count(.starEarned) >= harvestThreshold, !performedActs.contains(.harvest) {
            return .harvest
        }
        // 安可：通关过，且**最新一次练习在通关之后**（通关了还在练才算安可）。
        if !performedActs.contains(.encore), count(.levelCleared) > 0 {
            let clearedAt = beats.last { $0.kind == .levelCleared }?.at
            let practicedAt = beats.last { $0.kind == .practiced }?.at
            if let clearedAt, let practicedAt, practicedAt > clearedAt {
                return .encore
            }
        }
        // 专注：观察窗口内练满三段。
        if !performedActs.contains(.focus) {
            let windowStart = now.addingTimeInterval(-focusWindow)
            let recent = beats.reduce(0) {
                $0 + ($1.kind == .practiced && $1.at >= windowStart ? 1 : 0)
            }
            if recent >= focusThreshold { return .focus }
        }
        return nil
    }
}
