import Foundation

/// 今日战绩海报（⑦-D）：把「今天练了什么」编排成一张能发出去的卡。
///
/// 年度记录要攒满一年才有东西看，这张是**今天就能发出去**的那一版 ——
/// 练完看一眼，导出成 PNG 丢到群里 / 朋友圈，发一次就多一次回来的理由。
///
/// ⚠️ 今天没练**返回 nil**，不给一张「练了 0 分钟」的空壳：海报是要发出去的，
/// 上面每个数字都是一句承诺。没练那天该有的是一句「还没开口」，不是一张图。
public struct DailyPoster: Sendable, Equatable {

    /// 海报上的一行数据。
    public struct Metric: Sendable, Equatable, Identifiable {
        /// 短名（「对话」）。同时也是时长太短时拼 headline 用的材料。
        public var title: String
        /// 带单位的值（「8 轮」）。
        public var value: String
        public var systemImage: String

        public var id: String { title }

        public init(title: String, value: String, systemImage: String) {
            self.title = title
            self.value = value
            self.systemImage = systemImage
        }
    }

    /// 海报上最多摆几行：摆满六行数字就不是战绩卡了，是体检报告。
    public static let maxMetrics = 4

    public var dateText: String
    public var headline: String
    /// 连续天数那一行（0 天时为空串 —— UI 据此不画这一行）。
    public var subhead: String
    public var metrics: [Metric]
    public var closing: String

    public init(
        dateText: String,
        headline: String,
        subhead: String,
        metrics: [Metric],
        closing: String
    ) {
        self.dateText = dateText
        self.headline = headline
        self.subhead = subhead
        self.metrics = metrics
        self.closing = closing
    }

    /// 编一张今日海报。今天没练过 → nil（理由见文件头）。
    public static func make(
        date: Date,
        activity: DailyActivity,
        streakDays: Int,
        goalMinutes: Int,
        goalReached: Bool
    ) -> DailyPoster? {
        // ⚠️ `hasPractice` 而不是「seconds > 0」：只背单词的那天是**真的练过**，
        // 口径与年度图上那格、连续天数完全一致（见 `DailyActivity.hasPractice`）。
        guard activity.hasPractice else { return nil }
        let metrics = Self.metrics(from: activity)
        return DailyPoster(
            dateText: Self.dateText(date),
            headline: Self.headline(activity: activity, metrics: metrics),
            subhead: Self.subhead(streakDays: streakDays),
            metrics: metrics,
            closing: Self.closing(streakDays: streakDays, goalMinutes: goalMinutes, goalReached: goalReached)
        )
    }
}

// MARK: - 编排规则（全是纯函数，可单测）

extension DailyPoster {

    /// 主标题。
    ///
    /// ⚠️ 满一分钟才说「练了多久」：只练了十几秒却报「练了 12 秒」是在替用户难堪，
    /// 那种时候该说他**做了什么**（「今天复习 8 个词」）。
    static func headline(activity: DailyActivity, metrics: [Metric]) -> String {
        if activity.seconds >= 60 {
            return "今天练了 \(ProgressAggregator.durationText(activity.seconds))"
        }
        if let first = metrics.first { return "今天\(first.title) \(first.value)" }
        return "今天开了个头"
    }

    /// 数据行：**只列真的做了的**（不写「复习 0 个词」那种凑数的行），顺序按重要度。
    static func metrics(from activity: DailyActivity) -> [Metric] {
        var rows: [Metric] = []
        if activity.messages > 0 {
            rows.append(Metric(title: "对话", value: "\(activity.messages) 轮", systemImage: "bubble.left.and.bubble.right.fill"))
        }
        if activity.shadowingAttempts > 0 {
            rows.append(Metric(title: "跟读", value: "\(activity.shadowingAttempts) 句", systemImage: "waveform.badge.mic"))
        }
        if activity.vocabularyReviewed > 0 {
            rows.append(Metric(title: "复习", value: "\(activity.vocabularyReviewed) 个词", systemImage: "rectangle.stack.fill"))
        }
        if activity.vocabularyAdded > 0 {
            rows.append(Metric(title: "收词", value: "\(activity.vocabularyAdded) 个", systemImage: "plus.circle.fill"))
        }
        if activity.writings > 0 {
            rows.append(Metric(title: "写作", value: "\(activity.writings) 篇", systemImage: "pencil.and.outline"))
        }
        if activity.readings > 0 {
            rows.append(Metric(title: "阅读", value: "\(activity.readings) 篇", systemImage: "book.fill"))
        }
        return Array(rows.prefix(Self.maxMetrics))
    }

    /// 连续天数那一行。
    ///
    /// ⚠️ 0 天返回空串而不是「连续 0 天」：海报上写「连续 0 天」等于替用户承认
    /// 「我刚断签」，那是他自己的事、不该由分享出去的那张图替他说。
    static func subhead(streakDays: Int) -> String {
        if streakDays >= 2 { return "连续练习 \(streakDays) 天" }
        if streakDays == 1 { return "连续第 1 天" }
        return ""
    }

    /// 收尾那句话。达标 > 长连胜 > 普通。
    ///
    /// ⚠️ 目标分钟数插真值（`goalMinutes`），不写死 5 / 20：写死了以后改保底口径，
    /// 海报会继续报旧数 —— 界面和判定各说一句（与今日卡那条教训同源）。
    static func closing(streakDays: Int, goalMinutes: Int, goalReached: Bool) -> String {
        if goalReached { return "今天的目标（\(goalMinutes) 分钟）达成了" }
        if streakDays >= 7 { return "已经连续 \(streakDays) 天，节奏稳住了" }
        return "明天接着来"
    }

    /// 「10 月 13 日」。
    ///
    /// ⚠️ 固定 `zh_Hans_CN` 与公历：海报是给中文用户看的，跟着系统 locale 走的话
    /// 换台机器就变成「Oct 13」，同一份数据导出两种图。
    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "M 月 d 日"
        return formatter.string(from: date)
    }
}
