import Foundation

// MARK: - 学习进度 / Dashboard（第 25 步）
//
// 设计依据：Implementation Plan §26「Dashboard and Progress」。
//
//   Dashboard：Today → Practice time → Recent mistakes → Vocabulary → Pronunciation → Learning goals
//   Progress ：grammar trend / vocabulary growth / pronunciation trend / speaking time /
//              practice frequency / skill distribution
//
// 铁律（Plan §26 末句）：**UI 只读应用层数据**。所以本文件只做两件事：
//   1. 描述「进度长什么样」（结构体）；
//   2. 把原始记录折算成进度（纯函数，脱机可测、不碰模型、不碰 IO）。
// 取数（SQL）在 Infrastructure，编排在 AIServices，渲染在 AppUI —— 三层各管各的。

// MARK: - 一天的活动

/// 一天的学习活动 —— 趋势图里的一根柱子。
public struct DailyActivity: Sendable, Equatable, Identifiable {

    /// 当天 0 点（本地时区）。
    public var day: Date
    /// 练习时长（秒）：由当天消息的时间跨度折算，已夹取掉异常值。
    public var seconds: TimeInterval
    /// 当天对话轮次（消息条数）。
    public var messages: Int
    /// 当天老师批注的纠错处数。
    public var corrections: Int
    /// 当天跟读次数。
    public var shadowingAttempts: Int
    /// 当天发音总分的平均（0...100；当天没录到音频为 nil）。
    public var pronunciation: Double?
    /// 当天新增词汇数。
    public var vocabularyAdded: Int

    public var id: Date { day }

    public init(
        day: Date,
        seconds: TimeInterval = 0,
        messages: Int = 0,
        corrections: Int = 0,
        shadowingAttempts: Int = 0,
        pronunciation: Double? = nil,
        vocabularyAdded: Int = 0
    ) {
        self.day = day
        self.seconds = max(seconds, 0)
        self.messages = messages
        self.corrections = corrections
        self.shadowingAttempts = shadowingAttempts
        self.pronunciation = pronunciation
        self.vocabularyAdded = vocabularyAdded
    }

    /// 练习时长（分钟，四舍五入）。
    public var minutes: Int { Int((seconds / 60).rounded()) }

    /// 这一天是否「练过」（有时长 / 有对话 / 有跟读 / 有新增词汇）。
    public var hasPractice: Bool {
        seconds > 0 || messages > 0 || shadowingAttempts > 0 || vocabularyAdded > 0
    }
}

// MARK: - 趋势点

/// 折线图 / 柱状图的一个点（纯展示：标签 + 数值）。
public struct TrendPoint: Sendable, Equatable, Identifiable {
    /// X 轴标签（图表直接渲染，如「9/12」）。
    public var label: String
    /// Y 轴数值。
    public var value: Double
    /// 悬停/脚注用的完整说明（如「9月12日 · 4 处批注」）。
    public var detail: String

    public var id: String { label + "#" + detail }

    public init(label: String, value: Double, detail: String = "") {
        self.label = label
        self.value = value
        self.detail = detail
    }
}

// MARK: - 技能分布

/// 技能维度（PRD「skill distribution」的中文化）。
public enum SkillKind: String, Sendable, CaseIterable, Identifiable {

    case grammar
    case vocabulary
    case pronunciation
    case shadowing
    case fluency

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .grammar: "语法准确"
        case .vocabulary: "词汇积累"
        case .pronunciation: "发音"
        case .shadowing: "跟读模仿"
        case .fluency: "流利度"
        }
    }

    public var systemImage: String {
        switch self {
        case .grammar: "text.badge.checkmark"
        case .vocabulary: "text.book.closed.fill"
        case .pronunciation: "waveform"
        case .shadowing: "waveform.badge.mic"
        case .fluency: "gauge.with.dots.needle.67percent"
        }
    }
}

/// 一格技能分（0...1）。**带样本数**：没数据就说没数据，不拿 0 分冒充「很差」。
public struct SkillScore: Sendable, Equatable, Identifiable {

    public var kind: SkillKind
    /// 0...1。
    public var score: Double
    /// 这个分数由多少条记录撑着（0 = 还没数据）。
    public var sampleCount: Int
    /// 口径说明（UI 脚注，告诉用户分数怎么来的）。
    public var detail: String

    public var id: String { kind.rawValue }

