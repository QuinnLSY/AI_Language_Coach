import AppCore
import Foundation

// MARK: - 每日任务推荐（PRD §7.1 Today's Focus / §7 今日学习状态）
//
// 硬要求：**推荐逻辑与 UI 分离** —— 排哪几项任务、目标定多少、算不算完成，
// 全是纯函数，本文件不 import 任何 UI / IO。
//
// 设计取舍（重要）：
// - 任务的完成度**来自真实记录**（今天的消息数、跟读次数、词条的 `lastReviewedAt`），
//   **不让用户自己打勾** —— 自己打勾的清单只会变成自我安慰。
// - 推荐理由必须是**可核对的说法**（「8 个词到期」），不是形容词（「你该练练了」）。

/// 一条今日任务。
public struct DailyTask: Sendable, Equatable, Identifiable {

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// 开口对话：和老师聊几句。
        case conversation
        /// 跟读纠音。
        case shadowing
        /// 复习到期单词。
        case review

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .conversation: "开口对话"
            case .shadowing: "跟读纠音"
            case .review: "复习单词"
            }
        }

        public var systemImage: String {
            switch self {
            case .conversation: "bubble.left.and.bubble.right.fill"
            case .shadowing: "waveform.badge.mic"
            case .review: "text.book.closed.fill"
            }
        }
    }

    public var kind: Kind
    /// 做什么（「和老师聊 4 轮」）。
    public var title: String
    /// 为什么今天推荐它 —— 可核对的依据。
    public var reason: String
    /// 目标量。
    public var target: Int
    /// 已完成量（来自真实记录）。
    public var progress: Int
    /// 单位（「轮」/「次」/「个词」）。
    public var unit: String

    public var id: String { kind.rawValue }

    public init(kind: Kind, title: String, reason: String, target: Int, progress: Int, unit: String) {
        self.kind = kind
        self.title = title
        self.reason = reason
        self.target = max(target, 1)
        self.progress = max(progress, 0)
        self.unit = unit
    }

    public var isDone: Bool { progress >= target }

    /// 0...1（超额算满，不显示 120%）。
    public var progressRatio: Double { min(Double(progress) / Double(target), 1) }

    /// 「3 / 5 个词」。
    public var progressText: String { "\(min(progress, target)) / \(target) \(unit)" }
}

/// 今天的计划：几项具体任务 + 一句「今天重点」。
public struct DailyPlan: Sendable, Equatable {

    /// 「今天的重点」：只说明方向，不产生可勾选项。
    public struct Focus: Sendable, Equatable {
        public var title: String
        /// 依据（「最近 12 处批注里有 5 处在时态上」）。
        public var reason: String

        public init(title: String, reason: String) {
            self.title = title
            self.reason = reason
        }
    }

    /// 计划归属的那一天（当天 0 点）。
    public var day: Date
    public var tasks: [DailyTask]
    public var focus: Focus?

    public init(day: Date, tasks: [DailyTask] = [], focus: Focus? = nil) {
        self.day = day
        self.tasks = tasks
        self.focus = focus
    }

    public static let empty = DailyPlan(day: Date())

    public var completedCount: Int { tasks.filter(\.isDone).count }
    public var totalCount: Int { tasks.count }
    public var isAllDone: Bool { !tasks.isEmpty && completedCount == tasks.count }

    /// 「2 / 3 项」。
    public var progressText: String { "\(completedCount) / \(totalCount) 项" }

    /// 整体完成度 0...1（没有任务时为 0）。
    public var progressRatio: Double {
        guard !tasks.isEmpty else { return 0 }
        return Double(completedCount) / Double(tasks.count)
    }

    /// 还没做完的那一项（UI 用来决定「接着做什么」）。
    public var nextTask: DailyTask? { tasks.first { !$0.isDone } }
}

// MARK: - 当天高水位（#328：三项指标只增不减）

