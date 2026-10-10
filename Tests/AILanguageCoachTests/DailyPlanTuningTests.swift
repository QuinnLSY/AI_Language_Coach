import AIDomain
import AppCore
import XCTest

/// 自适应微调真的改到安排上（⑤ 的另一半）。
///
/// ⑤ 只把 stance 显示出来了，安排本身没动 —— 那是「说了不做」。
/// 这一组钉住「做」：`AdaptivePathStance` → 每日任务三项目标 + 一轮复习张数。
///
/// 全覆盖的判据：样本不足（`.observing`）**一个字都不改**、改了就必须带理由、
/// 任何一项都不许被调没（0 会让任务凭空消失）。
final class DailyPlanTuningTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// 一份「什么都有」的快照：今天聊了 2 轮、跟读 1 次、起初到期 30 个词。
    ///
    /// ⚠️ 到期数要**明显大于**复习 cap（8）：复习目标是 `min(due, cap)`，
    /// 到期数卡在 cap 附近的话，加 cap 的那几档会被 `min` 夹住看不出差别。
    private func snapshot(
        goalMinutes: Int = 15,
        dueAtDayStart: Int = 30,
        mode: DailyGoalMode = .advanced
    ) -> ProgressSnapshot {
        let now = day(2026, 10, 11, 20, 0)
        return ProgressSnapshot(
            skills: [],
            today: DailyActivity(
                day: calendar.startOfDay(for: now),
                seconds: 300, messages: 2, shadowingAttempts: 1
            ),
            vocabulary: VocabularyStats(
                total: 30, due: dueAtDayStart, mastered: 4, defined: 30,
                dueAtDayStart: dueAtDayStart, dueAtDayStartReviewed: 2
            ),
            vocabularyReviewedToday: 2,
            shadowing: ShadowingStats(
                attempts: 12, bestAccuracy: 0.9, averageAccuracy: 0.82, lastAccuracy: 0.85,
                bestPronunciation: 88, averagePronunciation: 78
            ),
            recentMistakes: [],
            goalMinutes: goalMinutes
        )
    }

    private func plan(
        stance: AdaptivePathStance,
        mode: DailyGoalMode = .advanced,
        dueAtDayStart: Int = 30
    ) -> DailyPlan {
        DailyPlanner.plan(
            snapshot: snapshot(dueAtDayStart: dueAtDayStart),
            mode: mode,
            now: day(2026, 10, 11, 20, 0),
            calendar: calendar,
            stance: stance
        )
    }

    private func target(_ plan: DailyPlan, _ kind: DailyTask.Kind) -> Int? {
        plan.tasks.first { $0.kind == kind }?.target
    }

    // MARK: - 样本不足时不许动

    /// `.observing` 的微调必须是恒等的 —— 数据不够还改安排，是把猜测当事实。
    func testObservingIsIdentity() {
        let tuning = DailyPlanTuningRule.tuning(for: .observing)
        XCTAssertTrue(tuning.isIdentity, "样本不足时一项都不该改")
        XCTAssertNil(tuning.note, "没改就不给理由 —— 硬凑一句只会显得廉价")
        XCTAssertEqual(tuning.reviewSessionLimit, DailyPlanTuningRule.defaultReviewSessionLimit)
    }

    /// 不传 stance（默认 `.observing`）排出来的计划，与老行为逐项一致。
    ///
    /// 这条是**兼容哨兵**：既有几十条每日任务测试都走这条路径，改坏了会成片红。
    func testDefaultStanceKeepsLegacyTargets() {
        let base = DailyPlanner.plan(
            snapshot: snapshot(), mode: .advanced,
            now: day(2026, 10, 11, 20, 0), calendar: calendar
        )
        let observing = plan(stance: .observing)
        XCTAssertEqual(base.tasks.map(\.target), observing.tasks.map(\.target))
        XCTAssertNil(observing.tuningNote)
    }

    // MARK: - 三个档位各自的量

    func testReinforceTrimsNewWorkAndAddsReview() {
        let observing = plan(stance: .observing)
        let reinforce = plan(stance: .reinforce)

        XCTAssertEqual(target(reinforce, .conversation), (target(observing, .conversation) ?? 0) - 1,
                       "欠着的时候先减对话量")
        XCTAssertEqual(target(reinforce, .shadowing), (target(observing, .shadowing) ?? 0) - 1)
        XCTAssertEqual(target(reinforce, .review), (target(observing, .review) ?? 0) + 4,
                       "复习量要加（到期 30 个，cap 从 8 抬到 12，不会被 min 夹住）")
        XCTAssertNotNil(reinforce.tuningNote)
    }

    func testAdvancePushesNewWorkAndTrimsReviewSession() {
        let observing = plan(stance: .observing)
        let advance = plan(stance: .advance)

        XCTAssertEqual(target(advance, .conversation), (target(observing, .conversation) ?? 0) + 2)
        XCTAssertEqual(target(advance, .shadowing), (target(observing, .shadowing) ?? 0) + 1)
        XCTAssertEqual(
            DailyPlanTuningRule.tuning(for: .advance).reviewSessionLimit,
            DailyPlanTuningRule.defaultReviewSessionLimit - DailyPlanTuningRule.advanceReviewDiscount,
            "状态好就少走几张复习卡，把时间让给新量"
        )
        XCTAssertNotNil(advance.tuningNote)
    }

    func testConsolidateKeepsNewWorkAndNudgesReview() {
        let observing = plan(stance: .observing)
        let consolidate = plan(stance: .consolidate)

        XCTAssertEqual(target(consolidate, .conversation), target(observing, .conversation),
                       "稳住的定义是「别退」，新量不动")
        XCTAssertEqual(target(consolidate, .shadowing), target(observing, .shadowing))
        XCTAssertEqual(target(consolidate, .review), (target(observing, .review) ?? 0) + 2)
    }

    /// 四个档位排出来的**安排**必须互不相同 —— 否则「自适应改安排」是句空话。
    func testEveryStanceChangesThePlanSomehow() {
        let observing = plan(stance: .observing)
        let signatures = Set(
            [.reinforce, .consolidate, .advance].map { plan(stance: $0).tasks.map(\.target) }
        )
        XCTAssertEqual(signatures.count, 3, "三个档位的量必须各不相同")
        for stance in [AdaptivePathStance.reinforce, .consolidate, .advance] {
            XCTAssertNotEqual(plan(stance: stance).tasks.map(\.target), observing.tasks.map(\.target),
                              "\(stance) 与 observing 排出来的安排完全一样 → 微调没生效")
        }
    }

    // MARK: - 不许把任务调没

    /// 保底档（对话 2 / 跟读 1）再叠加 reinforce（各 −1）：跟读会被减到 0。
    /// 0 会让整项任务凭空消失（用户视角就是开关坏了），必须夹到 1。
    func testBaselinePlusReinforceNeverDropsATask() {
        let reinforce = plan(stance: .reinforce, mode: .baseline)
        XCTAssertEqual(reinforce.tasks.map(\.kind), [.conversation, .shadowing, .review],
                       "三项都得在：减量减到任务消失是不允许的")
        XCTAssertEqual(target(reinforce, .conversation), 1)
        XCTAssertEqual(target(reinforce, .shadowing), 1, "1 − 1 = 0 必须夹回 1")
    }

    func testClampedTargetFloorIsOne() {
        XCTAssertEqual(DailyPlanTuningRule.clampedTarget(0), 1)
        XCTAssertEqual(DailyPlanTuningRule.clampedTarget(-5), 1)
        XCTAssertEqual(DailyPlanTuningRule.clampedTarget(7), 7)
    }

    /// 复习目标取 `min(due, cap)`：到期只有 1 个时，cap 再怎么加也只要求 1 个。
    func testReviewTargetNeverExceedsDue() {
        XCTAssertEqual(target(plan(stance: .reinforce, dueAtDayStart: 1), .review), 1)
        XCTAssertEqual(target(plan(stance: .observing, dueAtDayStart: 1), .review), 1)
    }

    /// 复习会话的张数下限：减量档位也不许减成 0（0 会开出一个空会话）。
    func testReviewSessionLimitNeverDropsBelowOne() {
        XCTAssertGreaterThanOrEqual(DailyPlanTuningRule.tuning(for: .advance).reviewSessionLimit, 1)
        XCTAssertGreaterThanOrEqual(DailyPlanTuningRule.tuning(for: .reinforce).reviewSessionLimit, 1)
        XCTAssertGreaterThanOrEqual(DailyPlanTuningRule.tuning(for: .consolidate).reviewSessionLimit, 1)
        XCTAssertGreaterThan(DailyPlanTuningRule.tuning(for: .reinforce).reviewSessionLimit,
                             DailyPlanTuningRule.tuning(for: .advance).reviewSessionLimit,
                             "欠得多 vs 状态好：复习张数必须真的不一样")
    }

    /// 复习会话的默认值与 `VocabularyReviewSession.maxCards` 同源 —— 两处写死必然漂移。
    func testDefaultReviewSessionLimitSharesTheSameSource() {
        XCTAssertEqual(DailyPlanTuningRule.defaultReviewSessionLimit, VocabularyReviewSession.maxCards)
    }
}