    public init(kind: SkillKind, score: Double, sampleCount: Int, detail: String) {
        self.kind = kind
        self.score = min(max(score, 0), 1)
        self.sampleCount = sampleCount
        self.detail = detail
    }

    public var hasData: Bool { sampleCount > 0 }

    public var percent: Int { Int((score * 100).rounded()) }
}

// MARK: - 带时间戳的纠错

/// 一条**带时间**的纠错记录。
///
/// `GrammarCorrection` 本体不带时间（它描述「错在哪」，不描述「什么时候」），
/// 而趋势图必须按天聚合，所以在读取层补一个时间戳包装，不去改动领域模型本身。
public struct CorrectionRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var correction: GrammarCorrection
    public var createdAt: Date

    public init(id: UUID = UUID(), correction: GrammarCorrection, createdAt: Date) {
        self.id = id
        self.correction = correction
        self.createdAt = createdAt
    }
}

// MARK: - 快照

/// 一次学习进度快照。**UI 只读它**，不自己做统计。
public struct ProgressSnapshot: Sendable, Equatable {

    public var generatedAt: Date
    /// 统计窗口天数。
    public var days: Int
    /// 窗口内每天的活动（**旧 → 新**，共 `days` 天，没练的天也在，值为 0）。
    public var activity: [DailyActivity]
    /// 累计词汇量曲线。
    public var vocabularyGrowth: [TrendPoint]
    /// 发音趋势（当天没有音频的日子跳过，不画假点）。
    public var pronunciationTrend: [TrendPoint]
    /// 语法趋势（每天批注处数）。
    public var grammarTrend: [TrendPoint]
    /// 技能分布。
    public var skills: [SkillScore]

    /// 今日活动。
    public var today: DailyActivity
    /// 连续练习天数（今天没练则从昨天往前数）。
    public var streakDays: Int
    /// 窗口内有练习的天数。
    public var activeDays: Int

    /// 累计（全量，不限于窗口）。
    public var totalSeconds: TimeInterval
    public var totalMessages: Int
    public var totalStars: Int
    public var totalCorrections: Int

    /// 词汇本统计（复用第 24 步的口径）。
    public var vocabulary: VocabularyStats
    /// 今天已经复习过的词数（`lastReviewedAt` 落在今天）。
    ///
    /// 单独拎出来是因为「今天复习完了没有」**只能由真实记录算出来**——
    /// 每日任务里那一项就是靠它判完成的，不能让用户自己打勾。
    public var vocabularyReviewedToday: Int
    /// 跟读统计（复用第 22/23 步的口径）。
    public var shadowing: ShadowingStats
    /// 最近错题（错题本在 Dashboard 上的「Recent mistakes」）。
    public var recentMistakes: [GrammarCorrection]

    /// 每日目标（分钟）。
    public var goalMinutes: Int

    public init(
        generatedAt: Date = Date(),
        days: Int = 14,
        activity: [DailyActivity] = [],
        vocabularyGrowth: [TrendPoint] = [],
        pronunciationTrend: [TrendPoint] = [],
        grammarTrend: [TrendPoint] = [],
        skills: [SkillScore] = [],
        today: DailyActivity,
        streakDays: Int = 0,
        activeDays: Int = 0,
        totalSeconds: TimeInterval = 0,
        totalMessages: Int = 0,
        totalStars: Int = 0,
        totalCorrections: Int = 0,
        vocabulary: VocabularyStats = .empty,
        vocabularyReviewedToday: Int = 0,
        shadowing: ShadowingStats = .empty,
        recentMistakes: [GrammarCorrection] = [],
        goalMinutes: Int = ProgressAggregator.defaultGoalMinutes
    ) {
        self.generatedAt = generatedAt
        self.days = days
        self.activity = activity
        self.vocabularyGrowth = vocabularyGrowth
        self.pronunciationTrend = pronunciationTrend
        self.grammarTrend = grammarTrend
        self.skills = skills
        self.today = today
        self.streakDays = streakDays
        self.activeDays = activeDays
        self.totalSeconds = totalSeconds
        self.totalMessages = totalMessages
        self.totalStars = totalStars
        self.totalCorrections = totalCorrections
        self.vocabulary = vocabulary
        self.vocabularyReviewedToday = max(vocabularyReviewedToday, 0)
        self.shadowing = shadowing
        self.recentMistakes = recentMistakes
        self.goalMinutes = goalMinutes
    }

