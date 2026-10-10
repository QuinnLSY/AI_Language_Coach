import Foundation

// MARK: - 每日安排的自适应微调
//
// ⑤ 做的是「说」：把 stance 摆到学习建议卡上。这一半是「做」——
// 把 `AdaptivePathStance` 翻译成**每日任务三项目标**与**一轮复习张数**该怎么变。
// 纯函数，不读数据库、不认识 UI。
//
// 三条刻意的设计决定：
//
// 1. **`.observing` 一律不动**。样本不足还改安排，是把猜测当事实 —— 宁可维持原样。
// 2. **只调量，不改口径**。目标怎么算仍然是 `DailyPlanner` 一把尺子，这里只在上头加减，
//    并且夹住下限：**任何一项都不许被调成 0**（0 会让整项任务凭空消失，看着像开关坏了）。
// 3. **理由一并产出**（`note`）。改了量却不说明，等于偷偷改数字 —— 用户会以为计划是随机的。

/// 一份 stance 对今日安排的微调量。
public struct DailyPlanTuning: Sendable, Equatable {

    /// 对话轮次的增减（可为负）。
    public var conversationDelta: Int
    /// 跟读句数的增减（可为负）。
    public var shadowingDelta: Int
    /// 复习目标上限的增减（可为负）。
    public var reviewCapDelta: Int
    /// 一轮复习最多走几个词。
    public var reviewSessionLimit: Int
    /// 为什么这么调。`nil` = 没调，就不硬凑一句话。
    public var note: String?

    public init(
        conversationDelta: Int = 0,
        shadowingDelta: Int = 0,
        reviewCapDelta: Int = 0,
        reviewSessionLimit: Int = DailyPlanTuningRule.defaultReviewSessionLimit,
        note: String? = nil
    ) {
        self.conversationDelta = conversationDelta
        self.shadowingDelta = shadowingDelta
        self.reviewCapDelta = reviewCapDelta
        self.reviewSessionLimit = max(1, reviewSessionLimit)
        self.note = note
    }

    /// 三项增减都是 0（也就是没动过安排）。
    public var isIdentity: Bool {
        conversationDelta == 0 && shadowingDelta == 0 && reviewCapDelta == 0
    }
}

public enum DailyPlanTuningRule {

    /// 一轮复习的默认张数。**与 `VocabularyReviewSession.maxCards` 同源**，不另写一个 20。
    public static let defaultReviewSessionLimit = VocabularyReviewSession.maxCards
    /// 欠得多时多走的张数。
    public static let reinforceReviewBonus = 8
    /// 稳住时多留一点给复习。
    public static let consolidateReviewBonus = 4
    /// 状态往上走时少走的张数（省下的时间让给新量）。
    public static let advanceReviewDiscount = 4
    /// 复习**每日目标上限**的增减（与上面那三个是**不同的量**：`reviewSessionLimit`
    /// 管「一轮走几张」，`reviewCapDelta` 管「今天复习这项要求几个」——
    /// 两者混用会让「上限 8 → 16」而说明还写着「加 4 个词」）。
    public static let reinforceReviewCapDelta = 4
    public static let consolidateReviewCapDelta = 2

    /// 把 stance 翻译成微调量。
    ///
    /// - reinforce（有欠账 / 在掉）：**压新量、加复习**。欠着还往前推只会越欠越多。
    /// - consolidate（持平 / 稳住）：新量不动，复习略加 —— 稳的定义就是「别退」。
    /// - advance（在进步）：加新量、减复习占比 —— 状态好的时候就该多见新东西。
    public static func tuning(for stance: AdaptivePathStance) -> DailyPlanTuning {
        switch stance {
        case .observing:
            // 数据不够，一个字都不改。
            return DailyPlanTuning()
        case .reinforce:
            let conversation = -1
            let shadowing = -1
            let cap = reinforceReviewCapDelta
            return DailyPlanTuning(
                conversationDelta: conversation,
                shadowingDelta: shadowing,
                reviewCapDelta: cap,
                reviewSessionLimit: defaultReviewSessionLimit + reinforceReviewBonus,
                // ⚠️ 理由里的数字必须**从上面的变量插值**，不许手抄：常量一改，
                // 文案就会开始说「加 4 个词」而实际加的是 6 个 —— 数字对不上比不说数字更糟。
                note: "有欠账先补：对话少 \(-conversation) 轮、跟读少 \(-shadowing) 句，复习上限加 \(cap) 个词"
            )
        case .consolidate:
            let cap = consolidateReviewCapDelta
            return DailyPlanTuning(
                conversationDelta: 0,
                shadowingDelta: 0,
                reviewCapDelta: cap,
                reviewSessionLimit: defaultReviewSessionLimit + consolidateReviewBonus,
                note: "稳住节奏：新量不变，复习上限加 \(cap) 个词"
            )
        case .advance:
            let conversation = 2
            let shadowing = 1
            let discount = advanceReviewDiscount
            return DailyPlanTuning(
                conversationDelta: conversation,
                shadowingDelta: shadowing,
                reviewCapDelta: 0,
                reviewSessionLimit: defaultReviewSessionLimit - advanceReviewDiscount,
                note: "状态在往上走：对话多 \(conversation) 轮、跟读多 \(shadowing) 句，复习少走 \(discount) 个词"
            )
        }
    }

    /// 目标的下限：至少 1。
    ///
    /// ⚠️ 目标为 0 时 `DailyTask.isDone` 的分母是 0，卡片会退化成一条永远做不完的空任务；
    /// 更糟的是 `min(due, cap)` 里 cap 为 0 会让复习这一项**整项消失** —— 那看起来就是开关坏了。
    public static func clampedTarget(_ raw: Int) -> Int {
        max(1, raw)
    }
}
