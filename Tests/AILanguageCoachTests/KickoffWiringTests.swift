import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// ⑦-B① 话题卡的**接线**：钉「卡片确实读了真数据」，而不是只在纯函数里成立。
///
/// 单独一组测试的理由与 `AdaptivePathWiringTests` 相同：纯函数全绿、界面上却一直
/// 只有一句问候 —— 那说明派生那一步没接上数据源。这一层就钉那一步。
@MainActor
final class KickoffWiringTests: XCTestCase {

    // MARK: - 有依据就有卡

    func testCardsComeFromRealRecords() {
        let state = makeState()
        state.scenarios = [Self.coffee]
        state.questRecords = ["test.coffee": ScenarioQuestRecord(
            scenarioID: "test.coffee",
            doneStepIDs: ["test.coffee-s1", "test.coffee-s2"],
            updatedAt: Date().addingTimeInterval(-7200)
        )]
        state.dailyWords = [DailyWord(word: "resilient", difficulty: 3)]
        state.starterQuestions = ["How was your day?"]

        state.refreshKickoffs()

        XCTAssertEqual(
            state.kickoffSuggestions.map(\.kind), [.resume, .todayWord, .smallTalk],
            "三样依据都在：断点续练排最前，其次是今天的词，最后是句库"
        )
        XCTAssertEqual(state.kickoffSuggestions.first?.action, .openScenario(id: "test.coffee"))
        XCTAssertTrue(
            state.kickoffSuggestions.first?.detail.contains("/3 步") == true,
            "步数分母来自情景自己的主线计划，不是写死的 3"
        )
    }

    /// 「今天做到了哪儿」变了就要跟着变：卡片是派生值，不是快照。
    func testCardsFollowQuestProgress() {
        let state = makeState()
        state.scenarios = [Self.coffee]
        state.questRecords = [:]
        state.starterQuestions = ["How was your day?"]
        state.refreshKickoffs()
        XCTAssertFalse(
            state.kickoffSuggestions.contains { $0.kind == .resume },
            "还没练过的情景不该出现「接着练」"
        )

        state.questRecords = ["test.coffee": ScenarioQuestRecord(
            scenarioID: "test.coffee", doneStepIDs: ["test.coffee-s1"], updatedAt: Date()
        )]
        state.refreshKickoffs()
        XCTAssertTrue(
            state.kickoffSuggestions.contains { $0.kind == .resume },
            "练过一步之后再算，卡片必须出现 —— 派生值不许粘住旧结果"
        )
    }

    func testFinishedScenarioStopsAskingToContinue() {
        let state = makeState()
        state.scenarios = [Self.coffee]
        state.questRecords = ["test.coffee": ScenarioQuestRecord(
            scenarioID: "test.coffee",
            doneStepIDs: ["test.coffee-s1", "test.coffee-s2", "test.coffee-s3"],
            isComplete: true,
            updatedAt: Date()
        )]

        state.refreshKickoffs()

        XCTAssertFalse(
            state.kickoffSuggestions.contains { $0.kind == .resume },
            "整条主线已经走完，再催就是催他重做一遍"
        )
    }

    // MARK: - 没有依据就不给卡

    /// 反证：把 `refreshTodayPanel` 里那行 `refreshKickoffs()` 删掉 → 这条立刻变红。
    ///
    /// 钉的是「刷新时机」这一环：卡片算得再对，没有人去调它，用户还是只看到一句问候。
    func testTodayPanelRefreshAlsoRefreshesCards() async {
        let state = makeState()
        state.starterQuestions = ["How was your day?"]
        state.kickoffSuggestions = []

        await state.refreshTodayPanel(force: true)

        XCTAssertFalse(
            state.kickoffSuggestions.isEmpty,
            "今日面板刷新时就该顺手算话题卡 —— 否则卡片要等下一次手动刷新才出现"
        )
    }

    func testMissingMaterialDropsResumeCard() {
        let state = makeState()
        // 记录还在，素材没了（换过素材包 / 手动删过自定义情景）。
        state.scenarios = []
        state.questRecords = ["gone.scenario": ScenarioQuestRecord(
            scenarioID: "gone.scenario", doneStepIDs: ["a", "b"], updatedAt: Date()
        )]

        state.refreshKickoffs()

        XCTAssertFalse(
            state.kickoffSuggestions.contains { $0.kind == .resume },
            "点开找不到素材的卡绝不能出现 —— 那是一张点下去没有反应的空壳"
        )
    }

    func testDoneStepsNeverExceedPlanTotal() {
        let state = makeState()
        state.scenarios = [Self.coffee]
        // 记录里的步数比计划多：素材改过、步数删过都会这样。
        state.questRecords = ["test.coffee": ScenarioQuestRecord(
            scenarioID: "test.coffee",
            doneStepIDs: ["a", "b", "c", "d", "e"],
            updatedAt: Date()
        )]

        state.refreshKickoffs()

        let detail = state.kickoffSuggestions.first?.detail ?? ""
        XCTAssertFalse(
            detail.contains("5/"), "「完成 5/3」这种数字一露面，整张卡的可信度就没了"
        )
        XCTAssertTrue(detail.contains("/3 步"), "超出部分要夹回上限：实测 \(detail)")
    }

    // MARK: - 工装

    /// 主线会被 `ScenarioQuestRule.plan` 切成 3 步（3 个目标句）。
    private static let coffee = Scenario(
        id: "test.coffee", title: "Coffee", titleZh: "咖啡店", category: "日常",
        difficulty: 2, level: "A2",
        objective: "Order a drink", aiRole: "barista", learnerRole: "customer",
        opening: "Hi! What can I get you?",
        targetVocabulary: [],
        targetGrammar: [],
        targetSentences: ["I'd like a latte.", "Can I have it iced?", "That's all, thanks."],
        maxTurns: 4,
        correctionMode: .gentle, icon: "cup.and.saucer.fill"
    )

    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-kickoff-\(UUID().uuidString).json")
        )
        // ⚠️ 必须 `:memory:`：裸 `CoachServices()` 的库路径是 nil，会落到真实学习库上。
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }
}