/// 当天各项完成量的**高水位**：每日任务的三项指标 + 练习时长。
///
/// 产品口径（用户 2026-09-23 报障）：「三个任务指标应该是确定的、不会改变的，
/// 完成的量只会增加、不会减少；任务一旦完成就固定为已完成，
/// 不管后面做什么学习操作都不会回退」。
/// 2026-09-29 又补一条：**「今天」卡片与「今日任务」必须说同一个数** ——
/// 前者读此刻的快照、后者读这份水位，于是自动复盘之后同一张页面上
/// 「今天 7 轮 / 6 分 47 秒」与「今天已聊 15 轮」并存（用户报障）。
/// 时长那一格就是为这件事记的：`ProgressSnapshot.raisingToday(to:dayKey:)` 用它把两张卡对齐。
///
/// 为什么必须另记一份：这些量读的都是**此刻还存在的记录**，而这些记录会被
/// 正当理由删掉 —— 复盘成功后练习流水会被清（`purgePracticeMessages`）、
/// 气泡上的删除、「清除学习记忆」删复习流水。记录一少，进度就掉回头，
/// 卡片从「已完成」退回「未完成」，而那一天他明明做到了。
/// （复习那一项早前已经用「取今天起初的到期数」绕过同一个坑，见 `reviewTask` 的注释；
/// 对话与跟读没有那样一个「起初量」可取，所以统一在这里记高水位。）
///
/// ⚠️ 高水位只属于**那一天**：存的是 `dayKey` + 几个数，换天自动作废。
/// 与 `shadowing.progress` 存成一行 `dayKey|index` 是同一个套路 ——
/// 攒字典只会留下一堆用不上的旧日子。
public struct DailyTaskFloor: Sendable, Equatable {

    /// 归属的日子（`ShadowingDailyRule.dayKey` 格式）。
    public var dayKey: String
    public var conversation: Int
    public var shadowing: Int
    public var review: Int
    /// 当天练习时长的高水位（秒）。
    ///
    /// ⚠️ 它**不参与任务判定**（三项任务只看上三个数），存在的唯一理由是让「今天」卡片
    /// 与「今日任务」说同一件事：自动复盘会把那一段的练习流水清掉（`purgePracticeMessages`），
    /// 时长与对话数一起掉下去，于是同一张页面上「今天练了 6 分 47 秒 / 7 轮」与
    /// 「今天已聊 15 轮」并存（2026-09-29 用户报障）。
    /// 与那三个数同源、同一条「只增不减」的口径。
    public var seconds: Int

    public init(dayKey: String, conversation: Int = 0, shadowing: Int = 0, review: Int = 0,
                seconds: Int = 0) {
        self.dayKey = dayKey
        self.conversation = max(conversation, 0)
        self.shadowing = max(shadowing, 0)
        self.review = max(review, 0)
        self.seconds = max(seconds, 0)
    }

    public static func empty(dayKey: String) -> DailyTaskFloor {
        DailyTaskFloor(dayKey: dayKey)
    }

    /// 这一项今天见过的最大值（不是今天记的一律当 0）。
    public func value(for kind: DailyTask.Kind) -> Int {
        switch kind {
        case .conversation: conversation
        case .shadowing: shadowing
        case .review: review
        }
    }

    /// 显示用的完成量：**此刻算出来的**与高水位取大。
    public func progress(for kind: DailyTask.Kind, current: Int) -> Int {
        max(current, value(for: kind))
    }

    /// 用一份计划抬高高水位（只增不减）。换天则从零开始重记。
    ///
    /// - Parameter seconds: 此刻算出来的当天练习时长（秒）。与三项指标一样只增不减 ——
    ///   传进来的必须是**原始记录**，不是已经抬过水位的快照。
    public func raising(_ plan: DailyPlan, dayKey: String, seconds: Int = 0) -> DailyTaskFloor {
        var next = self.dayKey == dayKey ? self : .empty(dayKey: dayKey)
        for task in plan.tasks {
            switch task.kind {
            case .conversation: next.conversation = max(next.conversation, task.progress)
            case .shadowing: next.shadowing = max(next.shadowing, task.progress)
            case .review: next.review = max(next.review, task.progress)
            }
        }
        next.seconds = max(next.seconds, max(seconds, 0))
        return next
    }

