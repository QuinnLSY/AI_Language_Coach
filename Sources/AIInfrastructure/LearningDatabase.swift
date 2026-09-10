import AIDomain
import AppCore
import Foundation

/// 学习数据库（SQLite，V1 schema）。
///
/// 职责：闯关进度、练习会话与消息的本地持久化。**只被 AIServices 访问**，UI 不得直接使用。
public actor LearningDatabase {

    private let db: SQLiteDatabase

    /// v2：messages 增加 reasoning 列（推理模型思考过程持久化）。
    /// v3：新增 session_reviews（练习复盘）。
    /// v4：sessions 增加 scenario_id 列（情景练习落库，重启后能接着练）。
    public static let schemaVersion = 4

    /// 测试用内存库。
    public static func inMemory() throws -> LearningDatabase {
        try LearningDatabase(path: ":memory:")
    }

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try migrate()
        try hygiene()
    }

    /// 默认库位置：项目空间 `.workbuddy/app-config/learning.db`。
    public static func defaultURL() -> URL {
        AppPaths.userDataDirectory().appendingPathComponent("learning.db")
    }

    // MARK: - 迁移

    private nonisolated func migrate() throws {
        let version = try db.schemaVersion()
        guard version < Self.schemaVersion else { return }

        try db.run("""
        CREATE TABLE IF NOT EXISTS levels (
            id TEXT PRIMARY KEY,
            sort_order INTEGER NOT NULL,
            title TEXT NOT NULL,
            subtitle TEXT NOT NULL,
            height_fraction REAL NOT NULL,
            branch TEXT NOT NULL,
            state TEXT NOT NULL,
            required_stars INTEGER NOT NULL,
            earned_stars INTEGER NOT NULL
        )
        """)

        try db.run("""
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            started_at REAL NOT NULL,
            ended_at REAL,
            mode TEXT NOT NULL,
            message_count INTEGER NOT NULL DEFAULT 0
        )
        """)

        try db.run("""
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at REAL NOT NULL,
            reasoning TEXT
        )
        """)
        try db.run("CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id)")

        try db.run("""
        CREATE TABLE IF NOT EXISTS corrections (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            original TEXT NOT NULL,
            corrected TEXT NOT NULL,
            explanation TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """)

        // v1 → v2：给已存在的 messages 表补 reasoning 列（列已存在时报错属预期，忽略）。
        try? db.run("ALTER TABLE messages ADD COLUMN reasoning TEXT")

        // v2 → v3：练习复盘（学习记忆）。
        try db.run("""
        CREATE TABLE IF NOT EXISTS session_reviews (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            duration REAL NOT NULL DEFAULT 0,
            message_count INTEGER NOT NULL DEFAULT 0,
            correction_count INTEGER NOT NULL DEFAULT 0,
            headline TEXT NOT NULL DEFAULT '',
            new_words TEXT NOT NULL DEFAULT '[]',
            strengths TEXT NOT NULL DEFAULT '[]',
            improvements TEXT NOT NULL DEFAULT '[]',
            suggestion TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT 'llm'
        )
        """)
        try db.run("CREATE INDEX IF NOT EXISTS idx_reviews_session ON session_reviews(session_id)")

        // v3 → v4：sessions 表补 scenario_id 列（已存在时报错属预期，忽略）。
        try? db.run("ALTER TABLE sessions ADD COLUMN scenario_id TEXT")

        try db.setSchemaVersion(Self.schemaVersion)
    }

    /// 轻量卫生清理（幂等，每次打开都跑）：
    /// 旧版本每次启动都会建一条空会话，而「最近会话」取最新的一条，
    /// 导致上次的练习永远恢复不回来 —— 把这种纯空会话删掉（有情景标记的保留）。
    private nonisolated func hygiene() throws {
        try db.run("""
        DELETE FROM sessions
        WHERE message_count = 0 AND scenario_id IS NULL AND id != 'archive'
          AND NOT EXISTS (SELECT 1 FROM messages WHERE messages.session_id = sessions.id)
        """)
    }

    public func schemaVersion() throws -> Int {
        try db.schemaVersion()
    }

    // MARK: - 闯关进度

    /// 无记录时返回 nil（由上层决定是否写入种子进度）。
    public func loadProgress() throws -> LearnerProgress? {
        let levels: [TreeLevel] = try db.query(
            "SELECT * FROM levels ORDER BY sort_order ASC"
        ) { row in
            guard let id = row.string(0),
                  let title = row.string(2),
                  let subtitle = row.string(3),
                  let height = row.double(4),
                  let branchRaw = row.string(5),
                  let branch = TreeLevel.BranchSide(rawValue: branchRaw),
                  let stateRaw = row.string(6),
                  let state = LevelState(rawValue: stateRaw),
                  let required = row.int(7)
            else { throw AppError.database("levels 行数据不完整") }
            return TreeLevel(
                id: id,
                title: title,
                subtitle: subtitle,
                heightFraction: height,
                branch: branch,
                state: state,
                requiredStars: required,
                earnedStars: row.int(8) ?? 0
            )
        }
        guard !levels.isEmpty else { return nil }

        let stars = levels.reduce(0) { $0 + $1.earnedStars }
        let requiredTotal = max(levels.reduce(0) { $0 + $1.requiredStars }, 1)
        let climb = min(Double(stars) / Double(requiredTotal), 1)
        return LearnerProgress(totalStars: stars, climbFraction: climb, levels: levels)
    }

    /// 全量替换进度（关卡数少，事务替换最简单可靠）。
    public func saveProgress(_ progress: LearnerProgress) throws {
        var statements: [(sql: String, params: [SQLiteValue])] = [
            ("DELETE FROM levels", [])
        ]
        for (index, level) in progress.levels.enumerated() {
            statements.append((
                """
                INSERT INTO levels (id, sort_order, title, subtitle, height_fraction, branch, state, required_stars, earned_stars)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                """,
                [
                    .text(level.id),
                    .int(index),
                    .text(level.title),
                    .text(level.subtitle),
                    .real(level.heightFraction),
                    .text(level.branch.rawValue),
                    .text(level.state.rawValue),
                    .int(level.requiredStars),
                    .int(level.earnedStars),
                ]
            ))
        }
        try db.runInTransaction(statements)
    }

    // MARK: - 会话与消息

    public func createSession(_ session: ChatSession) throws {
        try db.run(
            "INSERT OR REPLACE INTO sessions (id, started_at, ended_at, mode, message_count, scenario_id) VALUES (?1, ?2, NULL, ?3, 0, ?4)",
            [
                .text(session.id.uuidString),
                .real(session.startedAt.timeIntervalSince1970),
                .text(session.mode.rawValue),
                session.scenarioID.map { .text($0) } ?? .null,
            ]
        )
    }

    /// 只在会话不存在时创建（不覆盖已有记录，message_count 不会被重置）。
    /// 首次发消息 / 首次进入情景时调用——**启动时不建空会话**，否则「最近会话」永远是空的，
    /// 上次的练习就再也恢复不回来了。
    public func createSessionIfAbsent(_ session: ChatSession) throws {
        try db.run(
            "INSERT OR IGNORE INTO sessions (id, started_at, ended_at, mode, message_count, scenario_id) VALUES (?1, ?2, NULL, ?3, 0, ?4)",
            [
                .text(session.id.uuidString),
                .real(session.startedAt.timeIntervalSince1970),
                .text(session.mode.rawValue),
                session.scenarioID.map { .text($0) } ?? .null,
            ]
        )
    }

    /// 把会话标记为「在练某个情景」（进入情景时调用）。行不存在时顺带建行，
    /// 避免刚进情景就落不了库。`started_at` 保持原值不动。
    public func setSessionScenario(id: UUID, scenarioID: String?, mode: PracticeMode, startedAt: Date) throws {
        try db.run(
            """
            INSERT INTO sessions (id, started_at, ended_at, mode, message_count, scenario_id)
            VALUES (?1, ?2, NULL, ?3, 0, ?4)
            ON CONFLICT(id) DO UPDATE SET scenario_id = excluded.scenario_id, mode = excluded.mode
            """,
            [
                .text(id.uuidString),
                .real(startedAt.timeIntervalSince1970),
                .text(mode.rawValue),
                scenarioID.map { .text($0) } ?? .null,
            ]
        )
    }

    public func appendMessage(_ message: ChatMessage, sessionID: UUID) throws {
        try db.runInTransaction([
            (
                "INSERT OR REPLACE INTO messages (id, session_id, role, content, created_at, reasoning) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                [
                    .text(message.id.uuidString),
                    .text(sessionID.uuidString),
                    .text(message.role.rawValue),
                    .text(message.content),
                    .real(message.createdAt.timeIntervalSince1970),
                    message.reasoning.map { .text($0) } ?? .null,
                ]
            ),
            (
                "UPDATE sessions SET message_count = message_count + 1 WHERE id = ?1",
                [.text(sessionID.uuidString)]
            ),
        ])
    }

    /// 某会话的全部消息（按时间正序），用于启动时恢复上次会话。
    public func messages(sessionID: UUID) throws -> [ChatMessage] {
        let rows = try db.query(
            "SELECT id, role, content, created_at, reasoning FROM messages WHERE session_id = ?1 ORDER BY created_at ASC, rowid ASC",
            [.text(sessionID.uuidString)]
        ) { row -> ChatMessage? in
            guard let idText = row.string(0), let id = UUID(uuidString: idText),
                  let roleRaw = row.string(1), let role = ChatRole(rawValue: roleRaw),
                  let content = row.string(2), let created = row.double(3)
            else { return nil }
            return ChatMessage(
                id: id, role: role, content: content,
                createdAt: Date(timeIntervalSince1970: created),
                reasoning: row.string(4)
            )
        }
        return rows.compactMap { $0 }
    }

    /// 最近一个会话（含消息）。没有历史会话时返回 nil。
    public func latestSession() throws -> (session: ChatSession, messages: [ChatMessage])? {
        let rows = try db.query(
            "SELECT id, started_at, mode, scenario_id FROM sessions WHERE id != 'archive' ORDER BY started_at DESC LIMIT 1"
        ) { row -> (UUID, Date, PracticeMode, String?)? in
            guard let idText = row.string(0), let id = UUID(uuidString: idText),
                  let started = row.double(1),
                  let modeRaw = row.string(2), let mode = PracticeMode(rawValue: modeRaw)
            else { return nil }
            return (id, Date(timeIntervalSince1970: started), mode, row.string(3))
        }
        guard let first = rows.compactMap({ $0 }).first else { return nil }
        let session = ChatSession(id: first.0, startedAt: first.1, mode: first.2, scenarioID: first.3)
        return (session, try messages(sessionID: first.0))
    }

    public func finishSession(id: UUID, endedAt: Date = Date()) throws {
        try db.run(
            "UPDATE sessions SET ended_at = ?2 WHERE id = ?1",
            [.text(id.uuidString), .real(endedAt.timeIntervalSince1970)]
        )
    }

    public func recentSessions(limit: Int = 20) throws -> [SessionSummary] {
        let rows = try db.query(
            "SELECT id, started_at, COALESCE(ended_at, ?2) AS ended, message_count, scenario_id FROM sessions ORDER BY started_at DESC LIMIT ?1",
            [.int(limit), .real(Date().timeIntervalSince1970)]
        ) { row -> SessionSummary? in
            guard let idText = row.string(0),
                  let id = UUID(uuidString: idText),
                  let started = row.double(1),
                  let ended = row.double(2)
            else { return nil }
            return SessionSummary(
                sessionID: id,
                startedAt: Date(timeIntervalSince1970: started),
                endedAt: Date(timeIntervalSince1970: ended),
                messageCount: row.int(3) ?? 0,
                newStars: 0,
                corrections: [],
                scenarioID: row.string(4)
            )
        }
        return rows.compactMap { $0 }
    }

    public func messageCount(sessionID: UUID) throws -> Int {
        try db.query(
            "SELECT COUNT(*) FROM messages WHERE session_id = ?1",
            [.text(sessionID.uuidString)],
            map: { $0.int(0) ?? 0 }
        ).first ?? 0
    }

    // MARK: - 纠错（学习记忆的核心资产）

    public func appendCorrection(_ correction: GrammarCorrection, sessionID: UUID) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO corrections (id, session_id, original, corrected, explanation, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """,
            [
                .text(correction.id.uuidString),
                .text(sessionID.uuidString),
                .text(correction.original),
                .text(correction.corrected),
                .text(correction.explanation),
                .real(Date().timeIntervalSince1970),
            ]
        )
    }

    public func corrections(sessionID: UUID) throws -> [GrammarCorrection] {
        try db.query(
            "SELECT id, original, corrected, explanation FROM corrections WHERE session_id = ?1 ORDER BY created_at ASC",
            [.text(sessionID.uuidString)]
        ) { row in Self.correction(from: row) }
    }

    /// 最近纠错（跨会话，用于复习/错题本）。
    public func recentCorrections(limit: Int = 50) throws -> [GrammarCorrection] {
        try db.query(
            "SELECT id, original, corrected, explanation FROM corrections ORDER BY created_at DESC LIMIT ?1",
            [.int(limit)]
        ) { row in Self.correction(from: row) }
    }

    /// 会话总结：消息数 + 本会话纠错。
    public func sessionSummary(id: UUID) throws -> SessionSummary? {
        let rows = try db.query(
            "SELECT id, started_at, COALESCE(ended_at, ?2), message_count, scenario_id FROM sessions WHERE id = ?1",
            [.text(id.uuidString), .real(Date().timeIntervalSince1970)]
        ) { row in
            (id: row.string(0), started: row.double(1), ended: row.double(2), count: row.int(3) ?? 0,
             scenario: row.string(4))
        }
        guard let row = rows.first,
              let idText = row.id,
              let sessionID = UUID(uuidString: idText)
        else { return nil }
        return SessionSummary(
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: row.started ?? 0),
            endedAt: Date(timeIntervalSince1970: row.ended ?? Date().timeIntervalSince1970),
            messageCount: row.count,
            newStars: 0,
            corrections: try corrections(sessionID: sessionID),
            scenarioID: row.scenario
        )
    }

    /// 某会话进行的情景 id（nil = 普通练习 / 会话不存在）。
    public func sessionScenarioID(id: UUID) throws -> String? {
        try db.query(
            "SELECT scenario_id FROM sessions WHERE id = ?1",
            [.text(id.uuidString)],
            map: { $0.string(0) }
        ).first ?? nil
    }

    // MARK: - 练习复盘（学习记忆：把一次练习沉淀成可回看的总结）

    /// 写入/覆盖一次复盘（同 id 覆盖，按会话保留最新一份）。
    public func saveReview(_ review: SessionReview) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO session_reviews
                (id, session_id, created_at, duration, message_count, correction_count,
                 headline, new_words, strengths, improvements, suggestion, source)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            """,
            [
                .text(review.id.uuidString),
                .text(review.sessionID.uuidString),
                .real(review.createdAt.timeIntervalSince1970),
                .real(review.duration),
                .int(review.messageCount),
                .int(review.correctionCount),
                .text(review.headline),
                .text(Self.encodeList(review.newWords)),
                .text(Self.encodeList(review.strengths)),
                .text(Self.encodeList(review.improvements)),
                .text(review.suggestion),
                .text(review.source.rawValue),
            ]
        )
    }

    /// 某会话最新一份复盘。
    public func review(sessionID: UUID) throws -> SessionReview? {
        try db.query(
            """
            SELECT id, session_id, created_at, duration, message_count, correction_count,
                   headline, new_words, strengths, improvements, suggestion, source
            FROM session_reviews WHERE session_id = ?1
            ORDER BY created_at DESC LIMIT 1
            """,
            [.text(sessionID.uuidString)]
        ) { row in Self.review(from: row) }.compactMap { $0 }.first
    }

    /// 最近的复盘（跨会话，学习记录页展示）。
    public func recentReviews(limit: Int = 10) throws -> [SessionReview] {
        try db.query(
            """
            SELECT id, session_id, created_at, duration, message_count, correction_count,
                   headline, new_words, strengths, improvements, suggestion, source
            FROM session_reviews ORDER BY created_at DESC LIMIT ?1
            """,
            [.int(limit)]
        ) { row in Self.review(from: row) }.compactMap { $0 }
    }

    private static func review(from row: SQLiteRow) -> SessionReview? {
        guard let idText = row.string(0), let id = UUID(uuidString: idText),
              let sessionText = row.string(1), let sessionID = UUID(uuidString: sessionText),
              let created = row.double(2)
        else { return nil }
        return SessionReview(
            id: id,
            sessionID: sessionID,
            createdAt: Date(timeIntervalSince1970: created),
            duration: row.double(3) ?? 0,
            messageCount: row.int(4) ?? 0,
            correctionCount: row.int(5) ?? 0,
            headline: row.string(6) ?? "",
            newWords: decodeList(row.string(7)),
            strengths: decodeList(row.string(8)),
            improvements: decodeList(row.string(9)),
            suggestion: row.string(10) ?? "",
            source: SessionReview.Source(rawValue: row.string(11) ?? "llm") ?? .llm
        )
    }

    /// 字符串列表以 JSON 数组存列（短列表，JSON 足够且可读）。
    private static func encodeList(_ items: [String]) -> String {
        let data = (try? JSONEncoder().encode(items)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func decodeList(_ text: String?) -> [String] {
        guard let text, let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func correction(from row: SQLiteRow) -> GrammarCorrection {
        guard let idText = row.string(0), let id = UUID(uuidString: idText),
              let original = row.string(1),
              let corrected = row.string(2)
        else { return GrammarCorrection(id: UUID(), original: "", corrected: "", explanation: "") }
        return GrammarCorrection(
            id: id,
            original: original,
            corrected: corrected,
            explanation: row.string(3) ?? ""
        )
    }

    // MARK: - 空间回收（缓存管理用）

    /// 清理超过保留窗口的旧会话：messages/corrections 随外键级联删除，
    /// **纠错本体先抢救出来**（学习记忆是资产）——把 session_id 改挂到归档哨兵会话。
    public func purgeSessionsOlderThan(days: Int) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        try db.runInTransaction([
            // 归档哨兵：为保外键有效而存在，不出现在会话列表（id 非 UUID）
            ("INSERT OR IGNORE INTO sessions (id, started_at, ended_at, mode, message_count) VALUES ('archive', 0, NULL, 'conversation', 0)", []),
            (
                "UPDATE corrections SET session_id = 'archive' WHERE session_id IN (SELECT id FROM sessions WHERE COALESCE(ended_at, started_at) < ?1)",
                [.real(cutoff)]
            ),
        ])
        try db.run(
            "DELETE FROM sessions WHERE COALESCE(ended_at, started_at) < ?1 AND id != 'archive'",
            [.real(cutoff)]
        )
    }

    /// WAL checkpoint：把预写日志合并回主库文件，WAL 归零。
    public func checkpoint() throws {
        try db.run("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// VACUUM 整理数据库文件，回收删除留下的空洞。
    public func vacuum() throws {
        try db.run("VACUUM")
    }
}
