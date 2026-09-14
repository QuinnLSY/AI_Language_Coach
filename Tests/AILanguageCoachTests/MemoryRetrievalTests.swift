import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import XCTest

/// 第 15 步 学习记忆检索：
/// - `MemoryRetriever` 纯函数（重复错误归一 / 待复习词 / 弱发音维度）；
/// - `PromptBuilder.learningMemoryBlock` 的渲染与空记忆短路；
/// - `CoachServices.learningMemory()` 从真实库里取原始事实。
@MainActor
final class MemoryRetrievalTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ original: String, _ corrected: String, explanation: String = "", at date: Date) -> CorrectionRecord {
        CorrectionRecord(
            correction: GrammarCorrection(original: original, corrected: corrected, explanation: explanation),
            createdAt: date
        )
    }

    private func vocab(_ word: String, mastery: Int, lastReviewed: Date? = nil) -> VocabularyEntry {
        VocabularyEntry(word: word, mastery: mastery, lastReviewedAt: lastReviewed, createdAt: now)
    }

    private func report(_ scores: [PronunciationDimension: Double]) -> PronunciationReport {
        PronunciationReport(
            referenceText: "How are you today",
            recognizedText: "how are you today",
            overall: 70,
            verdict: .fair,
            lines: scores.map { PronunciationScoreLine(dimension: $0.key, score: $0.value, detail: "测试") },
            metrics: .empty,
            weakest: nil,
            tips: []
        )
    }

    // MARK: - 重复错误

    func testRecurringErrorsGroupsNormalizedDuplicates() {
        // 大小写 / 连续空白不同，但**是同一个错** —— 必须并成一条，否则统计不出「重复」。
        let records = [
            record("i go to school  yesterday", "I went to school yesterday", at: now),
            record("I go to school yesterday", "I went to school yesterday", at: now.addingTimeInterval(-3600)),
        ]
        let errors = MemoryRetriever.recurringErrors(from: records)
        XCTAssertEqual(errors.count, 1, "归一后应只有一条")
        XCTAssertEqual(errors.first?.count, 2)
        XCTAssertEqual(errors.first?.corrected, "I went to school yesterday")
    }

    func testRecurringErrorsRanksByCountThenRecency() {
        let records = [
            record("a apple", "an apple", at: now),
            record("He don't like it", "He doesn't like it", at: now.addingTimeInterval(-10)),
            record("he don't like it", "He doesn't like it", at: now.addingTimeInterval(-20)),
            record("HE DON'T LIKE IT", "He doesn't like it", at: now.addingTimeInterval(-30)),
        ]
        let errors = MemoryRetriever.recurringErrors(from: records)
        XCTAssertEqual(errors.count, 2)
        XCTAssertEqual(errors.first?.count, 3, "出现 3 次的错必须排在前面")
        XCTAssertEqual(errors.first?.corrected, "He doesn't like it")
        XCTAssertEqual(errors.last?.corrected, "an apple")
    }

    func testRecurringErrorsDropsEmptyFields() {
        let records = [record("", "an apple", at: now), record("a apple", "", at: now)]
        XCTAssertTrue(MemoryRetriever.recurringErrors(from: records).isEmpty)
    }

    func testRecurringErrorsRespectsLimit() {
        let records = (0..<8).map { record("wrong \($0)", "right \($0)", at: now.addingTimeInterval(Double($0))) }
        XCTAssertEqual(MemoryRetriever.recurringErrors(from: records, limit: 3).count, 3)
    }

    // MARK: - 待复习词

    func testFocusWordsPicksDueLowMasteryFirst() {
        let vocabulary = [
            vocab("boarding", mastery: 5),            // 已掌握：不在候选
            vocab("alpha", mastery: 2),               // 到期
            vocab("beta", mastery: 0),                // 到期，掌握度更低
        ]
        let words = MemoryRetriever.focusWords(from: vocabulary, limit: 6, now: now)
        XCTAssertEqual(words, ["beta", "alpha"])
    }

    func testFocusWordsFallsBackWhenNothingDue() {
        // 没有到期的词时退回「掌握度最低的未掌握词」，而不是给空。
        let future = now.addingTimeInterval(90 * 86_400)
        let vocabulary = [
            vocab("alpha", mastery: 4, lastReviewed: now),
            vocab("beta", mastery: 1, lastReviewed: now),
        ]
        let words = MemoryRetriever.focusWords(from: vocabulary, limit: 6, now: future.addingTimeInterval(-1))
        XCTAssertEqual(words.first, "beta")
    }

    // MARK: - 弱发音维度

    func testWeakDimensionsAveragesAcrossReports() {
        let reports = [
            report([.fluency: 60, .wordAccuracy: 90]),
            report([.fluency: 70, .wordAccuracy: 80]),
        ]
        let weak = MemoryRetriever.weakDimensions(from: reports, limit: 3)
        XCTAssertEqual(weak.count, 1, "只有 fluency 均值 65 低于阈值")
        XCTAssertEqual(weak.first?.dimension, .fluency)
        XCTAssertEqual(weak.first?.averageScore ?? 0, 65, accuracy: 0.001)
        XCTAssertEqual(weak.first?.sampleCount, 2)
    }

    func testWeakDimensionsEmptyWhenAllStrong() {
        let reports = [report([.fluency: 88, .intonation: 92])]
        XCTAssertTrue(MemoryRetriever.weakDimensions(from: reports).isEmpty)
    }

    // MARK: - 组装

    func testBriefIsEmptyWithoutContent() {
        let memory = MemoryRetriever.brief(corrections: [], vocabulary: [], reports: [], sessionCount: 12)
        XCTAssertTrue(memory.isEmpty, "只有练习次数不算内容")
        XCTAssertEqual(memory.sessionsPracticed, 12)
    }

    // MARK: - Prompt 渲染

    func testLearningMemoryBlockRendersSections() {
        let memory = LearningMemory(
            recurringErrors: [RecurringError(original: "I go to school yesterday", corrected: "I went to school yesterday", explanation: "past tense", count: 3, lastSeen: now)],
            focusWords: ["luggage", "boarding pass"],
            weakDimensions: [WeakDimension(dimension: .fluency, averageScore: 62, sampleCount: 4)],
            sessionsPracticed: 5,
            totalCorrections: 9
        )
        let block = PromptBuilder.learningMemoryBlock(memory, learningLanguage: "English", nativeLanguage: "Chinese")
        XCTAssertTrue(block.contains("Recurring mistakes:"))
        XCTAssertTrue(block.contains("(x3)"))
        XCTAssertTrue(block.contains("luggage"))
        XCTAssertTrue(block.contains("Fluency") || block.contains("流利度"))
        XCTAssertTrue(block.contains("English"), "学习语言占位符应被替换")
        XCTAssertFalse(block.contains("{memory_items}"), "占位符必须被替换干净")
    }

    func testLearningMemoryBlockIsEmptyForEmptyMemory() {
        let block = PromptBuilder.learningMemoryBlock(.empty, learningLanguage: "English", nativeLanguage: "Chinese")
        XCTAssertTrue(block.isEmpty, "空记忆不得追加任何内容（新学员看到的就是干净人设）")
    }

    // MARK: - 从真实库取数

    func testServicesLearningMemoryReadsDatabase() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-probe-\(UUID().uuidString).json")
        )
        let services = CoachServices(config: store, databasePath: ":memory:")
        let opened = await services.learning
        let database = try XCTUnwrap(opened)

        let sessionID = UUID()
        try await database.createSessionIfAbsent(ChatSession(id: sessionID, startedAt: Date()))
        try await database.appendCorrection(
            GrammarCorrection(original: "I have went to London", corrected: "I went to London", explanation: "past tense"),
            sessionID: sessionID
        )
        try await database.appendCorrection(
            GrammarCorrection(original: "i have went  to london", corrected: "I went to London", explanation: ""),
            sessionID: sessionID
        )
        try await database.upsertVocabulary(VocabularyEntry(word: "luggage", mastery: 0))

        let memory = await services.learningMemory()
        XCTAssertEqual(memory.recurringErrors.count, 1, "跨会话的同一处错应并成一条")
        XCTAssertEqual(memory.recurringErrors.first?.count, 2)
        XCTAssertTrue(memory.focusWords.contains("luggage"))
        XCTAssertEqual(memory.sessionsPracticed, 1)
    }

    func testServicesLearningMemoryIsEmptyOnFreshDatabase() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-probe-\(UUID().uuidString).json")
        )
        let services = CoachServices(config: store, databasePath: ":memory:")
        let memory = await services.learningMemory()
        XCTAssertTrue(memory.isEmpty)
    }
}
