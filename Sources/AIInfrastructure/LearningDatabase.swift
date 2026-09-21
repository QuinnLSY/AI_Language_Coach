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
    /// v5：新增 shadowing_attempts（跟读记录：参考句 / 学员实际说的 / 匹配率）。
    /// v6：shadowing_attempts 增加 pronunciation 列（发音评测报告 JSON，第 23 步）。
    /// v7：词汇本（vocabulary_items / vocabulary_reviews）。
    /// v8：messages 增加 attachments 列（图片 / 视频 / 文件附件，JSON 数组）。
    /// v9：新增 scenario_quests（情景主线任务进度，需求 3/5：跨会话续做）
    ///     + **一次性清零闯关进度**（需求 1：从零开始学习）。
    /// v10：新增 writing_entries（写作批改记录）/ reading_passages（当天短文与作答进度，
    ///      #233：阅读当天多篇固定展示、写作与阅读进学习记录）。
    public static let schemaVersion = 11

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

        // v4 → v5：跟读记录（第 22 步 Shadowing）。
        // 跟读是独立练习，不挂在某次对话会话上，因此**不设 session 外键**。
        try db.run("""
        CREATE TABLE IF NOT EXISTS shadowing_attempts (
            id TEXT PRIMARY KEY,
            drill_id TEXT NOT NULL,
            reference TEXT NOT NULL,
            recognized TEXT NOT NULL,
            accuracy REAL NOT NULL,
            created_at REAL NOT NULL
        )
        """)
        try db.run("CREATE INDEX IF NOT EXISTS idx_shadowing_created ON shadowing_attempts(created_at DESC)")

        // v5 → v6：跟读记录补发音评测列（第 23 步 Pronunciation）。
        // 报告是结构化的只读结果，JSON 一列足够；旧行为 NULL = 当时没有音频。
        try? db.run("ALTER TABLE shadowing_attempts ADD COLUMN pronunciation TEXT")

        // v6 → v7：词汇本（第 24 步 Vocabulary）。
        // word 是业务唯一键（复盘提取 / 手动添加都按它去重），id 只是行标识。
        try db.run("""
        CREATE TABLE IF NOT EXISTS vocabulary_items (
            id TEXT PRIMARY KEY,
            word TEXT NOT NULL UNIQUE,
            meaning TEXT NOT NULL DEFAULT '',
            example TEXT NOT NULL DEFAULT '',
            difficulty INTEGER NOT NULL DEFAULT 3,
            mastery INTEGER NOT NULL DEFAULT 0,
            review_count INTEGER NOT NULL DEFAULT 0,
            last_reviewed_at REAL,
            source TEXT NOT NULL DEFAULT 'manual',
            created_at REAL NOT NULL
        )
        """)
        try db.run("CREATE INDEX IF NOT EXISTS idx_vocab_created ON vocabulary_items(created_at DESC)")
        try db.run("""
        CREATE TABLE IF NOT EXISTS vocabulary_reviews (
            id TEXT PRIMARY KEY,
            item_id TEXT NOT NULL REFERENCES vocabulary_items(id) ON DELETE CASCADE,
            remembered INTEGER NOT NULL,
            reviewed_at REAL NOT NULL
        )
        """)

        // v7 → v8：消息补附件列（第 3 项需求：聊天支持图片 / 视频 / 文件）。
        // 用 JSON 一列而不是建附件表：附件永远跟着消息整体读写，没有「单独查某个附件」的场景，
        // 拆表只会多一次 join 和一次一致性维护。旧行为 NULL = 当时没有附件。
        try? db.run("ALTER TABLE messages ADD COLUMN attachments TEXT")

        // v8 → v9：情景主线任务进度（需求 3 / 5）。
        //
        // 独立一张表而不是塞进 levels：主线任务是**按情景**记的（没绑关卡的场景也要能续做），
        // 而 levels 是**按关卡**记的，两者维度不同 —— 混在一起会在「一个关卡换绑情景」时错乱。
        // done_steps 存 JSON 数组：永远整体读写，没有「单独查某一步」的场景。
        try db.run("""
        CREATE TABLE IF NOT EXISTS scenario_quests (
            scenario_id TEXT PRIMARY KEY,
            session_id TEXT,
            done_steps TEXT NOT NULL DEFAULT '[]',
            is_complete INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        )
        """)

        // v8 → v9：**一次性清零闯关进度**（需求 1：闯关进度归零，从零开始学习）。
        //
        // 老库里的 levels 是老种子（前三关已完成），光改 `LearnerProgress.seed()` 动不了它 ——
        // 这里直接清空，下一次 `loadProgress()` 因「无记录」而写入零进度种子
        // （第 1 关 unlocked，其余 locked）。
        // ⚠️ 只清 levels：练习记录 / 复盘 / 单词本 / 跟读记录都属于学习成果，不动。
        try db.run("DELETE FROM levels")

        // v9 → v10：写作记录 + 当天阅读（#233）。
        //
        // 写作只留极简一行（题目 / 分数 / 词数 / 时间）—— 批改正文随交话即逝，
        // 学习记录要的是「写了没有、写得怎样」，不是整篇作文。
        // 阅读整篇存 JSON（题目/答案/解析一体）：当天回看与重启恢复是同一个读法，
        // 分列只会造成「文章新、答案旧」的错位。
        try db.run("""
        CREATE TABLE IF NOT EXISTS writing_entries (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            score REAL,
            word_count INTEGER NOT NULL,
            created_at REAL NOT NULL
        )
        """)
        try db.run("CREATE INDEX IF NOT EXISTS idx_writing_created ON writing_entries(created_at DESC)")
        try db.run("""
        CREATE TABLE IF NOT EXISTS reading_passages (
            id TEXT PRIMARY KEY,
            day_key INTEGER NOT NULL,
            payload TEXT NOT NULL,
            choices TEXT NOT NULL DEFAULT '{}',
            is_reviewed INTEGER NOT NULL DEFAULT 0,
            correct_count INTEGER,
            question_count INTEGER,
            created_at REAL NOT NULL
        )
        """)
        try db.run("CREATE INDEX IF NOT EXISTS idx_reading_day ON reading_passages(day_key, created_at ASC)")

        // v10 → v11：词汇本补「个人难度系数」列（复习间隔按词自适应）。
        //
        // 加列而不是重建表：老库里的掌握度 / 复习次数是学员攒下来的学习资产，
        // 重建等于清零。
        //
        // ⚠️ DEFAULT 直接写进 DDL 而不是等读出时再兜 nil：老行在**加列的那一刻**
        // 就被填上中性值，库里根本不存在 NULL 行 —— 少一条「读出时才发现是旧数据」
        // 的分支，也就少一处会漏测的兜底。常量走插值而非写死 2.5，避免两处漂移。
        try? db.run(
            "ALTER TABLE vocabulary_items ADD COLUMN ease REAL DEFAULT \(ReviewScheduler.defaultEase)"
        )

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
        // 附件列存 JSON 数组。**编码失败不能把整条消息写丢** ——
        // 消息正文才是用户真正在乎的东西，附件编码异常时宁可不带附件，也要把话留下来。
        let attachmentsJSON = message.attachments.isEmpty
            ? nil
            : (try? Self.attachmentsEncoder.encode(message.attachments)).flatMap { String(data: $0, encoding: .utf8) }
        try db.runInTransaction([
            (
                """
                INSERT OR REPLACE INTO messages (id, session_id, role, content, created_at, reasoning, attachments)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                """,
                [
                    .text(message.id.uuidString),
                    .text(sessionID.uuidString),
                    .text(message.role.rawValue),
                    .text(message.content),
                    .real(message.createdAt.timeIntervalSince1970),
                    message.reasoning.map { .text($0) } ?? .null,
                    attachmentsJSON.map { .text($0) } ?? .null,
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
            "SELECT id, role, content, created_at, reasoning, attachments FROM messages WHERE session_id = ?1 ORDER BY created_at ASC, rowid ASC",
            [.text(sessionID.uuidString)]
        ) { row -> ChatMessage? in
            guard let idText = row.string(0), let id = UUID(uuidString: idText),
                  let roleRaw = row.string(1), let role = ChatRole(rawValue: roleRaw),
                  let content = row.string(2), let created = row.double(3)
            else { return nil }
            return ChatMessage(
                id: id, role: role, content: content,
                createdAt: Date(timeIntervalSince1970: created),
                reasoning: row.string(4),
                attachments: Self.decodeAttachments(row.string(5))
            )
        }
        return rows.compactMap { $0 }
    }

    /// 附件 JSON 解码：坏数据一律当「没有附件」，**绝不因为一条附件的字节坏掉就让整段历史读不出来**。
    static func decodeAttachments(_ json: String?) -> [ChatAttachment] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? attachmentsDecoder.decode([ChatAttachment].self, from: data)) ?? []
    }

    static let attachmentsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let attachmentsDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

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

    // MARK: - 进度聚合用的时间窗口查询（第 25 步 Dashboard）
    //
    // 趋势图要按天聚合，所以这里只取「窗口内的原始事实」，怎么折算成趋势是
    // `ProgressAggregator` 的纯函数活儿 —— 数据库不做业务口径。

    /// 窗口内每条消息的时间戳（正序）。练习时长由「同一天首条 → 末条」折算。
    public func messageTimestamps(since: Date) throws -> [Date] {
        try db.query(
            "SELECT created_at FROM messages WHERE created_at >= ?1 ORDER BY created_at ASC",
            [.real(since.timeIntervalSince1970)],
            map: { row in row.double(0).map { Date(timeIntervalSince1970: $0) } }
        ).compactMap { $0 }
    }

    /// 窗口内的纠错（新 → 旧），带创建时间。
    public func correctionRecords(since: Date, limit: Int = 500) throws -> [CorrectionRecord] {
        try db.query(
            """
            SELECT id, original, corrected, explanation, created_at
            FROM corrections WHERE created_at >= ?1 ORDER BY created_at DESC LIMIT ?2
            """,
            [.real(since.timeIntervalSince1970), .int(limit)]
        ) { row -> CorrectionRecord? in
            guard let idText = row.string(0), let id = UUID(uuidString: idText),
                  let original = row.string(1), let corrected = row.string(2),
                  let created = row.double(4)
            else { return nil }
            return CorrectionRecord(
                correction: GrammarCorrection(
                    id: id, original: original, corrected: corrected,
                    explanation: row.string(3) ?? ""
                ),
                createdAt: Date(timeIntervalSince1970: created)
            )
        }.compactMap { $0 }
    }

    /// 窗口内的跟读记录（新 → 旧）。
    public func shadowingAttempts(since: Date, limit: Int = 500) throws -> [ShadowingAttempt] {        try db.query(
            """
            SELECT id, drill_id, reference, recognized, accuracy, pronunciation, created_at
            FROM shadowing_attempts WHERE created_at >= ?1 ORDER BY created_at DESC LIMIT ?2
            """,
            [.real(since.timeIntervalSince1970), .int(limit)]
        ) { row -> ShadowingAttempt? in
            guard let idText = row.string(0), let id = UUID(uuidString: idText),
                  let drillID = row.string(1), let reference = row.string(2),
                  let recognized = row.string(3), let accuracy = row.double(4),
                  let created = row.double(6)
            else { return nil }
            return ShadowingAttempt(
                id: id, drillID: drillID, referenceText: reference,
                recognizedText: recognized, accuracy: accuracy,
                pronunciation: Self.decodeJSON(row.string(5)),
                createdAt: Date(timeIntervalSince1970: created)
            )
        }.compactMap { $0 }
    }

    /// 窗口内的跟读**极简记录**（旧 → 新）：只要「参考句 + 时间」。
    ///
    /// 年度记录要往回看一整年，一年上千次跟读 —— 把每次的发音报告（一整块 JSON）
    /// 也解出来纯属浪费。窗口趋势仍走 `shadowingAttempts(since:)`，那边要分数。
    ///
    /// ⚠️ 这里**不设 LIMIT**：`shadowingAttempts` 默认截 500 条，一年下来很容易超过，
    /// 截断等于悄悄少算几天的练习量 —— 时间范围已经由 `since` 兜住了。
    public func shadowingStamps(since: Date) throws -> [ShadowingStamp] {
        try db.query(
            "SELECT reference, created_at FROM shadowing_attempts WHERE created_at >= ?1 ORDER BY created_at ASC",
            [.real(since.timeIntervalSince1970)]
        ) { row -> ShadowingStamp? in
            guard let reference = row.string(0), let created = row.double(1) else { return nil }
            return ShadowingStamp(
                referenceText: reference,
                createdAt: Date(timeIntervalSince1970: created)
            )
        }.compactMap { $0 }
    }

    /// 窗口内的词汇复习流水（旧 → 新）：哪天复习了哪个词。
    ///
    /// `vocabulary_items.last_reviewed_at` 只记得**最后一次**，一个词跨几天复习
    /// 只会留下最后那天的痕迹；要还原「每天复习了几个词」只能靠流水表。
    public func vocabularyReviewStamps(since: Date) throws -> [VocabularyReviewStamp] {
        try db.query(
            """
            SELECT item_id, reviewed_at FROM vocabulary_reviews
            WHERE reviewed_at >= ?1 ORDER BY reviewed_at ASC
            """,
            [.real(since.timeIntervalSince1970)]
        ) { row -> VocabularyReviewStamp? in
            guard let idText = row.string(0), let id = UUID(uuidString: idText),
                  let reviewed = row.double(1)
            else { return nil }
            return VocabularyReviewStamp(
                itemID: id,
                reviewedAt: Date(timeIntervalSince1970: reviewed)
            )
        }.compactMap { $0 }
    }

    /// 窗口内的会话（新 → 旧）。
    public func sessions(since: Date, limit: Int = 500) throws -> [SessionSummary] {
        try db.query(
            """
            SELECT id, started_at, COALESCE(ended_at, ?3) AS ended, message_count, scenario_id
            FROM sessions
            WHERE started_at >= ?1 AND id != 'archive'
            ORDER BY started_at DESC LIMIT ?2
            """,
            [.real(since.timeIntervalSince1970), .int(limit), .real(Date().timeIntervalSince1970)]
        ) { row -> SessionSummary? in
            guard let idText = row.string(0), let id = UUID(uuidString: idText),
                  let started = row.double(1), let ended = row.double(2)
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
        }.compactMap { $0 }
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

    // MARK: - 情景主线任务进度（需求 3 / 5：实时保存 + 断点续做）

    /// 某情景的主线任务进度（没练过返回 nil）。
    public func questProgress(scenarioID: String) throws -> ScenarioQuestRecord? {
        try db.query(
            "SELECT scenario_id, session_id, done_steps, is_complete, updated_at FROM scenario_quests WHERE scenario_id = ?1",
            [.text(scenarioID)]
        ) { row in Self.questRecord(from: row) }.compactMap { $0 }.first
    }

    /// 全部情景的主线任务进度（大树 / 情景卡片一次取完，避免 N 次查询）。
    public func allQuestProgress() throws -> [ScenarioQuestRecord] {
        try db.query(
            "SELECT scenario_id, session_id, done_steps, is_complete, updated_at FROM scenario_quests ORDER BY updated_at DESC"
        ) { row in Self.questRecord(from: row) }.compactMap { $0 }
    }

    /// 写入主线任务进度（upsert）。
    public func saveQuestProgress(_ record: ScenarioQuestRecord) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO scenario_quests
                (scenario_id, session_id, done_steps, is_complete, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            """,
            [
                .text(record.scenarioID),
                record.sessionID.map { .text($0.uuidString) } ?? .null,
                .text(Self.encodeList(record.doneStepIDs)),
                .int(record.isComplete ? 1 : 0),
                .real(record.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    /// 清掉某情景的主线任务进度（重新开始这一关时调用）。
    public func clearQuestProgress(scenarioID: String) throws {
        try db.run("DELETE FROM scenario_quests WHERE scenario_id = ?1", [.text(scenarioID)])
    }

    private static func questRecord(from row: SQLiteRow) -> ScenarioQuestRecord? {
        guard let scenarioID = row.string(0) else { return nil }
        return ScenarioQuestRecord(
            scenarioID: scenarioID,
            sessionID: row.string(1).flatMap { UUID(uuidString: $0) },
            doneStepIDs: decodeList(row.string(2)),
            isComplete: (row.int(3) ?? 0) != 0,
            updatedAt: Date(timeIntervalSince1970: row.double(4) ?? 0)
        )
    }

    /// 某情景最近一次复盘（跨会话找，因为复盘是跟着会话走的）。
    ///
    /// 「任务前情提要」要的正是这一条：上次练这个情景时复盘说了什么。
    public func latestReview(scenarioID: String) throws -> SessionReview? {
        try db.query(
            """
            SELECT r.id, r.session_id, r.created_at, r.duration, r.message_count, r.correction_count,
                   r.headline, r.new_words, r.strengths, r.improvements, r.suggestion, r.source
            FROM session_reviews r
            JOIN sessions s ON s.id = r.session_id
            WHERE s.scenario_id = ?1
            ORDER BY r.created_at DESC LIMIT 1
            """,
            [.text(scenarioID)]
        ) { row in Self.review(from: row) }.compactMap { $0 }.first
    }

    /// 某会话最近一次复盘记录下来的消息数（判断「有没有新内容需要复盘」）。
    public func reviewedMessageCount(sessionID: UUID) throws -> Int {
        try db.query(
            "SELECT message_count FROM session_reviews WHERE session_id = ?1 ORDER BY created_at DESC LIMIT 1",
            [.text(sessionID.uuidString)],
            map: { $0.int(0) ?? 0 }
        ).first ?? 0
    }

    /// 删除某个会话的**练习流水**：消息与纠错。
    ///
    /// ⚠️ 刻意保留 `sessions` 行与 `session_reviews`：
    /// 「上次练习卡片」要显示情景名、时长、复盘内容，删了会话行这些就全丢了。
    /// 复盘成功之后才允许调用（`PracticeReviewPolicy.canPurgeSource`）。
    @discardableResult
    public func purgeSessionMessages(sessionID: UUID) throws -> Int {
        let before = try messageCount(sessionID: sessionID)
        try db.runInTransaction([
            ("DELETE FROM corrections WHERE session_id = ?1", [.text(sessionID.uuidString)]),
            ("DELETE FROM messages WHERE session_id = ?1", [.text(sessionID.uuidString)]),
        ])
        return before
    }

    // MARK: - 跟读记录（第 22 步 Shadowing）

    /// 记一次跟读（评测完成后写入；跟读不挂在对话会话上，故无 session 外键）。
    /// 发音报告（第 23 步）随行保存为 JSON。
    public func appendShadowingAttempt(_ attempt: ShadowingAttempt) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO shadowing_attempts
                (id, drill_id, reference, recognized, accuracy, pronunciation, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            """,
            [
                .text(attempt.id.uuidString),
                .text(attempt.drillID),
                .text(attempt.referenceText),
                .text(attempt.recognizedText),
                .real(attempt.accuracy),
                attempt.pronunciation.map(Self.encodeJSON) ?? .null,
                .real(attempt.createdAt.timeIntervalSince1970),
            ]
        )
    }

    /// 最近的跟读记录（**新 → 旧**）。
    public func recentShadowingAttempts(limit: Int = 50) throws -> [ShadowingAttempt] {
        try db.query(
            """
            SELECT id, drill_id, reference, recognized, accuracy, pronunciation, created_at
            FROM shadowing_attempts ORDER BY created_at DESC LIMIT ?1
            """,
            [.int(limit)]
        ) { row -> ShadowingAttempt? in
            guard let idText = row.string(0), let id = UUID(uuidString: idText),
                  let drillID = row.string(1), let reference = row.string(2),
                  let recognized = row.string(3), let accuracy = row.double(4),
                  let created = row.double(6)
            else { return nil }
            return ShadowingAttempt(
                id: id, drillID: drillID, referenceText: reference,
                recognizedText: recognized, accuracy: accuracy,
                pronunciation: Self.decodeJSON(row.string(5)),
                createdAt: Date(timeIntervalSince1970: created)
            )
        }.compactMap { $0 }
    }

    // MARK: - 写作与阅读记录（#233）

    /// 记一次写作批改（交卷成功后写入；一次写作 = 一行）。
    public func appendWritingEntry(
        id: UUID = UUID(),
        title: String,
        score: Double?,
        wordCount: Int,
        createdAt: Date = Date()
    ) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO writing_entries (id, title, score, word_count, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            """,
            [
                .text(id.uuidString),
                .text(title),
                score.map { .real($0) } ?? .null,
                .int(max(wordCount, 0)),
                .real(createdAt.timeIntervalSince1970),
            ]
        )
    }

    /// 窗口内的写作记录（旧 → 新）：哪天写了几篇、平均分多少。
    ///
    /// ⚠️ 不设 LIMIT：统计口径靠 `since` 兜住，截断等于悄悄少算。
    public func writingStamps(since: Date) throws -> [WritingStamp] {
        try db.query(
            "SELECT score, word_count, created_at FROM writing_entries WHERE created_at >= ?1 ORDER BY created_at ASC",
            [.real(since.timeIntervalSince1970)]
        ) { row -> WritingStamp? in
            guard let created = row.double(2) else { return nil }
            return WritingStamp(
                score: row.double(0),
                wordCount: row.int(1) ?? 0,
                createdAt: Date(timeIntervalSince1970: created)
            )
        }.compactMap { $0 }
    }

    /// 保存一篇短文（含作答进度）。整篇 upsert：同一篇的每次作答变化都整体覆盖。
    public func saveReading(_ entry: StoredReading) throws {
        let payload = Self.encodeJSON(entry.passage)
        let choices = Self.encodeJSON(entry.choices)
        let correct = entry.isReviewed ? entry.correctCount() : nil
        try db.run(
            """
            INSERT OR REPLACE INTO reading_passages
                (id, day_key, payload, choices, is_reviewed, correct_count, question_count, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            """,
            [
                .text(entry.id.uuidString),
                .int(entry.passage.dayKey),
                payload,
                choices,
                .int(entry.isReviewed ? 1 : 0),
                correct.map { .int($0) } ?? .null,
                .int(entry.isReviewed ? entry.passage.questions.count : 0),
                .real(entry.createdAt.timeIntervalSince1970),
            ]
        )
    }

    /// 某一天的短文（旧 → 新，「编号 1、2、3…」的顺序）。
    public func readings(dayKey: Int) throws -> [StoredReading] {
        try db.query(
            """
            SELECT id, payload, choices, is_reviewed, created_at
            FROM reading_passages WHERE day_key = ?1 ORDER BY created_at ASC, rowid ASC
            """,
            [.int(dayKey)]
        ) { row -> StoredReading? in
            guard let idText = row.string(0), let id = UUID(uuidString: idText),
                  let payloadText = row.string(1),
                  let passage = Self.decodeJSON(payloadText, as: ReadingPassage.self),
                  let created = row.double(4)
            else { return nil }
            return StoredReading(
                id: id,
                passage: passage,
                choices: Self.decodeJSON(row.string(2), as: [Int: Int].self) ?? [:],
                isReviewed: (row.int(3) ?? 0) != 0,
                createdAt: Date(timeIntervalSince1970: created)
            )
        }.compactMap { $0 }
    }

    /// 窗口内**交卷**的阅读（旧 → 新）：进度统计只认交卷的。
    public func readingStamps(since: Date) throws -> [ReadingStamp] {
        try db.query(
            """
            SELECT correct_count, question_count, created_at
            FROM reading_passages
            WHERE is_reviewed = 1 AND created_at >= ?1
            ORDER BY created_at ASC
            """,
            [.real(since.timeIntervalSince1970)]
        ) { row -> ReadingStamp? in
            guard let created = row.double(2) else { return nil }
            return ReadingStamp(
                correct: row.int(0) ?? 0,
                total: row.int(1) ?? 0,
                createdAt: Date(timeIntervalSince1970: created)
            )
        }.compactMap { $0 }
    }

    // MARK: - 词汇本（第 24 步 Vocabulary）

    /// 新增 / 更新词汇（按 word 去重：已存在时**不动**，保住已有掌握度与释义）。
    /// 返回是否真的新插入了（false = 已有同词）。
    @discardableResult
    public func upsertVocabulary(_ entry: VocabularyEntry) throws -> Bool {
        // 先查后插（封装层没有 changes() 计数）：已存在就不覆盖 ——
        // 复习进度是学习资产，重复导入不能把它抹平。
        let existing = try db.query(
            "SELECT 1 FROM vocabulary_items WHERE word = ?1 COLLATE NOCASE",
            [.text(entry.word)]
        ) { _ in true }
        guard existing.isEmpty else { return false }
        try db.run(
            """
            INSERT INTO vocabulary_items
                (id, word, meaning, example, difficulty, mastery, review_count,
                 last_reviewed_at, ease, source, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            """,
            [
                .text(entry.id.uuidString),
                .text(entry.word),
                .text(entry.meaning),
                .text(entry.example),
                .int(entry.difficulty),
                .int(entry.mastery),
                .int(entry.reviewCount),
                entry.lastReviewedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .real(entry.ease),
                .text(entry.source.rawValue),
                .real(entry.createdAt.timeIntervalSince1970),
            ]
        )
        return true
    }

    /// 全部词汇（**新 → 旧**）。
    public func allVocabulary() throws -> [VocabularyEntry] {
        try db.query(
            """
            SELECT id, word, meaning, example, difficulty, mastery, review_count,
                   last_reviewed_at, source, created_at, ease
            FROM vocabulary_items ORDER BY created_at DESC
            """
        ) { row -> VocabularyEntry? in
            guard let idText = row.string(0), let id = UUID(uuidString: idText),
                  let word = row.string(1), let sourceRaw = row.string(8),
                  let source = VocabularyEntry.Source(rawValue: sourceRaw),
                  let created = row.double(9)
            else { return nil }
            return VocabularyEntry(
                id: id,
                word: word,
                meaning: row.string(2) ?? "",
                example: row.string(3) ?? "",
                difficulty: row.int(4) ?? 3,
                mastery: row.int(5) ?? 0,
                reviewCount: row.int(6) ?? 0,
                lastReviewedAt: row.double(7).map { Date(timeIntervalSince1970: $0) },
                // NULL = v11 之前的老行 → 中性值：折算后间隔与升级前完全一致。
                // ⚠️ 这一读**没有编译器兜底**（`ease` 在 init 里有默认值，漏读照样编过），
                // 靠 `testEaseSurvivesDatabaseRoundTrip` 锁住。
                ease: row.double(10) ?? ReviewScheduler.defaultEase,
                source: source,
                createdAt: Date(timeIntervalSince1970: created)
            )
        }.compactMap { $0 }
    }

    /// 删除一条词汇（连带复习流水，外键 CASCADE）。
    public func deleteVocabulary(id: UUID) throws {
        try db.run("DELETE FROM vocabulary_items WHERE id = ?1", [.text(id.uuidString)])
    }

    /// 清除「学习记忆」喂给老师的那部分素材（**不可逆**）。
    ///
    /// 范围刻意限定在四类：纠错记录 / 练习复盘 / 跟读发音记录 / 词汇复习流水。
    /// **对话记录与单词本不删** —— 那是学员自己攒的资产，另有管理入口；
    /// 混进「清除记忆」里一起删掉是最容易挨骂的那种顺手。
    ///
    /// 返回实际删掉的数量，供上层先给用户看清楚再让他确认。
    @discardableResult
    public func clearLearningMemory() throws -> MemoryClearance {
        func count(in table: String) throws -> Int {
            try db.query("SELECT COUNT(*) FROM \(table)", []) { row in row.int(0) }
                .compactMap { $0 }
                .first ?? 0
        }
        let clearance = MemoryClearance(
            corrections: try count(in: "corrections"),
            reviews: try count(in: "session_reviews"),
            shadowing: try count(in: "shadowing_attempts"),
            vocabularyReviews: try count(in: "vocabulary_reviews")
        )
        for table in ["corrections", "session_reviews", "shadowing_attempts", "vocabulary_reviews"] {
            try db.run("DELETE FROM \(table)", [])
        }
        return clearance
    }

    /// 记一次复习：更新掌握度 / 次数 / 时间，并落复习流水。
    public func recordVocabularyReview(_ graded: VocabularyEntry, remembered: Bool) throws {
        try db.run(
            """
            UPDATE vocabulary_items
            SET mastery = ?1, review_count = ?2, last_reviewed_at = ?3, ease = ?4
            WHERE id = ?5
            """,
            [
                .int(graded.mastery),
                .int(graded.reviewCount),
                .real(graded.lastReviewedAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970),
                .real(graded.ease),
                .text(graded.id.uuidString),
            ]
        )
        try db.run(
            "INSERT INTO vocabulary_reviews (id, item_id, remembered, reviewed_at) VALUES (?1, ?2, ?3, ?4)",
            [
                .text(UUID().uuidString),
                .text(graded.id.uuidString),
                .int(remembered ? 1 : 0),
                .real(Date().timeIntervalSince1970),
            ]
        )
    }

    /// 补释义 / 例句（按需 LLM 产出后回写）。
    public func updateVocabularyDefinition(id: UUID, meaning: String, example: String) throws {
        try db.run(
            "UPDATE vocabulary_items SET meaning = ?1, example = ?2 WHERE id = ?3",
            [.text(meaning), .text(example), .text(id.uuidString)]
        )
    }

    /// 字符串列表以 JSON 数组存列（短列表，JSON 足够且可读）。
    private static func encodeList(_ items: [String]) -> String {
        let data = (try? JSONEncoder().encode(items)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// 结构化结果（如发音报告）以 JSON 存列；解码失败按缺失处理，不让坏数据弄崩读取。
    static func encodeJSON<T: Encodable>(_ value: T) -> SQLiteValue {
        guard let data = try? JSONEncoder().encode(value) else { return .null }
        guard let text = String(data: data, encoding: .utf8) else { return .null }
        return .text(text)
    }

    static func decodeJSON<T: Decodable>(_ text: String?, as type: T.Type = T.self) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
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
