import AIDomain
@testable import AIDomain
import Foundation
import XCTest

/// ① 个性化学习计划（V1.2）：
/// - 阶段层**只透传**能力定位的 `level` / `gaps` / `nextLevel`，不重算；
/// - 重点项**只收有实际待办的来源**，顺序钉死为 错题 → 顽固音素 → 到期词汇；
/// - 今日层**原样收** `DailyPlan`，完成度口径不另立一套。
final class LearningPlanTests: XCTestCase {

    // MARK: - 构造器

    private func estimate(
        level: CEFRLevel? = .a2,
        next: CEFRLevel? = .b1,
        confident: Bool = true,
        gaps: [String] = ["再多说 20 轮"]
    ) -> PlacementEstimate {
        PlacementEstimate(
            level: level,
            score: 0.6,
            isConfident: confident,
            signals: ["开口 \(level?.code ?? "-") 水平"],
            gaps: gaps,
            nextLevel: next
        )
    }

    private func plan(
        estimate: PlacementEstimate? = nil,
        tasks: Int = 3,
        done: Int = 1,
        errors: Int = 0,
        phonemes: Int = 0,
        dueVocabulary: Int = 0
    ) -> LearningPlan {
        let items = (0..<tasks).map { index in
            DailyTask(
                kind: .conversation,
                title: "任务 \(index)",
                reason: "依据",
                target: 10,
                progress: index < done ? 10 : 0,
                unit: "轮"
            )
        }
        return LearningPlanner.plan(
            estimate: estimate ?? self.estimate(),
            dailyPlan: DailyPlan(day: Date(), tasks: items),
            recurringErrorCount: errors,
            weakPhonemeCount: phonemes,
            dueVocabularyRemaining: dueVocabulary
        )
    }

    // MARK: - 重点项

    func testNoPendingMeansNoFocus() {
        let plan = self.plan(errors: 0, phonemes: 0, dueVocabulary: 0)
        XCTAssertTrue(plan.stage.focus.isEmpty)
        XCTAssertFalse(plan.stage.hasFocus)
    }

    func testFocusOrderIsErrorThenPhonemeThenVocabulary() {
        let plan = self.plan(errors: 3, phonemes: 2, dueVocabulary: 5)
        XCTAssertEqual(plan.stage.focus.map(\.action), [.errorDrill, .phonemeDrill, .vocabulary])
    }

    func testOnlyPendingSourcesAppear() {
        let onlyVocabulary = self.plan(errors: 0, phonemes: 0, dueVocabulary: 4)
        XCTAssertEqual(onlyVocabulary.stage.focus.map(\.action), [.vocabulary])
        XCTAssertEqual(onlyVocabulary.stage.focus.first?.pending, 4)

        let onlyErrors = self.plan(errors: 1, phonemes: 0, dueVocabulary: 0)
        XCTAssertEqual(onlyErrors.stage.focus.map(\.action), [.errorDrill])
    }

    func testFocusReasonCarriesTheCount() {
        // 「可核对的说法」纪律：数量必须出现在依据里，不能只写形容词。
        let plan = self.plan(errors: 7, phonemes: 0, dueVocabulary: 0)
        let reason = plan.stage.focus.first?.reason ?? ""
        XCTAssertTrue(reason.contains("7"), "依据里应带上真实数量：\(reason)")
    }

    func testNegativePendingIsClampedToZero() {
        let item = LearningPlanFocus(
            action: .errorDrill, title: "t", reason: "r", pending: -3, unit: "处"
        )
        XCTAssertEqual(item.pending, 0)
        XCTAssertEqual(item.pendingText, "0 处")
    }

    // MARK: - 阶段层标题与靶子

    func testHeadlineShowsTransition() {
        let plan = self.plan(estimate: estimate(level: .a2, next: .b1))
        XCTAssertEqual(plan.stage.headline, "A2 → B1")
    }

    func testHeadlineShowsSingleLevelWhenAlreadyAtTop() {
        let plan = self.plan(estimate: estimate(level: .b2, next: nil))
        XCTAssertEqual(plan.stage.headline, "B2")
    }

    func testHeadlineSaysObservingWhenNotConfident() {
        let plan = self.plan(estimate: estimate(level: nil, next: nil, confident: false))
        XCTAssertEqual(plan.stage.headline, "还在观察中")
    }

    func testTargetCanDoUsesTargetLevelNotCurrent() {
        let plan = self.plan(estimate: estimate(level: .a2, next: .b1))
        XCTAssertEqual(plan.stage.targetCanDo, CEFRLevel.b1.canDo)
        XCTAssertNotEqual(plan.stage.targetCanDo, CEFRLevel.a2.canDo)
    }

    func testTargetCanDoIsNilWhenNotConfident() {
        let plan = self.plan(estimate: estimate(level: nil, next: nil, confident: false))
        XCTAssertNil(plan.stage.targetCanDo)
    }

    // MARK: - 透传

    func testGapsArePassedThroughVerbatim() {
        let gaps = ["再多说 20 轮", "再收 40 个词"]
        let plan = self.plan(estimate: estimate(gaps: gaps))
        XCTAssertEqual(plan.stage.gaps, gaps)
    }

    func testTodayIsCarriedThroughVerbatim() {
        let plan = self.plan(tasks: 3, done: 2)
        XCTAssertEqual(plan.today.totalCount, 3)
        XCTAssertEqual(plan.today.completedCount, 2)
        XCTAssertEqual(plan.todayRemaining, 1)
    }

    func testTodayRemainingNeverGoesNegative() {
        let plan = self.plan(tasks: 0, done: 0)
        XCTAssertEqual(plan.todayRemaining, 0)
    }

    // MARK: - 空判定

    func testIsEmptyOnlyWhenBothLayersAreEmpty() {
        let bothEmpty = self.plan(tasks: 0, done: 0, errors: 0, phonemes: 0, dueVocabulary: 0)
        XCTAssertTrue(bothEmpty.isEmpty)

        let onlyFocus = self.plan(tasks: 0, done: 0, errors: 2)
        XCTAssertFalse(onlyFocus.isEmpty)

        let onlyToday = self.plan(tasks: 2, done: 0)
        XCTAssertFalse(onlyToday.isEmpty)
    }
}
