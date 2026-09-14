import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 第 22 步 跟读（Shadowing）单测：
/// 覆盖素材解析容错、目录加载、逐词对齐、判定分档、统计、落库与页面接线。
/// **不依赖任何真实模型 / 麦克风 / runtime**。
final class ShadowingTests: XCTestCase {

    // MARK: - 素材解析容错

    func testDrillDecodesDefaultsAndClampsDifficulty() throws {
        let json = #"{ "id": "d1", "text": "Hello there.", "difficulty": 9 }"#
        let drill = try JSONDecoder().decode(ShadowingDrill.self, from: Data(json.utf8))
        XCTAssertEqual(drill.id, "d1")
        XCTAssertEqual(drill.text, "Hello there.")
        XCTAssertEqual(drill.translation, "", "缺 translation 用空串")
        XCTAssertEqual(drill.topic, "")
        XCTAssertEqual(drill.focus, "")
        XCTAssertEqual(drill.difficulty, 5, "难度越界应夹取到 5")

        XCTAssertEqual(ShadowingDrill.clamp(0), 1)
        XCTAssertEqual(ShadowingDrill.clamp(3), 3)
    }

    func testDrillRejectsMissingRequiredFields() {
        // 没有参考句的素材是坏数据：必须显式报错，不得静默兜底。
        XCTAssertThrowsError(try JSONDecoder().decode(ShadowingDrill.self, from: Data(#"{ "id": "x" }"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ShadowingDrill.self, from: Data(#"{ "text": "no id" }"#.utf8)))
    }

    // MARK: - 归一化与逐词对齐

    func testWordsLowercasesStripsPunctuationAndKeepsInnerMarks() {
        XCTAssertEqual(ShadowingScorer.words("Good morning, Lin!"), ["good", "morning", "lin"])
        XCTAssertEqual(ShadowingScorer.words("  I'd  like   a latte  "), ["i'd", "like", "a", "latte"],
                       "缩略与连字符词必须保留为一个词，拆开会凭空抬高匹配率")
        XCTAssertEqual(ShadowingScorer.words("check-in at gate 12"), ["check-in", "at", "gate", "12"])
        XCTAssertEqual(ShadowingScorer.words("..."), [])
    }

    func testPerfectShadowingScoresFull() {
        let comparison = ShadowingScorer.compare(
            reference: "Nice to meet you.",
            recognized: "nice to meet you"
        )
        XCTAssertEqual(comparison.accuracy, 1.0, accuracy: 0.0001)
        XCTAssertEqual(comparison.verdict, .perfect)
        XCTAssertEqual(comparison.matched, 4)
        XCTAssertEqual(comparison.referenceCount, 4)
        XCTAssertTrue(comparison.missedWords.isEmpty)
        XCTAssertFalse(comparison.tokens.contains { $0.status != .matched })
    }

    func testMissingWordsReduceAccuracyAndAreNamed() {
        let comparison = ShadowingScorer.compare(
            reference: "I would like a large latte please",
            recognized: "I like a latte please"
        )
        // 参考 7 词，学员漏掉 would / large → 命中 5 词
        XCTAssertEqual(comparison.matched, 5)
        XCTAssertEqual(comparison.referenceCount, 7)
        XCTAssertEqual(comparison.accuracy, 5.0 / 7.0, accuracy: 0.0001)
        XCTAssertEqual(comparison.verdict, .keepGoing)
        XCTAssertEqual(Set(comparison.missedWords), ["would", "large"])
        XCTAssertTrue(comparison.hint.contains("would") || comparison.hint.contains("large"),
                      "反馈必须点名漏掉的词，而不是只说「继续加油」")
        XCTAssertEqual(comparison.tokens.filter { $0.status == .missing }.count, 2)
    }

    func testExtraWordsDoNotReduceAccuracyButAreVisible() {
        let comparison = ShadowingScorer.compare(
            reference: "I like coffee",
            recognized: "I really like coffee"
        )
        XCTAssertEqual(comparison.accuracy, 1.0, accuracy: 0.0001, "多说词不该扣分")
        XCTAssertEqual(comparison.tokens.filter { $0.status == .extra }.map(\.word), ["really"])
    }

    func testSilentAttemptScoresZeroWithActionableHint() {
        let comparison = ShadowingScorer.compare(reference: "How are you today?", recognized: "")
        XCTAssertEqual(comparison.accuracy, 0)
        XCTAssertEqual(comparison.verdict, .retry)
        XCTAssertEqual(comparison.matched, 0)
        XCTAssertEqual(comparison.missedWords, ["how", "are", "you", "today"])
        XCTAssertTrue(comparison.hint.contains("麦克风"), "没听到声音要给可操作提示")
    }

    func testEmptyReferenceDoesNotCrash() {
        let comparison = ShadowingScorer.compare(reference: "!!!", recognized: "anything")
        XCTAssertEqual(comparison.accuracy, 0)
        XCTAssertEqual(comparison.referenceCount, 0)
        XCTAssertTrue(comparison.tokens.isEmpty)
        XCTAssertEqual(comparison.verdict, .retry)
    }

    func testVerdictThresholds() {
        XCTAssertEqual(ShadowingScorer.verdict(for: 1.0), .perfect)
        XCTAssertEqual(ShadowingScorer.verdict(for: 0.95), .perfect)
        XCTAssertEqual(ShadowingScorer.verdict(for: 0.94), .great)
        XCTAssertEqual(ShadowingScorer.verdict(for: 0.85), .great)
        XCTAssertEqual(ShadowingScorer.verdict(for: 0.84), .keepGoing)
        XCTAssertEqual(ShadowingScorer.verdict(for: 0.6), .keepGoing)
        XCTAssertEqual(ShadowingScorer.verdict(for: 0.59), .retry)
        XCTAssertEqual(Set(ShadowingVerdict.allCases.map(\.displayName)).count, 4, "四档文案必须互不相同")
    }

    func testAccuracyPercentRounds() {
        let comparison = ShadowingScorer.compare(reference: "one two three", recognized: "one two")
        XCTAssertEqual(comparison.accuracyPercent, 67)
    }

    // MARK: - 统计 / 记录

    func testStatsFromAttempts() {
        var attempts = [
            attempt(accuracy: 0.9, minutesAgo: 0),
            attempt(accuracy: 0.5, minutesAgo: 5),
            attempt(accuracy: 0.7, minutesAgo: 10),
        ]
        let stats = ShadowingStats.from(attempts) // 约定新 → 旧
        XCTAssertEqual(stats.attempts, 3)
        XCTAssertEqual(stats.bestAccuracy, 0.9, accuracy: 0.0001)
        XCTAssertEqual(stats.averageAccuracy, 0.7, accuracy: 0.0001)
        XCTAssertEqual(stats.lastAccuracy ?? -1, 0.9, accuracy: 0.0001)
        XCTAssertNil(stats.bestPronunciation, "没有发音报告时不该编出一个分数")
        XCTAssertEqual(ShadowingStats.from([]), .empty)

        // 带发音报告的记录：只有带报告的行才计入发音统计。
        attempts[0].pronunciation = report(overall: 88)
        attempts[1].pronunciation = report(overall: 72)
        let withPronunciation = ShadowingStats.from(attempts)
        XCTAssertEqual(withPronunciation.bestPronunciation ?? 0, 88, accuracy: 0.0001)
        XCTAssertEqual(withPronunciation.averagePronunciation ?? 0, 80, accuracy: 0.0001)
    }

    func testAttemptClampsAccuracy() {
        XCTAssertEqual(attempt(accuracy: 1.7).accuracy, 1.0)
        XCTAssertEqual(attempt(accuracy: -2).accuracy, 0)
    }

    // MARK: - 目录加载

    func testCatalogLoadsBothFormatsSkipsBrokenAndDeduplicates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-shadowing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 1) 带 version 的文件格式，难度 3
        try write(#"{ "version": 1, "drills": [ { "id": "b", "text": "B line", "topic": "Z", "difficulty": 3 } ] }"#,
                  to: directory, name: "b.json")
        // 2) 裸数组格式，难度 1 → 应排在最前
        try write(#"[ { "id": "a", "text": "A line", "topic": "Z", "difficulty": 1 } ]"#,
                  to: directory, name: "a.json")
        // 3) 同 id 重复：保留先出现的（文件名排序 a.json 在前）
        try write(#"[ { "id": "a", "text": "A dup", "difficulty": 5 } ]"#, to: directory, name: "a_dup.json")
        // 4) 坏文件：只跳过它
        try write("{ not json", to: directory, name: "c_broken.json")
        // 5) 非 json 忽略
        try write("hello", to: directory, name: "readme.txt")

        let loaded = ShadowingCatalog.load(from: directory)
        XCTAssertEqual(loaded.map(\.id), ["a", "b"], "按难度升序、同 id 去重、坏文件跳过")
        XCTAssertEqual(loaded.first?.text, "A line")
    }

    func testCatalogMissingDirectoryIsEmptyNotCrash() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-shadowing-none-\(UUID().uuidString)")
        XCTAssertTrue(ShadowingCatalog.load(from: missing).isEmpty)
    }

    func testGroupedKeepsFirstAppearanceOrder() {
        let drills = [
            ShadowingDrill(id: "1", text: "one", topic: "日常", difficulty: 1),
            ShadowingDrill(id: "2", text: "two", topic: "机场", difficulty: 2),
            ShadowingDrill(id: "3", text: "three", topic: "日常", difficulty: 3),
            ShadowingDrill(id: "4", text: "four", difficulty: 1),
        ]
        let groups = ShadowingCatalog.grouped(drills)
        XCTAssertEqual(groups.map(\.topic), ["日常", "机场", "其他"])
        XCTAssertEqual(groups[0].items.map(\.id), ["1", "3"])
        XCTAssertEqual(groups[2].items.map(\.id), ["4"], "没写主题的素材归到「其他」")
    }

    func testBundledDrillsAreUsable() {
        let drills = ShadowingCatalog.bundled()
        XCTAssertFalse(drills.isEmpty, "内置跟读素材不应为空（Resources/Shadowing/*.json）")
        XCTAssertEqual(Set(drills.map(\.id)).count, drills.count, "素材 id 必须唯一")
        for drill in drills {
            XCTAssertFalse(drill.text.isEmpty, "\(drill.id) 缺参考句")
            XCTAssertFalse(drill.translation.isEmpty, "\(drill.id) 缺中文释义，跟读前看不懂就只是鹦鹉学舌")
            XCTAssertFalse(drill.topic.isEmpty, "\(drill.id) 缺主题，无法分组")
            XCTAssertTrue((1...5).contains(drill.difficulty), "\(drill.id) 难度越界")
        }
        XCTAssertEqual(drills.map(\.difficulty), drills.map(\.difficulty).sorted(), "素材按难度升序")
    }

    // MARK: - 落库（schema v6）

    func testDatabaseStoresAndReturnsAttemptsNewestFirst() async throws {
        let database = try LearningDatabase.inMemory()
        let version = try await database.schemaVersion()
        // 「至少 v7」才是这条测试真正要的：发音评测列属于 v6+、词汇表 v7。
        // 写死等号会让下一次迁移无谓地把它打红。
        XCTAssertGreaterThanOrEqual(version, 7, "发音评测列属于 schema v6+，词汇表 v7")

        let older = attempt(accuracy: 0.4, minutesAgo: 30)
        var newer = attempt(accuracy: 0.8, minutesAgo: 0)
        newer.pronunciation = report(overall: 76)
        try await database.appendShadowingAttempt(older)
        try await database.appendShadowingAttempt(newer)

        let loaded = try await database.recentShadowingAttempts(limit: 10)
        XCTAssertEqual(loaded.map(\.id), [newer.id, older.id], "最近记录在前")
        XCTAssertEqual(loaded.first?.referenceText, newer.referenceText)
        XCTAssertEqual(loaded.first?.accuracy ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(loaded.first?.pronunciation?.overall ?? 0, 76, accuracy: 0.0001, "发音报告应随行往返")
        XCTAssertNil(loaded.last?.pronunciation, "旧行没有报告")
        let limited = try await database.recentShadowingAttempts(limit: 1)
        XCTAssertEqual(limited.count, 1)
    }

    // MARK: - 服务编排（无麦克风 / 无模型）

    func testServiceEvaluatesAndPersists() async throws {
        let database = try LearningDatabase.inMemory()
        let service = ShadowingService(voice: VoiceService(), learning: database)
        let drills = await service.drills()
        let drill = try XCTUnwrap(drills.first)

        let result = await service.evaluate(drill: drill, recognized: drill.text)
        XCTAssertEqual(result.comparison.accuracy, 1.0, accuracy: 0.0001, "照读原文应当满分")
        XCTAssertNil(result.pronunciation, "没有录到音频时不算发音，不硬编分数")

        let stats = await service.stats()
        XCTAssertEqual(stats.attempts, 1)
        XCTAssertEqual(stats.bestAccuracy, 1.0, accuracy: 0.0001)

        let saved = await service.recentAttempts()
        XCTAssertEqual(saved.first?.drillID, drill.id)
        XCTAssertEqual(saved.first?.recognizedText, drill.text)
    }

    func testServiceWithoutDatabaseStillEvaluates() async throws {
        let service = ShadowingService(voice: VoiceService(), learning: nil)
        let drill = ShadowingDrill(id: "x", text: "Hello there, friend")
        let result = await service.evaluate(drill: drill, recognized: "Hello there")
        XCTAssertEqual(result.comparison.accuracy, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertNil(result.pronunciation)
        let attempts = await service.recentAttempts()
        XCTAssertTrue(attempts.isEmpty, "没有数据库时只评测不落库，不崩")
        let stats = await service.stats()
        XCTAssertEqual(stats, .empty)
    }

    // MARK: - 页面接线

    @MainActor
    func testOpenShadowingLoadsDrillsAndPreviewDoesNotPersist() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-shadowing-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = ConfigStore(fileURL: fileURL)
        let services = CoachServices(config: store, databasePath: ":memory:")
        let state = AppState(services: services)

        await state.openShadowing()
        XCTAssertTrue(state.showingShadowing)
        XCTAssertFalse(state.showingRecords, "两个页面互斥")
        XCTAssertFalse(state.shadowingDrills.isEmpty)
        XCTAssertNotNil(state.currentShadowingDrill)
        XCTAssertEqual(state.shadowingStats.attempts, 0)

        await state.previewShadowingResult("totally different words here")
        XCTAssertNotNil(state.shadowingComparison)
        XCTAssertNotNil(state.shadowingPronunciation, "预览用演示波形驱动同一条发音链路")
        XCTAssertEqual(state.shadowingStats.attempts, 0, "预览走纯函数，不写库")

        let first = state.currentShadowingDrill?.id
        state.nextShadowingDrill()
        XCTAssertNotEqual(state.currentShadowingDrill?.id, first, "换一句应真的换")
        XCTAssertNil(state.shadowingComparison, "换句后清掉上一句的结果")
    }

    // MARK: - 工具

    private func attempt(accuracy: Double, minutesAgo: Double = 0) -> ShadowingAttempt {
        ShadowingAttempt(
            drillID: "d",
            referenceText: "I like coffee",
            recognizedText: "I like coffee",
            accuracy: accuracy,
            createdAt: Date().addingTimeInterval(-minutesAgo * 60)
        )
    }

    /// 最小可用的发音报告（评测逻辑本身由 PronunciationTests 覆盖）。
    private func report(overall: Double) -> PronunciationReport {
        PronunciationReport(
            referenceText: "I like coffee",
            recognizedText: "I like coffee",
            overall: overall,
            verdict: PronunciationScorer.verdict(for: overall),
            lines: [],
            metrics: .empty,
            weakest: nil,
            tips: []
        )
    }

    private func write(_ content: String, to directory: URL, name: String) throws {
        try content.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
