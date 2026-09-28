import AIDomain
import AIInfrastructure
import AIServices
@testable import AppUI
import XCTest

/// 跟读逐句分析**不许跨天冒充**（#331）。
///
/// 用户报障：昨天读过的分析今天还挂在句子上，匹配率还是昨天那个数。
/// 根因：记录与素材之间只有 `drill_id` 相连，而那个 id 是
/// `daily-<主题序号>-<句内序号>` —— **只跟位置有关、与内容无关**。
/// 换一天主题轮换，同一批 id 换了一批全新的句子，于是昨天的识别文本被拿去对
/// 今天的参考句算匹配率，发音分也是昨天那一次的。
///
/// 这一组先钉判据（纯函数），再钉真链路（`AppState.loadTodayShadowingDrills` → 补回内存）。
final class ShadowingAnalysisAdoptionTests: XCTestCase {

    private func drill(id: String, text: String) -> ShadowingDrill {
        ShadowingDrill(id: id, text: text, translation: "释义", topic: "机场值机", difficulty: 3)
    }

    private func attempt(
        drillID: String, reference: String, recognized: String, daysAgo: Int = 0
    ) -> ShadowingAttempt {
        let created = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return ShadowingAttempt(
            drillID: drillID, referenceText: reference, recognizedText: recognized,
            accuracy: 0.9, createdAt: created
        )
    }

    private var today: String { ShadowingDailyRule.dayKey() }
    private var yesterday: String {
        let date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return ShadowingDailyRule.dayKey(date)
    }

    // MARK: - 判据

    func testSameDayAndSameSentenceIsAdopted() {
        let day = today
        let sentence = drill(id: "daily-0-0", text: "Could I get a window seat?")
        let record = attempt(
            drillID: "daily-0-0", reference: "Could I get a window seat?", recognized: "Could I get a window seat"
        )
        XCTAssertTrue(ShadowingAnalysisAdoption.adopts(record, for: sentence, dayKey: day))
    }

    /// 跟读这件事**按天算**：哪怕昨天读的**就是同一句**（内容一字不差），也不算今天读过。
    ///
    /// ⚠️ 这条是「同一天」判据**唯一**能被单独证伪的地方 —— 别的夹具里昨天那条连参考文本
    /// 都对不上，把参考文本判据撤掉它照样红，于是两条判据谁在起作用就分不出来了
    /// （#326 吃过同一个亏：两个机制共用一个用例 = 假绿）。
    /// 为什么同一句也不能认：那一份分析里的识别文本与发音分都属于**昨天那次练习**，
    /// 今天的句子列表拿它当「这一句已经读过」，用户会以为自己今天读过了（而且昨天的分算今天的）。
    func testTheSameSentenceFromAnotherDayIsStillRefused() {
        let day = today
        let sentence = drill(id: "daily-0-0", text: "Could I get a window seat?")
        let sameTextYesterday = attempt(
            drillID: "daily-0-0",
            reference: "Could I get a window seat?",
            recognized: "could i get a window seat",
            daysAgo: 1
        )
        XCTAssertEqual(
            ShadowingAnalysisAdoption.normalized(sameTextYesterday.referenceText),
            ShadowingAnalysisAdoption.normalized(sentence.text),
            "夹具：这一条的参考文本与今天这一句一字不差"
        )
        XCTAssertFalse(
            ShadowingAnalysisAdoption.adopts(sameTextYesterday, for: sentence, dayKey: day),
            "跨天一律不认 —— 跟读的进度、发音分、识别文本都是按天算的"
        )
    }

    /// 病根就在这一条：**同一个 id、不同的句子**（今天这一句是新的）。
    func testYesterdaysRecordIsRefusedEvenThoughTheIDMatches() {
        let day = today
        let sentence = drill(id: "daily-0-0", text: "Could I get a window seat?")
        let yesterdays = attempt(
            drillID: "daily-0-0",
            reference: "Yesterday the flight was delayed.",
            recognized: "yesterday the flight was delayed",
            daysAgo: 1
        )
        XCTAssertFalse(
            ShadowingAnalysisAdoption.adopts(yesterdays, for: sentence, dayKey: day),
            "换天会重用同一批 drill_id —— 只按 id 认，昨天的成绩就挂在今天的句子上了"
        )
        // 顺带钉住「那天确实是昨天」：夹具没造错，红是真的红。
        XCTAssertEqual(ShadowingDailyRule.dayKey(yesterdays.createdAt), yesterday)
    }

