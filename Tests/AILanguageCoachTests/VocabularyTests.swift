import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import XCTest

/// 词汇本（第 24 步）：调度纯函数 / 输出解析 / 生词清洗 / 落库与去重。
final class VocabularyTests: XCTestCase {

    // MARK: - ReviewScheduler（复习调度，Plan §24 硬要求：复习逻辑与 UI 分离）

    private func makeEntry(
        word: String = "apple",
        meaning: String = "",
        mastery: Int = 0,
        reviewCount: Int = 0,
        lastReviewedAt: Date? = nil
    ) -> VocabularyEntry {
        VocabularyEntry(word: word, meaning: meaning, mastery: mastery, reviewCount: reviewCount, lastReviewedAt: lastReviewedAt)
    }

    func testNewWordIsAlwaysDue() {
        // 没复习过的新词永远当天到期 —— 否则加了词就再也不会见到第二面。
        XCTAssertTrue(ReviewScheduler.isDue(makeEntry(mastery: 0)))
        // 刚复习完的（掌握度 3 → 间隔 4 天）不该立刻又到期。
        XCTAssertFalse(ReviewScheduler.isDue(makeEntry(mastery: 3, lastReviewedAt: Date())))
    }

    func testMasteredWordIsNeverDue() {
        XCTAssertFalse(ReviewScheduler.isDue(makeEntry(mastery: 5, lastReviewedAt: Date(timeIntervalSinceNow: -100 * 86_400))))
        XCTAssertTrue(makeEntry(mastery: 5).isMastered)
    }

    func testIntervalGrowsWithMastery() throws {
        // 掌握度 1 → 间隔 1 天：刚复习完不到 1 天不该到期。
        let yesterday = Date(timeIntervalSinceNow: -0.5 * 86_400)
        XCTAssertFalse(ReviewScheduler.isDue(makeEntry(mastery: 1, lastReviewedAt: yesterday)))
        // 掌握度 0 → 间隔 0 天：复习完立刻又到期（今天内可反复过）。
        XCTAssertTrue(ReviewScheduler.isDue(makeEntry(mastery: 0, lastReviewedAt: Date())))
        // 掌握度 2 → 间隔 2 天：过了 2 天多才到期。
        let threeDaysAgo = Date(timeIntervalSinceNow: -3 * 86_400)
        XCTAssertTrue(ReviewScheduler.isDue(makeEntry(mastery: 2, lastReviewedAt: threeDaysAgo)))
    }

    func testGradedRememberedRaisesMasteryAndCapsAtFive() {
        let now = Date()
        let up = ReviewScheduler.graded(makeEntry(mastery: 2, reviewCount: 1), .remembered, now: now)
        XCTAssertEqual(up.mastery, 3)
        XCTAssertEqual(up.reviewCount, 2)
        XCTAssertEqual(up.lastReviewedAt, now)

        let capped = ReviewScheduler.graded(makeEntry(mastery: 5), .remembered, now: now)
        XCTAssertEqual(capped.mastery, 5, "掌握度封顶 5")
    }

    func testGradedForgottenLowersMasteryAndFloorsAtZero() {
        let down = ReviewScheduler.graded(makeEntry(mastery: 3), .forgotten)
        XCTAssertEqual(down.mastery, 2)
        XCTAssertEqual(down.reviewCount, 1)
        let floored = ReviewScheduler.graded(makeEntry(mastery: 0), .forgotten)
        XCTAssertEqual(floored.mastery, 0, "保底 0，不为负")
    }

    func testStatsCounts() {
        let now = Date()
        let entries = [
            makeEntry(word: "a", mastery: 5, lastReviewedAt: now),           // 已掌握
            makeEntry(word: "b", mastery: 0, lastReviewedAt: now),           // 到期（间隔 0）
            makeEntry(word: "c", meaning: "苹果", mastery: 3, lastReviewedAt: now), // 未到期
        ]
        let stats = VocabularyStats.from(entries, now: now)
        XCTAssertEqual(stats.total, 3)
        XCTAssertEqual(stats.mastered, 1)
        XCTAssertEqual(stats.due, 1)
        XCTAssertEqual(stats.defined, 1)
        XCTAssertEqual(VocabularyStats.from([]), .empty)
    }

    // MARK: - 输出解析 / 生词清洗（纯函数）

