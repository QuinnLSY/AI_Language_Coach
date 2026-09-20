import AIDomain
import AIInfrastructure
import Foundation

/// 学习进度（Dashboard，第 25 步）：把学习数据库里的原始记录汇成一份 `ProgressSnapshot`。
///
/// 职责边界：
/// - **取数**在这里（只经 `LearningDatabase`，不写 SQL、不碰 Provider）；
/// - **折算**在 `ProgressAggregator`（AIDomain 的纯函数）；
/// - **渲染**在 AppUI。
///
/// 数据库不可用时返回空快照 —— Dashboard 要能空着打开，而不是报错或空白。
public actor ProgressService {

    private let learning: LearningDatabase?

    public init(learning: LearningDatabase?) {
        self.learning = learning
    }

    /// 生成一份快照。
    /// - Parameters:
    ///   - days: 统计窗口天数（默认 14 天）。
    ///   - totalStars: 累计星星（由闯关进度提供，不在本服务算）。
    ///   - goalMinutes: 每日目标（分钟）。
    public func snapshot(
        days: Int = ProgressAggregator.defaultDays,
        now: Date = Date(),
        calendar: Calendar = .current,
        totalStars: Int = 0,
        goalMinutes: Int = ProgressAggregator.defaultGoalMinutes
    ) async -> ProgressSnapshot {
        guard let learning else {
            return ProgressSnapshot.empty(now: now, days: days, goalMinutes: goalMinutes)
        }
        let window = max(days, 1)
        // 窗口起点往前多取一天：本地时区换算可能让「窗口前一天的深夜」落进第一天。
        let start = calendar.startOfDay(for: now)
            .addingTimeInterval(-Double(window + 1) * 86_400)

        let sessions = (try? await learning.sessions(since: start)) ?? []
        let messages = (try? await learning.messageTimestamps(since: start)) ?? []
        let corrections = (try? await learning.correctionRecords(since: start)) ?? []
        let shadowing = (try? await learning.shadowingAttempts(since: start)) ?? []
        // 词汇用全量：累计曲线需要窗口之前的存量当起始高度。
        let vocabulary = (try? await learning.allVocabulary()) ?? []
        // 写作 / 阅读（#233）：阅读只认交卷的（口径见 `ReadingStamp`）。
        let writings = (try? await learning.writingStamps(since: start)) ?? []
        let readings = (try? await learning.readingStamps(since: start)) ?? []

        return ProgressAggregator.snapshot(
            days: window,
            now: now,
            calendar: calendar,
            sessions: sessions,
            messages: messages,
            corrections: corrections,
            shadowing: shadowing,
            vocabulary: vocabulary,
            totalStars: totalStars,
            goalMinutes: goalMinutes,
            writings: writings,
            readings: readings
        )
    }

    /// 最近错题（Dashboard「Recent mistakes」直接用的列表，比窗口更宽）。
    public func recentMistakes(limit: Int = 20) async -> [GrammarCorrection] {
        guard let learning else { return [] }
        return (try? await learning.recentCorrections(limit: limit)) ?? []
    }

    // MARK: - 每周小结与月环比（#228）

    /// 「本周小结」卡的数字：本周 / 上周时长与纠错、本周新增词、月环比。
    ///
    /// 与 `snapshot(days:)` **分开取数**（同年度记录的理由）：小结要看 63 天
    /// （覆盖到上个月 1 号之前，月环比才有整月的上期样本），窗口只要 7–30 天。
    /// 折算仍走 `ProgressAggregator` 纯函数，不另立第二把尺。
    public func weeklyInsight(now: Date = Date(), calendar: Calendar = .current) async -> WeeklyInsight? {
        guard let learning else { return nil }
        // 63 天 = 上月整月 + 本月至今的最坏情况（31 + 31）再放宽一天。
        let window = 63
        let start = calendar.startOfDay(for: now)
            .addingTimeInterval(-Double(window) * 86_400)
        let messages = (try? await learning.messageTimestamps(since: start)) ?? []
        let corrections = (try? await learning.correctionRecords(since: start)) ?? []
        let shadowing = (try? await learning.shadowingStamps(since: start)) ?? []
        // 词汇用全量：`dailyActivity` 按 createdAt 折每天新增。
        let vocabulary = (try? await learning.allVocabulary()) ?? []
        let writings = (try? await learning.writingStamps(since: start)) ?? []
        let readings = (try? await learning.readingStamps(since: start)) ?? []

        let days = ProgressAggregator.daySlots(count: window, endingAt: calendar.startOfDay(for: now), calendar: calendar)
        let activity = ProgressAggregator.dailyActivity(
            days: days,
            calendar: calendar,
            messages: messages,
            corrections: corrections,
            shadowing: shadowing,
            vocabulary: vocabulary,
            writings: writings,
            readings: readings
        )
        return ProgressAggregator.weeklyInsight(days: activity, now: now, calendar: calendar)
    }

    // MARK: - 年度学习记录

    /// 近一年的练习分布（53 周 × 7 天）。
    ///
    /// 与 `snapshot(days:)` **分开取数**，不图省事合并：窗口只看 7–30 天，
    /// 年度要看一整年；而且年度不需要发音报告 / 纠错 / 会话这些，
    /// 只取「哪天有过什么」。合成一次查询会把窗口的取数量级也抬到一年。
    public func annualRecap(
        now: Date = Date(),
        calendar: Calendar = .current,
        goalMinutes: Int = ProgressAggregator.defaultGoalMinutes
    ) async -> AnnualRecap {
        guard let learning else {
            return AnnualRecap.empty(now: now, goalMinutes: goalMinutes)
        }
        let slots = AnnualRecapBuilder.daySlots(now: now, calendar: calendar)
        guard let start = slots.first else {
            return AnnualRecap.empty(now: now, goalMinutes: goalMinutes)
        }
        let messages = (try? await learning.messageTimestamps(since: start)) ?? []
        let shadowing = (try? await learning.shadowingStamps(since: start)) ?? []
        let reviews = (try? await learning.vocabularyReviewStamps(since: start)) ?? []
        let writings = (try? await learning.writingStamps(since: start)) ?? []
        let readings = (try? await learning.readingStamps(since: start)) ?? []

        let activity = ProgressAggregator.dailyActivity(
            days: slots,
            calendar: calendar,
            messages: messages,
            shadowing: shadowing,
            reviews: reviews,
            writings: writings,
            readings: readings
        )
        return AnnualRecapBuilder.build(
            days: activity, goalMinutes: goalMinutes, now: now, calendar: calendar
        )
    }
}