    /// 今日目标完成度（0...1，超出按 1 计）。
    public var goalProgress: Double {
        guard goalMinutes > 0 else { return 0 }
        return min(Double(today.seconds) / (Double(goalMinutes) * 60), 1)
    }

    public var goalReached: Bool { goalProgress >= 1 }

    /// 今日时长文案（「12 分 30 秒」/「0 秒」）。
    public var todayDurationText: String { ProgressAggregator.durationText(today.seconds) }

    /// 初始快照（数据库不可用 / 首次进入时的占位，UI 直接可渲染）。
    public static func empty(now: Date = Date(), days: Int = 14, goalMinutes: Int = ProgressAggregator.defaultGoalMinutes) -> ProgressSnapshot {
        ProgressAggregator.snapshot(
            days: days, now: now, calendar: .current,
            sessions: [], messages: [], corrections: [], shadowing: [],
            vocabulary: [], totalStars: 0, goalMinutes: goalMinutes
        )
    }
}

// MARK: - 聚合（纯函数）

/// 把原始记录折算成进度快照。**全部是纯函数**：不碰模型、不碰数据库、不读系统时间以外的任何状态。
public enum ProgressAggregator {

    /// 默认统计窗口。
    public static let defaultDays = 14
    /// 默认每日目标（分钟）。
    public static let defaultGoalMinutes = 15
    /// 单次会话的时长上限（秒）。会话不一定会被显式结束，敞口会话按「最后一条消息」算，
    /// 但极端情况（挂机两天再说话）会把时长放大到荒唐值 —— 夹取掉，宁可少算不可虚报。
    public static let sessionDurationCap: TimeInterval = 4 * 3600
    /// 同一天内消息跨度也算作练习时长，同样夹取。
    public static let dailyDurationCap: TimeInterval = 6 * 3600

    // MARK: 入口

