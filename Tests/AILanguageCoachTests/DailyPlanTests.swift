import AIDomain
import XCTest

/// 每日任务推荐（P1-1）单测。
///
/// 覆盖：目标折算与夹取、三项任务各自的进度口径、缺数据时**不硬凑任务**、
/// 「今日重点」的优先级与兜底、完成度判定，以及聚合器把「今天复习了几个」算进快照。
/// 全部是纯函数，不碰模型 / 数据库 / 麦克风。
final class DailyPlanTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// 直接拼快照（`today` / `vocabulary` 都是现成的值对象，不必绕聚合器）。
    /// 参数顺序必须与 `ProgressSnapshot.init` 的声明顺序一致。
    private func snapshot(
        today: DailyActivity,
        vocabulary: VocabularyStats = .empty,
        reviewedToday: Int = 0,
        shadowing: ShadowingStats = .empty,
        skills: [SkillScore] = [],
        recentMistakes: [GrammarCorrection] = [],
        goalMinutes: Int = 15
    ) -> ProgressSnapshot {
        ProgressSnapshot(
            skills: skills,
            today: today,
            vocabulary: vocabulary,
            vocabularyReviewedToday: reviewedToday,
            shadowing: shadowing,
            recentMistakes: recentMistakes,
            goalMinutes: goalMinutes
        )
    }

    // MARK: - 目标折算

    func testExchangeTargetFollowsGoalMinutesAndClamps() {
        // 一轮往来按 1.5 分钟算：15 分钟 → 10 轮（15×60 / 90）
        XCTAssertEqual(DailyPlanner.exchangeTarget(goalMinutes: 15), 10)
        XCTAssertEqual(DailyPlanner.exchangeTarget(goalMinutes: 5), DailyPlanner.conversationFloor,
                       "5 分钟折算出来只有 3 轮，必须抬到下限 4 —— 三句话热不了身")
        XCTAssertEqual(DailyPlanner.exchangeTarget(goalMinutes: 180), DailyPlanner.conversationCeiling,
                       "上限 12 轮：目标是催人开口，不是压任务")
    }

    // MARK: - 三项任务

    func testPlanCarriesAllThreeTasksWithRealProgress() {
        let now = day(2026, 9, 15, 20, 0)
        let plan = DailyPlanner.plan(
            snapshot: snapshot(
                today: DailyActivity(day: calendar.startOfDay(for: now), seconds: 120, messages: 2, shadowingAttempts: 1),
                vocabulary: VocabularyStats(total: 9, due: 3, mastered: 1, defined: 9),
                reviewedToday: 1,
                shadowing: ShadowingStats(
                    attempts: 12, bestAccuracy: 0.9, averageAccuracy: 0.82, lastAccuracy: 0.85,
                    bestPronunciation: 88, averagePronunciation: 78
                )
            ),
            now: now, calendar: calendar
        )

        XCTAssertEqual(plan.tasks.map(\.kind), [.conversation, .shadowing, .review])

        let conversation = plan.tasks[0]
        XCTAssertEqual(conversation.progress, 2, "今天已聊 2 轮")
        XCTAssertEqual(conversation.target, 10)
        XCTAssertEqual(conversation.reason, "每日目标 15 分钟 · 今天已聊 2 轮")

        let shadowing = plan.tasks[1]
        XCTAssertEqual(shadowing.progress, 1)
        XCTAssertEqual(shadowing.target, DailyPlanner.shadowingTarget)
        XCTAssertTrue(shadowing.reason.contains("发音均分 78"), "实测：\(shadowing.reason)")

        let review = plan.tasks[2]
        XCTAssertEqual(review.target, 3, "到期 3 个")
        XCTAssertEqual(review.progress, 1, "今天复习过 1 个")
    }

    /// 没有到期的词 → **不排这一项**，而不是挂个 0/0 的空任务。
    func testReviewTaskIsDroppedWhenNothingIsDue() {
        let now = day(2026, 9, 15, 20, 0)
        let plan = DailyPlanner.plan(
            snapshot: snapshot(
                today: DailyActivity(day: calendar.startOfDay(for: now)),
                vocabulary: VocabularyStats(total: 4, due: 0, mastered: 4, defined: 4)
            ),
            now: now, calendar: calendar
        )
        XCTAssertFalse(plan.tasks.contains { $0.kind == .review }, "没有到期的词就没有复习任务")
        XCTAssertEqual(plan.tasks.count, 2)
    }

    /// 到期很多也只要求先做 8 个，且理由文案要把「先做前 N 个」说清楚。
    func testReviewTargetIsCappedAndSaysSo() throws {
        let now = day(2026, 9, 15, 20, 0)
        let plan = DailyPlanner.plan(
            snapshot: snapshot(
                today: DailyActivity(day: calendar.startOfDay(for: now)),
                vocabulary: VocabularyStats(total: 20, due: 20, mastered: 0, defined: 20)
            ),
            now: now, calendar: calendar
        )
        let review = try XCTUnwrap(plan.tasks.first { $0.kind == .review })
        XCTAssertEqual(review.target, DailyPlanner.reviewCap)
        XCTAssertEqual(review.reason, "有 20 个词到期，先做前 8 个")
    }

    /// 完全没记录时也要给出可做的任务（今天还没开口 + 跟读），不因为「没数据」就空着。
    func testEmptySnapshotStillOffersSomethingToDo() {
        let now = day(2026, 9, 15, 9, 0)
        let plan = DailyPlanner.plan(
            snapshot: .empty(now: now, goalMinutes: 15), now: now, calendar: calendar
        )
        XCTAssertEqual(plan.tasks.map(\.kind), [.conversation, .shadowing])
        XCTAssertTrue(plan.tasks.allSatisfy { $0.progress == 0 })
        XCTAssertFalse(plan.isAllDone)
        XCTAssertEqual(plan.progressText, "0 / 2 项")
        XCTAssertEqual(plan.nextTask?.kind, .conversation)
        XCTAssertEqual(plan.tasks[0].reason, "每日目标 15 分钟，今天还没开口",
                       "理由必须说清为什么推荐它")
    }

    // MARK: - 「今天复习了几个」的口径

    /// 只认 `lastReviewedAt` 落在**同一天**的记录。
    func testReviewedCountUsesSameCalendarDay() {
        let now = day(2026, 9, 15, 20, 0)
        let entries = [
            VocabularyEntry(word: "today", mastery: 1, lastReviewedAt: now),
            VocabularyEntry(word: "lastnight", mastery: 1, lastReviewedAt: day(2026, 9, 14, 22, 0)),
            VocabularyEntry(word: "never", mastery: 1, lastReviewedAt: nil),
        ]
        XCTAssertEqual(ReviewScheduler.reviewedCount(entries, on: now, calendar: calendar), 1)
        XCTAssertEqual(ReviewScheduler.reviewedCount(entries, on: day(2026, 9, 14), calendar: calendar), 1,
                       "14 号那天复习过 lastnight")
        XCTAssertEqual(ReviewScheduler.reviewedCount(entries, on: day(2026, 9, 13), calendar: calendar), 0)
    }

    /// 聚合器要把「今天复习了几个」算进快照 —— 这是任务完成度唯一的来源。
    func testAggregatorPutsTodaysReviewCountIntoSapshot() {
        let now = day(2026, 9, 15, 20, 0)
        let snapshot = ProgressAggregator.snapshot(
            days: 14, now: now, calendar: calendar,
            sessions: [], messages: [], corrections: [], shadowing: [],
            vocabulary: [
                VocabularyEntry(word: "a", mastery: 1, lastReviewedAt: now),
                VocabularyEntry(word: "b", mastery: 2, lastReviewedAt: day(2026, 9, 12)),
                VocabularyEntry(word: "c"),
            ],
            totalStars: 0, goalMinutes: 15
        )
        XCTAssertEqual(snapshot.vocabulary.total, 3)
        XCTAssertEqual(snapshot.vocabularyReviewedToday, 1)
    }

    // MARK: - 完成度

    func testCompletionAndNextTask() {
        let tasks = [
            DailyTask(kind: .conversation, title: "聊 4 轮", reason: "", target: 4, progress: 4, unit: "轮"),
            DailyTask(kind: .shadowing, title: "跟读 3 句", reason: "", target: 3, progress: 1, unit: "次"),
        ]
        let plan = DailyPlan(day: Date(), tasks: tasks)
        XCTAssertEqual(plan.completedCount, 1)
        XCTAssertFalse(plan.isAllDone)
        XCTAssertEqual(plan.progressText, "1 / 2 项")
        XCTAssertEqual(plan.progressRatio, 0.5, accuracy: 0.0001)
        XCTAssertEqual(plan.nextTask?.kind, .shadowing)
        XCTAssertTrue(tasks[0].isDone)

        // 超额算满，不显示 150%。
        let over = DailyTask(kind: .review, title: "", reason: "", target: 2, progress: 5, unit: "个词")
        XCTAssertEqual(over.progressRatio, 1)
        XCTAssertEqual(over.progressText, "2 / 2 个词")
    }

    // MARK: - 今日重点

    func testFocusPrefersMostFrequentTeachableCategory() {
        let now = day(2026, 9, 15, 20, 0)
        // 三处时态错、一处冠词错 → 点名的必须是时态。
        let snapshot = snapshot(
            today: DailyActivity(day: calendar.startOfDay(for: now)),
            recentMistakes: [
                GrammarCorrection(original: "I go to Seattle yesterday.",
                                  corrected: "I went to Seattle yesterday.",
                                  explanation: "过去的时间要用过去式"),
                GrammarCorrection(original: "He go home.", corrected: "He went home.",
                                  explanation: "过去式"),
                GrammarCorrection(original: "We eat already.", corrected: "We ate already.",
                                  explanation: "过去式"),
                GrammarCorrection(original: "I saw a elephant.", corrected: "I saw an elephant.",
                                  explanation: "冠词选择"),
            ]
        )
        let focus = DailyPlanner.focus(snapshot)
        XCTAssertEqual(focus?.title, "今天重点：时态")
        XCTAssertTrue(focus?.reason.contains("4 处批注里有 3 处") == true,
                      "理由要给出可核对的数目，实测：\(focus?.reason ?? "nil")")
    }

    /// 兜底分类 `.other` **不能**被点名 —— 「今天重点：其他」等于什么也没说。
    func testFocusNeverNamesTheCatchAllCategory() {
        let now = day(2026, 9, 15, 20, 0)
        let candidates = [
            snapshot(today: DailyActivity(day: calendar.startOfDay(for: now))),
            snapshot(
                today: DailyActivity(day: calendar.startOfDay(for: now)),
                recentMistakes: [GrammarCorrection(original: "zzz", corrected: "yyy", explanation: "说不清")]
            ),
            // 兜底占多数、真分类只有一条：**不许**因为 other 多就去点 other。
            snapshot(
                today: DailyActivity(day: calendar.startOfDay(for: now)),
                recentMistakes: [
                    GrammarCorrection(original: "zzz1", corrected: "yyy1", explanation: ""),
                    GrammarCorrection(original: "zzz2", corrected: "yyy2", explanation: ""),
                    GrammarCorrection(original: "I saw a elephant.", corrected: "I saw an elephant.",
                                      explanation: "冠词选择"),
                ]
            ),
        ]
        for candidate in candidates {
            let focus = DailyPlanner.focus(candidate)
            XCTAssertNotEqual(focus?.title, "今天重点：其他", "不许把兜底分类当重点")
        }
    }

    func testFocusFallsBackToWeakestMeasuredSkill() {
        let now = day(2026, 9, 15, 20, 0)
        let snapshot = snapshot(
            today: DailyActivity(day: calendar.startOfDay(for: now)),
            skills: [
                SkillScore(kind: .grammar, score: 0.9, sampleCount: 12, detail: ""),
                SkillScore(kind: .pronunciation, score: 0.62, sampleCount: 5, detail: ""),
                // 没有样本的技能不算数：0 分是「没数据」，不是「很差」。
                SkillScore(kind: .fluency, score: 0.0, sampleCount: 0, detail: ""),
            ]
        )
        let focus = DailyPlanner.focus(snapshot)
        XCTAssertEqual(focus?.title, "今天重点：发音")
        XCTAssertTrue(focus?.reason.contains("62 分") == true, "实测：\(focus?.reason ?? "nil")")
        XCTAssertTrue(focus?.reason.contains("5 条记录") == true, "要点明有多少条记录撑着这个结论")
    }

    /// 没什么可说的就**不说**，不硬凑一句鼓励。
    func testFocusIsNilWhenNothingToSay() {
        let now = day(2026, 9, 15, 20, 0)
        let healthy = snapshot(
            today: DailyActivity(day: calendar.startOfDay(for: now)),
            skills: [SkillScore(kind: .grammar, score: 0.95, sampleCount: 20, detail: "")]
        )
        XCTAssertNil(DailyPlanner.focus(healthy))
    }
}
