import Foundation

// MARK: - 今日卷轴（首屏今日面板）的纯规则
//
// 与 `DailyPlanner` 同一条规矩：**排什么、算不算完成、说什么话全是纯函数**，
// 本文件不 import 任何 UI / IO。
//
// 为什么单独一份规则（而不是直接把 `DailyPlan` 丢给 UI）：
// 卷轴是「打开应用第一眼看到的东西」，它必须**在没有数据时也说得清楚** ——
// 到期词为 0 不能显示空白、快照还没汇总不能显示「今日 0/3」。
// 这些边界写进纯函数才能被单测钉住。

public enum TodayPanel {

    /// 收起态状态栏：一眼看完「做了几项 / 连续几天 / 今天练了多久」。
    ///
    /// ⚠️ 快照还没汇总（`totalCount == 0`）时**不说进度**：那是「还没算出来」，
    /// 说「今日 0/3」等于告诉用户「你今天什么都没做」—— 一次误报就够劝退的了。
    public static func statusLine(
        plan: DailyPlan,
        streakDays: Int,
        todaySeconds: TimeInterval
    ) -> String {
        var parts: [String] = []
        if plan.totalCount > 0 {
            parts.append(plan.isAllDone ? "今日 全部完成" : "今日 \(plan.progressText)")
        } else {
            parts.append("今日 待安排")
        }
        parts.append("连续 \(streakDays) 天")
        parts.append(ProgressAggregator.durationText(todaySeconds))
        return parts.joined(separator: " · ")
    }

    /// 展开态标题。
    public static func title(plan: DailyPlan) -> String {
        plan.isAllDone ? "今天都做完了" : "今天做这 \(plan.totalCount) 件"
    }

    /// 到期词那一行（**到期为 0 也要说清楚**，不显示空白）。
    ///
    /// `due` 是「此刻到期的词数」，`reviewedToday` 是「今天复习过的不同词数」——
    /// 两者都由真实记录算出来，不靠用户打勾。
    public static func dueLine(due: Int, reviewedToday: Int) -> String {
        guard due > 0 else {
            return reviewedToday > 0 ? "今天已复习 \(reviewedToday) 个词" : "今天没有到期词"
        }
        if reviewedToday >= due { return "\(due) 个到期词都复习完了" }
        return "\(due) 个词到期 · 今天已复习 \(reviewedToday) 个"
    }

    /// 今日全部完成时要不要放一次庆祝（**一天只放一次**）。
    ///
    /// 幂等靠 `dayKey`：练完那一刻放一次，之后同一次启动里反复汇总都不再放；
    /// 隔天再练完会再放一次（`celebratedDayKey` 与新的 `dayKey` 不同）。
    /// ⚠️ 计划为空时**不算完成** —— 没任务不等于做完了。
    public static func shouldCelebrate(
        plan: DailyPlan,
        celebratedDayKey: String?,
        dayKey: String
    ) -> Bool {
        guard plan.isAllDone else { return false }
        return celebratedDayKey != dayKey
    }

    /// 「还差一点」的那句督促（未完成时给一个**可核对**的缺口，不是形容词）。
    ///
    /// 没有未完成项时返回 nil —— 没什么可说就不说。
    public static func remainingLine(plan: DailyPlan) -> String? {
        guard let next = plan.nextTask else { return nil }
        let left = max(next.target - next.progress, 0)
        guard left > 0 else { return nil }
        return "还差 \(left) \(next.unit)：\(next.title)"
    }

    // MARK: 打卡徽章（连续天数提到台前 + 断签保护）

    /// 首屏打卡徽章的数据。纯值，UI 拿去渲染。
    public struct StreakBadge: Sendable, Equatable {
        /// 连续天数（今天没练时它是「到昨天为止」的存量）。
        public let days: Int
        /// 今天还没练：这串连续纪录今天随时会断 —— 徽章要亮警示，催一句。
        public let isAtRisk: Bool

        public init(days: Int, isAtRisk: Bool) {
            self.days = days
            self.isAtRisk = isAtRisk
        }
    }

    /// 打卡徽章：连续 ≥1 天才展示（0 天不展示 —— 首屏挂个「连续 0 天」纯属提醒失败史）。
    ///
    /// 「断签保护」的判定也在这里：`streak` 的口径本来就是「今天没练从昨天往前数」，
    /// 所以**连续还在、今天没练**就是最该提醒的时刻 —— 再拖到明天，真的清零。
    public static func streakBadge(streakDays: Int, hasPracticeToday: Bool) -> StreakBadge? {
        guard streakDays >= 1 else { return nil }
        return StreakBadge(days: streakDays, isAtRisk: !hasPracticeToday)
    }