    public static func snapshot(
        days: Int = defaultDays,
        now: Date = Date(),
        calendar: Calendar = .current,
        sessions: [SessionSummary],
        messages: [Date],
        corrections: [CorrectionRecord],
        shadowing: [ShadowingAttempt],
        vocabulary: [VocabularyEntry],
        totalStars: Int,
        goalMinutes: Int = defaultGoalMinutes
    ) -> ProgressSnapshot {
        let window = max(days, 1)
        let today = calendar.startOfDay(for: now)
        let dayList = daySlots(count: window, endingAt: today, calendar: calendar)
        let windowStart = dayList.first ?? today

        // 消息按天分组：同一天内「首条 → 末条」的时间跨度 = 那天的练习时长。
        let messagesByDay = group(messages, by: { calendar.startOfDay(for: $0) }, calendar: calendar)

        let correctionsByDay = group(corrections.map(\.createdAt), by: { calendar.startOfDay(for: $0) }, calendar: calendar)
        let shadowingByDay = group(shadowing, by: { calendar.startOfDay(for: $0.createdAt) }, calendar: calendar)
        let vocabularyByDay = group(vocabulary.map(\.createdAt), by: { calendar.startOfDay(for: $0) }, calendar: calendar)

        var activity: [DailyActivity] = []
        for day in dayList {
            let stamps = (messagesByDay[day] ?? []).sorted()
            var seconds: TimeInterval = 0
            if let first = stamps.first, let last = stamps.last {
                seconds = min(last.timeIntervalSince(first), dailyDurationCap)
            }
            // 只有一条消息的会话：按「一条消息 ≈ 半分钟开口」估，不然全部显示 0 分钟。
            if stamps.count == 1 { seconds = 30 }

            let dayCorrections = correctionsByDay[day] ?? []
            let dayShadowing = (shadowingByDay[day] ?? []).sorted { $0.createdAt < $1.createdAt }
            let scores = dayShadowing.compactMap(\.pronunciation).map(\.overall)

            // 语音练习也应算作练习时长：跟读一次按「参考句词数 × 0.4 秒」估。
            for attempt in dayShadowing {
                let words = ShadowingScorer.words(attempt.referenceText).count
                seconds += Double(max(words, 1)) * 0.4
            }

            activity.append(
                DailyActivity(
                    day: day,
                    seconds: seconds,
                    messages: stamps.count,
                    corrections: dayCorrections.count,
                    shadowingAttempts: dayShadowing.count,
                    pronunciation: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
                    vocabularyAdded: (vocabularyByDay[day] ?? []).count
                )
            )
        }

        let windowActivity = activity
        let todayActivity = windowActivity.last ?? DailyActivity(day: today)

        // 累计口径：窗口起点之前的存量也要算进「起始高度」，否则曲线从 0 开始跳。
        let openedVocabulary = vocabulary.filter { $0.createdAt < windowStart }.count
        var runningVocabulary = openedVocabulary
        var growth: [TrendPoint] = []
        for day in windowActivity {
            runningVocabulary += vocabularyByDay[day.day]?.count ?? 0
            growth.append(
                TrendPoint(
                    label: shortLabel(day.day, calendar: calendar),
                    value: Double(runningVocabulary),
                    detail: "\(longLabel(day.day, calendar: calendar)) · 累计 \(runningVocabulary) 词"
                )
            )
        }

        let grammarTrend = windowActivity.map { day in
            TrendPoint(
                label: shortLabel(day.day, calendar: calendar),
                value: Double(day.corrections),
                detail: "\(longLabel(day.day, calendar: calendar)) · \(day.corrections) 处批注"
            )
        }

        let pronunciationTrend = windowActivity.compactMap { day -> TrendPoint? in
            guard let score = day.pronunciation else { return nil }
            return TrendPoint(
                label: shortLabel(day.day, calendar: calendar),
                value: score,
                detail: "\(longLabel(day.day, calendar: calendar)) · 发音 \(Int(score.rounded())) 分"
            )
        }

        let windowMessages = windowActivity.reduce(0) { $0 + $1.messages }
        let windowCorrections = windowActivity.reduce(0) { $0 + $1.corrections }
        let windowSeconds = windowActivity.reduce(0) { $0 + $1.seconds }

        let skills = skillScores(
            messages: windowMessages,
            corrections: windowCorrections,
            shadowing: shadowing,
            vocabulary: vocabulary
        )

        return ProgressSnapshot(
            generatedAt: now,
            days: window,
            activity: windowActivity,
            vocabularyGrowth: growth,
            pronunciationTrend: pronunciationTrend,
            grammarTrend: grammarTrend,
            skills: skills,
            today: todayActivity,
            streakDays: streak(windowActivity, calendar: calendar),
            activeDays: windowActivity.filter(\.hasPractice).count,
            totalSeconds: sessions.reduce(0) { $0 + sessionSeconds($1) } + shadowingSessionSeconds(shadowing),
            totalMessages: sessions.reduce(0) { $0 + $1.messageCount },
            totalStars: totalStars,
            totalCorrections: corrections.count,
            vocabulary: VocabularyStats.from(vocabulary),
            vocabularyReviewedToday: ReviewScheduler.reviewedCount(vocabulary, on: now, calendar: calendar),
            shadowing: ShadowingStats.from(shadowing),
            recentMistakes: corrections
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(5)
                .map(\.correction),
            goalMinutes: max(goalMinutes, 0)
        )
    }

    // MARK: 技能分布

