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
        try runHygiene()
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
        // 年度学习记录按 created_at 扫全年消息，没索引就是全表扫（消息是最大的一张表）。
        try db.run("CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at)")

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

        // 错题汇总 / 年度纠错密度都按 created_at 扫时间窗口。
        try db.run("CREATE INDEX IF NOT EXISTS idx_corrections_created ON corrections(created_at)")

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
        // 词汇业务唯一键是 word（大小写不敏感去重）：NOCASE 唯一索引让 upsertVocabulary
        // 的「查重」与 INSERT 都走索引，且从数据库层面兜住大小写重复（列上的 UNIQUE 是 BINARY 口径，管不住）。
        // ⚠️ 老库若已攒下大小写重复行，直接建唯一索引会失败 → 先去重（保留最早插入的一行，
        // 它握着复习进度这份学习资产），再建索引。
        try db.run(
            """
            DELETE FROM vocabulary_items
            WHERE EXISTS (
                SELECT 1 FROM vocabulary_items w
                WHERE w.word = vocabulary_items.word COLLATE NOCASE
                  AND (w.created_at < vocabulary_items.created_at
                       OR (w.created_at = vocabulary_items.created_at AND w.id < vocabulary_items.id))
            )
            """
        )
        try db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_vocab_word_nocase ON vocabulary_items(word COLLATE NOCASE)")
        try db.run("""
        CREATE TABLE IF NOT EXISTS vocabulary_reviews (
            id TEXT PRIMARY KEY,
            item_id TEXT NOT NULL REFERENCES vocabulary_items(id) ON DELETE CASCADE,
            remembered INTEGER NOT NULL,
            reviewed_at REAL NOT NULL
        )
        """
        )
        // 复习历史按 reviewed_at 取最近窗口。
        try db.run("CREATE INDEX IF NOT EXISTS idx_vocab_reviews_created ON vocabulary_reviews(reviewed_at DESC)")

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
    /// 开库清理「学员从未参与」的会话。
    ///
    /// ⚠️ 判据是「学员没发过言、也没复盘过」，**不是** `message_count = 0`：
    /// 复盘成功后 `purgeSessionMessages` 会清空流水、把计数归零（设计如此，骨架行要留下，
    /// `endedExpression` / `messageCountExpression` 专门为它兜底）。旧判据「count = 0 且无流水」
    /// 下，复盘过的随口练会话恰好全中「空会话」，开库即删 —— `corrections` 随外键级联
    /// 被物理清空，错题本每天退回几天前（2026-09-28 取证实锤：09-23 起的复盘行全成孤儿）。
    ///
    /// 因此只删两类：一条消息都没有的真空会话；「只有开场白」的空段
    /// （开屏招呼落了库、学员没接话 —— 反正下一句招呼每次都重新生成）。
    /// 情景会话、复盘过的会话、学员发过言还没复盘的会话一律不动。
    public nonisolated func runHygiene() throws {
        try db.run("""
        DELETE FROM sessions
        WHERE scenario_id IS NULL AND id != 'archive'
          AND NOT EXISTS (SELECT 1 FROM session_reviews WHERE session_reviews.session_id = sessions.id)
          AND NOT EXISTS (SELECT 1 FROM messages WHERE messages.session_id = sessions.id AND messages.role = 'user')
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

    /// 会话「开始时刻」的唯一口径：**首条消息的时间**；一条消息都没有才退回建行的时刻。
    ///
    /// ⚠️ 只信 `started_at` 会算出差时长：那一列是「会话行落盘那一刻」写的 `Date()`，
    /// 不是「学员开口那一刻」。实测库里出现过 `started_at` 比末条消息还晚 5–6 秒的行
    /// （`D4341083…` / `D7BB801F…` / `8517689B…`），
    /// 于是 `末条 − 开始` 为负、被夹到 0，卡片上就是「练了一段、时长 0 秒」。
    /// 三处会话查询共用这一个表达式，改口径只改这一行。
    static let startedExpression = """
    COALESCE((SELECT MIN(created_at) FROM messages WHERE messages.session_id = sessions.id), started_at)
    """

    /// 会话「结束时刻」的唯一口径：**末条消息的时间** → 复盘记下的时长 → 开始时刻。
    ///
    /// ⚠️ 以前这里写的是 `COALESCE(ended_at, now)`。而 `ended_at` 实际上从来没有被写过
    /// （会话不显式结束 —— `finishSession` 在正常使用路径上没人调），于是
    /// 「结束时刻」永远等于「此刻」：每个会话的时长都变成「从开始到此刻」，
    /// 昨天开的会话今天看是 1180 分钟，而且每刷新一次还在涨。
    ///
    /// ⚠️ 第二级兜底（复盘时长）是为**已经删掉流水的历史行**补的：
    /// 复盘完会把消息清掉（`purgeSessionMessages`），清了之后 `MAX(created_at)` 是 NULL、
    /// 只剩 `started_at`，跨度归零 —— 而同一屏的复盘卡里明明写着「37 分 35 秒」。
    /// 复盘行里存着 `duration`，拿它还原结束时刻，卡片与复盘就再也对不上了。
    /// 三处会话查询共用这一个表达式，改口径只改这一行。
    static let endedExpression = """
    COALESCE(ended_at, (SELECT MAX(created_at) FROM messages WHERE messages.session_id = sessions.id), (SELECT started_at + duration FROM session_reviews WHERE session_reviews.session_id = sessions.id AND duration > 0 ORDER BY created_at DESC LIMIT 1), started_at)
    """

    /// 会话「对话条数」的唯一口径：**现存的流水条数** → 复盘时记下的条数 → 0。
    ///
    /// ⚠️ 只读 `sessions.message_count` 会算出「0 条对话」：复盘成功后
    /// `purgeSessionMessages` 会把消息清掉、并把这一列归零
    /// （归零让这一列始终守住「现存流水条数」的本义；`runHygiene()` 已不看这一列）。
    /// 于是「最近练习」里那一条明明写着「时长 2 分 54 秒」，右边却是「0 条对话」，
    /// 而同屏展开的复盘里写着「1 轮对话」—— 同一件事在三个地方各说各的。
    /// 复盘行里存着当时的条数，拿它兜底，卡片与复盘就再也打不了架。
    ///
    /// 取两者**较大值**而不是「0 就用复盘顶着」：复盘之后又接着聊了几句时
    /// （清过流水、计数从 0 重新涨），计数不会比复盘里那句缩水。
    /// 三处会话查询共用这一个表达式，改口径只改这一行。
    static let messageCountExpression = """
    MAX(COALESCE(message_count, 0), COALESCE((SELECT message_count FROM session_reviews WHERE session_reviews.session_id = sessions.id ORDER BY created_at DESC LIMIT 1), 0))
    """

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

    /// 某会话的消息（按时间正序）。开屏恢复上次会话、导出学习记录都用它。
    ///
    /// - Parameter limit: 最多取多少条；`nil` = 不限。
    ///
    /// 超限时留**最近**的那些：内部按时间**倒序**取、返回前翻回正序 ——
    /// 对话是有头的，丢掉最老的那一截不伤上下文，反过来（留最老的）等于把当前状态截没。
    ///
    /// ⚠️ 导出路径（`CoachServices.exportLearningRecords`）必须传 `nil`：截断等于悄悄
    /// 少给用户几条学习记录，而那种「少」没有任何人会察觉。
    public func messages(sessionID: UUID, limit: Int? = nil) throws -> [ChatMessage] {
        let decodeRow: (SQLiteRow) -> ChatMessage? = { row in
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

        if let limit {
            guard limit > 0 else { return [] }
            let rows = try db.query(
                """
                SELECT id, role, content, created_at, reasoning, attachments
                FROM messages WHERE session_id = ?1
                ORDER BY created_at DESC, rowid DESC
                LIMIT ?2
                """,
                [.text(sessionID.uuidString), .int(limit)],
                map: decodeRow
            )
            return Array(rows.compactMap { $0 }.reversed())
        }

        let rows = try db.query(
            "SELECT id, role, content, created_at, reasoning, attachments FROM messages WHERE session_id = ?1 ORDER BY created_at ASC, rowid ASC",
            [.text(sessionID.uuidString)],
            map: decodeRow
        )
        return rows.compactMap { $0 }
    }

    // MARK: - 消息的删 / 改（气泡内的操作）

    /// 删掉若干条消息。
    ///
    /// ⚠️ **删完必须把 `sessions.message_count` 重新对齐**（见 `syncMessageCount`）：
    /// 这个列是**存储字段**（`appendMessage` 自增），不是实时 COUNT。
    /// 光删行不校数，这一列就会虚高 —— 它还参与「对话条数」的取大值口径，
    /// 显示上永远比真实多。
    ///
    /// - Returns: 真的删掉的行数（id 不存在的不算）。
    @discardableResult
    public func deleteMessages(ids: [UUID], sessionID: UUID) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try db.runInTransaction {
            let before = try messageCount(sessionID: sessionID)
            // ⚠️ 必须**分页**：SQLite 的绑定变量数有上限（旧版 999），长会话点「重新生成」会一次
            // 传上千个 id —— 超限时 `sqlite3_prepare_v2` 直接失败、整条事务回滚，
            // 表现为「界面上的消息消失了、库里一条没删」，下次启动整批复活。
            // 一批留一个变量给 `session_id`，所以是 `maxBoundVariables - 1`。
            for batch in ids.batched(SQLiteDatabase.maxBoundVariables - 1) {
                let placeholders = batch.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ", ")
                try db.run(
                    "DELETE FROM messages WHERE session_id = ?\(batch.count + 1) AND id IN (\(placeholders))",
                    batch.map { .text($0.uuidString) } + [.text(sessionID.uuidString)]
                )
            }
            let after = try messageCount(sessionID: sessionID)
            try syncMessageCount(sessionID: sessionID)
            return max(before - after, 0)
        }
    }

    /// 改写一条消息的正文（气泡内编辑后重发）。
    ///
    /// 用**同一个 id** 覆盖而不是「删旧行 + 插新行」：这条消息的附件、时间戳、
    /// 以及界面上的滚动锚点（`ScrollViewReader` 按 id 定位）都跟着它走，
    /// 换成新 id 等于让「编辑」表现成「删一条又冒出一条」。
    public func updateMessageContent(id: UUID, content: String) throws {
        try db.run(
            "UPDATE messages SET content = ?1 WHERE id = ?2",
            [.text(content), .text(id.uuidString)]
        )
    }

    /// 把 `sessions.message_count` 重算成 `messages` 表的实际条数。
    ///
    /// ⚠️ 这是这个列**唯一**的校正口：凡是绕过 `appendMessage` 的删除
    /// （清理流水、删气泡）都必须调它一次。计数错比数据错更难查 ——
    /// 数据错看得见，计数错只是让「最近练习」的条数说谎。
    public func syncMessageCount(sessionID: UUID) throws {
        try db.run(
            """
            UPDATE sessions
            SET message_count = (SELECT COUNT(*) FROM messages WHERE messages.session_id = sessions.id)
            WHERE id = ?1
            """,
            [.text(sessionID.uuidString)]
        )
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

    /// 开屏恢复时最多回填多少条消息（见 `latestSession`）。
    ///
    /// 正常一次练习就几百条（复盘后流水还会被清），2000 已是极宽松的余量。
    /// 定上限的理由是这一步跑在**开屏同步**路径上：真出现上万条的会话，
    /// 一次性物化卡的正是启动那一下最不该卡的地方。
    public static let maxRestoredMessages = 2000

    /// 最近一个会话（含消息）。没有历史会话时返回 nil。
    public func latestSession() throws -> (session: ChatSession, messages: [ChatMessage])? {
        let rows = try db.query(
            "SELECT id, \(Self.startedExpression), mode, scenario_id FROM sessions WHERE id != 'archive' ORDER BY \(Self.startedExpression) DESC LIMIT 1"
        ) { row -> (UUID, Date, PracticeMode, String?)? in
            guard let idText = row.string(0), let id = UUID(uuidString: idText),
                  let started = row.double(1),
                  let modeRaw = row.string(2), let mode = PracticeMode(rawValue: modeRaw)
            else { return nil }
            return (id, Date(timeIntervalSince1970: started), mode, row.string(3))
        }
        guard let first = rows.compactMap({ $0 }).first else { return nil }
        let session = ChatSession(id: first.0, startedAt: first.1, mode: first.2, scenarioID: first.3)
        // 只给**恢复**这条路加上限（导出学习记录那条路不传 limit，见 `messages(sessionID:limit:)`）。
        return (session, try messages(sessionID: first.0, limit: Self.maxRestoredMessages))
    }

    public func finishSession(id: UUID, endedAt: Date = Date()) throws {
        try db.run(
            "UPDATE sessions SET ended_at = ?2 WHERE id = ?1",
            [.text(id.uuidString), .real(endedAt.timeIntervalSince1970)]
        )
    }

    public func recentSessions(limit: Int = 20) throws -> [SessionSummary] {
        let rows = try db.query(
            """
            SELECT id, \(Self.startedExpression) AS started, \(Self.endedExpression) AS ended, \(Self.messageCountExpression) AS message_count, scenario_id
            FROM sessions WHERE id != 'archive' ORDER BY started DESC LIMIT ?1
            """,
            [.int(limit)]
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

    /// 在对话正文里搜关键词（#414 全局搜索）。
    ///
    /// ⚠️ 用 LIKE + 参数绑定，**绝不把用户输入拼进 SQL**：拼字符串时一个引号
    /// 就能让整条查询变成语法错误（或更糟）。
    /// ⚠️ `%` 与 `_` 是 LIKE 自己的通配符：用户搜「50%」不该命中一切含数字的消息，
    /// 所以要先转义再包 `%…%`（`ESCAPE '\'` 与这里的转义符是同一套）。
    /// ⚠️ 排除 `archive` 会话：那是复盘后归档的旧流水，不是用户练过的对话。
    public func searchMessages(query: String, limit: Int = 30) throws -> [GlobalSearchMessage] {
        let needle = GlobalSearch.normalize(query)
        guard !needle.isEmpty else { return [] }
        let pattern = "%" + Self.likeEscaped(needle) + "%"
        let rows = try db.query(
            """
            SELECT m.id, m.session_id, m.role, m.content, m.created_at
            FROM messages m
            WHERE m.content LIKE ?1 ESCAPE '\\' AND m.session_id != 'archive'
            ORDER BY m.created_at DESC
            LIMIT ?2
            """,
            [.text(pattern), .int(limit)]
        ) { row -> GlobalSearchMessage? in
            guard let messageID = row.string(0),
                  let sessionText = row.string(1),
                  let sessionID = UUID(uuidString: sessionText),
                  let role = row.string(2),
                  let content = row.string(3),
                  let created = row.double(4)
            else { return nil }
            return GlobalSearchMessage(
                sessionID: sessionID,
                messageID: messageID,
                role: role,
                snippet: GlobalSearch.snippet(text: content, query: needle),
                createdAt: Date(timeIntervalSince1970: created)
            )
        }
        return rows.compactMap { $0 }
    }

    /// LIKE 通配符转义（% / _ / 转义符本身）。
    static func likeEscaped(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "%", "_", "\\":
                out.append("\\")
                out.append(character)
            default:
                out.append(character)
            }
        }
        return out
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
            SELECT id, \(Self.startedExpression) AS started, \(Self.endedExpression) AS ended, \(Self.messageCountExpression) AS message_count, scenario_id
            FROM sessions
            WHERE \(Self.startedExpression) >= ?1 AND id != 'archive'
            ORDER BY started DESC LIMIT ?2
            """,
            [.real(since.timeIntervalSince1970), .int(limit)]
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
            """
            SELECT id, \(Self.startedExpression), \(Self.endedExpression), \(Self.messageCountExpression), scenario_id
            FROM sessions WHERE id = ?1
            """,
            [.text(id.uuidString)]
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
    ///
    /// ⚠️ `expectedCount` 是**同一个事务内**的比对基数。复盘是一次模型调用（几秒到几十秒），
    /// 这期间学员完全可能又说了几句 —— 那些话不在复盘里，照删就是「我没说过的话被静默丢掉」。
    /// 数量对不上就不删（宁可留着重叠，也不能丢内容）。
    ///
    /// - Returns: 删掉的消息条数；**-1 表示「消息数已变，本次不删」**。
    @discardableResult
    public func purgeSessionMessages(sessionID: UUID, expectedCount: Int? = nil) throws -> Int {
        try db.runInTransaction {
            let actual = try messageCount(sessionID: sessionID)
            if let expectedCount, actual != expectedCount { return -1 }
            guard actual > 0 else { return 0 }
            // ⚠️ **删流水之前先把两个时刻冻到列上**，且必须在 DELETE 之前执行
            // （下面的子查询要读 `messages`，删了就什么都算不出来了）。
            // 不冻的后果：清完之后 `MAX(created_at)` 成了 NULL、`ended_at` 又是 NULL，
            // 「结束时刻」只能退回 `started_at` —— 于是同屏的复盘卡写着「37 分 35 秒」，
            // 上面那条记录却写着「0 秒」（用户报障的正是这一条）。
            // 冻的就是「此刻查询本来会算出来的那两个值」，所以读取口径零变化。
            try db.run(
                """
                UPDATE sessions
                SET started_at = \(Self.startedExpression), ended_at = \(Self.endedExpression)
                WHERE id = ?1
                """,
                [.text(sessionID.uuidString)]
            )
            // ⚠️ 纠错（corrections）**不删**：它是学习记忆，不是流水。
            // 错题本、复盘里的「老师记住了你什么」、反复错误统计都靠它 ——
            // 以前这里顺手 DELETE，复盘一跑错题本就被清空（#3 报障的根因）。
            // 它的生命周期归 `clearLearningMemory`（用户显式清除）管。
            try db.run("DELETE FROM messages WHERE session_id = ?1", [.text(sessionID.uuidString)])
            // ⚠️ 顺手把 `message_count` 归零：这一列的本义是「现存流水条数」，
            // 清完必须归零，否则取大值口径会拿虚高值（`runHygiene()` 已不看这一列）。
            try syncMessageCount(sessionID: sessionID)
            return actual
        }
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

    /// 每句跟读的**最近一次**记录（`drill_id` → 最新那一条）。
    ///
    /// 用途：跟读页「每句的分析常驻」在**重启之后**要能把之前读过的那几句摆回来，
    /// 而内存缓存那时是空的。
    ///
    /// 排序取候选、再在 Swift 里每句留第一条（而不是 `GROUP BY` + 窗口函数）：
    /// 一次最多几十句，SQL 好读比省那点遍历更值钱。
    public func latestShadowingAttempts(drillIDs: [String]) throws -> [String: ShadowingAttempt] {
        guard !drillIDs.isEmpty else { return [:] }
        // ⚠️ 同一个绑定变量上限的问题（见 `deleteMessages`），这里也分页。
        // 合并口径与「一次取全再每句留第一条」**等价**：每批各自按时间倒序，
        // 跨批取 `createdAt` 更晚的那条。
        var latest: [String: ShadowingAttempt] = [:]
        for batch in drillIDs.batched(SQLiteDatabase.maxBoundVariables) {
            let placeholders = batch.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ", ")
            let rows = try db.query(
                """
                SELECT id, drill_id, reference, recognized, accuracy, pronunciation, created_at
                FROM shadowing_attempts
                WHERE drill_id IN (\(placeholders))
                ORDER BY created_at DESC
                """,
                batch.map { .text($0) }
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
            for row in rows {
                if let existing = latest[row.drillID], existing.createdAt >= row.createdAt { continue }
                latest[row.drillID] = row
            }
        }
        return latest
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

    /// 最近读过的短文（**新 → 旧**，供跨页搜索用）。
    ///
    /// 为什么要有它（2026-10-01）：全局搜索的「阅读」来源原本只读内存里的
    /// `readingEntries` —— 那是**今天**那一两篇，而且没进过阅读页时是空的，
    /// 于是搜索框写着「搜读过的短文」却一条都搜不到（昨天、上周读的更搜不到）。
    /// 封顶 `limit`：一年也就几百篇，取最近这些足够兜住「我读过的」。
    public func recentReadings(limit: Int = 200) throws -> [StoredReading] {
        try db.query(
            """
            SELECT id, payload, choices, is_reviewed, created_at
            FROM reading_passages ORDER BY created_at DESC, rowid DESC LIMIT ?1
            """,
            [.int(limit)]
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

    /// 批量插入生词（按 word 大小写不敏感去重，已有词**不动**，保住复习进度）。
    /// 返回真正新插入的个数。
    ///
    /// 一次事务里「先取一遍现有词、再只插缺的」：复盘导入原来是双循环逐词
    /// upsert —— 每个词都带一次 `COLLATE NOCASE` 全表扫（命中不了 BINARY 索引），
    /// 一次导入 20 条就是 20 次全表扫。这里把「读现状」收敛成一遍，整批一个事务，
    /// 中途失败整体回滚，不会留下插一半的生词。
    public func insertVocabularyIfAbsent(_ entries: [VocabularyEntry]) throws -> Int {
        guard !entries.isEmpty else { return 0 }
        var existing = Set<String>()
        let words = try db.query("SELECT word FROM vocabulary_items") { row in
            row.string(0) ?? ""
        }
        words.forEach { existing.insert($0.lowercased()) }
        var inserted = 0
        try db.runInTransaction {
            for entry in entries {
                guard !entry.word.isEmpty,
                      !existing.contains(entry.word.lowercased())
                else { continue }
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
                existing.insert(entry.word.lowercased())
                inserted += 1
            }
            return ()
        }
        return inserted
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

    /// 四类学习记忆当前的条数（不删任何东西）。
    ///
    /// 供「清除记忆」在动手前判断有没有可删的：没有就不留底、不走删除，
    /// 免得每次点一下都往备份目录塞一份空包。
    public func learningMemoryCounts() throws -> MemoryClearance {
        func count(in table: String) throws -> Int {
            try db.query("SELECT COUNT(*) FROM \(table)", []) { row in row.int(0) }
                .compactMap { $0 }
                .first ?? 0
        }
        return MemoryClearance(
            corrections: try count(in: "corrections"),
            reviews: try count(in: "session_reviews"),
            shadowing: try count(in: "shadowing_attempts"),
            vocabularyReviews: try count(in: "vocabulary_reviews")
        )
    }

    /// 清除「学习记忆」喂给老师的那部分素材（**不可逆**）。
    ///
    /// 范围刻意限定在四类：纠错记录 / 练习复盘 / 跟读发音记录 / 词汇复习流水。
    /// **对话记录与单词本不删** —— 那是学员自己攒的资产，另有管理入口；
    /// 混进「清除记忆」里一起删掉是最容易挨骂的那种顺手。
    ///
    /// 计数与删除都在**同一个事务**里：中途任何一条 DELETE 失败就整体回滚，
    /// 绝不出现「纠错删了、复盘还剩一半」的半清除状态。
    ///
    /// 返回实际删掉的数量，供上层先给用户看清楚再让他确认。
    @discardableResult
    public func clearLearningMemory() throws -> MemoryClearance {
        try db.runInTransaction { () -> MemoryClearance in
            func count(in table: String) throws -> Int {
                try self.db.query("SELECT COUNT(*) FROM \(table)", []) { row in row.int(0) }
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
                try self.db.run("DELETE FROM \(table)", [])
            }
            return clearance
        }
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

// MARK: - 绑定变量分页

private extension Array {
    /// 按 `size` 切成若干批。
    ///
    /// 存在的唯一理由是**绑定变量上限**：SQLite 旧版本单条语句最多 999 个 `?N`，
    /// 批量 `IN (...)` 一旦越线就是 `sqlite3_prepare_v2` 失败 → 整条事务回滚。
    /// 切批是唯一稳的解法（越限时报错信息指向 SQL 形状，不会告诉你是「参数太多」）。
    func batched(_ size: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        guard size > 0, count > size else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
