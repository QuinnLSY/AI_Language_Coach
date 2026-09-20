import Foundation

// MARK: - 年度学习记录（学习进度页的「近一年」汇总）
//
// 版式照 GitHub 的贡献图：53 列 × 7 行，一格一天。
//
// 但深浅**不是**照搬「当天提交了几个 commit」——本应用没有「提交次数」这个量。
// 有的是两张卡片上已经写出的话：
//   「今天」卡片   → 今天练了多久、有没有达成每日目标；
//   「今日任务」卡片 → 三项任务做完了几项。
// 所以四档深浅直接由这两件事推出来（`PracticeIntensity.of`），
// **格子与卡片永远说同一句话**：卡片说今天达标了，格子里就不会是浅的。
//
// 本文件只有结构 + 纯函数：不 import UI、不碰 IO、不看系统时间以外的状态。

// MARK: - 深浅（四档）

/// 一个格子的深浅。
public enum PracticeIntensity: Int, Sendable, CaseIterable, Identifiable, Comparable {

    /// 没开过口。
    case none = 0
    /// 开过口，但目标与任务都还没到。
    case light = 1
    /// 每日目标达成 **或** 任务过半。
    case solid = 2
    /// 每日目标达成 **且** 三项任务全清。
    case full = 3

    public var id: Int { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .none: "没练"
        case .light: "开过口"
        case .solid: "达标"
        case .full: "全清"
        }
    }

    /// 由两张卡片的完成情况定深浅。
    ///
    /// - Parameters:
    ///   - hasPractice: 当天有没有练过（时长 / 对话 / 跟读 / 收词，与「今天」卡片同源）。
    ///   - goalReached: 「今天」卡片上的每日目标是否达成。
    ///   - tasksDone / tasksTotal: 「今日任务」卡片上的完成项数。
    public static func of(
        hasPractice: Bool,
        goalReached: Bool,
        tasksDone: Int,
        tasksTotal: Int
    ) -> PracticeIntensity {
        guard hasPractice else { return .none }
        let total = max(tasksTotal, 0)
        let done = max(tasksDone, 0)
        // 「全清」= 两个卡片都完成；「达标」= 完成其一（任务过半也算「就差一点」以外的进度）。
        if goalReached, total > 0, done >= total { return .full }
        if goalReached || (total > 0 && done * 2 >= total) { return .solid }
        return .light
    }
}

// MARK: - 一整年

public struct AnnualRecap: Sendable, Equatable {

    /// 一个格子（一天）。
    public struct Cell: Sendable, Equatable, Identifiable {

        /// 当天 0 点。
        public var day: Date
        public var intensity: PracticeIntensity
        /// 那天的活动（与「今天」卡片同源的原始事实）。
        public var activity: DailyActivity
        /// 「今天」卡片上的每日目标是否达成。
        public var goalReached: Bool
        /// 「今日任务」卡片上完成了几项 / 共几项。
        public var tasksDone: Int
        public var tasksTotal: Int
        public var isToday: Bool

        public var id: Date { day }

        /// 0...3：直接当色阶用。
        public var level: Int { intensity.rawValue }

