import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 第 25 步 学习进度（Dashboard）：
/// - `ProgressAggregator` 纯函数聚合（脱机可测，不依赖 runtime）；
/// - 数据库时间窗口查询；
/// - 进度页能否在空数据 / 有数据两种情况下真实布局。
@MainActor
final class ProgressTests: XCTestCase {

    /// 固定时区 + 固定「现在」，避免跨时区/跨天导致的偶发失败。
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute)) ?? Date()
    }

    private func pronunciation(overall: Double, fluency: Double) -> PronunciationReport {
        PronunciationReport(
            referenceText: "How are you today",
            recognizedText: "how are you today",
            overall: overall,
            verdict: .good,
            lines: [PronunciationScoreLine(dimension: .fluency, score: fluency, detail: "有声占比 78%")],
            metrics: .empty,
            weakest: nil,
            tips: []
        )
    }

    private func makeAppState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("progress-probe-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    // MARK: - 聚合：按天折算

    func testActivityFoldsMessageSpanIntoSameDaySeconds() {
        let now = day(2026, 9, 12, 20, 0)
        let snapshot = ProgressAggregator.snapshot(
            days: 3, now: now, calendar: calendar,
            sessions: [],
            // 今天三条消息横跨 8 分钟；两天前只有一条消息（按「开口半分钟」估）。
            messages: [
                day(2026, 9, 12, 10, 0),
                day(2026, 9, 12, 10, 4),
                day(2026, 9, 12, 10, 8),
                day(2026, 9, 10, 15, 0),
            ],
            corrections: [], shadowing: [], vocabulary: [],
            totalStars: 0, goalMinutes: 15
        )

        XCTAssertEqual(snapshot.activity.count, 3, "窗口 3 天就该有 3 个格子（没练的也要在）")
        XCTAssertEqual(snapshot.today.messages, 3)
        XCTAssertEqual(snapshot.today.seconds, 8 * 60, accuracy: 0.5, "同一天首条→末条 = 练习时长")
        XCTAssertEqual(snapshot.activity[1].messages, 0, "昨天没说话")
        XCTAssertEqual(snapshot.activity[0].messages, 1)
        XCTAssertEqual(snapshot.activity[0].seconds, 30, accuracy: 0.5, "单条消息按半分钟估，不能显示 0")
    }

    func testWindowIsOrderedOldestToNewestAndKeepsEmptyDays() {
        let now = day(2026, 9, 12, 20, 0)
        let snapshot = ProgressAggregator.snapshot(
            days: 7, now: now, calendar: calendar,
            sessions: [], messages: [now], corrections: [], shadowing: [], vocabulary: [],
            totalStars: 5, goalMinutes: 15
        )
        XCTAssertEqual(snapshot.activity.count, 7)
        XCTAssertEqual(snapshot.activity.first?.day, day(2026, 9, 6))
        XCTAssertEqual(snapshot.activity.last?.day, day(2026, 9, 12))
        XCTAssertEqual(snapshot.activeDays, 1)
        XCTAssertEqual(snapshot.activity.filter { !$0.hasPractice }.count, 6)
        XCTAssertEqual(snapshot.totalStars, 5)
    }

    func testStreakDoesNotBreakJustBecauseTodayIsStillEmpty() {
        // 前天 + 昨天都练了、今天还没开口 → 连续 2 天（今天才开始不算断档）。
        let activity = [
            DailyActivity(day: day(2026, 9, 8), messages: 4),
            DailyActivity(day: day(2026, 9, 9)),
            DailyActivity(day: day(2026, 9, 10), messages: 3),
            DailyActivity(day: day(2026, 9, 11), messages: 6),
            DailyActivity(day: day(2026, 9, 12)),
        ]
        XCTAssertEqual(ProgressAggregator.streak(activity, calendar: calendar), 2)

        // 今天也练了 → 3。
        var withToday = activity
        withToday[4] = DailyActivity(day: day(2026, 9, 12), messages: 2)
        XCTAssertEqual(ProgressAggregator.streak(withToday, calendar: calendar), 3)

        // 中间断过 → 只数到断档前。
        let broken = [
            DailyActivity(day: day(2026, 9, 10), messages: 1),
            DailyActivity(day: day(2026, 9, 11)),
            DailyActivity(day: day(2026, 9, 12), messages: 1),
        ]
        XCTAssertEqual(ProgressAggregator.streak(broken, calendar: calendar), 1)
        XCTAssertEqual(ProgressAggregator.streak([], calendar: calendar), 0)
    }

    func testCorrectionsAndPronunciationAndVocabularyLandOnTheirOwnDays() {
        let now = day(2026, 9, 12, 20, 0)
        let correction = GrammarCorrection(original: "I go", corrected: "I went", explanation: "过去时")
        let older = GrammarCorrection(original: "He go", corrected: "He goes", explanation: "第三人称单数")
        let snapshot = ProgressAggregator.snapshot(
            days: 3, now: now, calendar: calendar,
            sessions: [],
            messages: [],
            corrections: [
                CorrectionRecord(correction: correction, createdAt: day(2026, 9, 12, 9, 0)),
                CorrectionRecord(correction: correction, createdAt: day(2026, 9, 12, 9, 30)),
                CorrectionRecord(correction: older, createdAt: day(2026, 9, 11, 9, 30)),
            ],
            shadowing: [
                ShadowingAttempt(drillID: "d1", referenceText: "How are you today",
                                 recognizedText: "how are you today", accuracy: 1,
                                 pronunciation: pronunciation(overall: 80, fluency: 70),
                                 createdAt: day(2026, 9, 12, 11, 0)),
            ],
            vocabulary: [
                VocabularyEntry(word: "apple", source: .manual, createdAt: day(2026, 9, 11, 8, 0)),
                VocabularyEntry(word: "peer", source: .manual, createdAt: day(2026, 9, 12, 8, 0)),
            ],
            totalStars: 0, goalMinutes: 15
        )

        XCTAssertEqual(snapshot.today.corrections, 2)
        XCTAssertEqual(snapshot.activity[1].corrections, 1)
        XCTAssertEqual(snapshot.today.pronunciation ?? 0, 80, accuracy: 0.01)
        XCTAssertEqual(snapshot.today.vocabularyAdded, 1)
        XCTAssertEqual(snapshot.activity[1].vocabularyAdded, 1)
        XCTAssertEqual(snapshot.totalCorrections, 3)
        // 词汇增长是累计口径：昨天 1 词 → 今天 2 词。
        XCTAssertEqual(snapshot.vocabularyGrowth.map(\.value), [0, 1, 2])
        // 发音趋势只画有音频的日子（今天 1 个点），不补假点。
        XCTAssertEqual(snapshot.pronunciationTrend.count, 1)
        XCTAssertEqual(snapshot.recentMistakes.count, 3)
        XCTAssertEqual(snapshot.recentMistakes.first?.original, "I go", "错题按时间从新到旧")
    }

    func testVocabularyGrowthStartsFromPreWindowStock() {
        let now = day(2026, 9, 12, 20, 0)
        let snapshot = ProgressAggregator.snapshot(
            days: 3, now: now, calendar: calendar,
            sessions: [], messages: [], corrections: [], shadowing: [],
            vocabulary: [
                // 窗口之前就有 2 个词，曲线要从 2 起步，而不是从 0 跳。
                VocabularyEntry(word: "old-a", source: .manual, createdAt: day(2026, 8, 1)),
                VocabularyEntry(word: "old-b", source: .manual, createdAt: day(2026, 8, 2)),
                VocabularyEntry(word: "new-a", source: .manual, createdAt: day(2026, 9, 12)),
            ],
            totalStars: 0, goalMinutes: 15
        )
        XCTAssertEqual(snapshot.vocabularyGrowth.map(\.value), [2, 2, 3])
    }

    // MARK: - 聚合：技能分布

    func testGrammarSkillUsesCorrectionDensityNotRawCount() {
        // 20 轮对话 0 处批注 = 满分；8 处批注 = 0.4 处/轮 = 0 分。
        let clean = ProgressAggregator.skillScores(messages: 20, corrections: 0, shadowing: [], vocabulary: [])
        XCTAssertEqual(clean.first { $0.kind == .grammar }?.score ?? -1, 1, accuracy: 0.001)

        let noisy = ProgressAggregator.skillScores(messages: 20, corrections: 8, shadowing: [], vocabulary: [])
        XCTAssertEqual(noisy.first { $0.kind == .grammar }?.score ?? -1, 0, accuracy: 0.001)

        // 同样 8 处批注，聊 80 轮时不该被判成「语法差」。
        let chatty = ProgressAggregator.skillScores(messages: 80, corrections: 8, shadowing: [], vocabulary: [])
        XCTAssertGreaterThan(chatty.first { $0.kind == .grammar }?.score ?? 0, 0.7)
    }

    func testVocabularySkillBlendsMasteryAndDefinition() {
        let vocabulary = [
            VocabularyEntry(word: "a", meaning: "释义", mastery: 5, source: .manual),
            VocabularyEntry(word: "b", meaning: "释义", mastery: 5, source: .manual),
            VocabularyEntry(word: "c", meaning: "释义", mastery: 0, source: .manual),
            VocabularyEntry(word: "d", meaning: "释义", mastery: 0, source: .manual),
        ]
        let skills = ProgressAggregator.skillScores(messages: 0, corrections: 0, shadowing: [], vocabulary: vocabulary)
        // 掌握度 2/4 = 0.5（占 6 成）+ 释义 4/4 = 1（占 4 成）→ 0.7
        XCTAssertEqual(skills.first { $0.kind == .vocabulary }?.score ?? -1, 0.7, accuracy: 0.001)
        XCTAssertEqual(skills.first { $0.kind == .vocabulary }?.sampleCount, 4)
    }

    func testPronunciationAndFluencySkillsComeFromShadowingReports() {
        let attempts = [
            ShadowingAttempt(drillID: "d1", referenceText: "How are you today", recognizedText: "how are you today",
                             accuracy: 0.9, pronunciation: pronunciation(overall: 80, fluency: 70)),
            ShadowingAttempt(drillID: "d2", referenceText: "Nice to meet you", recognizedText: "nice to meet you",
                             accuracy: 0.7, pronunciation: pronunciation(overall: 90, fluency: 50)),
        ]
        let skills = ProgressAggregator.skillScores(messages: 0, corrections: 0, shadowing: attempts, vocabulary: [])
        XCTAssertEqual(skills.first { $0.kind == .pronunciation }?.score ?? -1, 0.85, accuracy: 0.001)
        XCTAssertEqual(skills.first { $0.kind == .fluency }?.score ?? -1, 0.6, accuracy: 0.001)
        XCTAssertEqual(skills.first { $0.kind == .shadowing }?.score ?? -1, 0.8, accuracy: 0.001)
    }

    func testSkillsWithoutDataAreLeftUnscored() {
        let skills = ProgressAggregator.skillScores(messages: 0, corrections: 0, shadowing: [], vocabulary: [])
        XCTAssertEqual(skills.count, SkillKind.allCases.count)
        for skill in skills {
            XCTAssertFalse(skill.hasData, "\(skill.kind) 没有数据就不该有样本")
            XCTAssertEqual(skill.score, 0)
            XCTAssertEqual(skill.percent, 0)
        }
    }

    // MARK: - 目标与文案

    func testGoalProgressAndDurationText() {
        XCTAssertEqual(ProgressAggregator.durationText(0), "0 秒")
        XCTAssertEqual(ProgressAggregator.durationText(58), "58 秒")
        XCTAssertEqual(ProgressAggregator.durationText(3 * 60 + 12), "3 分 12 秒")
        XCTAssertEqual(ProgressAggregator.durationText(3600 + 4 * 60), "1 小时 4 分")

        let now = day(2026, 9, 12, 20, 0)
        let snapshot = ProgressAggregator.snapshot(
            days: 1, now: now, calendar: calendar,
            sessions: [], messages: [day(2026, 9, 12, 10, 0), day(2026, 9, 12, 10, 20)],
            corrections: [], shadowing: [], vocabulary: [],
            totalStars: 0, goalMinutes: 10
        )
        XCTAssertEqual(snapshot.today.minutes, 20)
        XCTAssertEqual(snapshot.goalProgress, 1, accuracy: 0.001, "超出目标按满计")
        XCTAssertTrue(snapshot.goalReached)
    }

    func testEmptySnapshotIsRenderableAndHasNoNaN() {
        let snapshot = ProgressSnapshot.empty(now: day(2026, 9, 12, 20, 0), days: 5, goalMinutes: 15)
        XCTAssertEqual(snapshot.activity.count, 5)
        XCTAssertEqual(snapshot.goalProgress, 0, "没有练习时完成度是 0，不能是 NaN")
        XCTAssertFalse(snapshot.goalReached)
        XCTAssertEqual(snapshot.skills.count, SkillKind.allCases.count)
        XCTAssertTrue(snapshot.skills.allSatisfy { !$0.hasData }, "空快照的技能维度一律「还没数据」，不冒充 0 分")
        XCTAssertEqual(snapshot.today.messages, 0)
    }

    // MARK: - 数据库时间窗口

    func testDatabaseWindowQueriesFilterByTime() async throws {
        let db = try LearningDatabase.inMemory()
        let now = Date()
        let session = ChatSession(id: UUID(), startedAt: now, mode: .conversation)
        try await db.createSession(session)

        // 新消息 + 30 天前的旧消息；窗口查询只应看到新的。
        let recent = ChatMessage(role: .user, content: "hello", createdAt: now.addingTimeInterval(-60))
        let old = ChatMessage(role: .user, content: "old", createdAt: now.addingTimeInterval(-30 * 86_400))
        try await db.appendMessage(recent, sessionID: session.id)
        try await db.appendMessage(old, sessionID: session.id)

        let cutoff = now.addingTimeInterval(-7 * 86_400)
        let stamps = try await db.messageTimestamps(since: cutoff)
        XCTAssertEqual(stamps.count, 1, "只取窗口内的消息时间戳")
        XCTAssertEqual(stamps.first?.timeIntervalSince1970 ?? 0, recent.createdAt.timeIntervalSince1970, accuracy: 1)

        // 跟读：新 + 旧。
        try await db.appendShadowingAttempt(
            ShadowingAttempt(drillID: "d1", referenceText: "How are you today", recognizedText: "how are you today",
                             accuracy: 0.9, createdAt: now.addingTimeInterval(-120))
        )
        try await db.appendShadowingAttempt(
            ShadowingAttempt(drillID: "d2", referenceText: "Nice to meet you", recognizedText: "nice to meet you",
                             accuracy: 0.5, createdAt: now.addingTimeInterval(-40 * 86_400))
        )
        let attempts = try await db.shadowingAttempts(since: cutoff)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.drillID, "d1")

        // 纠错：写入即带上「此刻」，窗口起点设在签名之后就不该被取到。
        try await db.appendCorrection(
            GrammarCorrection(original: "I go", corrected: "I went", explanation: "过去时"),
            sessionID: session.id
        )
        let windowCorrections = try await db.correctionRecords(since: cutoff)
        XCTAssertEqual(windowCorrections.count, 1)
        let futureCorrections = try await db.correctionRecords(since: now.addingTimeInterval(3600))
        XCTAssertTrue(futureCorrections.isEmpty)

        // 会话窗口。
        let windowSessions = try await db.sessions(since: cutoff)
        XCTAssertEqual(windowSessions.count, 1)
        let futureSessions = try await db.sessions(since: now.addingTimeInterval(3600))
        XCTAssertTrue(futureSessions.isEmpty)
    }

    func testProgressServiceAggregatesFromDatabase() async throws {
        let db = try LearningDatabase.inMemory()
        let service = ProgressService(learning: db)
        let now = Date()
        let session = ChatSession(id: UUID(), startedAt: now, mode: .conversation)
        try await db.createSession(session)
        for offset in [0.0, 300, 600] {
            try await db.appendMessage(
                ChatMessage(role: .user, content: "hi", createdAt: now.addingTimeInterval(-600 + offset)),
                sessionID: session.id
            )
        }
        try await db.appendCorrection(
            GrammarCorrection(original: "I go", corrected: "I went", explanation: "过去时"),
            sessionID: session.id
        )

        let snapshot = await service.snapshot(days: 7, now: now, calendar: calendar, totalStars: 9, goalMinutes: 10)
        XCTAssertEqual(snapshot.today.messages, 3)
        XCTAssertEqual(snapshot.today.corrections, 1)
        XCTAssertEqual(snapshot.today.seconds, 600, accuracy: 1)
        XCTAssertEqual(snapshot.totalStars, 9)
        XCTAssertEqual(snapshot.goalMinutes, 10)
        XCTAssertEqual(snapshot.activeDays, 1)

        // 数据库不可用（nil）时必须返回可渲染的空快照，而不是崩或空白页。
        let degraded = await ProgressService(learning: nil).snapshot(days: 3, totalStars: 0, goalMinutes: 15)
        XCTAssertEqual(degraded.activity.count, 3)
        XCTAssertEqual(degraded.totalMessages, 0)
    }

    // MARK: - 页面

    func testProgressPageLayoutsEmptyAndFilledStates() async {
        let state = makeAppState()
        XCTAssertFalse(state.showingProgress)

        await state.openProgress()
        XCTAssertTrue(state.showingProgress)
        XCTAssertEqual(state.progressSnapshot.activity.count, state.progressWindowDays)
        XCTAssertEqual(state.progressSnapshot.goalMinutes, state.dailyGoalMinutes)

        let hosting = NSHostingView(rootView: LearningProgressView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0, "空数据的进度页也要能完整布局")

        // 切窗口 + 改目标（要真的重算，不是只改数字）。
        await state.setProgressWindow(30)
        XCTAssertEqual(state.progressSnapshot.activity.count, 30)
        await state.setDailyGoalMinutes(25)
        XCTAssertEqual(state.progressSnapshot.goalMinutes, 25)
        XCTAssertEqual(state.dailyGoalMinutes, 25, "每日目标要写进产品配置（持久化）")

        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }

    func testProgressPageSitsAloneInTheMiddleColumn() async {
        let state = makeAppState()
        await state.openProgress()
        await state.openRecords()
        XCTAssertFalse(state.showingProgress, "进学习记录页时进度页要退出")
        await state.openProgress()
        await state.openShadowing()
        XCTAssertFalse(state.showingProgress)
        await state.openProgress()
        await state.openVocabulary()
        XCTAssertFalse(state.showingProgress)
        await state.openProgress()
        await state.openPractice()
        XCTAssertFalse(state.showingProgress)
    }
}
