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
                vocabulary: VocabularyStats(
                    total: 9, due: 3, mastered: 1, defined: 9,
                    dueAtDayStart: 3, dueAtDayStartReviewed: 1
                ),
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
                vocabulary: VocabularyStats(
                    total: 4, due: 0, mastered: 4, defined: 4,
                    dueAtDayStart: 0, dueAtDayStartReviewed: 0
                )
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
                vocabulary: VocabularyStats(
                    total: 20, due: 20, mastered: 0, defined: 20,
                    dueAtDayStart: 20, dueAtDayStartReviewed: 0
                )
            ),
            now: now, calendar: calendar
        )
        let review = try XCTUnwrap(plan.tasks.first { $0.kind == .review })
        XCTAssertEqual(review.target, DailyPlanner.reviewCap)
        XCTAssertEqual(review.reason, "今天有 20 个词要复习，先做前 8 个")
    }

    /// **核心回归**：今天起初 8 个到期词，复习掉 3 个之后任务仍是「复习 8 个」、进度 3/8；
    /// 全部复习完是 8/8 且任务**留在板上**。
    ///
    /// 撤掉修复（指标改回「此刻到期」）时这条会红成 5/5，最后那一档还会整项消失 ——
    /// 用户报的正是这个：「多完成的不应该再计入，也不应该改动任务中的指标」。
    func testReviewTargetStaysFixedWhileProgressGrows() throws {
        let now = day(2026, 9, 15, 20, 0)

        /// `reviewed` = 今天起初那批词里已经复习掉的个数；「此刻到期」随之减少。
        func reviewTask(reviewed: Int) -> DailyTask? {
            DailyPlanner.plan(
                snapshot: snapshot(
                    today: DailyActivity(day: calendar.startOfDay(for: now)),
                    vocabulary: VocabularyStats(
                        total: 8, due: 8 - reviewed, mastered: 0, defined: 8,
                        dueAtDayStart: 8, dueAtDayStartReviewed: reviewed
                    )
                ),
                now: now, calendar: calendar
            ).tasks.first { $0.kind == .review }
        }

        let start = try XCTUnwrap(reviewTask(reviewed: 0))
        XCTAssertEqual(start.progressText, "0 / 8 个词")

        let midway = try XCTUnwrap(reviewTask(reviewed: 3))
        XCTAssertEqual(midway.target, 8, "复习掉 3 个，指标仍是 8 —— 此刻到期只剩 5 也不算数")
        XCTAssertEqual(midway.progressText, "3 / 8 个词")
        XCTAssertFalse(midway.isDone)

        let done = try XCTUnwrap(reviewTask(reviewed: 8))
        XCTAssertEqual(done.target, 8)
        XCTAssertEqual(done.progressText, "8 / 8 个词")
        XCTAssertEqual(done.reason, "今天有 8 个词要复习")
        XCTAssertTrue(done.isDone, "全部复习完 → 任务留着显示已完成，而不是整项消失")
    }

    // MARK: - 保底档（#225）

    /// 保底档把三项任务缩到 5 分钟内可完成的量：对话 2 轮、跟读 1 句、复习至多 3 个。
    func testBaselinePlanScalesAllTargetsDown() throws {
        let now = day(2026, 9, 15, 20, 0)
        let plan = DailyPlanner.plan(
            snapshot: snapshot(
                today: DailyActivity(day: calendar.startOfDay(for: now)),
                vocabulary: VocabularyStats(
                    total: 30, due: 30, mastered: 0, defined: 30,
                    dueAtDayStart: 30, dueAtDayStartReviewed: 0
                )
            ),
            mode: .baseline,
            now: now, calendar: calendar
        )

        let conversation = try XCTUnwrap(plan.tasks.first { $0.kind == .conversation })
        XCTAssertEqual(conversation.target, DailyPlanner.baselineConversationTarget, "保底档对话只要 2 轮（≈3 分钟）")
        XCTAssertEqual(conversation.reason, "保底目标 5 分钟，今天还没开口")

        let shadowing = try XCTUnwrap(plan.tasks.first { $0.kind == .shadowing })
        XCTAssertEqual(shadowing.target, DailyPlanner.baselineShadowingTarget, "保底档跟读 1 句就够")

        let review = try XCTUnwrap(plan.tasks.first { $0.kind == .review })
        XCTAssertEqual(review.target, DailyPlanner.baselineReviewCap, "保底档复习至多 3 个")
    }

    /// 保底档的完成判定：2 轮 + 1 句 + 复习齐了 = 全部完成（保住连续的那条路）。
    func testBaselinePlanCompletionKeepsStreak() {
        let now = day(2026, 9, 15, 20, 30)
        let plan = DailyPlanner.plan(
            snapshot: snapshot(
                today: DailyActivity(
                    day: calendar.startOfDay(for: now), seconds: 300, messages: 4, shadowingAttempts: 2
                ),
                vocabulary: VocabularyStats(
                    total: 10, due: 2, mastered: 0, defined: 10,
                    dueAtDayStart: 2, dueAtDayStartReviewed: 2
                ),
                reviewedToday: 2
            ),
            mode: .baseline,
            now: now, calendar: calendar
        )
        XCTAssertTrue(plan.isAllDone, "保底档完成量（2 轮 + 1 句 + 2 词）应当判全部完成")
        XCTAssertEqual(plan.completedCount, plan.totalCount)
    }

    /// 进阶档行为不变：同一份快照，两档的目标量必须不同 —— 这是「档位」存在的意义。
    func testAdvancedAndBaselineDivergeOnSameSnapshot() throws {
        let now = day(2026, 9, 15, 20, 0)
        let snap = snapshot(
            today: DailyActivity(day: calendar.startOfDay(for: now)),
            vocabulary: VocabularyStats(
                total: 20, due: 20, mastered: 0, defined: 20,
                dueAtDayStart: 20, dueAtDayStartReviewed: 0
            )
        )
        let advanced = DailyPlanner.plan(snapshot: snap, mode: .advanced, now: now, calendar: calendar)
        let baseline = DailyPlanner.plan(snapshot: snap, mode: .baseline, now: now, calendar: calendar)

        let advancedConversation = try XCTUnwrap(advanced.tasks.first { $0.kind == .conversation })
        let baselineConversation = try XCTUnwrap(baseline.tasks.first { $0.kind == .conversation })
        XCTAssertNotEqual(advancedConversation.target, baselineConversation.target)
        // 进阶档沿用「每日目标折算 + 夹取」的旧口径。
        XCTAssertEqual(advancedConversation.target, DailyPlanner.exchangeTarget(goalMinutes: 15))
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

    /// **端到端**：真实词条 → 聚合器 → 快照 → 每日计划 → 任务文案。
    /// 中间任何一环漏填「今天起初的到期盘子」，这条都会红。
    ///
    /// 场景就是用户报的那个：今天起初 8 个到期词，复习掉 3 个（答对 → 不再到期），
    /// 任务必须仍是「复习 8 个到期单词 · 3 / 8 个词」。
    func testReviewTaskKeepsDayStartTargetEndToEnd() throws {
        let now = day(2026, 9, 15, 20, 0)
        let yesterday = day(2026, 9, 14, 20, 0)

        // 8 个昨天入本、掌握度 0 的词（间隔 0 天 → 今天 0 点必然到期）；
        // 前 3 个今天已复习过（答对 → 掌握度 1 → 今天不再到期）。
        let entries = (1...8).map { index -> VocabularyEntry in
            let reviewed = index <= 3
            return VocabularyEntry(
                word: "w\(index)",
                mastery: reviewed ? 1 : 0,
                reviewCount: reviewed ? 1 : 0,
                lastReviewedAt: reviewed ? now : nil,
                createdAt: yesterday
            )
        }
        let snapshot = ProgressAggregator.snapshot(
            days: 14, now: now, calendar: calendar,
            sessions: [], messages: [], corrections: [], shadowing: [],
            vocabulary: entries,
            totalStars: 0, goalMinutes: 15
        )
        XCTAssertEqual(snapshot.vocabulary.due, 5, "「此刻到期」只剩 5 个")
        XCTAssertEqual(snapshot.vocabulary.dueAtDayStart, 8, "今天起初是 8 个")
        XCTAssertEqual(snapshot.vocabulary.dueAtDayStartReviewed, 3)

        let plan = DailyPlanner.plan(snapshot: snapshot, now: now, calendar: calendar)
        let review = try XCTUnwrap(plan.tasks.first { $0.kind == .review })
        XCTAssertEqual(review.title, "复习 8 个到期单词")
        XCTAssertEqual(review.progressText, "3 / 8 个词")
        XCTAssertFalse(review.isDone)
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

    // MARK: - 当天高水位（#328：三项指标只增不减）

    /// 用户报障的正题：今天聊够了 → 关掉应用 → 重开时对上一段做了复盘（流水被清）
    /// → 续聊。今天的对话数掉回个位数，卡片又变成「未完成」。
    ///
    /// 高水位必须在**复盘之前**记下来（`refreshTodayPanel` 里，见 `raiseDailyTaskFloor`），
    /// 之后无论如何都不许回退。
    ///
    /// 反证：把 `conversationTask` 里的 `floor?.progress(...)` 换回 `today.messages` → 变红。
    func testConversationStaysDoneAfterTheFlowIsPurged() {
        let now = day(2026, 9, 23, 21, 0)
        let today = calendar.startOfDay(for: now)
        // 目标 10 轮（15 分钟档），今天已经聊了 10 条 —— 刚好达标。
        let before = snapshot(today: DailyActivity(day: today, seconds: 900, messages: 10))
        let donePlan = DailyPlanner.plan(snapshot: before, now: now, calendar: calendar)
        XCTAssertTrue(
            donePlan.tasks.first { $0.kind == .conversation }?.isDone == true,
            "10 条对话对 10 轮目标就是达标"
        )

        // 复盘那一刻记下高水位。
        let floor = DailyTaskFloor.empty(dayKey: "2026-09-23")
            .raising(donePlan, dayKey: "2026-09-23")
        XCTAssertEqual(floor.conversation, 10)

        // 复盘之后流水被清，续聊只说了一句 —— 此刻的记录只剩 2 条。
        let after = snapshot(today: DailyActivity(day: today, seconds: 120, messages: 2))
        let afterPlan = DailyPlanner.plan(snapshot: after, now: now, calendar: calendar, floor: floor)
        let task = afterPlan.tasks.first { $0.kind == .conversation }
        XCTAssertEqual(task?.progress, 10, "完成量只增不减：记录被清掉也不能把进度带回去")
        XCTAssertTrue(task?.isDone == true, "任务一旦完成就固定为已完成，不许回退")
        XCTAssertEqual(afterPlan.completedCount, donePlan.completedCount, "整卡完成数也不许掉")
        XCTAssertTrue(
            task?.reason.contains("已聊 10 轮") == true,
            "理由行跟进度同口径，不能一个说 10 一个说 2；实测：\(task?.reason ?? "nil")"
        )
    }

    /// 跟读与复习两项同样吃高水位（「清除学习记忆」会把这两项的流水删掉）。
    func testShadowingAndReviewAlsoHonorTheFloor() {
        let now = day(2026, 9, 23, 21, 0)
        let today = calendar.startOfDay(for: now)
        let full = snapshot(
            today: DailyActivity(day: today, seconds: 600, messages: 10, shadowingAttempts: 3),
            vocabulary: VocabularyStats(
                total: 20, due: 0, mastered: 8, defined: 20,
                dueAtDayStart: 8, dueAtDayStartReviewed: 8
            ),
            shadowing: ShadowingStats(attempts: 30, bestAccuracy: 0.9, averageAccuracy: 0.8,
                                      lastAccuracy: 0.8, bestPronunciation: 90, averagePronunciation: 80)
        )
        let before = DailyPlanner.plan(snapshot: full, now: now, calendar: calendar)
        XCTAssertTrue(before.isAllDone, "夹具前提：三项都做完了")
        let floor = DailyTaskFloor.empty(dayKey: "2026-09-23").raising(before, dayKey: "2026-09-23")
        XCTAssertEqual(floor.shadowing, 3)
        XCTAssertEqual(floor.review, 8)

        // 清除学习记忆：跟读流水与复习流水都没了。
        // ⚠️ 单词本本身还在，所以「今天起初到期 8 个」这个量**不变** ——
        // 变的是「今天复习过几个」（复习流水被删），任务因此从 8/8 掉回 0/8。
        let wiped = snapshot(
            today: DailyActivity(day: today, seconds: 600, messages: 10),
            vocabulary: VocabularyStats(
                total: 20, due: 0, mastered: 0, defined: 20,
                dueAtDayStart: 8, dueAtDayStartReviewed: 0
            )
        )
        let raw = DailyPlanner.plan(snapshot: wiped, now: now, calendar: calendar)
        XCTAssertEqual(
            raw.tasks.first { $0.kind == .review }?.progress, 0,
            "夹具前提：只看此刻的记录，复习进度确实掉回 0"
        )
        let after = DailyPlanner.plan(snapshot: wiped, now: now, calendar: calendar, floor: floor)
        XCTAssertEqual(after.tasks.first { $0.kind == .shadowing }?.progress, 3)
        XCTAssertEqual(after.tasks.first { $0.kind == .review }?.progress, 8)
        XCTAssertTrue(after.isAllDone, "清完学习记忆也不该把当天已完成的判定收回去")
    }

    /// 高水位只涨不跌，且**换天自动作废**（昨天的高水位不许套到今天头上）。
    func testFloorOnlyRisesAndExpiresOnANewDay() {
        let now = day(2026, 9, 23, 21, 0)
        let today = calendar.startOfDay(for: now)
        let busy = DailyPlanner.plan(
            snapshot: snapshot(today: DailyActivity(day: today, messages: 12, shadowingAttempts: 3)),
            now: now, calendar: calendar
        )
        var floor = DailyTaskFloor.empty(dayKey: "2026-09-23").raising(busy, dayKey: "2026-09-23")
        XCTAssertEqual(floor.conversation, 12)

        // 再用一份「做得更少」的计划去抬 —— 不许把 12 拉下来。
        let quieter = DailyPlanner.plan(
            snapshot: snapshot(today: DailyActivity(day: today, messages: 3)), now: now, calendar: calendar
        )
        floor = floor.raising(quieter, dayKey: "2026-09-23")
        XCTAssertEqual(floor.conversation, 12, "高水位只涨不跌")

        // 换一天：从零重记，昨天的 12 不许溢出到今天。
        let tomorrow = floor.raising(
            DailyPlanner.plan(
                snapshot: snapshot(today: DailyActivity(day: today)), now: now, calendar: calendar
            ),
            dayKey: "2026-09-24"
        )
        XCTAssertEqual(tomorrow.conversation, 0)
        XCTAssertEqual(tomorrow.dayKey, "2026-09-24")
    }

    /// 持久化格式：一行 `dayKey|对话|跟读|复习`；坏数据一律当「没有记录」
    /// （宁可少记一天，也不能让一行坏字符串把三项任务都读成一个离谱的数）。
    func testFloorStorageRoundTripAndGarbage() {
        let floor = DailyTaskFloor(dayKey: "2026-09-23", conversation: 12, shadowing: 3, review: 8)
        XCTAssertEqual(DailyTaskFloor.parse(floor.storageText), floor)

        XCTAssertNil(DailyTaskFloor.parse(nil))
        XCTAssertNil(DailyTaskFloor.parse(""))
        XCTAssertNil(DailyTaskFloor.parse("2026-09-23|12|3"), "字段不足")
        XCTAssertNil(DailyTaskFloor.parse("|12|3|8"), "没有日期")
        XCTAssertNil(DailyTaskFloor.parse("2026-09-23|a|3|8"), "不是数字")
        // 缺省值：没记录时三项都是 0，显示的就是「此刻算出来的」。
        XCTAssertEqual(DailyTaskFloor.empty(dayKey: "2026-09-23").progress(for: .conversation, current: 4), 4)
    }
}
