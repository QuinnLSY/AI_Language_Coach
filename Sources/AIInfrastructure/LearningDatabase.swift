import AIDomain
import AppCore
import Foundation

/// 学习数据库（SQLite，V1 schema）。
///
/// 职责：闯关进度、练习会话与消息的本地持久化。**只被 AIServices 访问**，UI 不得直接使用。
public actor LearningDatabase {

    private let db: SQLiteDatabase

    public static let schemaVersion = 1

    /// 测试用内存库。
    public static func inMemory() throws -> LearningDatabase {
        try LearningDatabase(path: ":memory:")
    }

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try migrate()
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
            created_at REAL NOT NULL
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

        try db.setSchemaVersion(Self.schemaVersion)
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
            "INSERT OR REPLACE INTO sessions (id, started_at, ended_at, mode, message_count) VALUES (?1, ?2, NULL, ?3, 0)",
            [.text(session.id.uuidString), .real(session.startedAt.timeIntervalSince1970), .text(session.mode.rawValue)]
        )
    }

    public func appendMessage(_ message: ChatMessage, sessionID: UUID) throws {
        try db.runInTransaction([
            (
                "INSERT OR REPLACE INTO messages (id, session_id, role, content, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
                [
                    .text(message.id.uuidString),
                    .text(sessionID.uuidString),
                    .text(message.role.rawValue),
                    .text(message.content),
                    .real(message.createdAt.timeIntervalSince1970),
                ]
            ),
            (
                "UPDATE sessions SET message_count = message_count + 1 WHERE id = ?1",
                [.text(sessionID.uuidString)]
            ),
        ])
    }

    public func finishSession(id: UUID, endedAt: Date = Date()) throws {
        try db.run(
            "UPDATE sessions SET ended_at = ?2 WHERE id = ?1",
            [.text(id.uuidString), .real(endedAt.timeIntervalSince1970)]
        )
    }

    public func recentSessions(limit: Int = 20) throws -> [SessionSummary] {
        try db.query(
            "SELECT id, started_at, COALESCE(ended_at, ?2) AS ended, message_count FROM sessions ORDER BY started_at DESC LIMIT ?1",
            [.int(limit), .real(Date().timeIntervalSince1970)]
        ) { row in
            guard let idText = row.string(0),
                  let id = UUID(uuidString: idText),
                  let started = row.double(1),
                  let ended = row.double(2)
            else { throw AppError.database("sessions 行数据不完整") }
            return SessionSummary(
                sessionID: id,
                startedAt: Date(timeIntervalSince1970: started),
                endedAt: Date(timeIntervalSince1970: ended),
                messageCount: row.int(3) ?? 0,
                newStars: 0,
                corrections: []
            )
        }
    }

    public func messageCount(sessionID: UUID) throws -> Int {
        try db.query(
            "SELECT COUNT(*) FROM messages WHERE session_id = ?1",
            [.text(sessionID.uuidString)],
            map: { $0.int(0) ?? 0 }
        ).first ?? 0
    }
}