        /// 悬停 / 点开时给人看的明细（「9月15日 · 12 分 30 秒 · 4 轮对话 · …」）。
        public func detailText(calendar: Calendar = .current) -> String {
            var parts = [ProgressAggregator.longLabel(day, calendar: calendar)]
            if activity.seconds > 0 {
                parts.append(ProgressAggregator.durationText(activity.seconds))
            }
            if activity.messages > 0 { parts.append("\(activity.messages) 轮对话") }
            if activity.shadowingAttempts > 0 { parts.append("跟读 \(activity.shadowingAttempts) 次") }
            if activity.vocabularyReviewed > 0 { parts.append("复习 \(activity.vocabularyReviewed) 词") }
            if activity.writings > 0 {
                parts.append(activity.writingScore.map { "写作 \(activity.writings) 篇（均分 \(Int($0.rounded()))）" }
                    ?? "写作 \(activity.writings) 篇")
            }
            if activity.readings > 0 {
                parts.append(activity.readingQuestions > 0
                    ? "阅读 \(activity.readings) 篇（答对 \(activity.readingCorrect)/\(activity.readingQuestions)）"
                    : "阅读 \(activity.readings) 篇")
            }
            if intensity == .none {
                parts.append("没有练习")
            } else {
                parts.append(goalReached ? "目标达成" : "未达目标")
                parts.append("任务 \(tasksDone) / \(tasksTotal)")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// X 轴上的一条月份刻度。
    public struct MonthMarker: Sendable, Equatable, Identifiable {
        public var title: String
        /// 第几列（0 起）。
        public var column: Int

        public var id: String { "\(column)#\(title)" }
    }

    /// 每一列一周，行 0 是 `calendar.firstWeekday` 那天；`nil` = 还没到的日子（不画）。
    public var weeks: [[Cell?]]
    public var months: [MonthMarker]
    /// 7 行里要写字的那几行（其余 nil）—— 只有三行有字，照 GitHub 的样子。
    public var rowLabels: [String?]

    /// 近一年练过的天数（= 「近一年有 N 天开过口」里的 N）。
    public var practicedDays: Int
    public var dayCount: Int
    public var totalMinutes: Int
    public var totalMessages: Int
    public var totalShadowing: Int
    public var totalReviewed: Int
    /// 当前连续练习天数（今天还没练不算断）。
    public var currentStreak: Int
    /// 这一年里最长的一段连续练习。
    public var longestStreak: Int
    /// 四档各有多少天。
    public var levelCounts: [PracticeIntensity: Int]

    public var goalMinutes: Int
    public var start: Date
    public var end: Date

    /// 「近一年有 16 天开过口」。
    public var headline: String { "近一年有 \(practicedDays) 天开过口" }

    /// 「累计 3 小时 20 分 · 当前连续 5 天 · 最长 12 天」。
    public var summaryText: String {
        var parts = ["累计 \(ProgressAggregator.durationText(Double(totalMinutes) * 60))"]
        parts.append("当前连续 \(currentStreak) 天")
        if longestStreak > currentStreak { parts.append("最长连续 \(longestStreak) 天") }
        return parts.joined(separator: " · ")
    }

    /// 空格子（数据库不可用 / 还没加载时）。**仍是一整张网格**，
    /// 免得 UI 先画一个空壳再跳成一年，Layout 也不会跳。
    public static func empty(
        now: Date = Date(),
        goalMinutes: Int = ProgressAggregator.defaultGoalMinutes
    ) -> AnnualRecap {
        AnnualRecapBuilder.build(days: [], goalMinutes: goalMinutes, now: now, calendar: .current)
    }
}

// MARK: - 建图（纯函数）

public enum AnnualRecapBuilder {

    /// 一年 = 53 周。正好铺满一年零几天，与贡献图一样。
    public static let weeksPerYear = 53

    /// 网格覆盖的日子（旧 → 新，最后一天是今天）。
    ///
    /// 起点对齐到「周首」而不是「去年的今天」：列必须整周整周的排，
    /// 否则 7 行的行标签（一 / 三 / 五）会错位。代价是实际覆盖 365…371 天。
    public static func daySlots(
        now: Date = Date(),
        calendar: Calendar = .current,
        weeks: Int = weeksPerYear
    ) -> [Date] {
        let lastDay = calendar.startOfDay(for: now)
        let lastColumnStart = startOfWeek(containing: lastDay, calendar: calendar)
        let firstColumnStart = calendar.date(
            byAdding: .day, value: -(max(weeks, 1) - 1) * 7, to: lastColumnStart
        ) ?? lastColumnStart

        var slots: [Date] = []
        var cursor = firstColumnStart
        while cursor <= lastDay {
            slots.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return slots
    }

    /// 所在周的起点（按 `calendar.firstWeekday`，中国区是周一）。
    public static func startOfWeek(containing day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        let weekday = calendar.component(.weekday, from: start)
        let firstWeekday = min(max(calendar.firstWeekday, 1), 7)
        let offset = (weekday - firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: start) ?? start
    }

    /// 7 行要不要写字：第 1、3、5 行（周一 / 周三 / 周五）。
    ///
    /// 行号 0 = `calendar.firstWeekday`。隔一行写字是贡献图的老规矩 ——
    /// 7 行都写会把网格挤瘦，一行都不写又看不出星期。
    ///
    /// ⚠️ 星期字**写死中文**而不是取 `veryShortWeekdaySymbols`：月份刻度写的就是
    /// 「9月」，两者必须是同一套语言。跟着系统 locale 走的话，英文系统上会出现
    /// 「9月 / 10月」配「M / W / F」——同一张图里两种语言。
    public static func rowLabels(calendar: Calendar = .current) -> [String?] {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        let firstWeekday = min(max(calendar.firstWeekday, 1), 7)
        return (0..<7).map { row in
            guard row % 2 == 0, row < 6 else { return nil }
            let weekday = (firstWeekday - 1 + row) % 7
            return names[weekday]
        }
    }

    /// 把逐日活动排成一整张年历。
    ///
    /// - Parameters:
    ///   - days: 逐日活动（顺序无所谓，按 `day` 归位）。传空数组会得到一张
    ///     **全空但完整**的网格（覆盖近一年）。
    public static func build(
        days: [DailyActivity],
        goalMinutes: Int = ProgressAggregator.defaultGoalMinutes,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AnnualRecap {
        let today = calendar.startOfDay(for: now)
        let goal = max(goalMinutes, 0)

        let slots = days.map(\.day)
        var byDay: [Date: DailyActivity] = [:]
        for day in days { byDay[calendar.startOfDay(for: day.day)] = day }

        // 网格起点取**输入里最早的那一天**所在周，而不是数组第一个元素：
        // 传进来的顺序不该改变网格的形状（顺序反了就会把早于首个元素的日子丢掉）。
        let anchor = slots.min() ?? daySlots(now: now, calendar: calendar).first
        guard let first = anchor else {
            return AnnualRecap(
                weeks: [], months: [], rowLabels: rowLabels(calendar: calendar),
                practicedDays: 0, dayCount: 0, totalMinutes: 0, totalMessages: 0,
                totalShadowing: 0, totalReviewed: 0, currentStreak: 0, longestStreak: 0,
                levelCounts: [:], goalMinutes: goal, start: today, end: today
            )
        }

        var columnStart = startOfWeek(containing: first, calendar: calendar)
        var column = 0
        var weeks: [[AnnualRecap.Cell?]] = []
        var monthStarts: [(month: Int, column: Int)] = []
        while columnStart <= today {
            var cells: [AnnualRecap.Cell?] = []
            for offset in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: columnStart),
                      date <= today else {
                    cells.append(nil)
                    continue
                }
                let activity = byDay[calendar.startOfDay(for: date)] ?? DailyActivity(day: date)
                cells.append(
                    makeCell(activity: activity, goalMinutes: goal, today: today)
                )
            }
            weeks.append(cells)

            // 月份刻度打在「这一列里出现了某个月的 1 号」的位置上 ——
            // 按列首那天判会错位：8/30 那一列其实已经跨进 9 月了。
            if let boundary = (0..<7).compactMap({ calendar.date(byAdding: .day, value: $0, to: columnStart) })
                .first(where: { calendar.component(.day, from: $0) == 1 }) {
                monthStarts.append((calendar.component(.month, from: boundary), column))
            }

            guard let next = calendar.date(byAdding: .day, value: 7, to: columnStart) else { break }
            columnStart = next
            column += 1
        }

        let allCells = weeks.flatMap { $0 }.compactMap { $0 }

        var counts: [PracticeIntensity: Int] = [:]
        for cell in allCells { counts[cell.intensity, default: 0] += 1 }
        // 分开算而不是塞进初始化参数里：一次性写十来个 `reduce` 会让
        // 类型检查器超时（实测 "unable to type-check this expression in reasonable time"）。
        let practicedDays = allCells.filter { $0.intensity != .none }.count
        let totalMinutes = allCells.reduce(0) { $0 + $1.activity.minutes }
        let totalMessages = allCells.reduce(0) { $0 + $1.activity.messages }
        let totalShadowing = allCells.reduce(0) { $0 + $1.activity.shadowingAttempts }
        let totalReviewed = allCells.reduce(0) { $0 + $1.activity.vocabularyReviewed }

        return AnnualRecap(
            weeks: weeks,
            months: monthMarkers(monthStarts, firstColumnMonth: calendar.component(.month, from: first)),
            rowLabels: rowLabels(calendar: calendar),
            practicedDays: practicedDays,
            dayCount: allCells.count,
            totalMinutes: totalMinutes,
            totalMessages: totalMessages,
            totalShadowing: totalShadowing,
            totalReviewed: totalReviewed,
            currentStreak: streak(allCells, allowOpenToday: true),
            longestStreak: longestStreak(allCells),
            levelCounts: counts,
            goalMinutes: goal,
            start: allCells.first?.day ?? today,
            end: allCells.last?.day ?? today
        )
    }

    // MARK: 内部

    private static func makeCell(
        activity: DailyActivity,
        goalMinutes: Int,
        today: Date
    ) -> AnnualRecap.Cell {
        let done = tasksDone(activity, goalMinutes: goalMinutes)
        let goalReached = goalMinutes > 0 && activity.seconds >= Double(goalMinutes) * 60
        return AnnualRecap.Cell(
            day: activity.day,
            intensity: PracticeIntensity.of(
                hasPractice: activity.hasPractice,
                goalReached: goalReached,
                tasksDone: done,
                tasksTotal: Self.tasksTotal
            ),
            activity: activity,
            goalReached: goalReached,
            tasksDone: done,
            tasksTotal: tasksTotal,
            isToday: activity.day == today
        )
    }

    /// 「今日任务」卡片固定三项（对话轮次 / 跟读 / 复习）。
    ///
    /// 分母写死三项而不是照搬当天卡片上的 `N 项`：卡片上少了「复习」那一项
    /// 只是因为**今天恰好没有到期的词**，那是当天的巧合，不是口径 ——
    /// 若按 N 记，昨天「2 / 2」算全清、今天「2 / 3」不算，同一种努力会有两种深浅。
    public static let tasksTotal = 3

    /// 当天三项任务完成了几项（判据与 `DailyPlanner` 同源，只是按天回放）。
    ///
    /// ⚠️ 「复习」一项按「当天有复习流水」记：历史每一天的**到期词数**还原不出来
    /// （到期是相对「当时」的概念），能确凿知道的只有「那天复习过词」。
    /// 宁可把这一项记松一点，也不编一个算不出来的目标数。
    public static func tasksDone(_ day: DailyActivity, goalMinutes: Int) -> Int {
        var done = 0
        if day.messages >= DailyPlanner.exchangeTarget(goalMinutes: goalMinutes) { done += 1 }
        if day.shadowingAttempts >= DailyPlanner.shadowingTarget { done += 1 }
        if day.vocabularyReviewed > 0 { done += 1 }
        return done
    }

    /// 连续练习天数。今天还没开口不算断（与「今天」卡片的连续口径一致）。
    public static func streak(_ cells: [AnnualRecap.Cell], allowOpenToday: Bool) -> Int {
        var days = cells
        if allowOpenToday, let last = days.last, !last.activity.hasPractice { days.removeLast() }
        var count = 0
        for cell in days.reversed() {
            guard cell.intensity != .none || cell.activity.hasPractice else { break }
            count += 1
        }
        return count
    }

    /// 一年里最长的一段。
    public static func longestStreak(_ cells: [AnnualRecap.Cell]) -> Int {
        var best = 0
        var run = 0
        for cell in cells {
            if cell.activity.hasPractice {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
        return best
    }

    /// 月份刻度：最左边一列（网格起始那个月）+ 每一列里出现了某月 1 号的位置。
    ///
    /// 这里**不做挤不挤的判断** —— 标签会不会叠在一起取决于格子和字号，
    /// 那是绘制层的事（见 `AnnualRecapCard`），领域层只回答「哪一列是新月份」。
    static func monthMarkers(
        _ monthStarts: [(month: Int, column: Int)],
        firstColumnMonth: Int
    ) -> [AnnualRecap.MonthMarker] {
        var markers = [AnnualRecap.MonthMarker(title: monthTitle(firstColumnMonth), column: 0)]
        markers.append(contentsOf: monthStarts.map {
            AnnualRecap.MonthMarker(title: monthTitle($0.month), column: $0.column)
        })
        return markers
    }

    static func monthTitle(_ month: Int) -> String { "\(month)月" }
}