    func testDefineRuleParsesMeaningAndExample() {
        let good = VocabularyDefineRule.parse("苹果||I eat an apple every day.")
        XCTAssertEqual(good?.meaning, "苹果")
        XCTAssertEqual(good?.example, "I eat an apple every day.")
        XCTAssertEqual(good?.keywords, "", "两段格式没有重点单词段，向后兼容")
        // 模型偶尔先客气一句 / 包围栏：取含 || 的那一行。
        let noisy = VocabularyDefineRule.parse("Sure!\n```\n香蕉||Bananas are yellow.\n```")
        XCTAssertEqual(noisy?.meaning, "香蕉")
        XCTAssertEqual(noisy?.example, "Bananas are yellow.")
        // 没有 ||：整行按释义，例句为空。
        let bare = VocabularyDefineRule.parse("橙子")
        XCTAssertEqual(bare?.meaning, "橙子")
        XCTAssertEqual(bare?.example, "")
        XCTAssertNil(VocabularyDefineRule.parse("  "))
    }

    func testDefineRuleParsesKeywordsSection() {
        let parsed = VocabularyDefineRule.parse(
            "指期待某事发生时激动不安的心情（常与 about 连用），多用于口语。||I'm really excited about the trip.||excite (v.) 使兴奋；trip (n.) 旅行"
        )
        XCTAssertEqual(parsed?.meaning, "指期待某事发生时激动不安的心情（常与 about 连用），多用于口语。")
        XCTAssertEqual(parsed?.example, "I'm really excited about the trip.")
        XCTAssertEqual(parsed?.keywords, "excite (v.) 使兴奋；trip (n.) 旅行")
        // 含释义的落库全文要带上「重点单词」行。
        XCTAssertTrue(parsed?.storedMeaning.contains("重点单词：excite (v.) 使兴奋") ?? false)
        // 单个词没有重点单词：`-` 占位 → 清空，落库不追加该行。
        let single = VocabularyDefineRule.parse("详细的中文释义||An example sentence.||-")
        XCTAssertEqual(single?.keywords, "")
        XCTAssertEqual(single?.storedMeaning, "详细的中文释义")
    }

    func testDefineRuleRepairsPlaceholderEcho() {
        // qwen3:8b 实测会把格式行的字段名原样回显、只在中间填内容：
        // 「MEANING||真实的释义||EXAMPLE」→ 字段名段必须剔除，真实释义升位。
        let echo = VocabularyDefineRule.parse("MEANING||Water is a common liquid essential for life.||EXAMPLE")
        XCTAssertEqual(echo?.meaning, "Water is a common liquid essential for life.")
        XCTAssertEqual(echo?.example, "", "EXAMPLE 是字段名回显，不是例句")
        XCTAssertEqual(echo?.keywords, "")
        // 整行纯字段名回显（没有任何真实内容）：拒绝解析。
        XCTAssertNil(VocabularyDefineRule.parse("MEANING||EXAMPLE||KEYWORDS"))
        // 大小写不敏感。
        let mixed = VocabularyDefineRule.parse("meaning||百分比是指百分之一为单位的比率。||-")
        XCTAssertEqual(mixed?.meaning, "百分比是指百分之一为单位的比率。")
    }

    func testSanitizedStoredMeaningCleansLegacyEchoRows() {
        // 历史坏数据（释义=「MEANING」+「重点单词：EXAMPLE」两行垃圾）→ 清完为空，
        // 退回「还没有释义」让用户重新查释义。
        let corrupt = VocabularyDefineRule.sanitizedStoredMeaning("MEANING\n重点单词： EXAMPLE")
        XCTAssertEqual(corrupt, "")
        // 好数据原样保留。
        let good = "详细的中文释义。\n重点单词：boost (v.) 提升"
        XCTAssertEqual(VocabularyDefineRule.sanitizedStoredMeaning(good), good)
        // 坏行剔除但好行保留。
        let partial = VocabularyDefineRule.sanitizedStoredMeaning("MEANING\n真正的释义。")
        XCTAssertEqual(partial, "真正的释义。")
    }

    // MARK: - 每日推荐（Daily Recommendation）

    /// 固定种子随机源：让选词测试可复现。
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func makeBank(easy: Int, medium: Int, hard: Int) -> [DailyWord] {
        var bank: [DailyWord] = []
        for index in 0..<easy { bank.append(DailyWord(word: "easy\(index)", difficulty: 1)) }
        for index in 0..<medium { bank.append(DailyWord(word: "med\(index)", difficulty: 2)) }
        for index in 0..<hard { bank.append(DailyWord(word: "hard\(index)", difficulty: 3)) }
        return bank
    }

