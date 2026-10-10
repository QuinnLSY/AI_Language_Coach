import Foundation

// MARK: - 自适应学习路径（V2 automatic learning path）
//
// 动机：仓库里真正「随时间变化」的自适应只有一处 —— 单词复习间隔（`ReviewScheduler` 的 ease）。
// 纠错密度趋势 `PracticeTrend`（进步 / 停滞 / 下滑）早就由 `LearningMemory` 算出来了，
// 却只进过提示词与记忆卡的展示，**没有任何一处拿它改安排**；每日任务不看昨天、
// 定级每次重算不演进、AI 排的课排完就静止。于是「自适应学习系统」在代码里只兑现了六分之一。
//
// 本文件补的是**「趋势 → 当下该做什么」**这一层：把已经算好的信号聚成一句话，
// 并复用 `LearningPlanFocus.Action` 落到**已有**的练习上（不新开链路）。
//
// ⚠️ 只做判定与措辞，**不新造真源**：
// - 纠错密度趋势 → `PracticeTrend`（真源 `LearningMemory`）
// - 发音走势 → `ProgressSnapshot.pronunciationTrend`（真源 `ProgressAggregator`）
// - 短板数量 → 学习记忆的反复错 / 顽固音素（真源各自的服务）
// - 档位是否可信 → `PlacementEstimate.isConfident`（真源 `PlacementEstimator`）
// 口径要改就改在各自的真源里，这里不许长出第二套算法。
//
// ⚠️ 全是纯函数：不碰 IO、不碰 UI、不读时钟（需要「现在」的量由调用方算好传进来）。

/// 判定用的输入快照。
///
/// ⚠️ 数量一律在 `init` 里夹到 ≥ 0：负数是调用方算错的信号，
/// 放过去会变成「-1 处错没练掉」这种说不通的文案。
public struct AdaptivePathSignals: Sendable, Equatable {

    /// 纠错密度趋势（最近 vs 更早）。
    public var trend: PracticeTrend
    /// 还没练掉的反复错条数。
    public var pendingErrors: Int
    /// 顽固音素个数。
    public var weakPhonemes: Int
    /// 今天起初到期、还没复习的词数。
    public var dueVocabulary: Int
    /// 能力定位是否可信（样本够不够）。
    public var isPlacementConfident: Bool
    /// 发音分的按日序列（**由旧到新**；没有练习的日子不进序列）。
    public var pronunciationPoints: [TrendPoint]

    public init(
        trend: PracticeTrend,
        pendingErrors: Int,
        weakPhonemes: Int,
        dueVocabulary: Int,
        isPlacementConfident: Bool,
        pronunciationPoints: [TrendPoint] = []
    ) {
        self.trend = trend
        self.pendingErrors = max(pendingErrors, 0)
        self.weakPhonemes = max(weakPhonemes, 0)
        self.dueVocabulary = max(dueVocabulary, 0)
        self.isPlacementConfident = isPlacementConfident
        self.pronunciationPoints = pronunciationPoints
    }

    /// 有没有明确短板（从他自己犯的错里长出来的那两类）。
    public var hasBacklog: Bool { pendingErrors > 0 || weakPhonemes > 0 }
}

/// 当下该走哪条路。
public enum AdaptivePathStance: String, Sendable, Equatable, CaseIterable {

    /// 样本还不够，不下结论。
    case observing
    /// 有短板：先补。
    case reinforce
    /// 没短板但最近在往下走 / 平平：稳住。
    case consolidate
    /// 没短板且最近在进步：往前推。
    case advance

    /// 一句话结论（给用户看的，不是日志）。
    public var headline: String {
        switch self {
        case .observing: "还在看你练，先不急着下结论"
        case .reinforce: "先把短板补上"
        case .consolidate: "稳住现在的节奏"
        case .advance: "可以往前推一档"
        }
    }

    /// 徽标图标（与「学习计划」卡同一套 SF Symbol 口径，别为同一件事换第二套）。
    public var symbolName: String {
        switch self {
        case .observing: "hourglass"
        case .reinforce: "hammer.fill"
        case .consolidate: "equal.circle.fill"
        case .advance: "arrow.up.forward.circle.fill"
        }
    }
}

