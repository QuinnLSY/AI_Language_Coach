import AIDomain
import XCTest

/// 老师黑板的**纯规则**：教棍敲完说什么、随机气泡里的今日进度怎么变色、
/// 开屏要不要自动展开。
///
/// 这些是纯函数（不 import UI / IO），所以能钉住几条最容易说错话的边界：
/// 没做完不许夸、没安排不许催、一天只自动展开一次。
final class BlackboardRulesTests: XCTestCase {

    private func task(_ kind: DailyTask.Kind, target: Int, progress: Int, unit: String) -> DailyTask {
        DailyTask(
            kind: kind,
            title: "做 \(target) \(unit)",
            reason: "测试用依据",
            target: target,
            progress: progress,
            unit: unit
        )
    }

    private func plan(_ pairs: [(DailyTask.Kind, Int, Int, String)]) -> DailyPlan {
        DailyPlan(day: Date(), tasks: pairs.map { task($0.0, target: $0.1, progress: $0.2, unit: $0.3) })
    }

    // MARK: - 教棍敲完那句

    func testKnockBubbleUrgesWithACheckableGapWhenNotDone() {
        let line = TodayPanel.knockBubble(
            plan: plan([(.conversation, 4, 4, "轮"), (.shadowing, 3, 1, "次"), (.review, 8, 0, "个词")]),
            streakDays: 5
        )
        XCTAssertEqual(line.segments.first?.tone, .alert, "没做完就该是催（红）")
        XCTAssertTrue(line.plainText.contains("还有 2 项没做完"), "要给出可核对的缺口：\(line.plainText)")
        XCTAssertTrue(line.plainText.contains("做 3 次"), "顺带点名下一项是什么：\(line.plainText)")
        XCTAssertFalse(line.plainText.contains("连续"), "没做完不提连续天数 —— 那是奖励不是待办")
    }

    func testKnockBubblePraisesOnlyWhenEverythingIsDone() {
        let line = TodayPanel.knockBubble(
            plan: plan([(.conversation, 4, 4, "轮"), (.shadowing, 3, 3, "次")]),
            streakDays: 5
        )
        XCTAssertTrue(line.segments.allSatisfy { $0.tone == .good }, "做完了才夸，且整句都是绿")
        XCTAssertTrue(line.plainText.contains("2 / 2 项"), "夸也要带上真实进度：\(line.plainText)")
        XCTAssertTrue(line.plainText.contains("连续 5 天"), "连续天数只在达标时出现")
    }

    func testKnockBubbleSaysNothingFalseWhenNothingIsPlanned() {
        let line = TodayPanel.knockBubble(plan: DailyPlan.empty, streakDays: 0)
        XCTAssertEqual(line.segments.first?.tone, .plain, "没有计划时不催也不夸")
        XCTAssertFalse(line.plainText.contains("还有"), "没有任务不许说「还有 0 项没做完」")
    }

    // MARK: - 断签保护（催的时候掺上「别断签」）

    func testKnockBubbleWarnsAboutBreakingStreakWhenAtRisk() {
        let line = TodayPanel.knockBubble(
            plan: plan([(.conversation, 4, 1, "轮")]),
            streakDays: 5,
            streakAtRisk: true
        )
        XCTAssertTrue(line.plainText.contains("连续 5 天别断"), "连续 5 天且今天没练，要催一句：\(line.plainText)")
        XCTAssertTrue(line.segments.contains { $0.text.contains("连续") && $0.tone == .alert },
                      "断签警告是红字（它在催，不是在夸）：\(line.plainText)")
    }

    func testKnockBubbleSkipsStreakWarningForOneDayStreak() {
        let line = TodayPanel.knockBubble(
            plan: plan([(.conversation, 4, 1, "轮")]),
            streakDays: 1,
            streakAtRisk: true
        )
        XCTAssertFalse(line.plainText.contains("别断"), "1 天的纪录没什么可保的，别烦新用户：\(line.plainText)")
    }

    func testKnockBubbleMentionsStreakOnlyWhenSafeAndDone() {
        let line = TodayPanel.knockBubble(
            plan: plan([(.conversation, 4, 4, "轮")]),
            streakDays: 5,
            streakAtRisk: true
        )
        XCTAssertTrue(line.plainText.contains("连续 5 天"), "做完了照旧夸上连续天数：\(line.plainText)")
        XCTAssertFalse(line.plainText.contains("别断"), "都做完了今天不会断签：\(line.plainText)")
    }

    // MARK: - 随机气泡里的今日进度

    func testProgressLineColorsTheNumberNotTheWholeSentence() {
        let pending = try? XCTUnwrap(
            TodayPanel.progressLine(plan: plan([(.conversation, 4, 1, "轮"), (.shadowing, 3, 0, "次")]))
        )
        let line = try! XCTUnwrap(pending)
        XCTAssertEqual(line.segments.count, 2, "只有数字着色，说明文字保持普通色")
        XCTAssertEqual(line.segments[0].tone, .plain)
        XCTAssertEqual(line.segments[1].tone, .alert)
        XCTAssertEqual(line.segments[1].text, "0 / 2 项")
    }

    func testProgressLineTurnsGreenWhenDone() {
        let line = try! XCTUnwrap(
            TodayPanel.progressLine(plan: plan([(.conversation, 4, 4, "轮")]))
        )
        XCTAssertEqual(line.segments[1].tone, .good)
        XCTAssertEqual(line.segments[1].text, "1 / 1 项")
    }

    func testProgressLineIsNilWhenNothingIsPlanned() {
        XCTAssertNil(TodayPanel.progressLine(plan: DailyPlan.empty), "没安排就不往气泡里塞进度")
    }

    // MARK: - 开屏自动展开

    func testAutoExpandHappensOncePerDayAndOnlyWhenNotDone() {
        let pending = plan([(.conversation, 4, 1, "轮")])
        XCTAssertTrue(
            TodayPanel.shouldAutoExpand(plan: pending, autoExpandedDayKey: nil, dayKey: "2026-09-19"),
            "今天还没做完 → 开屏自动展开一次"
        )
        XCTAssertFalse(
            TodayPanel.shouldAutoExpand(plan: pending, autoExpandedDayKey: "2026-09-19", dayKey: "2026-09-19"),
            "同一天展开过就不再自动展开"
        )
        XCTAssertTrue(
            TodayPanel.shouldAutoExpand(plan: pending, autoExpandedDayKey: "2026-09-18", dayKey: "2026-09-19"),
            "换了一天要重新展开一次"
        )
    }

    func testAutoExpandNeverBothersSomeoneWhoFinished() {
        let done = plan([(.conversation, 4, 4, "轮")])
        XCTAssertFalse(
            TodayPanel.shouldAutoExpand(plan: done, autoExpandedDayKey: nil, dayKey: "2026-09-19"),
            "今日全部完成 —— 那是奖励不是待办，开屏不该糊上去"
        )
        XCTAssertFalse(
            TodayPanel.shouldAutoExpand(plan: DailyPlan.empty, autoExpandedDayKey: nil, dayKey: "2026-09-19"),
            "快照还没汇总时不展开一块空板"
        )
    }
}
