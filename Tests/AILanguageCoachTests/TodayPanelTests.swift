import AIDomain
import XCTest

/// 今日卷轴文案的纯函数回归。
///
/// 这张卡是**打开应用第一眼**看到的东西：说错一句就是一次误报
/// （把「还没算出来」说成「你今天什么都没做」，把「没有到期词」显示成空白）。
/// 所以文案规则必须能脱机单测，不能只靠看图。
final class TodayPanelTests: XCTestCase {

    private func task(
        _ kind: DailyTask.Kind, target: Int, progress: Int, unit: String, title: String = "做点什么"
    ) -> DailyTask {
        DailyTask(kind: kind, title: title, reason: "依据", target: target, progress: progress, unit: unit)
    }

    private func plan(_ tasks: [DailyTask]) -> DailyPlan {
        DailyPlan(day: Date(), tasks: tasks, focus: nil)
    }

    // MARK: - 收起态状态栏

    func testEmptyPlanIsNotReportedAsZeroProgress() {
        let line = TodayPanel.statusLine(plan: plan([]), streakDays: 3, todaySeconds: 0)
        XCTAssertTrue(line.contains("待安排"), "快照还没汇总时不该说「今日 0/3」——那是在诬告用户：\(line)")
        XCTAssertFalse(line.contains("0 / 3"), "\(line)")
    }

    func testStatusLineReportsRealProgressAndStreak() {
        let line = TodayPanel.statusLine(
            plan: plan([
                task(.conversation, target: 10, progress: 4, unit: "轮"),
                task(.shadowing, target: 3, progress: 1, unit: "次"),
                task(.review, target: 8, progress: 8, unit: "个词"),
            ]),
            streakDays: 6,
            todaySeconds: 754
        )
        XCTAssertTrue(line.contains("今日 1 / 3 项"), line)
        XCTAssertTrue(line.contains("连续 6 天"), line)
        XCTAssertTrue(line.contains("12 分"), "今天练了 754 秒 =\(line)")
    }

    func testStatusLineSaysAllDoneInsteadOfCounts() {
        let line = TodayPanel.statusLine(
            plan: plan([task(.shadowing, target: 3, progress: 3, unit: "次")]),
            streakDays: 1,
            todaySeconds: 60
        )
        XCTAssertTrue(line.contains("全部完成"), line)
    }

    // MARK: - 到期词那一行（为 0 也要说清楚）

    func testDueLineNeverGoesBlank() {
        XCTAssertEqual(
            TodayPanel.dueLine(dueAtDayStart: 0, reviewedOfDue: 0, reviewedToday: 0), "今天没有到期词")
        XCTAssertEqual(
            TodayPanel.dueLine(dueAtDayStart: 0, reviewedOfDue: 0, reviewedToday: 5), "今天已复习 5 个词")
        XCTAssertEqual(
            TodayPanel.dueLine(dueAtDayStart: 8, reviewedOfDue: 3, reviewedToday: 3),
            "8 个词到期 · 今天已复习 3 个")
        XCTAssertEqual(
            TodayPanel.dueLine(dueAtDayStart: 8, reviewedOfDue: 8, reviewedToday: 8),
            "8 个到期词都复习完了")
    }

    /// ⚠️ 分母是**今天起初**那批词（不随复习缩水），分子也只数**同一批**里的完成数 ——
    /// 今天新加的词复习得再多，也不许把 3/8 说成 8/8。
    /// 这条钉的正是用户报的现象（「多完成的不应该再计入」）。
    func testDueLineKeepsTheDayStartDenominator() {
        XCTAssertEqual(
            TodayPanel.dueLine(dueAtDayStart: 8, reviewedOfDue: 3, reviewedToday: 12),
            "8 个词到期 · 今天已复习 3 个",
            "今天另复习了 9 个新加的 / 不到期的词，不改这一行的口径"
        )
    }

    // MARK: - 庆祝（一天只放一次）

    func testCelebratesOnlyOncePerDay() {
        let done = plan([task(.shadowing, target: 3, progress: 3, unit: "次")])
        XCTAssertTrue(TodayPanel.shouldCelebrate(plan: done, celebratedDayKey: "", dayKey: "2026-09-18"))
        XCTAssertFalse(
            TodayPanel.shouldCelebrate(plan: done, celebratedDayKey: "2026-09-18", dayKey: "2026-09-18"),
            "同一天反复汇总不该反复放烟花"
        )
        XCTAssertTrue(
            TodayPanel.shouldCelebrate(plan: done, celebratedDayKey: "2026-09-18", dayKey: "2026-09-19"),
            "隔天再练完要再放一次"
        )
    }