/// 一次判定的结果。
///
/// ⚠️ `reasons` 每条都必须**可核对**（带数量或比率），与 `DailyTask.reason` /
/// `LearningPlanFocus.reason` 同一条纪律 —— 不许出现「你该多练练」这种形容词。
public struct AdaptivePath: Sendable, Equatable {

    public var stance: AdaptivePathStance
    /// 依据（≥ 1 条）。
    public var reasons: [String]
    /// 接着做什么（复用 `LearningPlanFocus.Action`，由 AppUI 映射到已有动作）。
    public var nextActions: [LearningPlanFocus.Action]

    public init(
        stance: AdaptivePathStance,
        reasons: [String],
        nextActions: [LearningPlanFocus.Action]
    ) {
        self.stance = stance
        self.reasons = reasons
        self.nextActions = nextActions
    }

    public var headline: String { stance.headline }

    /// 有没有可执行的下一步。
    public var hasNextAction: Bool { !nextActions.isEmpty }
}

// MARK: - 判定（纯函数）

public enum AdaptivePathRule {

    /// 发音走势：升 / 平 / 降。**样本不够返回 nil**（与 `PracticeTrend.Direction.unknown` 同一口径）。
    ///
    /// ⚠️ 判据是**前后两半的均值差**，不是首尾两点之差：首尾只看两个点，
    /// 某天一次走音就能把结论翻过来。少于 4 个点不下结论。
    public static func pronunciationSlope(_ points: [TrendPoint]) -> Slope? {
        guard points.count >= 4 else { return nil }
        let half = points.count / 2
        guard half >= 2 else { return nil }
        let earlier = Self.mean(points[0..<half])
        let recent = Self.mean(points[half..<points.count])
        guard earlier.isFinite, recent.isFinite else { return nil }
        if recent - earlier >= Self.pronunciationThreshold { return .up }
        if earlier - recent >= Self.pronunciationThreshold { return .down }
        return .flat
    }

    /// 发音走势的方向。
    public enum Slope: String, Sendable, Equatable {
        case up
        case flat
        case down
    }

    /// 前后两半均值差多少才算「变了」（发音分是百分制，2 分以内当平）。
    static let pronunciationThreshold = 2.0

    static func mean(_ slice: ArraySlice<TrendPoint>) -> Double {
        guard !slice.isEmpty else { return .nan }
        return slice.reduce(0.0) { $0 + $1.value } / Double(slice.count)
    }

    /// 判定当下该走哪条路。
    ///
    /// 判据顺序是刻意的：
    /// ① **样本不足一律不下结论**（宁可说「还在看」，也不给一个看着确定的错方向）；
    /// ② **有短板先补短板** —— 反复错与顽固音素是**从他自己犯的错里长出来的**，
    ///    比推进新材料值钱（与 `LearningPlanner.focusItems` 的排序纪律一致）；
    /// ③ 没短板时看趋势：在掉 → 稳住；在进步 → 往前推；平平 → 稳住。
    public static func evaluate(_ signals: AdaptivePathSignals) -> AdaptivePath {
        let slope = pronunciationSlope(signals.pronunciationPoints)

        // ① 样本不足：档位还不可信、连纠错趋势都没结论。
        if !signals.isPlacementConfident && signals.trend.direction == .unknown {
            return AdaptivePath(
                stance: .observing,
                reasons: Self.observingReasons(signals),
                nextActions: [.conversation]
            )
        }

        // ② 有短板：先补。
        if signals.hasBacklog {
            return AdaptivePath(
                stance: .reinforce,
                reasons: Self.backlogReasons(signals, slope: slope),
                nextActions: Self.backlogActions(signals)
            )
        }

        // ③ 没短板：看趋势。
        if signals.trend.direction == .slipping || slope == .down {
            return AdaptivePath(
                stance: .consolidate,
                reasons: Self.slippingReasons(signals, slope: slope),
                nextActions: [.shadowing, .conversation]
            )
        }

        if signals.trend.direction == .improving {
            return AdaptivePath(
                stance: .advance,
                reasons: Self.improvingReasons(signals, slope: slope),
                nextActions: [.conversation, .shadowing]
            )
        }

        return AdaptivePath(
            stance: .consolidate,
            reasons: Self.steadyReasons(signals, slope: slope),
            nextActions: [.shadowing, .conversation]
        )
    }

    // MARK: - 措辞（每条都带可核对的量）

