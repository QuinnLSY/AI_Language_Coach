import AIDomain
import AIInfrastructure
import AIServices
@testable import AppUI
import XCTest

/// 跟读页的「回到上一句 / 每句分析常驻 / 记住练到哪一句」。
///
/// 三条需求（用户原话）：
/// ① 不是第一句时，在「换一句」左边显示「上一句」；
/// ② 切页再回来要**落在离开前那一句**，而不是从第一句重新开始；
/// ③ 读过的句子，**最新分析常驻** —— 跳回去看不用重读一遍。
///
/// ⚠️ 这些用例会写真实的 `UserDefaults`（`shadowing.progress` 就是它的存储），
/// 所以每条都先快照、`defer` 原样放回 —— 绝不许把开发机上的真实进度抹掉。
@MainActor
final class ShadowingSentenceStateTests: XCTestCase {

    // MARK: - 工具

    private func makeState(databasePath: String = ":memory:") -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("shadowing-state-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: databasePath))
    }

    private func drills(_ count: Int = 3) -> [ShadowingDrill] {
        (0..<count).map { index in
            ShadowingDrill(
                id: "daily-0-\(index)",
                text: "This is sentence number \(index)",
                translation: "这是第 \(index) 句",
                topic: "测试",
                difficulty: 1
            )
        }
    }

