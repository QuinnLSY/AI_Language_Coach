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
        XCTAssertEqual(version, LearningDatabase.schemaVersion)    }
}