    // MARK: 持久化（格式留在域层，**存哪儿**由 UI 层决定）

    /// 一行：`dayKey|对话|跟读|复习|时长秒`。
    public var storageText: String {
        "\(dayKey)|\(conversation)|\(shadowing)|\(review)|\(seconds)"
    }

    /// 解析一行；格式不对或字段缺失一律当「没有记录」（返回 nil）。
    ///
    /// ⚠️ **兼容四段的老格式**（加时长水位之前写的）：那一格按 0 读，
    /// 今天的水位下一次汇总时会从「此刻的记录」重新抬起。宁可少记一次时长，
    /// 也不能因为多了一格就把整行当坏数据扔掉（那会把三项指标一起清零）。
    public static func parse(_ raw: String?) -> DailyTaskFloor? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4 || parts.count == 5, !parts[0].isEmpty,
              let conversation = Int(parts[1]),
              let shadowing = Int(parts[2]),
              let review = Int(parts[3])
        else { return nil }
        let seconds = parts.count == 5 ? Int(parts[4]) : nil
        return DailyTaskFloor(
            dayKey: String(parts[0]),
            conversation: conversation,
            shadowing: shadowing,
            review: review,
            seconds: seconds ?? 0
        )
    }
}

// MARK: - 排计划（纯函数）

public enum DailyPlanner {

    /// 跟读目标句数。三句是一口气能做完、又不至于敷衍的量。
    public static let shadowingTarget = 3
    /// 复习目标上限：到期再多，今天也只要求先做这么多（一次八个个词，不会吓退人）。
    public static let reviewCap = 8
    /// 对话轮次的下限 / 上限。
    public static let conversationFloor = 4
    public static let conversationCeiling = 12
    /// 换算常数：一轮往来（学员说 + 老师答 = 2 条消息）按 1.5 分钟算。
    ///
    /// 这是个**公开的估算**，用于把「每日目标 N 分钟」折算成轮次；
    /// 不精确也没关系 —— 卡片上写的是「每日目标 15 分钟」，不是「必须聊满 4 轮」。
    public static let secondsPerExchange = 90.0
    /// 「目标分钟数再往上调，对话轮数也不再变」的分界线（分钟）。
    ///
    /// 由 `conversationCeiling` 与折算常数**推出来**，不另写一个 18 —— 两处写死必然漂移。
    /// UI 要在越过这条线时说清楚（2026-10-01）：否则用户把目标从 20 调到 60，
    /// 今日任务的对话轮数一格不动，看着就像开关坏了。
    public static var exchangeCeilingMinutes: Int {
        Int((Double(conversationCeiling) * secondsPerExchange / 60).rounded(.up))
    }
    /// 技能分低于这个值才值得单独点名（0...1）。
    public static let weakSkillThreshold = 0.8

    // MARK: 保底档（#225）

    /// 保底档的对话轮次：两轮往来 ≈ 3 分钟，一口气能做完。
    public static let baselineConversationTarget = 2
    /// 保底档的跟读句数：一句就够 —— 保底档的存在意义是「别断」，不是「练透」。
    public static let baselineShadowingTarget = 1
    /// 保底档的复习上限：到期再多也只要求 3 个，两三分钟的事。
    public static let baselineReviewCap = 3

    /// 排今天的计划。
    ///
    /// 只需要一份 `ProgressSnapshot` —— 「今天复习了几个词」也是快照里的一项事实
    /// （`vocabulary.dueAtDayStart` / `dueAtDayStartReviewed`），
    /// 所以计划是快照的**纯函数**，不额外读数据库。
    ///
    /// - Parameters:
    ///   - snapshot: 进度快照（今日活动 / 目标 / 词汇 / 技能分布 / 最近错题都在里面）。
    ///   - mode: 目标档位。保底档把三项任务都缩到 5 分钟内可完成的量；
    ///     进阶档按 `snapshot.goalMinutes` 排（原有行为）。
    ///   - now: 判定「今天」的基准时间（测试注入）。
    ///   - floor: 当天高水位（见 `DailyTaskFloor`）。传 nil = 只看此刻的记录。
    ///     传进来之后**三项的完成量都只增不减** —— 任务一旦完成就固定为已完成。
    public static func plan(
        snapshot: ProgressSnapshot,
        mode: DailyGoalMode = .advanced,
        now: Date = Date(),
        calendar: Calendar = .current,
        floor: DailyTaskFloor? = nil
    ) -> DailyPlan {
        let day = calendar.startOfDay(for: now)
        let tasks = [
            conversationTask(snapshot, mode: mode, floor: floor),
            shadowingTask(snapshot, mode: mode, floor: floor),
            reviewTask(snapshot, mode: mode, floor: floor),
        ].compactMap { $0 }

        return DailyPlan(day: day, tasks: tasks, focus: focus(snapshot))
    }

