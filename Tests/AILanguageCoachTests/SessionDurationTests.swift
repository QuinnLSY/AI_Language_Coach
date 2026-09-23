import AIDomain
import AIInfrastructure
import AppCore
import XCTest

/// 「练习时长」的口径回归。
///
/// 真机报障（2026-09-23）：学习记录里**每一条**最近练习的时长都是 0，
/// 而同一条展开后的复盘卡里却明明白白写着「37 分 35 秒」。
///
/// 两个各自独立的原因，都在这组用例里钉住：
/// 1. 开始时刻取了「会话行落盘那一刻」（一个延迟 Task 里的 `Date()`），
///    库里实测有它比末条消息还晚 5–6 秒的行 → 跨度为负 → 被夹成 0。
/// 2. 复盘之后流水（消息）会被删掉，删完之后「结束时刻」只能退回开始时刻
///    → 跨度归零，而复盘行里存的 `duration` 还好好的。
final class SessionDurationTests: XCTestCase {

    private func makeDB() throws -> LearningDatabase {
        try LearningDatabase.inMemory()
    }

    private let start = Date(timeIntervalSince1970: 1_772_000_000)

    /// 场景 1（历史坏数据）：会话行比首条消息晚落盘。
    ///
    /// 反证：把 `startedExpression` 换回 `started_at` → 跨度为 −6 秒 → 夹成 0 → 本用例变红。
    func testDurationComesFromMessageSpanNotFromRowCreationMoment() async throws {
        let db = try makeDB()
        let id = UUID()
        let last = start.addingTimeInterval(174)

        // ⚠️ 故意让会话行的时刻**晚于**末条消息 6 秒 —— 库里实测就是这个形状
        // （`D4341083…` / `D7BB801F…` / `8517689B…` / `ABE0C85C…` 都是 −5 ~ −6 秒）。
        try await db.createSessionIfAbsent(
            ChatSession(
                id: id,
                startedAt: last.addingTimeInterval(6),
                mode: .conversation,
                scenarioID: nil
            )
        )
        try await db.appendMessage(
            ChatMessage(role: .user, content: "Hi teacher", createdAt: start),
            sessionID: id
        )
        try await db.appendMessage(
            ChatMessage(role: .assistant, content: "Hello! Ready?", createdAt: last),
            sessionID: id
        )

        // ⚠️ `await` 不能写在 `XCTUnwrap` 的 autoclosure 里，先取出再解包。
        let loaded = try await db.sessionSummary(id: id)
        let summary = try XCTUnwrap(loaded)
        XCTAssertEqual(summary.startedAt, start, "开始时刻应取首条消息的时间，而不是会话行落盘的那一刻")
        XCTAssertEqual(summary.endedAt, last, "结束时刻应取末条消息的时间")
        XCTAssertEqual(
            summary.endedAt.timeIntervalSince(summary.startedAt), 174, accuracy: 0.001,
            "这一段是 174 秒，不该因为会话行落盘晚了几秒就变成 0"
        )
        // 列表页读的是另一条查询，口径必须一致（`最近练习` 走 `recentSessions`）。
        let rows = try await db.recentSessions(limit: 5)
        let listed = try XCTUnwrap(rows.first)
        XCTAssertEqual(listed.sessionID, id)
        XCTAssertEqual(listed.endedAt.timeIntervalSince(listed.startedAt), 174, accuracy: 0.001)
    }

    /// 场景 2（用户截图那一条）：复盘之后流水被删，时长必须活下来。
    ///
    /// 反证：删掉 `purgeSessionMessages` 里那句封存 UPDATE → 跨度归零 → 本用例变红。
    func testDurationSurvivesPurgingTheFlow() async throws {
        let db = try makeDB()
        let id = UUID()
        let end = start.addingTimeInterval(2255.4)   // 37 分 35 秒
        try await db.createSessionIfAbsent(
            ChatSession(id: id, startedAt: start, mode: .conversation, scenarioID: nil)
        )
        try await db.appendMessage(
            ChatMessage(role: .user, content: "Hi teacher", createdAt: start),
            sessionID: id
        )
        try await db.appendMessage(
            ChatMessage(role: .assistant, content: "Hello! Ready?", createdAt: end),
            sessionID: id
        )
        // 复盘行里存着真实的对话时长（用户看到的那一行「37 分 35 秒」就是它）。
        try await db.saveReview(
            SessionReview(
                sessionID: id,
                createdAt: end,
                duration: 2255.4,
                messageCount: 2,
                headline: "聊得不错"
            )
        )

        let purged = try await db.purgeSessionMessages(sessionID: id)
        XCTAssertEqual(purged, 2, "流水应被删掉")
        let remaining = try await db.messageCount(sessionID: id)
        XCTAssertEqual(remaining, 0)

        let loaded = try await db.sessionSummary(id: id)
        let summary = try XCTUnwrap(loaded)
        // 任务#1 起条数兜底到复盘快照：库里现存 0、复盘里记着 2 ⇒ 展示 2。
        // （用户报障的正是这里显示 0 ——「已复盘却写 0 条对话」。）
        XCTAssertEqual(summary.messageCount, 2, "流水删了，但复盘快照里的条数要兜底")
        XCTAssertEqual(
            summary.endedAt.timeIntervalSince(summary.startedAt), 2255.4, accuracy: 1,
            "删流水不能把时长一起删掉 —— 卡片与复盘卡必须说同一件事"
        )
    }

