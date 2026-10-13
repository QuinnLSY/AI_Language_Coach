import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// ⑦-B② 碎片热身的**接线**：钉「这一轮确实读了真数据」。
///
/// 与 `KickoffWiringTests` 同款理由：纯函数全绿、界面上却永远只有一句问候，
/// 说明派生那一步没接上数据源。这一层就钉那一步。
///
/// ⚠️ 跟读那一步的素材有两处来源（今日素材 / 随包素材），测试环境里随包素材
/// 解不解得出来不由本文件决定 —— 所以凡是会受它影响的断言，都只钉**本用例
/// 自己喂进去的那部分**，不钉总步数。
@MainActor
final class WarmUpWiringTests: XCTestCase {

    // MARK: - 有依据就排得出步骤

    func testPlanFollowsRealDueWords() async {
        let state = makeState()
        state.vocabularyEntries = Self.entries(count: 5)
        state.shadowingDrills = [Self.drill]
        state.starterQuestions = ["How was your day?"]

        await state.refreshWarmUp()

        XCTAssertEqual(state.warmUpPlan?.wordCount, WarmUpPlan.defaultWordCount,
                       "词数来自真的到期队列，不是写死的 3")
        XCTAssertTrue(state.warmUpPlan?.hasShadow == true, "给了跟读素材就该有跟读这一步")
        XCTAssertTrue(state.warmUpPlan?.hasSpeak == true, "给了预设提问就该有开口这一步")
    }

    func testMasteredWordsLeaveNoWordStep() async {
        let state = makeState()
        state.vocabularyEntries = Self.entries(count: 3).map { entry in
            var copy = entry
            copy.mastery = 5
            return copy
        }
        state.starterQuestions = ["How was your day?"]

        await state.refreshWarmUp()

        XCTAssertEqual(state.warmUpPlan?.wordCount, 0, "已掌握的词不该被拉来热身")
        XCTAssertTrue(state.warmUpPlan?.hasSpeak == true, "没有词了，开口那一步照样成立")
    }

    /// 没有到期词、也没有预设提问 → 这两个步骤都不排（不拿随包素材去凑「有得练」）。
    func testNoWordsAndNoPromptsLeaveThoseStepsOut() async {
        let state = makeState()
        state.vocabularyEntries = []
        state.starterQuestions = []

        await state.refreshWarmUp()

        XCTAssertEqual(state.warmUpPlan?.wordCount ?? 0, 0)
        XCTAssertFalse(state.warmUpPlan?.hasSpeak == true)
    }

    // MARK: - 刷新时机（反证：删掉 `refreshTodayPanel` 里那行 `await refreshWarmUp()` → 这条变红）

    func testTodayPanelRefreshAlsoRefreshesWarmUp() async {
        let state = makeState()
        state.vocabularyEntries = Self.entries(count: 2)
        state.starterQuestions = ["How was your day?"]
        XCTAssertNil(state.warmUpPlan)

        await state.refreshTodayPanel(force: true)

        XCTAssertNotNil(
            state.warmUpPlan,
            "今日面板刷新时就该顺手排一轮 —— 否则要等下一次手动刷新才出现"
        )
    }

    // MARK: - 跑着的那一轮不换题

    func testRunningRoundIsNotReplanned() async {
        let state = makeState()
        state.vocabularyEntries = Self.entries(count: 3)
        state.starterQuestions = ["How was your day?"]
        await state.refreshWarmUp()
        let planned = state.warmUpPlan
        await state.startWarmUp()
        let running = state.warmUp?.plan

        // 中途词表变了（别处刚判过几个）：跑着的这一轮不许跟着换题。
        state.vocabularyEntries = Self.entries(count: 1)
        await state.refreshWarmUp()

        XCTAssertEqual(state.warmUp?.plan, running,
                       "中途换掉会让「第 2 步」指向另一件事，已判的分也记在前一批词名下")
        XCTAssertEqual(state.warmUpPlan, planned,
                       "这一轮没收就不许提前排下一轮的单子 —— 收起时那次刷新自然会排")
    }

    // MARK: - 判词 / 跳过 / 结算

    func testGradingAWordAdvancesTheRound() async {
        let state = makeState()
        state.vocabularyEntries = Self.entries(count: 3)
        state.starterQuestions = ["How was your day?"]
        await state.startWarmUp()
        let before = state.warmUp?.completedCount ?? -1

        await state.gradeWarmUpWord(remembered: true)

        XCTAssertEqual(state.warmUp?.remembered, 1)
        XCTAssertEqual(state.warmUp?.completedCount, before + 1, "判一个词就前进一步")
        XCTAssertEqual(state.warmUp?.forgotten, 0)
    }

