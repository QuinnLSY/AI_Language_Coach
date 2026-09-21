import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 无文本听力在 AppState 上的接线回归（进阶 ④）。
///
/// Domain 的分档 / 轮转 / 结算由 `ListeningDictationTests` 覆盖；这里只管三件事：
/// 会话怎么起、交了之后成绩去哪、跨天加载有没有把昨天的账算进今天。
///
/// ⚠️ 这个类里的用例会碰 `UserDefaults`（听写成绩就存在那儿）—— 每一条都
/// 先把原值取出来、`defer` 原样放回：测试数据绝不能留在开发机上（那是**真实用户数据**）。
///
/// ⚠️ 用 `async` 测试方法而不是 `wait(for:)` 等 Task：类已经标了 `@MainActor`，
/// 主线程被 `wait` 堵住时，那个 `@MainActor` 的 Task 永远排不上队 —— 直接死锁。
@MainActor
final class ListeningFlowTests: XCTestCase {

    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("listening-flow-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    /// `listening.log` 这条真实数据的保护：进函数时快照，退出时原样写回。
    private func snapshotListeningLog() -> Data? {
        UserDefaults.standard.data(forKey: AppState.listeningLogStorageKey)
    }

    private func restoreListeningLog(_ snapshot: Data?) {
        let defaults = UserDefaults.standard
        if let snapshot {
            defaults.set(snapshot, forKey: AppState.listeningLogStorageKey)
        } else {
            defaults.removeObject(forKey: AppState.listeningLogStorageKey)
        }
    }

    // MARK: - 开局

    /// 开一轮：素材就是我们给它的那几句（不依赖模型有没有起）。
    func testStartListeningDrillUsesTodayMaterial() async {
        let state = makeState()
        state.shadowingDrills = (0..<20).map {
            ShadowingDrill(id: "d\($0)", text: "line number \($0)", topic: "t")
        }

        await state.startListeningDrill()

        XCTAssertTrue(state.isListeningDrill)
        XCTAssertEqual(state.listeningRound.count, ListeningRule.roundSize)
        XCTAssertEqual(state.listeningIndex, 0)
        XCTAssertNil(state.listeningResult, "刚开局不该有对照结果")
        XCTAssertTrue(state.listeningDraft.isEmpty)
        XCTAssertEqual(state.listeningPlayCount, 0)
        XCTAssertNil(state.listeningSummary)
        XCTAssertNotNil(state.currentListeningDrill)
    }

    /// 手上还没有素材时，开轮要**自己把它取回来**，而不是开一张空卡。
    func testStartWithoutMaterialLoadsItFirst() async {
        let state = makeState()
        XCTAssertTrue(state.shadowingDrills.isEmpty, "前提：此刻手上没有句子")

        await state.startListeningDrill()

        XCTAssertTrue(state.isListeningDrill)
        XCTAssertEqual(state.listeningRound.count, ListeningRule.roundSize)
        XCTAssertNotNil(state.currentListeningDrill)
    }

    // MARK: - 交卷

    /// 交卷：判分 + 落账，**不发起任何模型请求**。
    func testSubmitScoresAndRecordsTheDay() async {
        let snapshot = snapshotListeningLog()
        defer { restoreListeningLog(snapshot) }

        let state = makeState()
        state.listeningRound = [ShadowingDrill(id: "d0", text: "Can I have a receipt", topic: "t")]
        state.listeningIndex = 0
        state.listeningPlayCount = 2

        state.listeningDraft = "Can I have receipt"
        state.submitListeningDraft()

        let result = state.listeningResult
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.playCount, 2)
        XCTAssertEqual(result?.comparison.matched, 4)
        XCTAssertEqual(result?.missedWords, ["a"])
        // 「听了几遍」是听力训练的核心指标，必须原样带出来。
        // 听了两遍、写得挺准 → 听懂了，但不是「一遍听懂」。
        XCTAssertEqual(result?.step, .understood)
        // 「写对了没有」逐词就有，不必等到结算。
        XCTAssertEqual(result?.accuracy ?? 0, 0.8, accuracy: 1e-9)

        XCTAssertEqual(state.listeningAttempts.count, 1)
        XCTAssertEqual(state.listeningLog.resolvedCount, 1, "今天的账要记上")
        XCTAssertNil(state.shadowingComparison, "跟读卡的结果不该被听写污染")
    }