    static func observingReasons(_ signals: AdaptivePathSignals) -> [String] {
        var reasons: [String] = []
        if signals.pendingErrors > 0 || signals.weakPhonemes > 0 || signals.dueVocabulary > 0 {
            reasons.append("已经记下 \(signals.pendingErrors + signals.weakPhonemes + signals.dueVocabulary) 条线索")
        }
        reasons.append("但练过的轮数还不够，先不下结论")
        return reasons
    }

    static func backlogReasons(_ signals: AdaptivePathSignals, slope: Slope?) -> [String] {
        var reasons: [String] = []
        if signals.pendingErrors > 0 {
            reasons.append("学习记忆里有 \(signals.pendingErrors) 处反复错还没练掉")
        }
        if signals.weakPhonemes > 0 {
            reasons.append("\(signals.weakPhonemes) 个音反复念错")
        }
        if let line = Self.trendLine(signals.trend) { reasons.append(line) }
        if let line = Self.slopeLine(slope) { reasons.append(line) }
        return reasons
    }

    static func slippingReasons(_ signals: AdaptivePathSignals, slope: Slope?) -> [String] {
        var reasons: [String] = []
        if let line = Self.trendLine(signals.trend) { reasons.append(line) }
        if let line = Self.slopeLine(slope) { reasons.append(line) }
        if reasons.isEmpty {
            reasons.append("最近 \(signals.trend.sessionCount) 轮里没什么明显变化，先稳住手感")
        }
        return reasons
    }

    static func improvingReasons(_ signals: AdaptivePathSignals, slope: Slope?) -> [String] {
        var reasons: [String] = []
        if let line = Self.trendLine(signals.trend) { reasons.append(line) }
        if let line = Self.slopeLine(slope) { reasons.append(line) }
        if reasons.isEmpty {
            reasons.append("最近 \(signals.trend.sessionCount) 轮比之前顺，可以加一点难度")
        }
        return reasons
    }

    static func steadyReasons(_ signals: AdaptivePathSignals, slope: Slope?) -> [String] {
        var reasons: [String] = []
        if let line = Self.trendLine(signals.trend) { reasons.append(line) }
        if let line = Self.slopeLine(slope) { reasons.append(line) }
        if reasons.isEmpty {
            reasons.append("短板清完了，最近也平稳 —— 接着保持")
        }
        return reasons
    }

    /// 纠错密度那句话（**带前后两个数**，用户能自己核对）。
    ///
    /// ⚠️ 密度是「每轮被纠几次错」，越小越好；措辞必须说清方向，别让人看反。
    static func trendLine(_ trend: PracticeTrend) -> String? {
        guard let recent = trend.recentRate, let earlier = trend.earlierRate else { return nil }
        let r = String(format: "%.2f", recent)
        let e = String(format: "%.2f", earlier)
        switch trend.direction {
        case .improving:
            return "最近 \(trend.sessionCount) 轮每轮平均被纠 \(r) 次，比之前的 \(e) 少了"
        case .slipping:
            return "最近 \(trend.sessionCount) 轮每轮平均被纠 \(r) 次，比之前的 \(e) 多了"
        case .steady:
            return "最近 \(trend.sessionCount) 轮每轮平均被纠 \(r) 次，和之前的 \(e) 差不多"
        case .unknown:
            return nil
        }
    }

    /// 发音走势那句话。
    static func slopeLine(_ slope: Slope?) -> String? {
        switch slope {
        case .up: return "近几天的发音分在往上走"
        case .down: return "近几天的发音分在往下走"
        case .flat, nil: return nil
        }
    }

    /// 补短板时先做什么：错题 → 顽固音素 → 到期词（与计划卡同一顺序）。
    ///
    /// ⚠️ 三样都清完时落到跟读，不留一个空数组 —— 「有短板」这个分支下不可能没有下一步。
    static func backlogActions(_ signals: AdaptivePathSignals) -> [LearningPlanFocus.Action] {
        var actions: [LearningPlanFocus.Action] = []
        if signals.pendingErrors > 0 { actions.append(.errorDrill) }
        if signals.weakPhonemes > 0 { actions.append(.phonemeDrill) }
        if signals.dueVocabulary > 0 { actions.append(.vocabulary) }
        return actions.isEmpty ? [.shadowing] : actions
    }
}
