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

    // MARK: - 情景落库（schema v4：sessions.scenario_id）

    func testSessionScenarioRoundtrip() async throws {
        let db = try makeDB()
        let session = ChatSession()
        try await db.createSession(session)
        let initialScenario = try await db.sessionScenarioID(id: session.id)
        XCTAssertNil(initialScenario, "新建会话默认不是情景练习")

        try await db.setSessionScenario(id: session.id, scenarioID: "restaurant", mode: .conversation, startedAt: session.startedAt)
        try await db.appendMessage(ChatMessage(role: .user, content: "A table for two"), sessionID: session.id)

        let rawLatest = try await db.latestSession()
        let latest = try XCTUnwrap(rawLatest)
        XCTAssertEqual(latest.session.scenarioID, "restaurant", "重启后应能读回情景，继续上课")
        XCTAssertEqual(latest.messages.count, 1)

        let summaries = try await db.recentSessions(limit: 5)
        XCTAssertEqual(summaries.first?.scenarioID, "restaurant", "学习记录页需要展示情景")
        let summary = try await db.sessionSummary(id: session.id)
        XCTAssertEqual(summary?.scenarioID, "restaurant")
    }

    func testSessionScenarioCanBeCleared() async throws {
        let db = try makeDB()
        let session = ChatSession(scenarioID: "restaurant")
        try await db.createSession(session)
        try await db.setSessionScenario(id: session.id, scenarioID: nil, mode: .conversation, startedAt: session.startedAt)
        let cleared = try await db.sessionScenarioID(id: session.id)
        XCTAssertNil(cleared, "退出情景后应清空绑定")
    }

    /// 启动时不得建空会话：否则「最近会话」永远是新行，上次练习恢复不回来。
    func testCreateSessionIfAbsentKeepsMessageCount() async throws {
        let db = try makeDB()
        let session = ChatSession()
        try await db.createSessionIfAbsent(session)
        try await db.appendMessage(ChatMessage(role: .user, content: "hi"), sessionID: session.id)

        // 再次登记（例如重启后再次发消息）不得把会话重置为空
        try await db.createSessionIfAbsent(session)
        let count = try await db.messageCount(sessionID: session.id)
        XCTAssertEqual(count, 1, "重复登记不得清零 message_count")

        // 情景绑定走 UPSERT：行不存在时也能落库
        let fresh = ChatSession()
        try await db.setSessionScenario(id: fresh.id, scenarioID: "shopping", mode: .conversation, startedAt: fresh.startedAt)
        let boundScenario = try await db.sessionScenarioID(id: fresh.id)
        XCTAssertEqual(boundScenario, "shopping")
    }

    func testSchemaVersionIsSix() async throws {
        let db = try makeDB()
        let version = try await db.schemaVersion()
        XCTAssertEqual(version, 6)
    }

    /// 迁移：旧版本每次启动都会建空会话，导致「最近会话」恢复不回来 —— v4 迁移要清掉它们。
    func testMigrationRemovesLegacyEmptySessions() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let legacy = try SQLiteDatabase(path: url.path)
        try legacy.run("""
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL,
            mode TEXT NOT NULL, message_count INTEGER NOT NULL DEFAULT 0
        )
        """)
        try legacy.run("""
        CREATE TABLE messages (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
            content TEXT NOT NULL, created_at REAL NOT NULL, reasoning TEXT
        )
        """)
        let empty = ChatSession(startedAt: Date(timeIntervalSinceNow: -60))
        let used = ChatSession(startedAt: Date(timeIntervalSinceNow: -30))
        try legacy.run(
            "INSERT INTO sessions (id, started_at, mode, message_count) VALUES (?1, ?2, 'conversation', 0)",
            [.text(empty.id.uuidString), .real(empty.startedAt.timeIntervalSince1970)]
        )
        try legacy.run(
            "INSERT INTO sessions (id, started_at, mode, message_count) VALUES (?1, ?2, 'conversation', 1)",
            [.text(used.id.uuidString), .real(used.startedAt.timeIntervalSince1970)]
        )
        try legacy.setSchemaVersion(3)
        legacy.close()

        // 重新打开 → 迁移到最新版：遗留空会话被清掉，真会话保留
        let db = try LearningDatabase(path: url.path)
        let sessions = try await db.recentSessions(limit: 10)
        XCTAssertEqual(sessions.count, 1, "空会话是历史包袱，应在迁移时清掉")
        XCTAssertEqual(sessions.first?.sessionID, used.id)
        let version = try await db.schemaVersion()
        XCTAssertEqual(version, 6)
    }

    /// 迁移：v4 旧库升级到 v5/v6 时必须补上跟读记录表（旧库根本没有这张表，
    /// 不补的话点「跟读」写记录会静默失败）。
    func testMigrationAddsShadowingTable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-v4-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let legacy = try SQLiteDatabase(path: url.path)
        try legacy.run("""
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL,
            mode TEXT NOT NULL, message_count INTEGER NOT NULL DEFAULT 0
        )
        """)
        try legacy.setSchemaVersion(4)
        legacy.close()

        let db = try LearningDatabase(path: url.path)
        let version = try await db.schemaVersion()
        XCTAssertEqual(version, 6)

        try await db.appendShadowingAttempt(ShadowingAttempt(
            drillID: "d", referenceText: "a b c", recognizedText: "a b", accuracy: 2.0 / 3.0
        ))
        let loaded = try await db.recentShadowingAttempts(limit: 5)
        XCTAssertEqual(loaded.count, 1, "升级后应能写入并读回跟读记录")
        XCTAssertEqual(loaded.first?.drillID, "d")
    }
}