    func testNeverCelebratesAnUnfinishedOrEmptyPlan() {
        let unfinished = plan([task(.shadowing, target: 3, progress: 2, unit: "次")])
        XCTAssertFalse(TodayPanel.shouldCelebrate(plan: unfinished, celebratedDayKey: "", dayKey: "2026-09-18"))
        XCTAssertFalse(
            TodayPanel.shouldCelebrate(plan: plan([]), celebratedDayKey: "", dayKey: "2026-09-18"),
            "没有任务 ≠ 做完了"
        )
    }

    // MARK: - 「还差一点」要可核对

    func testRemainingLineNamesTheActualGap() {
        let plan = plan([
            task(.conversation, target: 10, progress: 10, unit: "轮", title: "和老师聊 10 轮"),
            task(.shadowing, target: 3, progress: 1, unit: "次", title: "跟读 3 句"),
        ])
        let line = try? XCTUnwrap(TodayPanel.remainingLine(plan: plan))
        XCTAssertEqual(line, "还差 2 次：跟读 3 句")
    }

    func testRemainingLineIsNilWhenEverythingIsDone() {
        let plan = plan([task(.shadowing, target: 3, progress: 5, unit: "次")])
        XCTAssertNil(TodayPanel.remainingLine(plan: plan), "超额完成不该再催")
    }

    // MARK: - 打卡徽章（连续天数提到台前 + 断签保护）

    func testStreakBadgeIsHiddenAtZeroDays() {
        XCTAssertNil(
            TodayPanel.streakBadge(streakDays: 0, hasPracticeToday: false),
            "连续 0 天不展示 —— 首屏挂个「0 天」是提醒失败史"
        )
    }

    func testStreakBadgeFlagsRiskWhenTodayNotPracticed() {
        let badge = try! XCTUnwrap(TodayPanel.streakBadge(streakDays: 5, hasPracticeToday: false))
        XCTAssertEqual(badge.days, 5, "今天没练时天数是「到昨天为止」的存量")
        XCTAssertTrue(badge.isAtRisk, "连续还在、今天没练 = 随时会断，要亮警示")
    }

    func testStreakBadgeIsCalmWhenTodayPracticed() {
        let badge = try! XCTUnwrap(TodayPanel.streakBadge(streakDays: 5, hasPracticeToday: true))
        XCTAssertFalse(badge.isAtRisk, "今天练过了，今天不会断签")
    }

    func testStreakGuardLineIsCheckableNotAdjective() {
        let atRisk = try! XCTUnwrap(TodayPanel.streakBadge(streakDays: 5, hasPracticeToday: false))
        XCTAssertEqual(TodayPanel.streakGuardLine(atRisk), "今天练一会儿，保住 5 天连续")
        let safe = try! XCTUnwrap(TodayPanel.streakBadge(streakDays: 5, hasPracticeToday: true))
        XCTAssertEqual(TodayPanel.streakGuardLine(safe), "已连续 5 天，保持住")
    }

    // MARK: - 定时练习提醒文案（#226）

    func testReminderCopyMentionsStreakWhenItExists() {
        let copy = TodayPanel.practiceReminderCopy(streakDays: 4)
        XCTAssertTrue(copy.body.contains("连续 4 天"), "有连续纪录就提「保住连续」——可核对的依据：\(copy.body)")
        XCTAssertTrue(copy.body.contains("保住"), copy.body)
    }

    func testReminderCopyIsGentleForNewcomers() {
        let copy = TodayPanel.practiceReminderCopy(streakDays: 0)
        XCTAssertFalse(copy.body.contains("连续"), "没有连续纪录时不说连续，别给新用户压力：\(copy.body)")
        XCTAssertTrue(copy.body.contains("5 分钟"), "保底档之后，5 分钟就是能兑现的承诺：\(copy.body)")
    }

    func testReminderCopyIsDeterministicAndPenguinFlavored() {
        // 同一天不随机换文案（通知是提前排好的，随机等于欺骗）。
        XCTAssertEqual(
            TodayPanel.practiceReminderCopy(streakDays: 3).title,
            TodayPanel.practiceReminderCopy(streakDays: 3).title
        )
        XCTAssertTrue(TodayPanel.practiceReminderCopy(streakDays: 3).title.contains("小鹅子"))
    }
}