    /// 技能分的口径（全部写在这里，UI 只显示，不再二次加工）：
    ///
    /// - **语法准确**：每轮对话的批注密度。0.4 处/轮 = 0 分，0 处 = 满分。
    ///   用密度而不是绝对条数 —— 聊得久不该被判成「语法差」。
    /// - **词汇积累**：掌握度（占 6 成）+ 已配释义比例（占 4 成）。
    /// - **发音**：历史发音总分平均。
    /// - **跟读模仿**：跟读匹配率平均（文本层对齐，不含音准）。
    /// - **流利度**：发音评测里「流利度」维度的平均分（有声占比 + 填充词）。
    public static func skillScores(
        messages: Int,
        corrections: Int,
        shadowing: [ShadowingAttempt],
        vocabulary: [VocabularyEntry]
    ) -> [SkillScore] {

        var result: [SkillScore] = []

        // 语法准确
        let correctionsPerTurn = messages > 0 ? Double(corrections) / Double(messages) : 0
        let grammarScore = messages > 0 ? max(0, 1 - correctionsPerTurn / 0.4) : 0
        result.append(
            SkillScore(
                kind: .grammar, score: grammarScore, sampleCount: messages,
                detail: messages > 0
                    ? "每轮 \(String(format: "%.2f", correctionsPerTurn)) 处批注（0.4 处/轮 记 0 分）"
                    : "还没有对话数据"
            )
        )

        // 词汇积累
        let total = vocabulary.count
        let mastered = vocabulary.filter(\.isMastered).count
        let defined = vocabulary.filter { !$0.meaning.isEmpty }.count
        let vocabularyScore = total > 0
            ? 0.6 * (Double(mastered) / Double(total)) + 0.4 * (Double(defined) / Double(total))
            : 0
        result.append(
            SkillScore(
                kind: .vocabulary, score: vocabularyScore, sampleCount: total,
                detail: total > 0
                    ? "\(total) 词 · 已掌握 \(mastered) · 已配释义 \(defined)"
                    : "词汇本还是空的"
            )
        )

        // 发音
        let reports = shadowing.compactMap(\.pronunciation)
        let pronunciationScore = reports.isEmpty
            ? 0
            : reports.map(\.overall).reduce(0, +) / Double(reports.count) / 100
        result.append(
            SkillScore(
                kind: .pronunciation, score: pronunciationScore, sampleCount: reports.count,
                detail: reports.isEmpty
                    ? "还没有录到音频的跟读"
                    : "平均 \(Int((pronunciationScore * 100).rounded())) 分（共 \(reports.count) 次）"
            )
        )

        // 跟读模仿（文本层匹配率）
        let accuracy = shadowing.isEmpty
            ? 0
            : shadowing.map(\.accuracy).reduce(0, +) / Double(shadowing.count)
        result.append(
            SkillScore(
                kind: .shadowing, score: accuracy, sampleCount: shadowing.count,
                detail: shadowing.isEmpty
                    ? "还没有跟读记录"
                    : "平均匹配率 \(Int((accuracy * 100).rounded()))%"
            )
        )

        // 流利度（发音评测的 fluency 维度）
        let fluencyScores = reports.compactMap { $0.line(.fluency)?.score }
        let fluency = fluencyScores.isEmpty
            ? 0
            : fluencyScores.reduce(0, +) / Double(fluencyScores.count) / 100
        result.append(
            SkillScore(
                kind: .fluency, score: fluency, sampleCount: fluencyScores.count,
                detail: fluencyScores.isEmpty
                    ? "还没有流利度数据"
                    : "有声占比与填充词加权平均 \(Int((fluency * 100).rounded())) 分"
            )
        )

        return result
    }

    // MARK: 小工具

    /// 单次会话时长（秒）：首条 → 末条的时间跨度（`endedAt` 不可信的兜底口径）。
    static func sessionSeconds(_ session: SessionSummary) -> TimeInterval {
        min(max(session.endedAt.timeIntervalSince(session.startedAt), 0), sessionDurationCap)
    }

    /// 跟读折算的练习时长（秒）：参考句词数 × 0.4 秒。
    static func shadowingSessionSeconds(_ attempts: [ShadowingAttempt]) -> TimeInterval {
        attempts.reduce(0) { partial, attempt in
            partial + Double(max(ShadowingScorer.words(attempt.referenceText).count, 1)) * 0.4
        }
    }

    /// 连续练习天数：从今天（今天没练则从昨天）往前数，遇到空白天停下。
    public static func streak(_ activity: [DailyActivity], calendar: Calendar) -> Int {
        var days = activity
        // 今天还没练不该把连续记录清零 —— 今天才开始而已。
        if let last = days.last, !last.hasPractice { days.removeLast() }
        var count = 0
        for day in days.reversed() {
            guard day.hasPractice else { break }
            count += 1
        }
        return count
    }

    /// 窗口内的天列表（旧 → 新）。
    static func daySlots(count: Int, endingAt end: Date, calendar: Calendar) -> [Date] {
        (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: end)
        }
    }

    private static func group<T>(_ items: [T], by key: (T) -> Date, calendar: Calendar) -> [Date: [T]] {
        var result: [Date: [T]] = [:]
        for item in items {
            result[calendar.startOfDay(for: key(item)), default: []].append(item)
        }
        return result
    }

    /// 「9/12」。
    public static func shortLabel(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }

    /// 「9月12日」。
    public static func longLabel(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    /// 时长文案：「58 秒」/「3 分 12 秒」/「1 小时 4 分」。
    public static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0).rounded())
        if total < 60 { return "\(total) 秒" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) 分 \(total % 60) 秒" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}