    /// 空着交不算：不许出现「听了 0 秒就 100%」这种假成绩。
    func testBlankDraftIsRejected() async {
        let snapshot = snapshotListeningLog()
        defer { restoreListeningLog(snapshot) }

        let state = makeState()
        state.listeningRound = [ShadowingDrill(id: "d0", text: "Hello there", topic: "t")]

        state.listeningDraft = "   \n "
        state.submitListeningDraft()

        XCTAssertNil(state.listeningResult)
        XCTAssertTrue(state.listeningAttempts.isEmpty)
        XCTAssertEqual(state.listeningLog.resolvedCount, 0)
        XCTAssertNotNil(state.listeningNotice)
    }

    /// 推进：最后一句之后直接结算，中途不许提前收尾。
    func testAdvanceWalksToTheEndThenSummarises() async {
        let snapshot = snapshotListeningLog()
        defer { restoreListeningLog(snapshot) }

        let state = makeState()
        state.listeningRound = (0..<2).map { ShadowingDrill(id: "d\($0)", text: "line \($0) here", topic: "t") }

        state.listeningDraft = "line 0 here"
        state.submitListeningDraft()
        state.advanceListening()

        XCTAssertNil(state.listeningSummary, "还有第二句，不该结算")
        XCTAssertEqual(state.listeningIndex, 1)
        XCTAssertNil(state.listeningResult)
        XCTAssertTrue(state.listeningDraft.isEmpty, "换句要清空输入")
        XCTAssertEqual(state.listeningPlayCount, 0, "遍数按句算")

        state.listeningDraft = "line 1 here"
        state.submitListeningDraft()
        state.advanceListening()

        let summary = state.listeningSummary
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.attempted, 2)
        XCTAssertEqual(summary?.firstPassCount, 2, "两句都是一遍写对的（playCount 0 → 一遍听懂）")
        XCTAssertEqual(state.listeningLog.resolvedCount, 2, "两句都要落账")
    }

    /// 退出：会话状态整体清掉，但**今天的账不清**（刚练对的成绩不该被收回）。
    func testExitKeepsTheDayLogButClearsTheSession() async {
        let snapshot = snapshotListeningLog()
        defer { restoreListeningLog(snapshot) }

        let state = makeState()
        state.listeningRound = [ShadowingDrill(id: "d0", text: "good morning", topic: "t")]
        state.listeningDraft = "good morning"
        state.submitListeningDraft()

        state.exitListeningDrill()

        XCTAssertFalse(state.isListeningDrill)
        XCTAssertTrue(state.listeningRound.isEmpty)
        XCTAssertNil(state.listeningResult)
        XCTAssertNil(state.listeningSummary)
        XCTAssertEqual(state.listeningLog.resolvedCount, 1)
    }

    // MARK: - 跨天加载（反证目标：`loadListeningLog` 里的 `rolledOver`）

    /// ⚠️ 跨天加载：昨天写对的句子**不许**算进今天的进度。
    ///
    /// 撤掉 `loadListeningLog` 里那一步 `rolledOver`，这条立刻变红 ——
    /// 用户第二天打开会看到「今天写了 6 句」，而他今天一句都没写。
    func testStaleLogFromYesterdayIsDroppedOnLoad() throws {
        let snapshot = snapshotListeningLog()
        defer { restoreListeningLog(snapshot) }

        let stale = ListeningLog(dayKey: "2001-01-01", best: ["x": 0.9, "y": 0.8])
        UserDefaults.standard.set(
            try JSONEncoder().encode(stale), forKey: AppState.listeningLogStorageKey
        )

        let state = makeState()

        XCTAssertEqual(state.listeningLog.resolvedCount, 0, "昨天的账不能挂进今天")
        XCTAssertNil(state.listeningLog.averageAccuracy)
        XCTAssertEqual(state.listeningLog.dayKey, ListeningLog.today().dayKey)
    }

    /// 今天写过的账要能读回来（与上一条成对：不该清的不能清）。
    func testSameDayLogSurvivesLoad() throws {
        let snapshot = snapshotListeningLog()
        defer { restoreListeningLog(snapshot) }

        let today = ListeningLog.today().recording(drillID: "d0", accuracy: 0.75)
        UserDefaults.standard.set(
            try JSONEncoder().encode(today), forKey: AppState.listeningLogStorageKey
        )

        let state = makeState()

        XCTAssertEqual(state.listeningLog.resolvedCount, 1)
        XCTAssertEqual(state.listeningLog.averageAccuracy ?? 0, 0.75, accuracy: 1e-9)
    }
}