    /// 最后一步做完要钉住结束时刻 —— 结算卡挂在屏幕上，用时不能再往后长。
    func testFinishingLastStepSealsElapsedTime() async {
        let state = makeState()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        state.warmUp = WarmUpProgress(
            plan: WarmUpPlan(steps: [.word(entryID: UUID(), word: "resilient")]),
            now: start
        )

        await state.gradeWarmUpWord(remembered: true)

        XCTAssertTrue(state.warmUp?.isFinished == true)
        XCTAssertNotNil(state.warmUp?.finishedAt)
        XCTAssertTrue(
            state.warmUp?.summary(now: start.addingTimeInterval(900)).headline.hasPrefix("记得 1/1 · 用时") == true,
            "结算上的两个数字都得是真值：实测 \(state.warmUp?.summary(now: start).headline ?? "")"
        )
    }

    func testSkippingDoesNotScore() async {
        let state = makeState()
        state.warmUp = WarmUpProgress(
            plan: WarmUpPlan(steps: [.word(entryID: UUID(), word: "resilient")]),
            now: Date()
        )

        await state.skipWarmUpStep()

        XCTAssertTrue(state.warmUp?.isFinished == true)
        XCTAssertEqual(state.warmUp?.remembered, 0)
        XCTAssertEqual(state.warmUp?.forgotten, 0, "跳过不算忘了：没判就是没判")
    }

    // MARK: - 发出去的是「你真说的那句」

    func testSendingSpokenTextSendsWhatWasHeard() {
        let state = makeState()
        var progress = WarmUpProgress(
            plan: WarmUpPlan(steps: [.speak(prompt: "How was your day?")]),
            now: Date()
        )
        // 模拟「听到的是学员自己说的那句」，而不是提示句。
        progress.markSpoken("I had a good day.")
        progress.finish(now: Date())
        state.warmUp = progress

        state.sendWarmUpSpokenText()

        XCTAssertEqual(
            state.chat.messages.last?.content, "I had a good day.",
            "发出去的必须是识别到的原话 —— 发提示句等于替用户说了一句他没说过的话"
        )
        XCTAssertNil(state.warmUp, "发完这一轮就收了，不该留一张结算卡压在对话上")
    }

    /// 没听到（或没开口）就不该有东西被发出去：拿提示句凑一条消息是替学员说话。
    func testNothingHeardSendsNothing() {
        let state = makeState()
        var progress = WarmUpProgress(
            plan: WarmUpPlan(steps: [.speak(prompt: "How was your day?")]),
            now: Date()
        )
        progress.markSpoken(nil)
        progress.finish(now: Date())
        state.warmUp = progress

        state.sendWarmUpSpokenText()

        XCTAssertTrue(state.chat.messages.isEmpty, "没听到就没有可发的")
        XCTAssertNotNil(state.warmUp, "没发出去就不该把结算卡收掉")
    }

    // MARK: - 结算脸不现取时钟（源码哨兵）

    /// 结算卡挂在那儿，`summary(now:)` 的入参不许是视图里现取的 `Date()`：
    /// body 随时可能被重算，现取时钟意味着「用时」有可能在自己往前走
    /// （`summary(now:)` 的语义哪天变了就会露出来）。钉调用形态整串。
    func testSettlementFaceUsesThePinnedSummary() throws {
        let raw = try Self.code("Sources/AppUI/Components/WarmUpCard.swift")
        XCTAssertTrue(
            raw.contains("settlementFace(progress.settlement)"),
            "结算脸必须走钉住结束时刻的摘要（WarmUpProgress.settlement）"
        )
        XCTAssertFalse(
            raw.contains("summary(now: Date())"),
            "视图体里不许现取时钟 —— 那是隐形的时钟依赖"
        )
    }

    // MARK: - 工装

    private static func entries(count: Int) -> [VocabularyEntry] {
        (0..<count).map { VocabularyEntry(word: "resilient-\($0)") }
    }

    private static let drill = ShadowingDrill(
        id: "warmup.1", text: "Practice makes progress.", difficulty: 2
    )

    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-warmup-\(UUID().uuidString).json")
        )
        // ⚠️ 必须 `:memory:`：裸 `CoachServices()` 的库路径是 nil，会落到真实学习库上。
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    /// 读源码做哨兵（去掉纯注释行，避免注释里的同款字串造成假绿）。
    private static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