    func testDailyPickerFollowsQuota() {
        // 雅思配额：3 简单 / 5 中等 / 2 困难。
        XCTAssertEqual(DailyWordPicker.quota, [1: 3, 2: 5, 3: 2])
        var rng = SeededRNG(state: 42)
        let picked = DailyWordPicker.pick(from: makeBank(easy: 10, medium: 10, hard: 10), using: &rng)
        XCTAssertEqual(picked.count, 10)
        XCTAssertEqual(picked.filter { $0.difficulty == 1 }.count, 3)
        XCTAssertEqual(picked.filter { $0.difficulty == 2 }.count, 5)
        XCTAssertEqual(picked.filter { $0.difficulty == 3 }.count, 2)
        // 同一批内不重复。
        XCTAssertEqual(Set(picked.map(\.word)).count, 10)
    }

    func testDailyPickerExcludesAndToleratesSmallBank() {
        var rng = SeededRNG(state: 7)
        let bank = makeBank(easy: 4, medium: 6, hard: 3)
        let first = DailyWordPicker.pick(from: bank, using: &rng)
        // 刷新时排除上一批：不会再抽到同一批词。
        let second = DailyWordPicker.pick(from: bank, excluding: Set(first.map { $0.word.lowercased() }), using: &rng)
        XCTAssertEqual(Set(first.map(\.word)).intersection(second.map(\.word)), [])
        // 词不够时有多少给多少，不崩。
        let tiny = DailyWordPicker.pick(from: makeBank(easy: 1, medium: 0, hard: 0), using: &rng)
        XCTAssertEqual(tiny.count, 1)
        XCTAssertEqual(tiny.first?.difficulty, 1)
    }

    func testDailyRuleParsesSixSegments() {
        let parsed = VocabularyDailyRule.parse(
            "adj.||巨大的、显著的；强调数量或程度超出一般。||The company made a substantial investment in research.||这家公司在研究上投入了大量资金。||considerable、significant||tiny、negligible"
        )
        XCTAssertEqual(parsed?.pos, "adj.")
        XCTAssertEqual(parsed?.meaning, "巨大的、显著的；强调数量或程度超出一般。")
        XCTAssertEqual(parsed?.example, "The company made a substantial investment in research.")
        XCTAssertEqual(parsed?.exampleTranslation, "这家公司在研究上投入了大量资金。")
        XCTAssertEqual(parsed?.synonyms, ["considerable", "significant"])
        XCTAssertEqual(parsed?.antonyms, ["tiny", "negligible"])

        // `-` 占位：近/反义词、例句都可缺席。
        let minimal = VocabularyDailyRule.parse("n.||某个中文释义。||-||-||-||-")
        XCTAssertEqual(minimal?.example, "")
        XCTAssertEqual(minimal?.synonyms, [])
        XCTAssertEqual(minimal?.antonyms, [])

        // 围栏 + 客套行要跳过；空释义拒绝。
        XCTAssertNil(VocabularyDailyRule.parse("```\nSure!\nadj.||||An example.||-||-||-"))
        XCTAssertNil(VocabularyDailyRule.parse("没有分隔符的一行"))

        // 字段名回显段（POS/MEANING/…）要剔除，真实内容按位升格。
        let echoed = VocabularyDailyRule.parse(
            "POS||大量的、实质性的；强调数量或程度超出一般。||EXAMPLE||EXAMPLE_TRANSLATION||considerable、significant||-"
        )
        XCTAssertEqual(echoed?.pos, "", "POS 是字段名回显")
        XCTAssertEqual(echoed?.meaning, "大量的、实质性的；强调数量或程度超出一般。")
        XCTAssertEqual(echoed?.example, "")
        XCTAssertEqual(echoed?.synonyms, ["considerable", "significant"])
    }

