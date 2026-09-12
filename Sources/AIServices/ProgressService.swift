import AIDomain
import AIInfrastructure
import AppCore
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
            goalMinutes: goalMinutes
        )
    }

    /// 最近错题（Dashboard「Recent mistakes」直接用的列表，比窗口更宽）。
    public func recentMistakes(limit: Int = 20) async -> [GrammarCorrection] {
        guard let learning else { return [] }
        return (try? await learning.recentCorrections(limit: limit)) ?? []
    }
}
