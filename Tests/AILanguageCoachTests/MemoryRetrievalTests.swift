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

    // MARK: - 话题与趋势（计划 §19 的 conversation topics / difficulty history）

    func testRecentTopicsAreDeduplicatedNewestFirst() {
        let facts = [
            MemorySessionFact(startedAt: now, topic: "问路"),
            MemorySessionFact(startedAt: now.addingTimeInterval(-100), topic: "点咖啡"),
            MemorySessionFact(startedAt: now.addingTimeInterval(-200), topic: "问路"),
            MemorySessionFact(startedAt: now.addingTimeInterval(-300), topic: "   "),
            MemorySessionFact(startedAt: now.addingTimeInterval(-400)),
        ]
        XCTAssertEqual(MemoryRetriever.recentTopics(from: facts), ["问路", "点咖啡"],
                       "话题按新→旧去重，空白话题与无话题都不算话题")
    }

    func testSessionWithoutScenarioProducesNoTopic() {
        let facts = [MemorySessionFact(startedAt: now, topic: nil, correctionCount: 2, messageCount: 4)]
        let memory = MemoryRetriever.brief(
            corrections: [], vocabulary: [], reports: [], sessionCount: 1, sessionFacts: facts
        )
        XCTAssertTrue(memory.recentTopics.isEmpty, "没绑情景就不编话题 —— 编出来的会让老师以为学员在练什么")
    }

    func testPracticeTrendIsUnknownWithTooFewSessions() {
        let facts = (0..<3).map {
            MemorySessionFact(startedAt: now.addingTimeInterval(Double(-$0) * 100),
                              correctionCount: 3, messageCount: 6)
        }
        let trend = MemoryRetriever.practiceTrend(from: facts)
        XCTAssertEqual(trend.direction, .unknown)
        XCTAssertNil(trend.recentRate, "样本不足不该给出数字 —— 数字会让人误以为有结论")
    }

    func testPracticeTrendDetectsImprovement() {
        // 新 → 旧：最近两次每轮 0.1 次纠错，更早两次每轮 0.5 次。
        let facts = [
            MemorySessionFact(startedAt: now, correctionCount: 1, messageCount: 10),
            MemorySessionFact(startedAt: now.addingTimeInterval(-100), correctionCount: 1, messageCount: 10),
            MemorySessionFact(startedAt: now.addingTimeInterval(-200), correctionCount: 5, messageCount: 10),
            MemorySessionFact(startedAt: now.addingTimeInterval(-300), correctionCount: 5, messageCount: 10),
        ]
        let trend = MemoryRetriever.practiceTrend(from: facts)
        XCTAssertEqual(trend.direction, .improving)
        XCTAssertEqual(trend.recentRate ?? -1, 0.1, accuracy: 1e-6)
        XCTAssertEqual(trend.earlierRate ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(trend.sessionCount, 4)
    }

    func testPracticeTrendDetectsSlipping() {
        let facts = [
            MemorySessionFact(startedAt: now, correctionCount: 5, messageCount: 10),
            MemorySessionFact(startedAt: now.addingTimeInterval(-100), correctionCount: 5, messageCount: 10),
            MemorySessionFact(startedAt: now.addingTimeInterval(-200), correctionCount: 1, messageCount: 10),
            MemorySessionFact(startedAt: now.addingTimeInterval(-300), correctionCount: 1, messageCount: 10),
        ]
        XCTAssertEqual(MemoryRetriever.practiceTrend(from: facts).direction, .slipping)
    }

    func testPracticeTrendIgnoresSessionsWithUnknownTurnCount() {
        // 名义 4 次会话，其中 2 次轮数为 0（算不出密度）→ 可用样本 2 < 4。
        let facts = [
            MemorySessionFact(startedAt: now, correctionCount: 1),
            MemorySessionFact(startedAt: now.addingTimeInterval(-100), correctionCount: 1),
            MemorySessionFact(startedAt: now.addingTimeInterval(-200), correctionCount: 5, messageCount: 10),
            MemorySessionFact(startedAt: now.addingTimeInterval(-300), correctionCount: 5, messageCount: 10),
        ]
        XCTAssertEqual(MemoryRetriever.practiceTrend(from: facts).direction, .unknown,
                       "轮数未知的会话不能硬算 —— 那等于把 0 当分母")
    }

    func testMemoryBlockRendersTopicsAndTrend() {
        var memory = LearningMemory(recentTopics: ["点咖啡", "问路"])
        memory.practiceTrend = PracticeTrend(direction: .slipping, recentRate: 0.5,
                                             earlierRate: 0.2, sessionCount: 6)
        let block = PromptBuilder.learningMemoryBlock(memory, learningLanguage: "English", nativeLanguage: "中文")
        XCTAssertTrue(block.contains("Recently practised"))
        XCTAssertTrue(block.contains("点咖啡"))
        XCTAssertTrue(block.contains("Recent trend"))
    }

    func testMemoryBlockOmitsTrendWhenUnknown() {
        let memory = LearningMemory(recentTopics: ["问路"])
        let block = PromptBuilder.learningMemoryBlock(memory, learningLanguage: "English", nativeLanguage: "中文")
        XCTAssertTrue(block.contains("Recently practised"))
        XCTAssertFalse(block.contains("Recent trend"), "趋势未知就别给老师一行空话，那会诱导它自己编一个")
    }

    // MARK: - 清除记忆（不可逆，范围必须窄）

    func testClearLearningMemoryKeepsVocabularyAndSessions() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-clear-\(UUID().uuidString).json")
        )
        let services = CoachServices(config: store, databasePath: ":memory:")
        let opened = await services.learning
        let database = try XCTUnwrap(opened)

        let sessionID = UUID()
        try await database.createSessionIfAbsent(ChatSession(id: sessionID, startedAt: Date()))
        try await database.appendCorrection(
            GrammarCorrection(original: "I have went", corrected: "I went", explanation: "past tense"),
            sessionID: sessionID
        )
        try await database.upsertVocabulary(VocabularyEntry(word: "luggage", mastery: 0))

        let before = await services.learningMemory()
        XCTAssertFalse(before.recurringErrors.isEmpty, "前置条件：清之前确实有记忆")

        let cleared = try await services.clearLearningMemory()
        XCTAssertGreaterThanOrEqual(cleared.corrections, 1)
        XCTAssertEqual(cleared.total, cleared.corrections + cleared.reviews
                       + cleared.shadowing + cleared.vocabularyReviews)

        let after = await services.learningMemory()
        XCTAssertTrue(after.recurringErrors.isEmpty, "纠错记录应已清掉")
        XCTAssertTrue(after.focusWords.contains("luggage"), "单词本不在清除范围内")
        let sessions = await services.recentSessions(limit: 10)
        XCTAssertEqual(sessions.count, 1, "对话记录不在清除范围内")
    }

    // MARK: - 单条记忆可控（#595：忘了一条 / 改了一条）

    /// 造一个带两条「反复犯的错」的服务实例。
    private func makeServicesWithErrors() async throws -> (CoachServices, LearningDatabase) {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-edit-\(UUID().uuidString).json")
        )
        let services = CoachServices(config: store, databasePath: ":memory:")
        let opened = await services.learning
        let database = try XCTUnwrap(opened)

        let sessionID = UUID()
        try await database.createSessionIfAbsent(ChatSession(id: sessionID, startedAt: Date()))
        // 同一处错三条（归一后同指纹）+ 另一处错一条。
        try await database.appendCorrection(
            GrammarCorrection(original: "He go home.", corrected: "He goes home.", explanation: "三单"),
            sessionID: sessionID
        )
        try await database.appendCorrection(
            GrammarCorrection(original: "he go home", corrected: "He goes home", explanation: ""),
            sessionID: sessionID
        )
        try await database.appendCorrection(
            GrammarCorrection(original: "I have went there", corrected: "I went there", explanation: "过去式"),
            sessionID: sessionID
        )
        return (services, database)
    }

    func testForgetRecurringErrorRemovesTheWholeBucket() async throws {
        let (services, _) = try await makeServicesWithErrors()

        let before = await services.learningMemory()
        let target = try XCTUnwrap(before.recurringErrors.first { $0.count == 2 })

        let deleted = try await services.forgetRecurringError(target)
        XCTAssertEqual(deleted, 2, "三条同指纹记录必须一起忘掉")

        let after = await services.learningMemory()
        XCTAssertEqual(after.recurringErrors.count, 1, "只剩另一处不同的错")
        XCTAssertEqual(after.recurringErrors.first?.corrected, "I went there")
    }

    func testEditRecurringErrorUpdatesTheWholeBucket() async throws {
        let (services, database) = try await makeServicesWithErrors()

        let before = await services.learningMemory()
        let target = try XCTUnwrap(before.recurringErrors.first { $0.count == 2 })

        let updated = try await services.editRecurringError(
            target, corrected: "He went home", explanation: "昨天的事用过去式"
        )
        XCTAssertEqual(updated, 2)

        let after = await services.learningMemory()
        XCTAssertEqual(after.recurringErrors.count, 2, "改完仍是两处独立的错（原句不同）")
        let edited = try XCTUnwrap(after.recurringErrors.first { $0.corrected == "He went home" })
        XCTAssertEqual(edited.count, 2, "次数不丢：两条记录仍并成一处")
        XCTAssertEqual(edited.explanation, "昨天的事用过去式")

        // 原句在库里原样保留。
        let originals = try await database.correctionRecords(since: .distantPast)
            .filter { $0.correction.corrected == "He went home" }
            .map(\.correction.original)
        XCTAssertEqual(Set(originals), ["He go home.", "he go home"])
    }

    func testEditRecurringErrorRejectsEmptyCorrection() async throws {
        let (services, _) = try await makeServicesWithErrors()
        let before = await services.learningMemory()
        let target = try XCTUnwrap(before.recurringErrors.first { $0.count == 2 })

        do {
            _ = try await services.editRecurringError(target, corrected: "  ", explanation: "")
            XCTFail("改正为空必须被挡住（那是删不是改）")
        } catch {
            XCTAssertEqual(error as? AppError, .database("改正后的句子不能为空。"))
        }
        let after = await services.learningMemory()
        XCTAssertEqual(after.recurringErrors.count, 2, "被挡下的编辑不许改变记忆")
    }

    func testForgetRecurringErrorOnNothingChangesNothing() async throws {
        let (services, _) = try await makeServicesWithErrors()
        let before = await services.learningMemory()
        let target = try XCTUnwrap(before.recurringErrors.first { $0.count == 2 })

        // 一条不在库里的「错」：0 条，且其余记忆原样。
        let ghost = RecurringError(original: "She don't like it", corrected: "She doesn't like it",
                                   explanation: "", count: 9, lastSeen: now)
        let deleted = try await services.forgetRecurringError(ghost)
        XCTAssertEqual(deleted, 0)

        let after = await services.learningMemory()
        XCTAssertEqual(after.recurringErrors.count, before.recurringErrors.count)
        XCTAssertEqual(after.recurringErrors.first?.count, target.count)
    }
}