    /// 徽章的悬停/无障碍提示：断签保护的核心一句，可核对、不说形容词。
    public static func streakGuardLine(_ badge: StreakBadge) -> String {
        badge.isAtRisk
            ? "今天练一会儿，保住 \(badge.days) 天连续"
            : "已连续 \(badge.days) 天，保持住"
    }

    // MARK: 定时练习提醒（#226，本地通知的文案）

    /// 提醒通知的文案。老师口吻 + 企鹅意象，**确定性**（同一天固定一份，不随机）。
    ///
    /// 有连续纪录时提「保住连续」（可核对的依据），没有时只说「5 分钟就够」——
    /// 不说「加油哦」这类没有信息量的话。
    public static func practiceReminderCopy(streakDays: Int) -> (title: String, body: String) {
        if streakDays >= 2 {
            return (
                "小鹅子来敲门啦 🐧",
                "已经连续 \(streakDays) 天了，今天练 5 分钟就保住！"
            )
        }
        return (
            "小鹅子来敲门啦 🐧",
            "今天聊两句吧，5 分钟就够。"
        )
    }
}

// MARK: - 老师黑板（今日作业）

extension TodayPanel {

    /// 一句气泡里的**分段**：哪几个字是红的、哪几个是绿的，由这里说了算。
    ///
    /// 分成段而不是整句一个色，是因为「关键字变色」才有效：
    /// 整句红会变成警告条，整句绿会变成恭喜条，只有数字变色才是「进度」。
    public struct Segment: Sendable, Equatable {
        public enum Tone: Sendable, Equatable {
            /// 普通（随主题）。
            case plain
            /// 完成 / 好（绿）。
            case good
            /// 没做完 / 该催了（红）。
            case alert
        }

        public let text: String
        public let tone: Tone

        public init(_ text: String, _ tone: Tone) {
            self.text = text
            self.tone = tone
        }
    }

    public struct BubbleLine: Sendable, Equatable {
        public var segments: [Segment]

        public init(_ segments: [Segment]) { self.segments = segments }

        public var plainText: String { segments.map(\.text).joined() }
    }

    /// 教棍敲完那一下的气泡：没做完就**给可核对的缺口**去催，做完了才夸。
    ///
    /// `streakAtRisk`（断签保护）：连续 ≥2 天且今天还没练时，催的那句话里**掺上别断签**——
    /// 只提醒「没做完」用户拖到明天，连续纪录清零才发现，那时说什么都晚了。
    /// ⚠️ 1 天不断签（1 天的纪录没什么可保的），不去烦新用户。
    ///
    /// ⚠️ 不做「今天也要加油哦」这种形容词 —— 夸和催都得能拿出依据，
    /// 否则连续几天看下来就变成噪音。
    public static func knockBubble(plan: DailyPlan, streakDays: Int, streakAtRisk: Bool = false) -> BubbleLine {
        guard plan.totalCount > 0 else {
            return BubbleLine([Segment("今天还没有安排，先开口说两句吧", .plain)])
        }
        guard plan.isAllDone else {
            let left = plan.totalCount - plan.completedCount
            var segments = [Segment("还有 \(left) 项没做完", .alert)]
            if let next = plan.nextTask {
                segments.append(Segment(" · \(next.title)", .plain))
            }
            if streakAtRisk, streakDays >= 2 {
                segments.append(Segment(" · 连续 \(streakDays) 天别断", .alert))
            }
            return BubbleLine(segments)
        }
        var segments = [Segment("今日 \(plan.progressText) 全部完成", .good)]
        if streakDays > 1 { segments.append(Segment(" · 连续 \(streakDays) 天", .good)) }
        return BubbleLine(segments)
    }

    /// 收起态随机气泡里掺的那句今日进度（**关键字变色**：没做完红、做完绿）。
    ///
    /// 计划还没排出来时返回 nil —— 没得说就不说，不硬凑一句。
    public static func progressLine(plan: DailyPlan) -> BubbleLine? {
        guard plan.totalCount > 0 else { return nil }
        let tone: Segment.Tone = plan.isAllDone ? .good : .alert
        return BubbleLine([
            Segment("今日任务 ", .plain),
            Segment(plan.progressText, tone),
        ])
    }

    /// 开屏要不要自动展开一次黑板（**一天最多一次，且只在今天还没做完时**）。
    ///
    /// 今日全部做完就不再自动展开 —— 那是奖励，不是待办，开屏就糊上去只会烦人。
    /// 计划为空（快照还没汇总）也不展开：展开一块空板没有意义。
    public static func shouldAutoExpand(
        plan: DailyPlan,
        autoExpandedDayKey: String?,
        dayKey: String
    ) -> Bool {
        guard plan.totalCount > 0, !plan.isAllDone else { return false }
        return autoExpandedDayKey != dayKey
    }
}