    /// 场景 3（已经坏掉、消息早就没了的老数据）：靠复盘里记的时长还原。
    ///
    /// 反证：去掉 `endedExpression` 里的复盘兜底 → 跨度 0 → 本用例变红。
    func testHistoricalRowWithoutMessagesRecoversDurationFromReview() async throws {
        let db = try makeDB()
        let id = UUID()
        try await db.createSessionIfAbsent(
            ChatSession(id: id, startedAt: start, mode: .conversation, scenarioID: nil)
        )
        // 没有任何消息（= 已经清过流水的老数据），`ended_at` 也是 NULL。
        try await db.saveReview(
            SessionReview(sessionID: id, createdAt: start, duration: 2255.4, messageCount: 20)
        )

        let loaded = try await db.sessionSummary(id: id)
        let summary = try XCTUnwrap(loaded)
        XCTAssertEqual(
            summary.endedAt.timeIntervalSince(summary.startedAt), 2255.4, accuracy: 0.001,
            "复盘里记着 2255.4 秒，卡片就该显示 2255.4 秒"
        )
    }

    /// 场景 2 的第二半（**只有封存能过**）：复盘被清除之后，时长仍然在。
    ///
    /// 「清除学习记忆」删的是纠错 / 复盘 / 跟读 / 复习流水，`sessions` 行留着。
    /// 所以已清流水的会话**不能靠复盘兜底**（那条路已经断了）——
    /// 唯一能救它的是删流水那一刻冻在 `started_at` / `ended_at` 上的两个值。
    ///
    /// 反证：删掉封存 UPDATE → 跨度 0 → 本用例变红（而 `testDurationSurvivesPurgingTheFlow` 仍绿，
    /// 因为它还能吃到复盘兜底 —— 两条路必须各有一条用例盯着）。
    func testDurationSurvivesAfterLearningMemoryIsCleared() async throws {
        let db = try makeDB()
        let id = UUID()
        let end = start.addingTimeInterval(2255.4)
        try await db.createSessionIfAbsent(
            ChatSession(id: id, startedAt: start, mode: .conversation, scenarioID: nil)
        )
        try await db.appendMessage(
            ChatMessage(role: .user, content: "Hi teacher", createdAt: start),
            sessionID: id
        )
        try await db.appendMessage(
            ChatMessage(role: .assistant, content: "Hello! Ready?", createdAt: end),
            sessionID: id
        )
        try await db.saveReview(
            SessionReview(sessionID: id, createdAt: end, duration: 2255.4, messageCount: 2)
        )
        _ = try await db.purgeSessionMessages(sessionID: id)

        // 学员随后点了「清除学习记忆」：复盘行被删，会话行还在。
        let cleared = try await db.clearLearningMemory()
        XCTAssertEqual(cleared.reviews, 1, "复盘应当被清掉")

        let loaded = try await db.sessionSummary(id: id)
        let summary = try XCTUnwrap(loaded)
        XCTAssertEqual(
            summary.endedAt.timeIntervalSince(summary.startedAt), 2255.4, accuracy: 1,
            "复盘没了、流水也早清了，时长还得靠封存下来的两个时刻撑着"
        )
    }

    /// 反面：既没消息、也没复盘 → 依然是 0。兜底不能凭空捏造时长。
    func testEmptySessionWithoutReviewStillReportsZero() async throws {
        let db = try makeDB()
        let id = UUID()
        try await db.createSessionIfAbsent(
            ChatSession(id: id, startedAt: start, mode: .conversation, scenarioID: nil)
        )
        let loaded = try await db.sessionSummary(id: id)
        let summary = try XCTUnwrap(loaded)
        XCTAssertEqual(summary.endedAt, summary.startedAt, "没有练习痕迹就是零跨度")
    }
}
