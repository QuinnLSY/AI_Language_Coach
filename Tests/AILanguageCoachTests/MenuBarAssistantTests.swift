import AIDomain
import XCTest

/// 菜单栏那一屏的**纯规则**。
///
/// 钉的都是会坑人的边界：
/// - 快照还没排出来时不许报「今天 0 / 3」（那是「还没算出来」，不是「你什么都没做」）；
/// - 0 天不提连续；
/// - 「现在该按」的那颗必须是**真的**还没做完的那一项；
/// - 与首屏今日卷轴说的是同一句话（两处口径漂移 = 有一边在胡说）。
final class MenuBarAssistantTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 状态那一行

    /// 与首屏今日卷轴逐字同源：两边都在报同一件事。
    ///
    /// ⚠️ 这条断言之所以能成立，是因为 `MenuBarAssistant.headline` / 副行的拼法
    /// 与 `TodayPanel.statusLine` 共用同样的用词；谁改一边另一边立刻变红 —— 这正是目的。
    func testHeadlineMatchesTodayPanel() {
        let plan = Self.plan(pending: [.conversation, .shadowing])
        let snapshot = MenuBarAssistant.snapshot(
            plan: plan, streakDays: 5, todaySeconds: 754, hasPracticeToday: true
        )
        let full = snapshot.headline + " · " + snapshot.detail
        XCTAssertEqual(
            full,
            TodayPanel.statusLine(plan: plan, streakDays: 5, todaySeconds: 754),
            "菜单栏与首屏说的是同一件事，必须一字不差"
        )
    }

    func testEmptyPlanSaysNotScheduledInsteadOfZeroProgress() {
        let snapshot = Self.snapshot(plan: DailyPlan(day: day), streakDays: 0, todaySeconds: 0, hasPracticeToday: false)
        XCTAssertEqual(snapshot.headline, "今日 待安排", "没排出来时不能说 0/3 —— 那是谎报")
    }

    func testAllDoneSaysCompleted() {
        let snapshot = Self.snapshot(plan: Self.plan(pending: []), streakDays: 2, todaySeconds: 100, hasPracticeToday: true)
        XCTAssertEqual(snapshot.headline, "今日 全部完成")
        XCTAssertTrue(snapshot.isAllDone)
    }

    /// 连续 0 天不该出现在副行里 —— 天天念一遍没坚持这件事没有任何价值。
    func testZeroStreakIsNotMentioned() {
        let snapshot = Self.snapshot(plan: DailyPlan(day: day), streakDays: 0, todaySeconds: 60, hasPracticeToday: false)
        XCTAssertFalse(snapshot.detail.contains("连续"))
        XCTAssertEqual(snapshot.detail, ProgressAggregator.durationText(60))
    }

    func testOneDayStreakIsMentioned() {
        let snapshot = Self.snapshot(plan: DailyPlan(day: day), streakDays: 1, todaySeconds: 60, hasPracticeToday: true)
        XCTAssertEqual(snapshot.detail, "连续 1 天 · \(ProgressAggregator.durationText(60))")
    }

    // MARK: - 断签那条警示

    func testStreakAtRiskWhenNothingDoneToday() {
        let snapshot = Self.snapshot(plan: DailyPlan(day: day), streakDays: 4, todaySeconds: 0, hasPracticeToday: false)
        XCTAssertTrue(snapshot.isStreakAtRisk, "连续还在、今天没练 —— 最该提醒的正是这一刻")
    }

    func testStreakSafeAfterPracticeToday() {
        let snapshot = Self.snapshot(plan: DailyPlan(day: day), streakDays: 4, todaySeconds: 120, hasPracticeToday: true)
        XCTAssertFalse(snapshot.isStreakAtRisk)
    }

    /// 0 天不断签：没有任何记录可保，不该去烦新用户。
    func testNoStreakIsNeverAtRisk() {
        let snapshot = Self.snapshot(plan: DailyPlan(day: day), streakDays: 0, todaySeconds: 0, hasPracticeToday: false)
        XCTAssertFalse(snapshot.isStreakAtRisk)
    }

    // MARK: - 「现在该按」那颗

    func testPrimaryIsTheFirstUnfinishedTask() {
        let plan = Self.plan(pending: [.conversation, .shadowing])
        let snapshot = Self.snapshot(plan: plan, streakDays: 0, todaySeconds: 0, hasPracticeToday: false)

        guard let primary = snapshot.primary else { return XCTFail("有未完成项却没给主按钮") }
        XCTAssertEqual(primary.section, AppSection(.conversation))
        XCTAssertEqual(primary.title, plan.tasks[0].title, "文案必须是排出来的那一句，不是在这重写一遍")
        XCTAssertEqual(primary.detail, plan.tasks[0].progressText)
    }

    /// 第一项做完了，「现在该按」就换成第二项 —— 而不是继续催已经做完的那件事。
    func testPrimarySkipsFinishedTasks() {
        let conversation = DailyTask(kind: .conversation, title: "和老师聊 4 轮", reason: "",
                                     target: 4, progress: 4, unit: "轮")
        var plan = DailyPlan(day: day)
        plan.tasks = [conversation, Self.task(.shadowing, done: 0)]
        let snapshot = Self.snapshot(plan: plan, streakDays: 0, todaySeconds: 0, hasPracticeToday: false)
        XCTAssertEqual(snapshot.primary?.section, .shadowing, "做完了就不该再催")
    }

    /// 备选最多两条：再多就变成第二个首页了 —— 菜单栏的价值是「不用挑」。
    func testSecondaryIsCapped() {
        let plan = Self.plan(pending: [.conversation, .shadowing, .review])
        let snapshot = Self.snapshot(plan: plan, streakDays: 0, todaySeconds: 0, hasPracticeToday: false)
        XCTAssertEqual(snapshot.secondary.count, MenuBarAssistant.maxSecondaryCount)
        XCTAssertEqual(snapshot.secondary.count, 2)
        XCTAssertFalse(snapshot.secondary.contains { $0.section == .practice }, "备选里不该重复主按钮那一页")
    }

    // MARK: - 没什么可做的时候

    /// 今日全做完：给一条「去看战绩」，而不是挂三条做完了的任务。
    func testAllDoneOffersAPlaceToLookBack() {
        let plan = Self.plan(pending: [])
        let snapshot = Self.snapshot(plan: plan, streakDays: 3, todaySeconds: 420, hasPracticeToday: true)
        XCTAssertEqual(snapshot.primary?.section, .practice)
        XCTAssertEqual(snapshot.secondary.count, 1)
        XCTAssertEqual(snapshot.secondary.first?.section, .progress)
        XCTAssertEqual(
            snapshot.secondary.first?.detail,
            ProgressAggregator.durationText(420),
            "战绩那一行要给真实时长，不许写形容词"
        )
    }

    /// 计划还没排出来：给两个「能马上开始」的入口，也不许报假进度。
    func testNoPlanYetOffersAWayToStart() {
        let snapshot = Self.snapshot(plan: DailyPlan(day: day), streakDays: 0, todaySeconds: 0, hasPracticeToday: false)
        XCTAssertEqual(snapshot.primary?.section, .practice)
        XCTAssertEqual(snapshot.secondary.first?.section, .scenarios)
    }

    // MARK: - 工装

    private static func snapshot(
        plan: DailyPlan,
        streakDays: Int,
        todaySeconds: TimeInterval,
        hasPracticeToday: Bool
    ) -> MenuBarAssistant.Snapshot {
        MenuBarAssistant.snapshot(
            plan: plan, streakDays: streakDays, todaySeconds: todaySeconds,
            hasPracticeToday: hasPracticeToday
        )
    }

    /// 排一份计划：`pending` 里的那些是**没做完**的，其余按做完处理。
    private static func plan(pending: [DailyTask.Kind]) -> DailyPlan {
        var plan = DailyPlan(day: Date(timeIntervalSince1970: 1_700_000_000))
        plan.tasks = DailyTask.Kind.allCases.map { kind in
            task(kind, done: pending.contains(kind) ? 0 : 6)
        }
        return plan
    }

    private static func task(_ kind: DailyTask.Kind, done: Int) -> DailyTask {
        let target = 6
        return DailyTask(
            kind: kind,
            title: "\(kind.displayName) \(target) \(unit(of: kind))",
            reason: "",
            target: target,
            progress: done,
            unit: unit(of: kind)
        )
    }

    private static func unit(of kind: DailyTask.Kind) -> String {
        switch kind {
        case .conversation: "轮"
        case .shadowing: "次"
        case .review: "个词"
        }
    }
}
