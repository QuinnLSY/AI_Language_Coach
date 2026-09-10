import AIDomain
import AIInfrastructure
import AIInterfaces
import AIProviders
import AIServices
import AppCore
import XCTest

/// 练习复盘（学习记忆）：JSON 解析容错、规则兜底、落库往返、Mock 全链路。
final class SessionReviewTests: XCTestCase {

    // MARK: 解析容错

    func testParseAcceptsFencedAndNoisyJSON() {
        let raw = """
        <think>让我看看这段对话…</think>
        Sure! Here is the review:
        ```json
        {"headline":"敢开口，时态还要再练","new_words":["by the way","I mean"],
         "strengths":["主动提问"],"improvements":["第三人称单数"],"suggestion":"复习 be 动词"}
        ```
        """
        let parsed = SessionReviewService.parse(raw)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.headline, "敢开口，时态还要再练")
        XCTAssertEqual(parsed?.newWords, ["by the way", "I mean"])
        XCTAssertEqual(parsed?.suggestion, "复习 be 动词")
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(SessionReviewService.parse("I cannot help with that."))
        XCTAssertNil(SessionReviewService.parse(""))
        // 空对象没有信息量，视为解析失败（走兜底）
        XCTAssertNil(SessionReviewService.parse("{}"))
    }

    func testParseToleratesMissingFields() {
        let parsed = SessionReviewService.parse(#"{"headline":"很棒"}"#)
        XCTAssertEqual(parsed?.headline, "很棒")
        XCTAssertTrue(parsed?.newWords.isEmpty == true)
    }

    // MARK: 规则兜底

    func testHeuristicUsesOnlyRecordedFacts() {
        var base = SessionReview(sessionID: UUID(), duration: 120, messageCount: 6, correctionCount: 2)
        base = SessionReviewService.heuristic(from: base, corrections: [
            GrammarCorrection(original: "he go", corrected: "he goes", explanation: "三单"),
            GrammarCorrection(original: "I am agree", corrected: "I agree", explanation: ""),
        ])
        XCTAssertEqual(base.source, .heuristic)
        XCTAssertTrue(base.headline.contains("6"))
        XCTAssertTrue(base.headline.contains("2"))
        XCTAssertEqual(base.improvements.count, 2)
        XCTAssertTrue(base.improvements[0].contains("三单"))
        XCTAssertTrue(base.improvements[1].contains("I agree"))
        XCTAssertFalse(base.suggestion.isEmpty)

        // 无纠错时给正向反馈，不编造问题
        let clean = SessionReviewService.heuristic(
            from: SessionReview(sessionID: UUID(), messageCount: 3, correctionCount: 0),
            corrections: []
        )
        XCTAssertTrue(clean.improvements.isEmpty)
        XCTAssertFalse(clean.strengths.isEmpty)
    }

    func testEmptySessionHeuristicIsGentle() {
        let review = SessionReviewService.heuristic(
            from: SessionReview(sessionID: UUID(), messageCount: 0, correctionCount: 0),
            corrections: []
        )
        XCTAssertTrue(review.headline.contains("还没开始"))
    }

    // MARK: 落库

    func testReviewRoundTripsThroughDatabase() async throws {
        let db = try LearningDatabase.inMemory()
        let sessionID = UUID()
        var review = SessionReview(
            sessionID: sessionID,
            duration: 200,
            messageCount: 8,
            correctionCount: 1,
            headline: "进步很明显",
            newWords: ["actually", "by the way"],
            strengths: ["敢说长句"],
            improvements: ["介词"],
            suggestion: "再练一次",
            source: .llm
        )
        try await db.saveReview(review)

        let loaded = try await db.review(sessionID: sessionID)
        XCTAssertEqual(loaded?.headline, "进步很明显")
        XCTAssertEqual(loaded?.newWords, ["actually", "by the way"])
        XCTAssertEqual(loaded?.improvements, ["介词"])
        XCTAssertEqual(loaded?.source, .llm)
        XCTAssertEqual(loaded?.durationText, "3 分 20 秒")

        // 同会话再写一份：保留最新
        review.headline = "第二次复盘"
        review.createdAt = Date().addingTimeInterval(60)
        try await db.saveReview(review)
        let latest = try await db.review(sessionID: sessionID)
        let recent = try await db.recentReviews(limit: 5)
        XCTAssertEqual(latest?.headline, "第二次复盘")
        XCTAssertEqual(recent.count, 1)
    }

    // MARK: 全链路（Mock LLM，不依赖真实模型）

    func testServiceUsesMockLLMAndPersistsReview() async throws {
        let db = try LearningDatabase.inMemory()
        let llm = LLMManager()
        let mock = MockLLMProvider(scriptedResponse: """
        {"headline":"敢开口","new_words":["actually"],"strengths":["主动提问"],
         "improvements":["时态"],"suggestion":"复习 be 动词"}
        """)
        try await mock.initialize(config: ProviderConfig(id: "mock.llm", kind: .llm, enabled: true, runtime: .mock))
        await llm.register(mock)
        let service = SessionReviewService(llm: llm, learning: db)

        let sessionID = UUID()
        let messages = [
            ChatMessage(role: .user, content: "I go to park yesterday"),
            ChatMessage(role: .assistant, content: "Almost! Say 'I went to the park yesterday'."),
        ]
        let corrections = [GrammarCorrection(original: "I go", corrected: "I went", explanation: "过去式")]
        let review = await service.makeReview(
            sessionID: sessionID,
            messages: messages,
            corrections: corrections,
            duration: 90,
            options: SessionReviewService.ReviewOptions(learningLanguage: "en-US", nativeLanguage: "zh-CN")
        )
        XCTAssertEqual(review.source, .llm)
        XCTAssertEqual(review.headline, "敢开口")
        XCTAssertEqual(review.messageCount, 1, "只统计学员发言")
        XCTAssertEqual(review.correctionCount, 1)

        let stored = try await db.review(sessionID: sessionID)
        XCTAssertEqual(stored?.headline, "敢开口")
    }

    func testServiceFallsBackWhenModelUnavailable() async throws {
        let db = try LearningDatabase.inMemory()
        // 未注册 Provider：generate 抛错 → 走规则兜底，仍要落库
        let service = SessionReviewService(llm: LLMManager(), learning: db)
        let sessionID = UUID()
        let review = await service.makeReview(
            sessionID: sessionID,
            messages: [ChatMessage(role: .user, content: "hello")],
            corrections: [GrammarCorrection(original: "a", corrected: "b", explanation: "说明")],
            duration: 30,
            options: SessionReviewService.ReviewOptions()
        )
        XCTAssertEqual(review.source, .heuristic)
        let stored = try await db.review(sessionID: sessionID)
        XCTAssertEqual(stored?.source, .heuristic)
    }

    // MARK: 入参拼装

    func testUserPayloadIncludesTranscriptAndCorrections() {
        let payload = SessionReviewService.userPayload(
            messages: [
                ChatMessage(role: .user, content: "I likes apple"),
                ChatMessage(role: .assistant, content: "Close! 'I like apples'."),
            ],
            corrections: [GrammarCorrection(original: "I likes", corrected: "I like", explanation: "三单")],
            duration: 60
        )
        XCTAssertTrue(payload.contains("Practice length: 60 seconds."))
        XCTAssertTrue(payload.contains("Learner: I likes apple"))
        XCTAssertTrue(payload.contains("Coach: Close!"))
        XCTAssertTrue(payload.contains("- I likes => I like (三单)"))
    }
}
