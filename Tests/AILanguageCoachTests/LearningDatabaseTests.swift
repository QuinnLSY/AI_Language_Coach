import AIDomain
import AIInfrastructure
import AppCore
import XCTest

/// 学习数据库：进度读写 / 会话消息 / 迁移，全部走内存库，不依赖外部 runtime。
final class LearningDatabaseTests: XCTestCase {

    private func makeDB() throws -> LearningDatabase {
        try LearningDatabase.inMemory()
    }

    func testProgressRoundtrip() async throws {
        let db = try makeDB()

        let initial = try await db.loadProgress()
        XCTAssertNil(initial, "空库不应有进度记录")

        var progress = LearnerProgress.seed()
        progress.levels[3].state = .completed
        progress.levels[3].earnedStars = 4
        progress.levels[4].state = .unlocked
        progress.recalculateSummary()
        try await db.saveProgress(progress)

        let loaded = try await db.loadProgress()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, progress, "进度读写应完整往返")
        XCTAssertEqual(loaded?.totalStars, 14, "种子 12 星 + 蜂鸟花丛补满 2 星")
    }

    func testProgressReplace() async throws {
        let db = try makeDB()
        try await db.saveProgress(.seed())
        var updated = LearnerProgress.seed()
        updated.levels[0].earnedStars = 0
        updated.levels[0].state = .inProgress
        updated.recalculateSummary()
        try await db.saveProgress(updated)

        let loaded = try await db.loadProgress()
        XCTAssertEqual(loaded, updated, "重复保存应全量替换而非追加")
    }

    func testSessionAndMessages() async throws {
        let db = try makeDB()
        let session = ChatSession(mode: .conversation)
        try await db.createSession(session)

        let user = ChatMessage(role: .user, content: "hello")
        let coach = ChatMessage(role: .assistant, content: "Hi! How are you?")
        try await db.appendMessage(user, sessionID: session.id)
        try await db.appendMessage(coach, sessionID: session.id)
        try await db.finishSession(id: session.id)

        let count = try await db.messageCount(sessionID: session.id)
        XCTAssertEqual(count, 2)

        let sessions = try await db.recentSessions(limit: 10)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.messageCount, 2)
        XCTAssertEqual(sessions.first?.sessionID, session.id)
    }

    func testMessageCountIncremental() async throws {
        let db = try makeDB()
        let session = ChatSession()
        try await db.createSession(session)
        for index in 0..<5 {
            try await db.appendMessage(
                ChatMessage(role: index % 2 == 0 ? .user : .assistant, content: "m\(index)"),
                sessionID: session.id
            )
        }
        let count = try await db.messageCount(sessionID: session.id)
        XCTAssertEqual(count, 5, "message_count 应随插入累加")
    }

    func testSchemaVersionStable() async throws {
        let db = try makeDB()
        let version = try await db.schemaVersion()
        XCTAssertEqual(version, LearningDatabase.schemaVersion)
    }

    // MARK: - 纠错（学习记忆）

    func testCorrectionsRoundtrip() async throws {
        let db = try makeDB()
        let session = ChatSession()
        try await db.createSession(session)

        let fix = GrammarCorrection(original: "I go to school yesterday", corrected: "I went to school yesterday", explanation: "昨天的事用过去式")
        try await db.appendCorrection(fix, sessionID: session.id)

        let loaded = try await db.corrections(sessionID: session.id)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.original, fix.original)
        XCTAssertEqual(loaded.first?.corrected, fix.corrected)
        XCTAssertEqual(loaded.first?.explanation, fix.explanation)

        let recent = try await db.recentCorrections(limit: 10)
        XCTAssertEqual(recent.count, 1)
    }

    func testSessionSummaryIncludesCorrections() async throws {
        let db = try makeDB()
        let session = ChatSession()
        try await db.createSession(session)
        try await db.appendMessage(ChatMessage(role: .user, content: "She don't like it"), sessionID: session.id)
        try await db.appendCorrection(
            GrammarCorrection(original: "She don't like it", corrected: "She doesn't like it", explanation: "三单"),
            sessionID: session.id
        )
        try await db.finishSession(id: session.id)

        let summary = try await db.sessionSummary(id: session.id)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.messageCount, 1)
        XCTAssertEqual(summary?.corrections.count, 1)
        XCTAssertEqual(summary?.corrections.first?.corrected, "She doesn't like it")
    }

    func testPurgeSessionsKeepsCorrections() async throws {
        let db = try makeDB()
        let old = ChatSession(startedAt: Date(timeIntervalSinceNow: -40 * 86_400))
        try await db.createSession(old)
        try await db.appendMessage(ChatMessage(role: .user, content: "old"), sessionID: old.id)
        try await db.appendCorrection(
            GrammarCorrection(original: "a old book", corrected: "an old book", explanation: "冠词"),
            sessionID: old.id
        )
        try await db.finishSession(id: old.id, endedAt: Date(timeIntervalSinceNow: -39 * 86_400))

        try await db.purgeSessionsOlderThan(days: 30)

        let sessions = try await db.recentSessions(limit: 10)
        XCTAssertTrue(sessions.isEmpty, "旧会话应被清理（归档哨兵不进会话列表）")
        let recent = try await db.recentCorrections(limit: 10)
        XCTAssertEqual(recent.count, 1, "纠错本体是学习记忆，清理会话时必须保留")
    }
}