    /// 快照真实进度键并清空，返回还原闭包。
    private func isolateShadowingProgress() -> () -> Void {
        let key = AppState.shadowingProgressStorageKey
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// 把某一句「读」出一个结果（走真实的纯函数打分，不碰模型）。
    @discardableResult
    private func record(_ state: AppState, drill: ShadowingDrill, recognized: String) -> ShadowingResult {
        let result = ShadowingResult(
            comparison: ShadowingScorer.compare(reference: drill.text, recognized: recognized)
        )
        state.rememberShadowingResult(result, drillID: drill.id)
        return result
    }

    // MARK: - 上一句

    func testPreviousDrillStopsAtTheFirstSentence() {
        let restore = isolateShadowingProgress()
        defer { restore() }
        let state = makeState()
        state.shadowingDrills = drills()
        state.shadowingIndex = 1

        state.previousShadowingDrill()
        XCTAssertEqual(state.shadowingIndex, 0)

        state.previousShadowingDrill()
        XCTAssertEqual(state.shadowingIndex, 0, "第一句就是尽头，不能绕到最后一句去")
    }

    func testNextDrillWrapsAroundAsBefore() {
        let restore = isolateShadowingProgress()
        defer { restore() }
        let state = makeState()
        state.shadowingDrills = drills(3)
        state.shadowingIndex = 2

        state.nextShadowingDrill()
        XCTAssertEqual(state.shadowingIndex, 0, "「换一句」到底回到第一句（原有口径不变）")
    }

    // MARK: - 每句分析常驻

    func testEachSentenceKeepsItsOwnLatestAnalysis() {
        let restore = isolateShadowingProgress()
        defer { restore() }
        let state = makeState()
        let list = drills()
        state.shadowingDrills = list

        // 第 0 句读对一半，第 1 句读全对。
        let first = record(state, drill: list[0], recognized: "This is sentence zero")
        let second = record(state, drill: list[1], recognized: list[1].text)

        // 停在第 0 句：看到的必须是**第 0 句那次**的结果。
        state.shadowingIndex = 0
        state.restoreShadowingResultForCurrentDrill()
        XCTAssertEqual(state.shadowingComparison?.recognizedText, "This is sentence zero")
        XCTAssertEqual(
            state.shadowingComparison?.accuracy ?? 0, first.comparison.accuracy, accuracy: 0.0001
        )

        // 换到第 1 句：自动带上它自己的结果（不需要再读一遍）。
        state.nextShadowingDrill()
        XCTAssertEqual(state.shadowingComparison?.recognizedText, list[1].text)
        XCTAssertEqual(state.shadowingComparison?.accuracy ?? 0, 1.0, accuracy: 0.0001)

        // 再回到第 0 句：还是第 0 句那次的结果，而不是空白。
        state.previousShadowingDrill()
        XCTAssertEqual(state.shadowingComparison?.recognizedText, "This is sentence zero")
        XCTAssertNotEqual(state.shadowingComparison?.accuracy ?? 0, second.comparison.accuracy)
    }

    /// 没读过的句子换过去就是空白 —— 不能把上一句的结果「粘」过来。
    func testUnreadSentenceShowsNothing() {
        let restore = isolateShadowingProgress()
        defer { restore() }
        let state = makeState()
        let list = drills()
        state.shadowingDrills = list
        record(state, drill: list[0], recognized: list[0].text)
        state.shadowingIndex = 0
        state.restoreShadowingResultForCurrentDrill()
        XCTAssertNotNil(state.shadowingComparison)

        state.nextShadowingDrill()
        XCTAssertNil(state.shadowingComparison, "第 1 句还没读过 → 不该显示第 0 句的结果")
        XCTAssertNil(state.shadowingPronunciation)
    }

    // MARK: - 记住「练到哪一句」

    func testSavedIndexIsRestoredOnTheSameDay() {
        let restore = isolateShadowingProgress()
        defer { restore() }
        let state = makeState()
        state.shadowingDrills = drills(5)
        state.shadowingIndex = 3
        state.nextShadowingDrill()
        XCTAssertEqual(state.shadowingIndex, 4)

        // 换了一批素材（= 切页回来 / 重启后重新加载今天的句子）。
        state.resetShadowingProgress(restoreSavedIndex: true)
        XCTAssertEqual(state.shadowingIndex, 4, "切页回来要落回离开前那一句")
    }

    func testResetWithoutRestoringStartsFromTheFirstSentence() {
        let restore = isolateShadowingProgress()
        defer { restore() }
        let state = makeState()
        state.shadowingDrills = drills(5)
        state.shadowingIndex = 3
        state.nextShadowingDrill()

        // 音素专项 / 材料跟读走的是**另一批素材**，记住的位置对它们没有意义。
        state.resetShadowingProgress()
        XCTAssertEqual(state.shadowingIndex, 0)
    }

    func testSavedIndexFromAnotherDayIsIgnored() {
        let restore = isolateShadowingProgress()
        defer { restore() }
        let key = AppState.shadowingProgressStorageKey
        UserDefaults.standard.set("1999-01-01|7", forKey: key)
        XCTAssertNil(
            AppState.storedShadowingIndex(day: ShadowingDailyRule.dayKey()),
            "昨天的位置不许落到今天的句子上（素材已经换了一批）"
        )

        let state = makeState()
        state.shadowingDrills = drills(3)
        state.resetShadowingProgress(restoreSavedIndex: true)
        XCTAssertEqual(state.shadowingIndex, 0, "认不出来就从头开始")
    }

    func testSavedIndexBeyondTheListIsIgnored() {
        let restore = isolateShadowingProgress()
        defer { restore() }
        UserDefaults.standard.set(
            "\(ShadowingDailyRule.dayKey())|99", forKey: AppState.shadowingProgressStorageKey
        )
        let state = makeState()
        state.shadowingDrills = drills(3)
        state.resetShadowingProgress(restoreSavedIndex: true)
        XCTAssertEqual(state.shadowingIndex, 0, "越界的位置要退回第一句，不能崩也不能乱指")
    }

    // MARK: - 分析缓存的键必须带日期

    func testAnalysisKeyIsScopedToTheDay() {
        // 素材每天换一批，而生成出来的 id 是 `daily-<主题序>-<句序>` ——
        // 跨天重号但句子不同：不带 dayKey 就会把昨天的分析挂到今天的同一序号上。
        let today = AppState.shadowingAnalysisKey(day: "2026-09-22", drillID: "daily-0-0")
        let yesterday = AppState.shadowingAnalysisKey(day: "2026-09-21", drillID: "daily-0-0")
        XCTAssertNotEqual(today, yesterday)
    }

    // MARK: - 重启后从库里补回分析

    func testRehydrateRebuildsAnalysisFromStoredAttempts() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowing-rehydrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("learning.db").path
        let restore = isolateShadowingProgress()
        defer { restore() }

        let state = makeState(databasePath: dbPath)
        let list = drills()
        let db = try LearningDatabase(path: dbPath)
        // 上次运行读过第 0 句（识别文本与原文差一个词）。
        try await db.appendShadowingAttempt(
            ShadowingAttempt(
                drillID: list[0].id,
                referenceText: list[0].text,
                recognizedText: "This is sentence zero",
                accuracy: ShadowingScorer.compare(
                    reference: list[0].text, recognized: "This is sentence zero"
                ).accuracy
            )
        )

        state.shadowingDrills = list
        XCTAssertNil(state.currentShadowingResult, "刚启动时内存里是空的")
        await state.rehydrateShadowingAnalyses()

        let restored = try XCTUnwrap(state.currentShadowingResult, "重启后要把上次的分析补回来")
        XCTAssertEqual(restored.comparison.recognizedText, "This is sentence zero")
        XCTAssertEqual(
            restored.comparison.accuracy,
            ShadowingScorer.compare(reference: list[0].text, recognized: "This is sentence zero").accuracy,
            accuracy: 0.0001,
            "对比结果由纯函数按「原文 + 当时识别出来的文本」重算，与当时那一遍一致"
        )
        state.shadowingIndex = 1
        XCTAssertNil(state.currentShadowingResult, "第 1 句没读过，仍然没有分析")
    }

    /// 内存里已有的（刚读过的）**不许被库里那条旧的覆盖**。
    func testRehydrateDoesNotOverwriteFresherInMemoryResult() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowing-rehydrate2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("learning.db").path
        let restore = isolateShadowingProgress()
        defer { restore() }

        let state = makeState(databasePath: dbPath)
        let list = drills()
        let db = try LearningDatabase(path: dbPath)
        try await db.appendShadowingAttempt(
            ShadowingAttempt(
                drillID: list[0].id,
                referenceText: list[0].text,
                recognizedText: "old attempt",
                accuracy: 0.1
            )
        )

        state.shadowingDrills = list
        record(state, drill: list[0], recognized: list[0].text)
        await state.rehydrateShadowingAnalyses()

        let current = try XCTUnwrap(state.currentShadowingResult)
        XCTAssertEqual(current.comparison.accuracy, 1.0, accuracy: 0.0001, "刚读的那一遍才是最新的")
    }
}