    /// 同一天里点了「换一批」：id 一个都没变，句子全换了。
    func testTodayButDifferentSentenceIsRefused() {
        let day = today
        let sentence = drill(id: "daily-1-2", text: "Please fasten your seatbelt.")
        let regenerated = attempt(
            drillID: "daily-1-2",
            reference: "The gate has changed to B12.",
            recognized: "the gate has changed to b twelve"
        )
        XCTAssertFalse(
            ShadowingAnalysisAdoption.adopts(regenerated, for: sentence, dayKey: day),
            "同一天换过一批句子之后，id 没变但内容变了 —— 也不许认"
        )
    }

    /// 多打的空格 / 大小写差异不该让用户白重读一遍。
    func testWhitespaceAndCaseDifferencesAreTolerated() {
        let day = today
        let sentence = drill(id: "daily-0-0", text: "Where is the check-in counter?")
        let record = attempt(
            drillID: "daily-0-0",
            reference: "  Where  is the   CHECK-IN counter? ",
            recognized: "where is the check in counter"
        )
        XCTAssertTrue(
            ShadowingAnalysisAdoption.adopts(record, for: sentence, dayKey: day),
            "只是空格与大小写不同，是同一句"
        )
    }

    /// 但**不能再往下归一**：标点/词形不同就是不同的话。
    /// 归一过头会把这次要修的病重新放进来（换个说法也算同一句）。
    func testDifferentWordingIsNotTolerated() {
        let day = today
        let sentence = drill(id: "daily-0-0", text: "Where is the check-in counter?")
        let other = attempt(
            drillID: "daily-0-0",
            reference: "Where is the check in counter",
            recognized: "where is the check in counter"
        )
        XCTAssertFalse(
            ShadowingAnalysisAdoption.adopts(other, for: sentence, dayKey: day),
            "标点也是内容的一部分：这里放行等于把「差不多就算同一句」的口子留着"
        )
    }

    func testNormalizationOnlyCollapsesWhitespaceAndCase() {
        XCTAssertEqual(
            ShadowingAnalysisAdoption.normalized("  A   b\nC "), "a b c"
        )
        XCTAssertEqual(ShadowingAnalysisAdoption.normalized(""), "")
    }
}

// MARK: - 真链路：补回内存时也要过这一关

/// `rehydrateShadowingAnalyses` 走的是**真库 + 真缓存**：
/// 昨天的记录必须被丢掉，今天的才补回来。
@MainActor
final class ShadowingRehydrateTests: XCTestCase {

    /// ⚠️ 不用 `setUp/tearDown`（非隔离上下文，碰主 actor 属性会刷屏警告）——
    /// 每个用例自己 `defer` 收尾。
    private func isolateShadowingProgress() -> () -> Void {
        let key = AppState.shadowingProgressStorageKey
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private struct Fixture {
        var state: AppState
        var directory: URL
    }

    /// 今天的素材一共四句（**id 与内容无关**：`daily-<主题>-<序号>`）。
    private let todaysSentences = [
        "Could I get a window seat?",
        "Please fasten your seatbelt.",
        "Is there a power outlet near my seat?",
        "Do I need to show my passport?",
    ]

    /// 今天第二句那次的识别文本：**故意漏一个词**，这样重算出来的匹配率一定不是满分
    /// （库里的 `accuracy` 字段是 0.94，页面读的是重算值 —— 两者不等才说明它真的在对今天这句话）。
    private static let todaysTranscript = "please fasten seatbelt"

    /// 造一份「今天已经有句子」的 AppState：
    /// - 缓存里是今天这三句（→ 走缓存命中那条路，不碰模型）；
    /// - 库里三条记录：`daily-0-0` 是**昨天的**、`daily-0-1` 是今天的、
    ///   `daily-0-2` 是今天但**参考文本不同**（同一批 id，内容换过）。
    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadowing-rehydrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let databasePath = directory.appendingPathComponent("learning.db").path
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let db = try LearningDatabase(path: databasePath)
        try await db.appendShadowingAttempt(
            ShadowingAttempt(
                drillID: "daily-0-0", referenceText: "Yesterday the flight was delayed.",
                recognizedText: "yesterday the flight was delayed",
                accuracy: 0.62,
                pronunciation: Self.samplePronunciation,
                createdAt: yesterday
            )
        )
        try await db.appendShadowingAttempt(
            ShadowingAttempt(
                drillID: "daily-0-1", referenceText: todaysSentences[1],
                recognizedText: Self.todaysTranscript, accuracy: 0.94, createdAt: Date()
            )
        )
        try await db.appendShadowingAttempt(
            ShadowingAttempt(
                drillID: "daily-0-2", referenceText: "The gate has changed to B12.",
                recognizedText: "the gate has changed to b twelve",
                accuracy: 0.31, createdAt: Date()
            )
        )
        // 第四句：**昨天读的、而且内容与今天这一句一字不差** ——
        // 这条只靠「参考文本一致」是拦不住的，专门用来单独证「同一天」那道判据。
        try await db.appendShadowingAttempt(
            ShadowingAttempt(
                drillID: "daily-0-3", referenceText: todaysSentences[3],
                recognizedText: "do i need to show my passport",
                accuracy: 0.88, createdAt: yesterday
            )
        )

        let store = ShadowingDailyStore(fileURL: directory.appendingPathComponent("shadowing-daily.json"))
        await store.save(
            day: ShadowingDailyRule.dayKey(),
            language: "en-US",
            drills: todaysSentences.enumerated().map { index, text in
                ShadowingDrill(id: "daily-0-\(index)", text: text, translation: "释义 \(index)")
            }
        )

        let config = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        let state = AppState(services: CoachServices(
            config: config, databasePath: databasePath, shadowingDailyStore: store
        ))
        return Fixture(state: state, directory: directory)
    }