    // MARK: 三项任务

    private static func conversationTask(
        _ snapshot: ProgressSnapshot, mode: DailyGoalMode, floor: DailyTaskFloor?
    ) -> DailyTask? {
        let target = mode == .baseline
            ? baselineConversationTarget
            : exchangeTarget(goalMinutes: snapshot.goalMinutes)
        let today = snapshot.today
        // ⚠️ 完成量取「此刻记录数」与「当天高水位」的较大者：
        // 复盘之后练习流水会被清掉，只看此刻的话「昨天聊够了」的对话数会掉回个位数，
        // 卡片又退回「未完成」（用户实测报障的正是这一条）。
        let done = floor?.progress(for: .conversation, current: today.messages) ?? today.messages
        // 今天已经聊够了就别再挂一项催他（完成了的任务留着，✅ 也是有价值的反馈）。
        let reason: String
        switch (mode, done == 0) {
        case (.baseline, true): reason = "保底目标 \(DailyGoalMode.baselineMinutes) 分钟，今天还没开口"
        case (.baseline, false): reason = "保底目标 · 今天已聊 \(done) 轮"
        case (_, true): reason = "每日目标 \(snapshot.goalMinutes) 分钟，今天还没开口"
        case (_, false): reason = "每日目标 \(snapshot.goalMinutes) 分钟 · 今天已聊 \(done) 轮"
        }
        return DailyTask(
            kind: .conversation,
            title: "和老师聊 \(target) 轮",
            reason: reason,
            target: target,
            progress: done,
            unit: "轮"
        )
    }

    /// 由「每日目标分钟数」折算成对话轮次（夹在上下限之间）。
    public static func exchangeTarget(goalMinutes: Int) -> Int {
        let raw = Int((Double(goalMinutes) * 60 / secondsPerExchange).rounded())
        return min(max(raw, conversationFloor), conversationCeiling)
    }

    private static func shadowingTask(
        _ snapshot: ProgressSnapshot, mode: DailyGoalMode, floor: DailyTaskFloor?
    ) -> DailyTask? {
        let recorded = snapshot.today.shadowingAttempts
        // 与对话同一口径：跟读记录也会被「清除学习记忆」删掉，完成量同样取高水位。
        let attempts = floor?.progress(for: .shadowing, current: recorded) ?? recorded
        var reason = attempts == 0 ? "今天还没跟读" : "今天已跟读 \(attempts) 次"
        if let average = snapshot.shadowing.averagePronunciation {
            reason += " · 发音均分 \(Int(average.rounded()))"
        }
        let target = mode == .baseline ? baselineShadowingTarget : shadowingTarget
        return DailyTask(
            kind: .shadowing,
            title: target == 1 ? "跟读 1 句，逐音素纠音" : "跟读 \(target) 句，逐音素纠音",
            reason: reason,
            target: target,
            progress: attempts,
            unit: "次"
        )
    }

