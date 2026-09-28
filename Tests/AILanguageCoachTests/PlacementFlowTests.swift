import AIDomain
import AIInfrastructure
import AIServices
@testable import AppUI
import XCTest

/// 入学定级在 AppState 上的接线回归（进阶 ⑤）。
///
/// 出卷 / 判分 / 定级的规则由 `EntrancePlacementTests` 覆盖（纯函数）。这里只管
/// 四件事：**卷子怎么发、答完落在哪、关掉浮层会不会丢进度**，以及
/// 「自测档位」与「实测档位」两把尺子谁说了算。
///
/// 三条纪律（与 `ListeningFlowTests` 同）：
/// - 会读 / 写 `placement.result` 的用例，一律先 `isolateResult()` 把开发机上那份
///   **真实数据挪走**、`defer` 原样放回。`AppState(services:)` 在 init 里就会把它读进来，
///   不清干净的话「没测过」这类前提会随开发机状态时红时绿 —— 那是测试数据污染真实数据，
///   反过来也是。
/// - 用 `async` 测试方法而不是 `wait(for:)`：类标了 `@MainActor`，主线程被堵住时
///   那个 `@MainActor` 的 Task 永远排不上队，直接死锁。
/// - 摸底**全程零模型请求**：这里一个 mock 都不需要，能跑通本身就是证据。
@MainActor
final class PlacementFlowTests: XCTestCase {

    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("placement-flow-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    /// 把真实的 `placement.result` 挪走，返回「原样放回」的动作。
    ///
    /// ⚠️ 必须在 `makeState()` **之前**调用 —— `AppState.init` 就是靠这个键恢复上次结果的。
    private func isolateResult() -> () -> Void {
        let defaults = UserDefaults.standard
        let snapshot = defaults.data(forKey: AppState.placementResultStorageKey)
        defaults.removeObject(forKey: AppState.placementResultStorageKey)
        return {
            if let snapshot {
                defaults.set(snapshot, forKey: AppState.placementResultStorageKey)
            } else {
                defaults.removeObject(forKey: AppState.placementResultStorageKey)
            }
        }
    }

    /// 一道题都不剩地答完：全程选 A（下标 0）。
    /// 返回**每一题之后**的 `placementOutcome`，用来证明「中途不给对错」。
    private func answerThrough(_ state: AppState) -> [PlacementResult?] {
        var outcomes: [PlacementResult?] = []
        var guardCount = 0
        while state.currentPlacementQuestion != nil {
            state.choosePlacementOption(0)
            outcomes.append(state.placementOutcome)
            guardCount += 1
            if guardCount > 100 { break } // 防呆：推进逻辑坏了也别把测试挂死
        }
        return outcomes
    }

    // MARK: - 开局

    /// 打开摸底：浮层起来、题库读到、**不留任何提示**（随包题库是完整的）。
    func testOpenPlacementShowsTheSheetWithACompleteBank() async {
        let restore = isolateResult()
        defer { restore() }

        let state = makeState()

        await state.openPlacement()

        XCTAssertTrue(state.isPlacementShowing)
        XCTAssertFalse(state.isPlacementLoading, "读完题库要落回 idle，否则界面会一直转")
        XCTAssertNil(state.placementNotice, "题库完整时不该有提示")
        XCTAssertNil(state.placementPaper.question(at: 0), "光打开不出卷 —— 先看说明再开始")
        XCTAssertNil(state.placementLevel, "还没测，就没有档位")
        XCTAssertEqual(state.effectivePlacementLevelText, "", "没测也没数据 → 空串（交给 Prompt 侧按「观察中」处理）")
    }

    /// 出卷：每档 3 题、四档齐全，且**从第 0 题开始**。
    func testStartBuildsAPaperCoveringEveryLevel() async {
        let restore = isolateResult()
        defer { restore() }

        let state = makeState()

        await state.startPlacement()

        XCTAssertEqual(
            state.placementPaper.questionCount,
            CEFRLevel.allCases.count * EntrancePlacementRule.questionsPerLevel
        )
        XCTAssertEqual(state.placementPaper.levels, CEFRLevel.allCases, "四档都要覆盖到")
        for level in CEFRLevel.allCases {
            XCTAssertEqual(state.placementPaper.count(of: level), EntrancePlacementRule.questionsPerLevel)
        }
        XCTAssertEqual(state.placementIndex, 0)
        XCTAssertTrue(state.placementAnswers.isEmpty)
        XCTAssertNil(state.placementOutcome)
        XCTAssertEqual(state.placementProgressText, "第 1 / \(state.placementPaper.questionCount) 题")
        XCTAssertNotNil(state.currentPlacementQuestion)
    }

    // MARK: - 作答

    /// 选完立刻进下一题，**中途不给对错**：给了反馈人会照着改，量出来的就不是水平。
    func testChoosingAdvancesWithoutRevealingAnything() async throws {
        let restore = isolateResult()
        defer { restore() }

        let state = makeState()
        await state.startPlacement()
        let first = try XCTUnwrap(state.currentPlacementQuestion)

        state.choosePlacementOption(0)

        XCTAssertEqual(state.placementIndex, 1)
        XCTAssertEqual(state.placementAnswers[first.id], 0, "答案要记下来")
        XCTAssertNil(state.placementOutcome, "第一题之后不许有结果")
        XCTAssertEqual(state.currentPlacementQuestion?.id, state.placementPaper.question(at: 1)?.id)

        // 一遍答到底：只有**最后一题**之后才出结果。
        // （上面已经先答掉一题，所以这里只剩 total - 1 题。）
        let outcomes = answerThrough(state)
        XCTAssertEqual(outcomes.count, state.placementPaper.questionCount - 1)
        XCTAssertTrue(outcomes.dropLast().allSatisfy { $0 == nil }, "最后一题之前全程无结果")
        XCTAssertNotNil(state.placementOutcome, "最后一题答完必须结算")
        XCTAssertNil(state.currentPlacementQuestion, "交卷之后不该还有「当前题」")
    }

    /// 越界的选项下标一律忽略（UI 传错不该把卷子推进一格）。
    func testOutOfRangeOptionIsIgnored() async {
        let restore = isolateResult()
        defer { restore() }

        let state = makeState()
        await state.startPlacement()

        state.choosePlacementOption(4)
        state.choosePlacementOption(-1)

        XCTAssertEqual(state.placementIndex, 0, "非法选项不算作答")
        XCTAssertTrue(state.placementAnswers.isEmpty)
    }

    /// 答完之后再点不会崩，也不会把结果改掉（题没了 → currentPlacementQuestion 为 nil）。
    func testChoosingAfterTheLastQuestionIsANoop() async {
        let restore = isolateResult()
        defer { restore() }

        let state = makeState()
        await state.startPlacement()
        _ = answerThrough(state)
        let settled = state.placementOutcome

        state.choosePlacementOption(1)

        XCTAssertEqual(state.placementOutcome, settled, "结算之后不许再改结果")
        XCTAssertNil(state.currentPlacementQuestion)
    }

    // MARK: - 落盘（反证目标：`savePlacementResult`）

    /// 答完要**存**：结果必须落在 UserDefaults 里，而不是只活在内存。
    ///
    /// 删掉 `finishPlacement` 里那一行 `savePlacementResult()`，这条立刻变红。
    func testFinishingSavesTheResultToDisk() async throws {
        let restore = isolateResult()
        defer { restore() }

        let state = makeState()
        await state.startPlacement()
        _ = answerThrough(state)

        let outcome = try XCTUnwrap(state.placementOutcome)
        XCTAssertEqual(state.placementResult, outcome, "结算即入账")

        let data = try XCTUnwrap(
            UserDefaults.standard.data(forKey: AppState.placementResultStorageKey),
            "结果没落盘 —— 关掉应用就没了"
        )
        XCTAssertEqual(try JSONDecoder().decode(PlacementResult.self, from: data), outcome)
    }

    /// 题只答了一半就退出，**不该**产生任何结果（半份卷子的分数是假分数）。
    func testHalfFinishedPaperProducesNoResult() async {
        let restore = isolateResult()
        defer { restore() }

        let state = makeState()
        await state.startPlacement()
        state.choosePlacementOption(0)
        state.choosePlacementOption(3)

        XCTAssertNil(state.placementOutcome)
        XCTAssertNil(state.placementResult)
        XCTAssertNil(UserDefaults.standard.data(forKey: AppState.placementResultStorageKey))
    }

    // MARK: - 恢复（反证目标：init 里的 `loadPlacementResult`）

    /// ⚠️ 存过的结果必须**跨启动读得回来**。
    ///
    /// 撤掉 `AppState.init` 里那行 `Self.loadPlacementResult()`，这条变红 ——
    /// 而它不会报错、不会崩，只是用户每次重开应用都被当成「没测过」。
    func testSavedResultIsRestoredOnNextLaunch() throws {
        let restore = isolateResult()
        defer { restore() }

        let saved = PlacementResult(
            level: .b1, correct: 9, total: 12, seed: 7,
            perLevel: [
                PlacementLevelScore(level: .a1, correct: 3, total: 3, isPassed: true),
                PlacementLevelScore(level: .a2, correct: 3, total: 3, isPassed: true),
                PlacementLevelScore(level: .b1, correct: 2, total: 3, isPassed: true),
                PlacementLevelScore(level: .b2, correct: 1, total: 3, isPassed: false)
            ]
        )
        UserDefaults.standard.set(
            try JSONEncoder().encode(saved), forKey: AppState.placementResultStorageKey
        )

        let state = makeState()

        XCTAssertEqual(state.placementResult, saved)
        XCTAssertEqual(state.placementLevel, .b1)
        XCTAssertEqual(state.effectivePlacementLevelText, "B1")
    }

    /// 坏数据不该把启动搞崩，也不该凭空冒出一个档位。
    func testCorruptedStoredResultIsTreatedAsNotTaken() {
        let restore = isolateResult()
        defer { restore() }

        UserDefaults.standard.set(Data("{ not json".utf8), forKey: AppState.placementResultStorageKey)

        let state = makeState()

        XCTAssertNil(state.placementResult)
        XCTAssertEqual(state.effectivePlacementLevelText, "")
    }

    // MARK: - 两把尺子

    /// 攒够真实输出之后，**实测档位压过自测档位**。
    ///
    /// 摸底只有十来道选择题，是第 0 天的权宜之计；25 轮对话 + 3 天 + 20 个词之后，
    /// 那条估计才是「实际用出来什么水平」。
    func testConfidentPracticeEstimateOutranksTheSelfTest() throws {
        let restore = isolateResult()
        defer { restore() }

        let state = makeState()
        state.progressSnapshot = ProgressSnapshot(
            today: DailyActivity(day: Date()),
            activeDays: 5,
            totalMessages: 30,
            vocabulary: VocabularyStats(
                total: 40, due: 0, mastered: 5, defined: 40,
                dueAtDayStart: 0, dueAtDayStartReviewed: 0
            )
        )

        let estimate = state.placementEstimate
        XCTAssertTrue(estimate.isConfident, "前提：样本已经够定性了")
        let estimateLevel = try XCTUnwrap(estimate.level)

        // 自测故意给一个**不同**的档位，确保这条真在测优先级，而不是碰巧相等。
        let selfTested: CEFRLevel = estimateLevel == .a1 ? .b2 : .a1
        state.placementResult = PlacementResult(level: selfTested, correct: 2, total: 12)

        XCTAssertEqual(state.placementLevel, selfTested, "摸底档位本身照样读得到")
        XCTAssertNotEqual(estimateLevel, selfTested)
        XCTAssertEqual(state.effectivePlacementLevelText, estimateLevel.code, "出题该用实测那一档")
    }

    /// 样本不够时，摸底的档位就是**唯一能用**的信息 —— 那正是新用户的情况。
    func testSelfTestFillsTheGapBeforeThereIsAnyPracticeData() {
        let restore = isolateResult()
        defer { restore() }

        let state = makeState()
        XCTAssertFalse(state.placementEstimate.isConfident, "前提：此刻没有任何练习数据")

        state.placementResult = PlacementResult(level: .a2, correct: 4, total: 12)

        XCTAssertEqual(state.effectivePlacementLevelText, "A2")
    }

    // MARK: - 收工

    /// 关浮层**不清进度**：做到第 7 题去接了个电话，回来要接着做。
    func testClosingTheSheetKeepsThePaperAndTheIndex() async {
        let restore = isolateResult()
        defer { restore() }

        let state = makeState()
        await state.startPlacement()
        state.choosePlacementOption(0)
        state.choosePlacementOption(0)
        let answered = state.placementAnswers

        state.closePlacement()

        XCTAssertFalse(state.isPlacementShowing)
        XCTAssertEqual(state.placementIndex, 2, "进度还在")
        XCTAssertEqual(state.placementAnswers, answered)
        XCTAssertNotNil(state.currentPlacementQuestion)
    }

    /// 结果确认之后才收摊：清卷面、**留结果**。
    func testDismissingTheOutcomeClearsThePaperButKeepsTheResult() async {
        let restore = isolateResult()
        defer { restore() }

        let state = makeState()
        await state.startPlacement()
        _ = answerThrough(state)
        let outcome = state.placementOutcome

        state.dismissPlacementOutcome()

        XCTAssertFalse(state.isPlacementShowing)
        XCTAssertTrue(state.placementPaper.isEmpty, "卷面清掉")
        XCTAssertTrue(state.placementAnswers.isEmpty)
        XCTAssertEqual(state.placementIndex, 0)
        XCTAssertNil(state.placementOutcome, "浮层里那份临时结果清掉")
        XCTAssertEqual(state.placementResult, outcome, "落过盘的档位留着")
    }

    /// 重测换一批题：种子每次 +1，同一档的 5 道会逐次轮换。
    func testRetestRotatesThePaper() async {
        let restore = isolateResult()
        defer { restore() }

        let state = makeState()
        await state.startPlacement()
        let firstIDs = state.placementPaper.questions.map(\.id)
        let firstSeed = state.placementPaper.seed
        _ = answerThrough(state)

        await state.startPlacement()

        XCTAssertEqual(state.placementPaper.seed, firstSeed + 1, "种子要往后走")
        XCTAssertNotEqual(state.placementPaper.questions.map(\.id), firstIDs, "连着两次不该是同一张卷子")
        XCTAssertEqual(state.placementIndex, 0, "新一轮从头开始")
        XCTAssertTrue(state.placementAnswers.isEmpty, "上一轮的答案不能带过来")
        XCTAssertNil(state.placementOutcome)
    }

    /// 提示可关（题库完整时本来就没有提示，这里验的是「关掉」这个动作本身）。
    func testNoticeCanBeDismissed() async {
        let state = makeState()

        state.placementNotice = "题库不完整"
        state.dismissPlacementNotice()

        XCTAssertNil(state.placementNotice)
    }
}
