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