    /// 一条发音报告（用它验「发音分也不会跨天被借用」）。
    private static let samplePronunciation = PronunciationReport(
        referenceText: "Yesterday the flight was delayed.",
        recognizedText: "yesterday the flight was delayed",
        overall: 55,
        verdict: .needsWork,
        lines: [],
        metrics: .empty,
        weakest: nil,
        tips: [],
        phonemeSource: .none
    )

    private func tearDown(_ fixture: Fixture, restore: @escaping () -> Void) {
        restore()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    func testRehydrateDropsYesterdaysAnalysisAndKeepsTodays() async throws {
        let restore = isolateShadowingProgress()
        let fixture = try await makeFixture()
        defer { tearDown(fixture, restore: restore) }
        let state = fixture.state

        await state.loadTodayShadowingDrills()

        XCTAssertEqual(state.shadowingDrills.count, 4, "夹具：今天这四句来自缓存（不碰模型）")
        XCTAssertEqual(state.shadowingIndex, 0)

        // ① 第一句只有**昨天**的记录（同一个 id、不同的句子）→ 当作「还没读过」。
        XCTAssertNil(
            state.currentShadowingResult,
            "昨天的记录不许安到今天这一句上 —— 这正是用户报障的那一条"
        )
        XCTAssertNil(state.shadowingComparison, "匹配率也不许是昨天的")
        XCTAssertNil(state.shadowingPronunciation, "发音分同样不许借用昨天的")

        // ② 第二句今天读过 → 补回来，而且匹配率是拿**今天的**参考句与**那一次的**识别文本
        //    重算出来的（不是库里那个 0.94 字段，也不是别的句子那一份）。
        state.nextShadowingDrill()
        let today = try XCTUnwrap(state.currentShadowingResult, "今天的记录应当补回内存")
        let expected = ShadowingScorer.compare(
            reference: todaysSentences[1], recognized: Self.todaysTranscript
        ).accuracy
        XCTAssertEqual(
            today.comparison.accuracy, expected, accuracy: 0.0001,
            "页面上的匹配率 = 今天这句参考句 vs 那一次的识别文本"
        )
        XCTAssertLessThan(today.comparison.accuracy, 1, "漏了一个词就不该是满分")
        XCTAssertEqual(
            state.shadowingComparison?.accuracy ?? -1, today.comparison.accuracy, accuracy: 0.0001,
            "页面上读的就是这一份"
        )

        // ③ 第三句是**今天**写的，但参考文本与今天这一句对不上（同一天换过一批）→ 同样不认。
        state.nextShadowingDrill()
        XCTAssertNil(
            state.currentShadowingResult,
            "同一天换过一批句子之后，id 不变但内容变了 —— 也算「这一句还没读过」"
        )

        // ④ 第四句：昨天读的、**内容与今天这一句一字不差**。
        //    参考文本判据拦不住它，能拦住它的只有「同一天」那一道（两条判据各自独立）。
        state.nextShadowingDrill()
        XCTAssertNil(
            state.currentShadowingResult,
            "同一句话但那是**昨天**读的：识别文本与发音分都属于昨天那次练习，不许当今天的"
        )
    }

    /// 最后一句读过的分析不许**借着下一次换句**留在界面上。
    func testSwitchingToASentenceWithoutTodayAnalysisClearsTheScreen() async throws {
        let restore = isolateShadowingProgress()
        let fixture = try await makeFixture()
        defer { tearDown(fixture, restore: restore) }
        let state = fixture.state

        await state.loadTodayShadowingDrills()
        state.nextShadowingDrill()
        XCTAssertNotNil(state.currentShadowingResult, "先落到今天读过的那一句上做基准")
        state.nextShadowingDrill()

        XCTAssertNil(
            state.currentShadowingResult,
            "换到没有今日分析的句子，界面必须跟着清空 —— 留着就是「上一句的结果挂在下一句上」"
        )
    }
}