    func testWordBankParseFiltersInvalidAndDuplicates() throws {
        let json = """
        [
          {"word": "  significant ", "difficulty": 2},
          {"word": "significant", "difficulty": 3},
          {"word": "", "difficulty": 1},
          {"difficulty": 1},
          {"word": "echo"},
          {"word": String(repeating: "a", count: 50), "difficulty": 1}
        ]
        """.replacingOccurrences(of: "String(repeating: \"a\", count: 50)", with: "\"" + String(repeating: "a", count: 50) + "\"")
        let parsed = VocabularyWordBank.parse(Data(json.utf8))
        XCTAssertEqual(parsed?.count, 2, "重复 / 空词 / 缺词 / 超长词全部过滤")
        XCTAssertEqual(parsed?.first?.word, "significant")
        XCTAssertEqual(parsed?.first?.difficulty, 2)
        // 缺 difficulty 默认中等档。
        XCTAssertEqual(parsed?.last?.word, "echo")
        XCTAssertEqual(parsed?.last?.difficulty, 2)
        XCTAssertNil(VocabularyWordBank.parse(Data("not json".utf8)))
    }

    func testNormalizeTrimsQuotesAndRejectsLongInput() {
        XCTAssertEqual(VocabularyService.normalize("  apple "), "apple")
        XCTAssertEqual(VocabularyService.normalize("“How come…”"), "How come…")
        XCTAssertEqual(VocabularyService.normalize(""), "")
        XCTAssertEqual(VocabularyService.normalize(String(repeating: "a", count: 50)), "", "超过 48 字符不是「一个词」")
    }

    // MARK: - 落库（schema v7）

    func testUpsertDeduplicatesByWordAndKeepsProgress() async throws {
        let database = try LearningDatabase.inMemory()
        let version = try await database.schemaVersion()
        XCTAssertEqual(version, 7, "词汇表属于 schema v7")

        let first = VocabularyEntry(word: "apple", meaning: "苹果", mastery: 3, reviewCount: 2, source: .review)
        let inserted = try await database.upsertVocabulary(first)
        XCTAssertTrue(inserted)

        // 同词再导入（复盘去重的关键）：不覆盖，保住掌握度与释义。
        let duplicate = VocabularyEntry(word: "apple", meaning: "", source: .review)
        let insertedAgain = try await database.upsertVocabulary(duplicate)
        XCTAssertFalse(insertedAgain, "重复词不应再插入")

        let all = try await database.allVocabulary()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.meaning, "苹果")
        XCTAssertEqual(all.first?.mastery, 3)
        XCTAssertEqual(all.first?.source, .review)
    }

    func testRecordReviewUpdatesAndLogs() async throws {
        let database = try LearningDatabase.inMemory()
        let original = VocabularyEntry(word: "banana", mastery: 1)
        try await database.upsertVocabulary(original)

        let graded = ReviewScheduler.graded(original, .remembered)
        try await database.recordVocabularyReview(graded, remembered: true)

        let all = try await database.allVocabulary()
        XCTAssertEqual(all.first?.mastery, 2)
        XCTAssertEqual(all.first?.reviewCount, 1)
        XCTAssertNotNil(all.first?.lastReviewedAt)
    }

    func testDeleteRemovesEntry() async throws {
        let database = try LearningDatabase.inMemory()
        let entry = VocabularyEntry(word: "cherry")
        try await database.upsertVocabulary(entry)
        try await database.deleteVocabulary(id: entry.id)
        let all = try await database.allVocabulary()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - 服务编排

    func testServiceWithoutDatabaseStaysHarmless() async {
        let llm = LLMManager()
        let service = VocabularyService(llm: llm, learning: nil)
        let entries = await service.entries()
        XCTAssertTrue(entries.isEmpty, "没有数据库时返回空，不崩")
        let added = await service.add(word: "apple")
        XCTAssertNil(added)
    }

    func testServiceImportDeduplicates() async throws {
        let database = try LearningDatabase.inMemory()
        let service = VocabularyService(llm: LLMManager(), learning: database)

        // 两份复盘都提到同一个词 → 只收一条。
        let review1 = SessionReview(sessionID: UUID(), newWords: ["apple", "banana"])
        let review2 = SessionReview(sessionID: UUID(), newWords: ["Apple", "  banana  "])
        try await database.saveReview(review1)
        try await database.saveReview(review2)

        let imported = await service.importFromReviews()
        XCTAssertEqual(imported, 2, "apple/banana 各收一条，重复与空白清洗后不再收")
        let entries = await service.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.word).sorted(), ["Apple", "banana"], "保留原样大小写")
        XCTAssertEqual(entries.map(\.source), [.review, .review])
    }
}
