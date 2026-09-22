import AIDomain
import XCTest

/// 年度学习记录（学习进度页的贡献图卡片）单测。
///
/// 覆盖四件事：
/// 1. **深浅四档的判据**与「今天」「今日任务」两张卡片同源；
/// 2. 年历的形状（周首对齐、7 行、53 列、月份刻度打在月初那一列）；
/// 3. 复习口径（同一天同一个词判两次只算一个词）与「一把尺子」（同一天的时长只能有一个数）；
/// 4. 连续天数、空数据不崩。
///
/// 全部是纯函数，不碰模型 / 数据库 / 麦克风。
final class AnnualRecapTests: XCTestCase {

    /// 周一为周首（中国区 `Calendar.current` 就是这样）。
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// 造一天的活动（`daysAgo` 天前）。
    private func activity(
        daysAgo: Int,
        minutes: Int = 0,
        messages: Int = 0,
        shadowing: Int = 0,
        reviewed: Int = 0,
        now: Date
    ) -> DailyActivity {
        let target = calendar.date(
            byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)
        )!
        return DailyActivity(
            day: target,
            seconds: Double(minutes) * 60,
            messages: messages,
            shadowingAttempts: shadowing,
            vocabularyReviewed: reviewed
        )
    }

    // MARK: - ① 四档深浅

    func testNoPracticeIsTheLightestLevel() {
        XCTAssertEqual(
            PracticeIntensity.of(hasPractice: false, goalReached: false, tasksDone: 0, tasksTotal: 3),
            .none
        )
        XCTAssertEqual(
            PracticeIntensity.of(hasPractice: false, goalReached: true, tasksDone: 3, tasksTotal: 3),
            .none,
            "没开过口就是没开过口 —— 目标/任务字段即使被填了也不该点亮"
        )
    }

    func testGoalOrTaskHalfMeansSolid() {
        // 目标达成（任务一项没做）
        XCTAssertEqual(
            PracticeIntensity.of(hasPractice: true, goalReached: true, tasksDone: 0, tasksTotal: 3),
            .solid
        )
        // 目标没达成但任务过半（2 / 3）
        XCTAssertEqual(
            PracticeIntensity.of(hasPractice: true, goalReached: false, tasksDone: 2, tasksTotal: 3),
            .solid
        )
        // 两者都差一点 —— 只有一项任务，够不着「过半」
        XCTAssertEqual(
            PracticeIntensity.of(hasPractice: true, goalReached: false, tasksDone: 1, tasksTotal: 3),
            .light
        )
    }

    func testFullRequiresBothCardsDone() {
        XCTAssertEqual(
            PracticeIntensity.of(hasPractice: true, goalReached: true, tasksDone: 3, tasksTotal: 3),
            .full
        )
        XCTAssertEqual(
            PracticeIntensity.of(hasPractice: true, goalReached: false, tasksDone: 3, tasksTotal: 3),
            .solid,
            "任务全清但没聊够时长：那是「达标」，不是「全清」—— 两张卡都要满才算满"
        )
    }

    /// 分母固定三项：昨天「2 / 2」算全清、今天「2 / 3」不算，同一种努力会有两种深浅。
    func testTaskDenominatorIsFixedAtThree() {
        XCTAssertEqual(AnnualRecapBuilder.tasksTotal, 3)
        XCTAssertEqual(DailyTask.Kind.allCases.count, AnnualRecapBuilder.tasksTotal,
                       "分母应该正好是「今日任务」卡片的候选任务数")
    }

    func testTasksDoneFollowsTheDailyPlannerRules() {
        let now = day(2026, 9, 15, 20, 0)
        // 15 分钟目标折算 10 轮。
        XCTAssertEqual(DailyPlanner.exchangeTarget(goalMinutes: 15), 10)

        let talkative = activity(daysAgo: 0, minutes: 5, messages: 10, now: now)
        XCTAssertEqual(AnnualRecapBuilder.tasksDone(talkative, goalMinutes: 15), 1, "说满轮次但不包括跟读与复习")

        let all = activity(daysAgo: 0, minutes: 20, messages: 10, shadowing: 3, reviewed: 4, now: now)
        XCTAssertEqual(AnnualRecapBuilder.tasksDone(all, goalMinutes: 15), 3)

        // 只复习了词：这一项也算。
        let reviewedOnly = activity(daysAgo: 0, reviewed: 2, now: now)
        XCTAssertEqual(AnnualRecapBuilder.tasksDone(reviewedOnly, goalMinutes: 15), 1)
    }

    // MARK: - ② 年历形状

    func testDaySlotsAreWeekAlignedAndEndToday() {
        let now = day(2026, 9, 15, 21, 0)
        let slots = AnnualRecapBuilder.daySlots(now: now, calendar: calendar)

        XCTAssertEqual(slots.last, calendar.startOfDay(for: now), "最后一格必须是今天")
        XCTAssertEqual(
            calendar.component(.weekday, from: slots[0]), calendar.firstWeekday,
            "第一天必须落在周首，否则 7 行的星期标签会整体错位"
        )
        XCTAssertGreaterThanOrEqual(slots.count, 365)
        XCTAssertLessThanOrEqual(slots.count, 53 * 7)
        XCTAssertEqual(slots.count, 366, "周首对齐后实际覆盖 365…371 天，本日为周二 → 366")
        for (index, slot) in slots.enumerated().dropFirst() {
            XCTAssertEqual(
                calendar.date(byAdding: .day, value: -1, to: slot), slots[index - 1],
                "日子必须一天不落地连起来"
            )
        }
    }

    func testGridAlwaysHasSevenRowsAndFiftyThreeColumns() {
        let now = day(2026, 9, 15, 21, 0)
        let recap = AnnualRecapBuilder.build(days: [], now: now, calendar: calendar)
        XCTAssertEqual(recap.weeks.count, AnnualRecapBuilder.weeksPerYear)
        for column in recap.weeks {
            XCTAssertEqual(column.count, 7, "每一列必须是 7 行（周一…周日）")
        }
        XCTAssertTrue(
            recap.weeks.flatMap { $0 }.compactMap { $0 }.allSatisfy { $0.intensity == .none },
            "空数据应是一整张空网格，而不是空白"
        )
        XCTAssertEqual(recap.practicedDays, 0)
        XCTAssertEqual(recap.headline, "近一年有 0 天开过口")
    }

    /// 未来几天必须是 nil（不画），不能画成「没练」——那是两回事。
    func testFutureSlotsAreNotDrawn() {
        let now = day(2026, 9, 15, 21, 0)   // 周二
        let recap = AnnualRecapBuilder.build(days: [], now: now, calendar: calendar)
        let lastColumn = try! XCTUnwrap(recap.weeks.last)
        XCTAssertNotNil(lastColumn[1], "周二本身要画")
        XCTAssertTrue(
            lastColumn[2...].allSatisfy { $0 == nil },
            "周三往后还没到，必须是空洞而不是「没练」的浅格子"
        )
        XCTAssertEqual(recap.end, calendar.startOfDay(for: now))
    }

    func testWeekdayLabelsOnlyOnThreeRows() {
        let labels = AnnualRecapBuilder.rowLabels(calendar: calendar)
        XCTAssertEqual(labels.count, 7)
        XCTAssertEqual(
            labels.enumerated().filter { $0.element != nil }.map(\.offset), [0, 2, 4],
            "只标一 / 三 / 五：7 行都标会把网格挤瘦"
        )
        XCTAssertEqual(
            labels.compactMap { $0 }, ["一", "三", "五"],
            "周一为周首时，第 1/3/5 行就是周一 / 周三 / 周五（与「9月」同一套中文）"
        )

        // 周日为周首的日历（美区）也不该错位：第 1/3/5 行变成周日 / 周二 / 周四。
        var sundayFirst = Calendar(identifier: .gregorian)
        sundayFirst.firstWeekday = 1
        XCTAssertEqual(
            AnnualRecapBuilder.rowLabels(calendar: sundayFirst).compactMap { $0 },
            ["日", "二", "四"]
        )
    }

    func testMonthMarkersSitOnTheFirstOfTheMonth() {
        let now = day(2026, 9, 15, 21, 0)
        let recap = AnnualRecapBuilder.build(days: [], now: now, calendar: calendar)

        XCTAssertFalse(recap.months.isEmpty)
        XCTAssertEqual(recap.months.first?.column, 0, "最左边一列必须有刻度，否则整排月份都往右漂")
        XCTAssertEqual(recap.months.map(\.column), recap.months.map(\.column).sorted(), "刻度必须从左到右")
        XCTAssertTrue(recap.months.allSatisfy { $0.title.hasSuffix("月") })

        for marker in recap.months.dropFirst() {
            let days = recap.weeks[marker.column].compactMap { $0 }
            XCTAssertTrue(
                days.contains { calendar.component(.day, from: $0.day) == 1 },
                "第 \(marker.column) 列标的「\(marker.title)」其实不含那个月的 1 号 —— 刻度打偏了"
            )
        }
    }

    // MARK: - ③ 一格一天，深浅看得见

    func testBuildMarksOneDayPerCellAndCountsLevels() {
        let now = day(2026, 9, 15, 21, 0)
        let recap = AnnualRecapBuilder.build(
            days: [
                activity(daysAgo: 0, minutes: 20, messages: 10, shadowing: 3, reviewed: 5, now: now),  // 全清
                activity(daysAgo: 1, minutes: 20, messages: 10, now: now),                            // 达标
                activity(daysAgo: 2, minutes: 2, messages: 1, now: now),                              // 开过口
                activity(daysAgo: 4, minutes: 20, messages: 10, shadowing: 3, reviewed: 2, now: now),  // 全清
            ],
            goalMinutes: 15,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(recap.practicedDays, 4)
        XCTAssertEqual(recap.levelCounts[.full], 2)
        XCTAssertEqual(recap.levelCounts[.solid], 1)
        XCTAssertEqual(recap.levelCounts[.light], 1)
        XCTAssertEqual(recap.levelCounts[.none], recap.dayCount - 4)
        XCTAssertEqual(recap.totalMinutes, 62)
        XCTAssertEqual(recap.totalMessages, 31)
        XCTAssertEqual(recap.totalReviewed, 7)
        XCTAssertEqual(recap.goalMinutes, 15)

        // 今天那格必须与「今天」卡片说的是同一件事。
        let today = recap.weeks.flatMap { $0 }.compactMap { $0 }.first { $0.isToday }
        XCTAssertEqual(today?.intensity, .full)
        XCTAssertEqual(today?.tasksDone, 3)
        XCTAssertEqual(today?.goalReached, true)
        XCTAssertTrue(today?.detailText().contains("目标达成") ?? false)
    }

    /// 今天那格与「今天」「今日任务」两张卡片同源 —— 这是这张卡的全部意义。
    func testTodayCellAgreesWithTheTodayCard() {
        let now = day(2026, 9, 15, 20, 0)
        let start = day(2026, 9, 15, 10, 0)
        let stamps = (0..<10).map { calendar.date(byAdding: .minute, value: $0 * 2, to: start)! }
        let reference = "I would like a cup of tea"
        let shadowingTime = day(2026, 9, 15, 11, 0)
        let attempts = (0..<3).map {
            ShadowingAttempt(
                drillID: "d\($0)", referenceText: reference, recognizedText: reference,
                accuracy: 1, createdAt: calendar.date(byAdding: .minute, value: $0, to: shadowingTime)!
            )
        }
        let reviews = [VocabularyReviewStamp(itemID: UUID(), reviewedAt: day(2026, 9, 15, 18, 0))]

        let snapshot = ProgressAggregator.snapshot(
            days: 14, now: now, calendar: calendar,
            sessions: [], messages: stamps, corrections: [], shadowing: attempts, vocabulary: [],
            totalStars: 0, goalMinutes: 15, reviews: reviews
        )
        let recap = AnnualRecapBuilder.build(
            days: ProgressAggregator.dailyActivity(
                days: [calendar.startOfDay(for: now)],
                calendar: calendar,
                messages: stamps,
                shadowing: attempts.map {
                    ShadowingStamp(referenceText: $0.referenceText, createdAt: $0.createdAt)
                },
                reviews: reviews
            ),
            goalMinutes: 15, now: now, calendar: calendar
        )
        let cell = recap.weeks.flatMap { $0 }.compactMap { $0 }.first { $0.isToday }

        XCTAssertEqual(cell?.activity.seconds, snapshot.today.seconds)
        XCTAssertEqual(cell?.goalReached, snapshot.goalReached, "「今天」卡片的达标判定与格子深浅必须同源")
        XCTAssertEqual(cell?.activity.vocabularyReviewed, snapshot.vocabularyReviewedToday)
        XCTAssertEqual(cell?.tasksDone, 3)
        XCTAssertEqual(cell?.intensity, .full, "时长够、三项任务齐 → 今天那格必须是全清")
    }

    // MARK: - ④ 复习口径：「复习几个词」= 几个**不同的**词

    func testReviewedCountsDistinctWordsPerDay() {
        let today = day(2026, 9, 15)
        let word = UUID()
        let activity = ProgressAggregator.dailyActivity(
            days: [calendar.startOfDay(for: today)],
            calendar: calendar,
            messages: [],
            reviews: [
                VocabularyReviewStamp(itemID: word, reviewedAt: day(2026, 9, 15, 9, 0)),
                VocabularyReviewStamp(itemID: word, reviewedAt: day(2026, 9, 15, 21, 0)),
                VocabularyReviewStamp(itemID: UUID(), reviewedAt: day(2026, 9, 15, 10, 0)),
            ]
        )
        XCTAssertEqual(activity.first?.vocabularyReviewed, 2, "同一个词一天判两次只算复习了一个词")
    }

    func testReviewedCountIsZeroOnDaysWithoutReviews() {
        let activity = ProgressAggregator.dailyActivity(
            days: [day(2026, 9, 15), day(2026, 9, 14)],
            calendar: calendar,
            messages: [],
            reviews: [VocabularyReviewStamp(itemID: UUID(), reviewedAt: day(2026, 9, 14, 9, 0))]
        )
        XCTAssertEqual(activity.map(\.vocabularyReviewed), [0, 1])
    }

    /// 复习流水为空时退回 `lastReviewedAt` 口径（老数据 / 手搓夹具走这条路），不能算成 0。
    func testReviewedCountFallsBackWhenNoReviewLogIsPassed() {
        let now = day(2026, 9, 15, 20, 0)
        let entries = [VocabularyEntry(word: "a", mastery: 1, lastReviewedAt: now)]
        let snapshot = ProgressAggregator.snapshot(
            days: 14, now: now, calendar: calendar,
            sessions: [], messages: [], corrections: [], shadowing: [],
            vocabulary: entries, totalStars: 0, goalMinutes: 15
        )
        XCTAssertEqual(snapshot.vocabularyReviewedToday, 1)
    }

    // MARK: - ⑤ 一把尺子

    /// 同一天的练习时长只能有一个数：窗口快照与年度记录必须走同一个折算。
    func testOneRulerForDailySeconds() {
        let now = day(2026, 9, 15, 20, 0)
        let start = day(2026, 9, 15, 10, 0)
        let stamps = (0..<6).map { calendar.date(byAdding: .minute, value: $0 * 3, to: start)! }
        let shadowing = [ShadowingStamp(referenceText: "I would like a cup of tea", createdAt: day(2026, 9, 15, 11, 0))]

        let annual = ProgressAggregator.dailyActivity(
            days: [calendar.startOfDay(for: now)], calendar: calendar,
            messages: stamps, shadowing: shadowing
        )
        let snapshot = ProgressAggregator.snapshot(
            days: 14, now: now, calendar: calendar,
            sessions: [], messages: stamps, corrections: [],
            shadowing: [
                ShadowingAttempt(
                    drillID: "d", referenceText: "I would like a cup of tea",
                    recognizedText: "I would like a cup of tea", accuracy: 1,
                    createdAt: day(2026, 9, 15, 11, 0)
                )
            ],
            vocabulary: [], totalStars: 0, goalMinutes: 15
        )
        XCTAssertEqual(annual.first?.seconds, snapshot.today.seconds)
        // 六条消息、三分钟一条 → 30 秒开口 + 5×180 秒 = 930 秒，再加 7 个词的跟读折算。
        XCTAssertEqual(
            annual.first?.seconds ?? 0,
            ProgressAggregator.openingSeconds
                + 15 * 60
                + 7 * ProgressAggregator.shadowingSecondsPerWord,
            accuracy: 0.001,
            "开口半分钟 + 五段间隔（各 3 分钟，未触顶）+ 7 个词的跟读折算"
        )
    }

    // MARK: - ⑥ 连续天数

    func testStacksCountBackFromTodayAndKeepTheLongestRun() {
        let now = day(2026, 9, 15, 21, 0)
        let recap = AnnualRecapBuilder.build(
            days: [
                activity(daysAgo: 9, minutes: 20, messages: 10, now: now),
                activity(daysAgo: 8, minutes: 20, messages: 10, now: now),
                activity(daysAgo: 7, minutes: 20, messages: 10, now: now),
                activity(daysAgo: 6, minutes: 20, messages: 10, now: now),
                activity(daysAgo: 0, minutes: 20, messages: 10, now: now),
            ],
            goalMinutes: 15, now: now, calendar: calendar
        )
        XCTAssertEqual(recap.currentStreak, 1, "中间断过，当前只剩今天这一天")
        XCTAssertEqual(recap.longestStreak, 4, "最长的一段是 6 天前那四天")
    }

    func testTodayNotPracticedYetDoesNotBreakTheStreak() {
        let now = day(2026, 9, 15, 8, 0)
        let recap = AnnualRecapBuilder.build(
            days: [
                activity(daysAgo: 1, minutes: 20, messages: 10, now: now),
                activity(daysAgo: 2, minutes: 20, messages: 10, now: now),
            ],
            goalMinutes: 15, now: now, calendar: calendar
        )
        XCTAssertEqual(recap.currentStreak, 2, "今天才早上八点，还没开口不该把连续记录清零")
        XCTAssertEqual(recap.levelCounts[.none], recap.dayCount - 2)
    }

    // MARK: - ⑦ 文案

    func testSummaryTextTellsTimeAndStreaks() {
        let now = day(2026, 9, 15, 21, 0)
        let recap = AnnualRecapBuilder.build(
            days: [
                activity(daysAgo: 0, minutes: 30, messages: 10, shadowing: 3, reviewed: 1, now: now),
                activity(daysAgo: 1, minutes: 30, messages: 10, shadowing: 3, reviewed: 1, now: now),
                activity(daysAgo: 2, minutes: 30, messages: 10, shadowing: 3, reviewed: 1, now: now),
                activity(daysAgo: 3, minutes: 30, messages: 10, shadowing: 3, reviewed: 1, now: now),
            ],
            goalMinutes: 15, now: now, calendar: calendar
        )
        XCTAssertEqual(recap.headline, "近一年有 4 天开过口")
        XCTAssertTrue(recap.summaryText.contains("累计 2 小时"), recap.summaryText)
        XCTAssertTrue(recap.summaryText.contains("当前连续 4 天"), recap.summaryText)
        XCTAssertFalse(recap.summaryText.contains("最长连续"), "与当前连续相同时不重复报一遍")
    }
}
