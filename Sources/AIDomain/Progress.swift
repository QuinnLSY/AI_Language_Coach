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
    /// 当天复习过的**不同**词数（同一天把同一个词判两次只算一次）。
    ///
    /// 与「今日任务」卡片上的复习进度、年度记录里那天格子的深浅同源。
    public var vocabularyReviewed: Int
    /// 当天交卷批改的作文篇数（#233）。
    public var writings: Int
    /// 当天作文的平均批改分（0...100；没交过为 nil）。
    public var writingScore: Double?
    /// 当天交卷的阅读篇数（#233；只算交了卷的）。
    public var readings: Int
    /// 当天阅读答对的题数（与 `readingQuestions` 配对使用）。
    public var readingCorrect: Int
    /// 当天阅读的总题数。
    public var readingQuestions: Int
    /// 当天作文的总词数。
    public var writingWords: Int

    public var id: Date { day }

    public init(
        day: Date,
        seconds: TimeInterval = 0,
        messages: Int = 0,
        corrections: Int = 0,
        shadowingAttempts: Int = 0,
        pronunciation: Double? = nil,
        vocabularyAdded: Int = 0,
        vocabularyReviewed: Int = 0,
        writings: Int = 0,
        writingScore: Double? = nil,
        readings: Int = 0,
        readingCorrect: Int = 0,
        readingQuestions: Int = 0,
        writingWords: Int = 0
    ) {
        self.day = day
        self.seconds = max(seconds, 0)
        self.messages = messages
        self.corrections = corrections
        self.shadowingAttempts = shadowingAttempts
        self.pronunciation = pronunciation
        self.vocabularyAdded = vocabularyAdded
        self.vocabularyReviewed = max(vocabularyReviewed, 0)
        self.writings = max(writings, 0)
        self.writingScore = writingScore
        self.readings = max(readings, 0)
        self.readingCorrect = max(readingCorrect, 0)
        self.readingQuestions = max(readingQuestions, 0)
        self.writingWords = max(writingWords, 0)
    }

    /// 练习时长（分钟，四舍五入）。
    public var minutes: Int { Int((seconds / 60).rounded()) }

    /// 这一天是否「练过」（有时长 / 有对话 / 有跟读 / 有收词 / 有复习）。
    ///
    /// ⚠️ 复习词数必须算进来 —— 只背单词的那天是**真的练过**：
    /// 漏掉这一项，那天在年度图上是「没练」、连续天数也会断，
    /// 可用户明明做了三项任务里的一项。
    public var hasPractice: Bool {
        seconds > 0 || messages > 0 || shadowingAttempts > 0
            || vocabularyAdded > 0 || vocabularyReviewed > 0
            || writings > 0 || readings > 0
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

// MARK: - 读取层的轻量时间戳
//
// 年度记录要往回看一整年，跟读一年上千条 —— 把发音报告的 JSON 也解出来纯属浪费。
// 这里只带「聚合真正用得到的那几列」，其余留给需要它的窗口查询。

/// 一次跟读的极简记录：什么时候跟的 + 参考句（词数用来折算练习时长）。
public struct ShadowingStamp: Sendable, Equatable {
    public var referenceText: String
    public var createdAt: Date

    public init(referenceText: String, createdAt: Date) {
        self.referenceText = referenceText
        self.createdAt = createdAt
    }

    /// 参考句词数（折算时长用，口径与跟读评测同一把尺）。
    public var wordCount: Int { max(ShadowingScorer.words(referenceText).count, 1) }
}

/// 一次词汇复习的极简记录。
///
/// 用 `itemID` 而不是「第几次」：同一天同一个词判两次只算复习了**一个**词，
/// 那是「今日任务」卡片上「复习 N 个词」的口径。
public struct VocabularyReviewStamp: Sendable, Equatable {
    public var itemID: UUID
    public var reviewedAt: Date

    public init(itemID: UUID, reviewedAt: Date) {
        self.itemID = itemID
        self.reviewedAt = reviewedAt
    }
}

/// 一次写作批改的极简记录（#233：写作/阅读进学习记录）。
public struct WritingStamp: Sendable, Equatable {
    /// 批改分数（0...100；模型没给分为 nil，不冒充 0 分）。
    public var score: Double?
    /// 作文词数（与跟读同一把分词尺）。
    public var wordCount: Int
    public var createdAt: Date

    public init(score: Double?, wordCount: Int, createdAt: Date) {
        self.score = score
        self.wordCount = max(wordCount, 0)
        self.createdAt = createdAt
    }
}

/// 一次**交卷**阅读的极简记录。
///
/// 只记交卷的：光生成一篇不读不算练习 —— 「读过」的口径是答完题交了卷。
public struct ReadingStamp: Sendable, Equatable {
    public var correct: Int
    public var total: Int
    public var createdAt: Date

    public init(correct: Int, total: Int, createdAt: Date) {
        self.correct = max(correct, 0)
        self.total = max(total, 0)
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
    /// 今天已经复习过的**不同**词数。
    ///
    /// 单独拎出来是因为「今天复习完了没有」**只能由真实记录算出来**——
    /// 每日任务里那一项就是靠它判完成的，不能让用户自己打勾。
    /// 口径与年度记录里今天那格完全一致（都取自 `DailyActivity.vocabularyReviewed`）。
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

    /// **连续练习天数**自己的窗口（天）。
    ///
    /// ⚠️ 连续天数**绝不能**拿统计窗口（`defaultDays` = 14）来数：那样它会被**截断到窗口长度**，
    /// 而且窗口每向前滑一天，最老的那一天就掉出数组 —— 于是「什么都没做」的跨天瞬间，
    /// 连续天数自己从 14 掉到 13、14 天以上的纪录永远显示不出来。
    /// 2026-09-24 用户报障的「跨天后打卡徽章由 14 倒退成 13」正是这个：
    /// 09-23 那天窗口 09-10…09-23 全绿 → 14；跨到 09-24 后窗口变 09-11…09-24，
    /// 09-24 还没练被摘掉、09-11 又掉了出去 → 只剩 13。
    /// 年度记录一直是对的，因为它自己铺了整整一年（`AnnualRecapBuilder.daySlots`）。
    ///
    /// 取一年：与年度记录同一把尺，且「连续一年以上」本身已超出这个数的意义。
    public static let streakWindowDays = 366
    /// 默认每日目标（分钟）。
    public static let defaultGoalMinutes = 15
    /// 单次会话的时长上限（秒）。会话不一定会被显式结束，敞口会话按「最后一条消息」算，
    /// 但极端情况（挂机两天再说话）会把时长放大到荒唐值 —— 夹取掉，宁可少算不可虚报。
    public static let sessionDurationCap: TimeInterval = 4 * 3600
    /// 同一天累计时长的上限（秒）。逐条折算之后基本撞不到它，
    /// 留着是为了「消息时间戳本身异常」（时区错乱、导入的历史数据）时有硬上限。
    public static let dailyDurationCap: TimeInterval = 6 * 3600

    /// 相邻两条消息之间**算作练习**的最大间隔（秒）。超出的部分不算。
    ///
    /// ⚠️ 这是「练习时长」这条口径的命门。以前的做法是「当天首条 → 末条的消息跨度」：
    /// 学员 00:00 打开应用说了一句、18:28 又来说一句，跨度 18.5 小时，
    /// 夹取到 6 小时上限 → 每天都是「6 小时 0 分」，14 天里一排 360 分钟。
    /// 真正该算的是「离开屏幕的时间不算练习」：间隔超过这条线就断档。
    public static let idleGapCap: TimeInterval = 5 * 60

    /// **第一句**的开口成本（秒）：读提示、想、打字、听老师第一句回复。
    ///
    /// ⚠️ 只给第一句加，不给每条消息各加一次。相邻两条之间的间隔**已经**是
    /// 「学员在屏幕前待着」的那段时间（含打字与听 TTS），再按条数补一次就是重复计数：
    /// 一场 10 分钟、20 条消息的密集对话会被算成 10 分钟 + 19×30 秒 ≈ 20 分钟。
    /// 口径定成「挂钟跨度 − 离开屏幕的时间 + 首句开口」，只多算开头那半分钟。
    public static let openingSeconds: TimeInterval = 30

    /// 跟读折算成练习时长的系数（秒 / 词）。
    public static let shadowingSecondsPerWord = 0.4

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
        goalMinutes: Int = defaultGoalMinutes,
        reviews: [VocabularyReviewStamp] = [],
        writings: [WritingStamp] = [],
        readings: [ReadingStamp] = []
    ) -> ProgressSnapshot {
        let window = max(days, 1)
        let today = calendar.startOfDay(for: now)
        let dayList = daySlots(count: window, endingAt: today, calendar: calendar)
        let windowStart = dayList.first ?? today

        let shadowingStamps = shadowing.map {
            ShadowingStamp(referenceText: $0.referenceText, createdAt: $0.createdAt)
        }
        let pronunciationByDay = group(
            shadowing.filter { $0.pronunciation != nil },
            by: { calendar.startOfDay(for: $0.createdAt) },
            calendar: calendar
        ).mapValues { attempts in attempts.compactMap { $0.pronunciation?.overall } }

        /// 按给定的日子铺一份逐日记录。
        ///
        /// ⚠️ 窗口与连续天数**共用这一份函数与同一批原始输入**：各铺各的日子，但折叠口径
        /// 不许分叉 —— 两处各写一遍 `dailyActivity(...)` 的实参，迟早有一处漏传
        /// （`reviews:` 就在 `ProgressService` 里漏过一次，导致「只复习了词汇的那一天」
        /// 在打卡口径里算没练）。
        func activity(_ slots: [Date], pronunciation: [Date: [Double]]) -> [DailyActivity] {
            dailyActivity(
                days: slots,
                calendar: calendar,
                messages: messages,
                corrections: corrections,
                shadowing: shadowingStamps,
                pronunciationByDay: pronunciation,
                vocabulary: vocabulary,
                reviews: reviews,
                writings: writings,
                readings: readings
            )
        }

        let windowActivity = activity(dayList, pronunciation: pronunciationByDay)
        // 连续天数自成一份、用更长的窗口（见 `streakWindowDays`）。
        // 发音打分只有窗口趋势要看，这一份不传 —— 省一趟按天分组。
        let streakActivity = streakWindowDays > window
            ? activity(
                daySlots(count: streakWindowDays, endingAt: today, calendar: calendar),
                pronunciation: [:]
            )
            : windowActivity
        let todayActivity = windowActivity.last ?? DailyActivity(day: today)

        // 累计口径：窗口起点之前的存量也要算进「起始高度」，否则曲线从 0 开始跳。
        let vocabularyByDay = group(vocabulary, by: { $0.createdAt }, calendar: calendar)
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
            streakDays: streak(streakActivity),
            activeDays: windowActivity.filter(\.hasPractice).count,
            totalSeconds: sessions.reduce(0) { $0 + sessionSeconds($1) } + shadowingSessionSeconds(shadowing),
            totalMessages: sessions.reduce(0) { $0 + $1.messageCount },
            totalStars: totalStars,
            totalCorrections: corrections.count,
            vocabulary: VocabularyStats.from(vocabulary, now: now, calendar: calendar),
            vocabularyReviewedToday: todayActivity.vocabularyReviewed,
            shadowing: ShadowingStats.from(shadowing),
            recentMistakes: corrections
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(5)
                .map(\.correction),
            goalMinutes: max(goalMinutes, 0)
        )
    }

    // MARK: 逐日折activity（窗口与年度记录**共用这一份**）

    /// 把原始事实折成「每天一条」。窗口快照与年度记录都走这里 ——
    /// 一旦各写一份，「今天」卡片说练了 12 分钟、年度格子里却是 3 分钟这种事迟早出现。
    ///
    /// - Parameters:
    ///   - days: 要铺的日子（旧 → 新，可以含没练的日子）。
    ///   - pronunciationByDay: 当天的发音总分（只有窗口趋势要，年度记录不传）。
    public static func dailyActivity(
        days dayList: [Date],
        calendar: Calendar = .current,
        messages: [Date],
        corrections: [CorrectionRecord] = [],
        shadowing: [ShadowingStamp] = [],
        pronunciationByDay: [Date: [Double]] = [:],
        vocabulary: [VocabularyEntry] = [],
        reviews: [VocabularyReviewStamp] = [],
        writings: [WritingStamp] = [],
        readings: [ReadingStamp] = []
    ) -> [DailyActivity] {
        // 传进来的「天」一律归一到当天 0 点：下面所有查表都以 0 点为键，
        // 不给这一刀的话，传进来一个带时刻的日期会**静默查不到**任何记录
        // （所有格子都变成没练过 —— 不报错，只是全错）。
        let dayList = dayList.map { calendar.startOfDay(for: $0) }
        // 消息按天分组：同一天内「首条 → 末条」的时间跨度 = 那天的练习时长。
        let messagesByDay = group(messages, by: { $0 }, calendar: calendar)
        let correctionsByDay = group(corrections, by: { $0.createdAt }, calendar: calendar)
        let shadowingByDay = group(shadowing, by: { $0.createdAt }, calendar: calendar)
        let vocabularyByDay = group(vocabulary, by: { $0.createdAt }, calendar: calendar)
        let reviewedByDay = reviewedCountsByDay(reviews, calendar: calendar)
        let writingsByDay = group(writings, by: { $0.createdAt }, calendar: calendar)
        let readingsByDay = group(readings, by: { $0.createdAt }, calendar: calendar)

        var activity: [DailyActivity] = []
        for day in dayList {
            let dayShadowing = shadowingByDay[day] ?? []
            let scores = pronunciationByDay[day] ?? []

            activity.append(
                DailyActivity(
                    day: day,
                    seconds: practiceSeconds(
                        messageStamps: messagesByDay[day] ?? [],
                        shadowingWordCounts: dayShadowing.map(\.wordCount)
                    ),
                    messages: (messagesByDay[day] ?? []).count,
                    corrections: (correctionsByDay[day] ?? []).count,
                    shadowingAttempts: dayShadowing.count,
                    pronunciation: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
                    vocabularyAdded: (vocabularyByDay[day] ?? []).count,
                    vocabularyReviewed: reviewedCounts(reviews, by: reviewedByDay, on: day, vocabulary: vocabulary, calendar: calendar),
                    writings: (writingsByDay[day] ?? []).count,
                    writingScore: Self.averageWritingScore(writingsByDay[day] ?? []),
                    readings: (readingsByDay[day] ?? []).count,
                    readingCorrect: (readingsByDay[day] ?? []).reduce(0) { $0 + $1.correct },
                    readingQuestions: (readingsByDay[day] ?? []).reduce(0) { $0 + $1.total },
                    writingWords: (writingsByDay[day] ?? []).reduce(0) { $0 + $1.wordCount }
                )
            )
        }
        return activity
    }

    /// 某一天的练习时长（秒）：**相邻消息的间隔逐段截断**，再叠加跟读折算。
    ///
    /// **这是唯一的一把尺子**：「今天」卡片、年度记录的深浅、每日任务的达标判定，
    /// 全都必须经过它。相隔两次窗口汇总各算一遍，就会出现两个「今天的时长」。
    ///
    /// 口径（三条，缺一条就会说谎）：
    /// 1. 空集合 = 0；有消息才加一次 `openingSeconds`（开口那半分钟）；
    /// 2. 相邻两条之间的间隔**只算到 `idleGapCap`**：中间离开屏幕的时间不是练习时间；
    /// 3. 全天累计夹取到 `dailyDurationCap`（防御异常时间戳）。
    ///
    /// ⚠️ 反例（旧口径）：`min(末条 − 首条, 6 小时)`。学员 00:00 与 18:28 各说一句 →
    /// 恒等于 6 小时。真机上连续 8 天显示 360 分钟就是这么来的。
    public static func practiceSeconds(
        messageStamps: [Date],
        shadowingWordCounts: [Int]
    ) -> TimeInterval {
        let stamps = messageStamps.sorted()
        var seconds: TimeInterval = stamps.isEmpty ? 0 : openingSeconds
        for (previous, next) in zip(stamps, stamps.dropFirst()) {
            seconds += min(next.timeIntervalSince(previous), idleGapCap)
        }
        // 语音练习也应算作练习时长：跟读一次按「参考句词数 × 0.4 秒」估。
        for count in shadowingWordCounts {
            seconds += Double(max(count, 1)) * shadowingSecondsPerWord
        }
        return min(seconds, dailyDurationCap)
    }

    /// 每天复习了几个**不同**的词。
    static func reviewedCountsByDay(
        _ reviews: [VocabularyReviewStamp],
        calendar: Calendar
    ) -> [Date: Set<UUID>] {
        var result: [Date: Set<UUID>] = [:]
        for stamp in reviews {
            result[calendar.startOfDay(for: stamp.reviewedAt), default: []].insert(stamp.itemID)
        }
        return result
    }

    /// 某天的复习词数。
    ///
    /// 以复习流水为准（`vocabulary_reviews` 一行一次判分，是唯一真源）；
    /// 流水为空时退回 `lastReviewedAt` 口径 —— 老数据与手搓夹具走这条路，
    /// 真实运行时判分与流水是同一笔写入，两者不会打架。
    static func reviewedCounts(
        _ reviews: [VocabularyReviewStamp],
        by day: [Date: Set<UUID>],
        on target: Date,
        vocabulary: [VocabularyEntry],
        calendar: Calendar
    ) -> Int {
        guard !reviews.isEmpty else {
            return ReviewScheduler.reviewedCount(vocabulary, on: target, calendar: calendar)
        }
        return day[target]?.count ?? 0
    }

    /// 当天作文的平均批改分（没有分数样本返回 nil —— 不冒充 0 分）。
    static func averageWritingScore(_ stamps: [WritingStamp]) -> Double? {
        let scores = stamps.compactMap(\.score)
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
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

    /// 跟读折算的练习时长（秒）：参考句词数 × 系数。
    static func shadowingSessionSeconds(_ attempts: [ShadowingAttempt]) -> TimeInterval {
        attempts.reduce(0) { partial, attempt in
            partial + Double(max(ShadowingScorer.words(attempt.referenceText).count, 1)) * shadowingSecondsPerWord
        }
    }

    /// 连续练习天数：从今天（今天没练则从昨天）往前数，遇到空白天停下。
    ///
    /// ⚠️ 不需要 `Calendar`：只按数组顺序数连续段，日期切分是调用方的事
    /// （早先收了个 `calendar` 却一次没用，读签名的人会以为它会做日期对齐）。
    public static func streak(_ activity: [DailyActivity]) -> Int {
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
    public static func daySlots(count: Int, endingAt end: Date, calendar: Calendar) -> [Date] {
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

    // MARK: 每周小结 / 月环比（#228）

    /// 月环比的**样本门槛**：上个月开口不足 5 分钟就不算环比 ——
    /// 拿「3 秒 vs 0 秒」算出「+∞%」或拿 0 冒充「没变化」，都是撒谎。
    public static let monthOverMonthMinSeconds: TimeInterval = 5 * 60

    /// 某天所在周的周一 0 点（**周一起算**的中国习惯，与系统日历设置无关）。
    public static func monday(of day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        // Gregorian weekday：周日 = 1 … 周六 = 7。距周一要回退 (weekday + 5) % 7 天。
        let backDays = (calendar.component(.weekday, from: start) + 5) % 7
        return calendar.date(byAdding: .day, value: -backDays, to: start) ?? start
    }

    /// 从逐日活动里折出「本周小结 + 月环比」。
    ///
    /// 口径与快照**完全同一份**：传入的 `activity` 必须是 `dailyActivity(days:…)`
    /// 的产物（时长唯一尺 `practiceSeconds` 在里面），这里只做切片求和，不再另算一遍。
    ///
    /// - Parameter activity: 旧 → 新的逐日活动，**必须覆盖到上个月 1 号之前**——
    ///   覆盖不到时月环比标记为「样本不足」（数字可以缺，不能是编出来的）。
    public static func weeklyInsight(
        days activity: [DailyActivity],
        now: Date,
        calendar: Calendar
    ) -> WeeklyInsight? {
        guard !activity.isEmpty else { return nil }

        let thisMonday = monday(of: calendar.startOfDay(for: now), calendar: calendar)
        let lastMonday = calendar.date(byAdding: .day, value: -7, to: thisMonday) ?? thisMonday

        func monthStart(containing day: Date) -> Date {
            let comps = calendar.dateComponents([.year, .month], from: day)
            return calendar.date(from: comps) ?? day
        }
        let thisMonthStart = monthStart(containing: now)
        let lastMonthStart: Date = {
            let firstOfThis = monthStart(containing: now)
            let endOfLast = calendar.date(byAdding: .day, value: -1, to: firstOfThis) ?? firstOfThis
            return monthStart(containing: endOfLast)
        }()

        var insight = WeeklyInsight()
        for day in activity {
            let d = calendar.startOfDay(for: day.day)
            if d >= thisMonday {
                insight.weekSeconds += day.seconds
                insight.weekCorrections += day.corrections
                insight.weekNewWords += day.vocabularyAdded
                insight.weekWriting += day.writings
                insight.weekReading += day.readings
            } else if d >= lastMonday {
                insight.lastWeekSeconds += day.seconds
                insight.lastWeekCorrections += day.corrections
            }
            if d >= thisMonthStart {
                insight.monthSeconds += day.seconds
            } else if d >= lastMonthStart {
                insight.lastMonthSeconds += day.seconds
            }
        }
        // 覆盖检查：数据最早的那天如果晚于上月 1 号，「上月」只是残片 → 不给环比。
        if let first = activity.first, calendar.startOfDay(for: first.day) > lastMonthStart {
            insight.isMonthSampleSufficient = false
        }
        return insight
    }
}

// MARK: - 每周小结与月环比（#228）

/// 「本周小结」卡的全部数字。
///
/// 时长口径与快照同一把尺（`practiceSeconds`）；环比只报**有把握**的数字 ——
/// 上月样本不足时 `monthChangePercent == nil`，UI 显示「还不够」而不是 0%。
public struct WeeklyInsight: Sendable, Equatable {

    /// 本周（周一至今）开口时长（秒）。
    public var weekSeconds: TimeInterval = 0
    /// 上周同时长。
    public var lastWeekSeconds: TimeInterval = 0
    /// 本周纠错处数。
    public var weekCorrections: Int = 0
    /// 上周纠错处数。
    public var lastWeekCorrections: Int = 0
    /// 本周新增词汇数。
    public var weekNewWords: Int = 0
    /// 本周交卷批改的作文篇数（#233）。
    public var weekWriting: Int = 0
    /// 本周交卷的阅读篇数（#233）。
    public var weekReading: Int = 0
    /// 本月（1 号至今）开口时长（秒）。
    public var monthSeconds: TimeInterval = 0
    /// 上月整月开口时长（秒）。
    public var lastMonthSeconds: TimeInterval = 0
    /// 月环比是否有足够样本（数据没覆盖到上月 / 上月开口太少都会是 false）。
    public var isMonthSampleSufficient: Bool = true

    public init() {}

    /// 月环比（百分比，正 = 练得更多）。样本不足返回 nil。
    public var monthChangePercent: Double? {
        guard isMonthSampleSufficient else { return nil }
        guard lastMonthSeconds >= ProgressAggregator.monthOverMonthMinSeconds else { return nil }
        return ((monthSeconds - lastMonthSeconds) / lastMonthSeconds) * 100
    }

    /// 本周纠错相对上周的变化（正 = 批注变多）。
    public var correctionChange: Int { weekCorrections - lastWeekCorrections }
}