    private static func reviewTask(
        _ snapshot: ProgressSnapshot, mode: DailyGoalMode, floor: DailyTaskFloor?
    ) -> DailyTask? {
        // ⚠️ 指标取「**今天起初**到期」（`dueAtDayStart`），**不是**「此刻到期」（`due`）。
        // 复习答对会把间隔拉长，此刻到期数随复习一路变小 —— 拿它当指标的话，
        // 今天原本 8 个词，复习完 3 个就变成「复习 5 个 / 5 个」，全做完那一项还会整个消失。
        // 每日任务的指标是**当天定住**的量：完成后显示 8/8，多复习的词不回头改指标。
        let due = snapshot.vocabulary.dueAtDayStart
        // 今天起初就没有到期的词 → 不排这一项，别挂个永远做不完的空任务。
        guard due > 0 else { return nil }
        let cap = mode == .baseline ? baselineReviewCap : reviewCap
        let target = min(due, cap)
        // 完成度也只在**今天起初那批词**里数：今天新加的词被复习了不算数
        // （用户口径：「完成了表示今天已经达标，多完成的不应该再计入」）。
        let recorded = snapshot.vocabulary.dueAtDayStartReviewed
        // 第三层保险：「清除学习记忆」会把复习流水一并删掉，那之后也要保持已完成。
        let done = floor?.progress(for: .review, current: recorded) ?? recorded
        let reason = due > cap
            ? "今天有 \(due) 个词要复习，先做前 \(target) 个"
            : "今天有 \(due) 个词要复习"
        return DailyTask(
            kind: .review,
            title: "复习 \(target) 个到期单词",
            reason: reason,
            target: target,
            progress: done,
            unit: "个词"
        )
    }

    // MARK: 今日重点

    /// 出现最多的**可教**错误类型。
    ///
    /// `.other` 是兜底分类，不是可以拿去教的点 —— 点名「今天重点：其他」等于什么也没说，
    /// 所以先把它剔掉再取最多。
    /// ⚠️ 不能直接信 `GrammarAnalysis.dominantCategory`：它把 `.other` 也算进去，
    /// 一旦兜底占多数，真正该练的那一类就被埋了。
    static func dominantTeachable(
        _ analysis: GrammarAnalysis
    ) -> (category: GrammarErrorCategory, hits: [GrammarError])? {
        let ranked: [(category: GrammarErrorCategory, hits: [GrammarError])] = GrammarErrorCategory.allCases
            .filter { $0 != .other }
            .map { category in (category, analysis.errors.filter { $0.category == category }) }
            .filter { !$0.1.isEmpty }
        // 票数相同时按枚举声明顺序取靠前的，保证确定性（与 `dominantCategory` 同款约定）。
        return ranked.max { lhs, rhs in
            if lhs.1.count != rhs.1.count { return lhs.1.count < rhs.1.count }
            let order = GrammarErrorCategory.allCases
            return (order.firstIndex(of: lhs.0) ?? 0) > (order.firstIndex(of: rhs.0) ?? 0)
        }
    }

    /// 「今天重点」的优先级：**反复出错的语法点 > 最弱的技能**。
    ///
    /// 都不满足就返回 nil —— 没什么可说的就不说，不硬凑一句鼓励。
    public static func focus(_ snapshot: ProgressSnapshot) -> DailyPlan.Focus? {
        let analysis = GrammarAgent.analyze(corrections: snapshot.recentMistakes)
        if let (category, hits) = dominantTeachable(analysis) {
            let repeated = hits.filter(\.isRepeated).count
            let repeatedNote = repeated > 0 ? "，其中 \(repeated) 处反复出现" : ""
            return DailyPlan.Focus(
                title: "今天重点：\(category.displayName)",
                reason: "最近 \(analysis.errors.count) 处批注里有 \(hits.count) 处在\(category.displayName)上\(repeatedNote)"
            )
        }

        // 技能分布里最低的一项，且确实低于阈值、且有样本撑着（没数据不点名）。
        let measured = snapshot.skills.filter { $0.sampleCount > 0 }
        guard let weakest = measured.min(by: { $0.score < $1.score }),
              weakest.score < weakSkillThreshold else { return nil }
        return DailyPlan.Focus(
            title: "今天重点：\(weakest.kind.displayName)",
            reason: "技能分布里\(weakest.kind.displayName)最低（\(Int((weakest.score * 100).rounded())) 分，\(weakest.sampleCount) 条记录）"
        )
    }
}
