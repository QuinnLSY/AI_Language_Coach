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
        // ⚠️ 需求 1 之后种子是**零进度**，所以这里的期望值来自测试自己改的那两关，
        // 不再是「种子自带的 12 星」。
        XCTAssertEqual(loaded?.totalStars, 4, "只有蜂鸟花丛补满的 4 星")
        XCTAssertEqual(LearnerProgress.seed().totalStars, 0, "种子必须是零进度（全新起点）")
        XCTAssertEqual(LearnerProgress.seed().levels.first?.state, .unlocked, "第一关开放")
        XCTAssertTrue(
            LearnerProgress.seed().levels.dropFirst().allSatisfy { $0.state == .locked },
            "第一关之后的关卡全部锁定"
        )
    }

    func testProgressReplace() async throws {        let db = try makeDB()
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

    /// 新建库上报的版本必须等于代码声明的版本。
    ///
    /// 这里刻意**不写字面量 7**：写死数字意味着每次加一次迁移就要改一遍测试，
    /// 而真正要防的是「建完表却忘了盖版本号」——那时 `db.schemaVersion()`（读 SQLite
    /// 的 user_version）与 `LearningDatabase.schemaVersion`（代码常量）会不一致。
    func testFreshDatabaseReportsDeclaredSchemaVersion() async throws {
        let db = try makeDB()
        let version = try await db.schemaVersion()
        XCTAssertEqual(version, LearningDatabase.schemaVersion)
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
        let empty = ChatSession(startedAt: Date(timeIntervalSinceNow: -90))
        // 幻影：列上写着 1 条、实际一条流水都没有（老版本不回滚计数的遗留）。
        let phantom = ChatSession(startedAt: Date(timeIntervalSinceNow: -60))
        let used = ChatSession(startedAt: Date(timeIntervalSinceNow: -30))
        try legacy.run(
            "INSERT INTO sessions (id, started_at, mode, message_count) VALUES (?1, ?2, 'conversation', 0)",
            [.text(empty.id.uuidString), .real(empty.startedAt.timeIntervalSince1970)]
        )
        try legacy.run(
            "INSERT INTO sessions (id, started_at, mode, message_count) VALUES (?1, ?2, 'conversation', 1)",
            [.text(phantom.id.uuidString), .real(phantom.startedAt.timeIntervalSince1970)]
        )
        try legacy.run(
            "INSERT INTO sessions (id, started_at, mode, message_count) VALUES (?1, ?2, 'conversation', 2)",
            [.text(used.id.uuidString), .real(used.startedAt.timeIntervalSince1970)]
        )
        try legacy.run(
            "INSERT INTO messages (id, session_id, role, content, created_at) VALUES (?1, ?2, 'user', 'hello', ?3)",
            [
                .text(UUID().uuidString), .text(used.id.uuidString),
                .real(used.startedAt.timeIntervalSince1970 + 5),
            ]
        )
        try legacy.setSchemaVersion(3)
        legacy.close()

        // 重新打开 → 迁移到最新版：空会话与幻影都被清掉，真会话保留
        let db = try LearningDatabase(path: url.path)
        let sessions = try await db.recentSessions(limit: 10)
        XCTAssertEqual(sessions.count, 1, "空会话是历史包袱，应在迁移时清掉")
        XCTAssertEqual(sessions.first?.sessionID, used.id)
        let phantomLeft = try await db.sessionSummary(id: phantom.id)
        XCTAssertNil(phantomLeft, "幻影（列上写着 1 条、实际零流水）同样是包袱 —— 留着会在界面凭空显示「1 条对话」")
        let version = try await db.schemaVersion()
        XCTAssertEqual(version, LearningDatabase.schemaVersion, "迁移后必须停在最新版")
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
        XCTAssertEqual(version, LearningDatabase.schemaVersion)

        try await db.appendShadowingAttempt(ShadowingAttempt(
            drillID: "d", referenceText: "a b c", recognizedText: "a b", accuracy: 2.0 / 3.0
        ))
        let loaded = try await db.recentShadowingAttempts(limit: 5)
        XCTAssertEqual(loaded.count, 1, "升级后应能写入并读回跟读记录")
        XCTAssertEqual(loaded.first?.drillID, "d")
    }

    // MARK: - 主线任务进度（schema v9，需求 3 / 5）

    func testQuestProgressRoundtripAndUpsert() async throws {
        let db = try makeDB()
        let sessionID = UUID()

        // ⚠️ `await` 不能进 XCTAssert 的 autoclosure —— 一律先取出值再断言。
        let nothing = try await db.questProgress(scenarioID: "restaurant")
        XCTAssertNil(nothing, "没练过就不该有记录")

        let first = ScenarioQuestRecord(
            scenarioID: "restaurant", sessionID: sessionID,
            doneStepIDs: ["s1"], isComplete: false
        )
        try await db.saveQuestProgress(first)
        var loaded = try await db.questProgress(scenarioID: "restaurant")
        XCTAssertEqual(loaded?.doneStepIDs, ["s1"])
        XCTAssertEqual(loaded?.sessionID, sessionID)

        // upsert：同一个情景再写一次是覆盖，不是新增一行。
        let second = first.merging(doneStepIDs: ["s1", "s2"], complete: false, sessionID: nil)
        try await db.saveQuestProgress(second)
        loaded = try await db.questProgress(scenarioID: "restaurant")
        XCTAssertEqual(loaded?.doneStepIDs, ["s1", "s2"])
        let all = try await db.allQuestProgress()
        XCTAssertEqual(all.count, 1, "一个情景只留一行")

        try await db.clearQuestProgress(scenarioID: "restaurant")
        let cleared = try await db.questProgress(scenarioID: "restaurant")
        XCTAssertNil(cleared, "重练这一关要能把进度清掉")
    }

    /// 复盘成功后删流水：消息清掉，**会话行、复盘、纠错必须留着**。
    /// 纠错是学习记忆不是流水 —— 错题本与「老师记住了你什么」都靠它，
    /// 清流水顺手删纠错会让复盘一跑错题本就被清空（#3 报障）。
    func testPurgeSessionMessagesKeepsSessionAndReview() async throws {
        let db = try makeDB()
        let session = ChatSession(mode: .conversation, scenarioID: "restaurant")
        try await db.createSession(session)
        try await db.appendMessage(ChatMessage(role: .assistant, content: "hi"), sessionID: session.id)
        try await db.appendMessage(ChatMessage(role: .user, content: "hello"), sessionID: session.id)
        try await db.appendCorrection(
            GrammarCorrection(original: "I go", corrected: "I went", explanation: "过去式"),
            sessionID: session.id
        )
        try await db.saveReview(SessionReview(
            sessionID: session.id, messageCount: 2, headline: "这次不错"
        ))

        let reviewedCount = try await db.reviewedMessageCount(sessionID: session.id)
        XCTAssertEqual(reviewedCount, 2, "复盘要记下当时复盘到第几条消息")

        let purged = try await db.purgeSessionMessages(sessionID: session.id)
        XCTAssertEqual(purged, 2, "被删掉的消息条数要如实返回")

        let messagesAfter = try await db.messages(sessionID: session.id)
        let correctionsAfter = try await db.corrections(sessionID: session.id)
        XCTAssertTrue(messagesAfter.isEmpty)
        XCTAssertEqual(correctionsAfter.count, 1, "纠错要留住 —— 清流水只清流水，不动学习记忆")
        XCTAssertEqual(correctionsAfter.first?.corrected, "I went")

        let summary = try await db.sessionSummary(id: session.id)
        XCTAssertNotNil(summary, "会话行必须留着 —— 记录页要显示情景名与时长")

        let keptReview = try await db.review(sessionID: session.id)
        XCTAssertEqual(keptReview?.headline, "这次不错", "复盘必须留着 —— 它就是删流水之后剩下的东西")

        let byScenario = try await db.latestReview(scenarioID: "restaurant")
        XCTAssertEqual(byScenario?.headline, "这次不错", "按情景找最近复盘要能找到（任务前情提要的原料）")
    }

    /// v8 → v9 迁移：**一次性清零闯关进度**（需求 1），同时补上任务进度表。
    func testMigrationToV9ClearsLegacyProgressAndAddsQuestTable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-v8-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let legacy = try SQLiteDatabase(path: url.path)
        try legacy.run("""
        CREATE TABLE levels (
            id TEXT PRIMARY KEY, sort_order INTEGER NOT NULL, title TEXT NOT NULL,
            subtitle TEXT NOT NULL, height_fraction REAL NOT NULL, branch TEXT NOT NULL,
            state TEXT NOT NULL, required_stars INTEGER NOT NULL, earned_stars INTEGER NOT NULL
        )
        """)
        // 老库里「前三关已通关」的假进度 —— 迁移后必须一条不剩。
        try legacy.run(
            "INSERT INTO levels VALUES ('l1', 0, '树根营地', '打招呼', 0.06, 'left', 'completed', 3, 3)"
        )
        try legacy.run(
            "INSERT INTO levels VALUES ('l2', 1, '苔藓石阶', '自我介绍', 0.18, 'right', 'completed', 3, 3)"
        )
        try legacy.setSchemaVersion(8)
        legacy.close()

        let db = try LearningDatabase(path: url.path)
        let version = try await db.schemaVersion()
        XCTAssertEqual(version, LearningDatabase.schemaVersion)

        let progressAfterMigration = try await db.loadProgress()
        XCTAssertNil(progressAfterMigration, "老进度必须被清空 —— 上一层应用层会因此写入零进度种子")

        // 任务进度表建好了（能写能读）。
        try await db.saveQuestProgress(ScenarioQuestRecord(scenarioID: "x", doneStepIDs: ["s1"]))
        let stored = try await db.questProgress(scenarioID: "x")
        XCTAssertEqual(stored?.doneStepIDs, ["s1"])
    }

    // MARK: - 复盘之后这个会话算「几条对话」（#1）
    //
    // 用户报障：记录页那条练习写着「时长 2 分 54 秒」，右边却是「0 条对话」，
    // 而同屏展开的复盘里明明白白写着「1 轮对话」。
    //
    // 根因：复盘成功会把练习流水清掉（`purgeSessionMessages`），顺手把
    // `sessions.message_count` 归零 —— 归零本身是对的（这一列的本义是「现存流水条数」），
    // 但三处会话查询直接读这一列，于是「做过复盘的那一条」永远报 0。
    // 修法是查询时用复盘行里存着的条数兜底（见 `messageCountExpression`）。

    /// 复盘 + 清流水之后：三处查询都要报复盘时记下的条数，不能塌成 0。
    func testReviewedSessionKeepsItsMessageCountAfterPurge() async throws {
        let db = try makeDB()
        let session = ChatSession(mode: .conversation)
        try await db.createSession(session)
        for content in ["hi", "hello", "good morning", "I like it"] {
            try await db.appendMessage(ChatMessage(role: .user, content: content), sessionID: session.id)
        }
        try await db.saveReview(SessionReview(sessionID: session.id, messageCount: 4, headline: "这次不错"))

        let purged = try await db.purgeSessionMessages(sessionID: session.id)
        XCTAssertEqual(purged, 4, "流水照删（这是复盘的收尾动作，不变）")

        let recent = try await db.recentSessions(limit: 20)
        XCTAssertEqual(recent.first?.messageCount, 4, "「最近练习」要沿用复盘记下的条数，而不是被清空后的 0")
        let summary = try await db.sessionSummary(id: session.id)
        XCTAssertEqual(summary?.messageCount, 4, "单会话查询（时长/轮次那一行）同一个口径")
        let windowed = try await db.sessions(since: .distantPast)
        XCTAssertEqual(windowed.first?.messageCount, 4, "窗口查询（学习进度）也要一致 —— 三处共用同一个表达式")
    }

    /// 没复盘过的会话：条数照旧读实时流水，兜底不许把 0 变成别的数。
    func testSessionWithoutReviewKeepsLiveMessageCount() async throws {
        let db = try makeDB()
        let session = ChatSession(mode: .conversation)
        try await db.createSession(session)
        try await db.appendMessage(ChatMessage(role: .user, content: "hi"), sessionID: session.id)
        try await db.appendMessage(ChatMessage(role: .assistant, content: "hello"), sessionID: session.id)

        let summariesWithOne = try await db.recentSessions(limit: 20)
        XCTAssertEqual(summariesWithOne.first?.messageCount, 2)

        // 一条消息都没有、也没复盘的会话：老实报 0（兜底不能凭空造数）。
        let empty = ChatSession(mode: .conversation)
        try await db.createSession(empty)
        let summaries = try await db.recentSessions(limit: 20)
        XCTAssertEqual(summaries.first(where: { $0.sessionID == empty.id })?.messageCount, 0)
    }

    /// 复盘之后又接着练（计数从 0 重新涨）：条数不能比复盘里那句缩水。
    func testMessageCountDoesNotShrinkBelowTheReviewedSnapshot() async throws {
        let db = try makeDB()
        let session = ChatSession(mode: .conversation)
        try await db.createSession(session)
        for content in ["a", "b", "c"] {
            try await db.appendMessage(ChatMessage(role: .user, content: content), sessionID: session.id)
        }
        try await db.saveReview(SessionReview(sessionID: session.id, messageCount: 3, headline: "不错"))
        _ = try await db.purgeSessionMessages(sessionID: session.id)

        // 复盘完又说了两句 —— 计数从 0 涨到 2，但那一段练习总共是 5 句。
        try await db.appendMessage(ChatMessage(role: .user, content: "d"), sessionID: session.id)
        try await db.appendMessage(ChatMessage(role: .assistant, content: "e"), sessionID: session.id)

        let afterMoreTalking = try await db.recentSessions(limit: 20)
        XCTAssertEqual(
            afterMoreTalking.first?.messageCount, 3,
            "取「现存条数」与「复盘快照」的较大值：既不能塌成 0，也不能比复盘里写的还少"
        )
    }

    // MARK: - 开库清理不许误伤复盘骨架（2026-09-28「学习记录回滚」报障）
    //
    // 用户报障：错题本与最近练习记录退回好几天前，年度记录却正常。
    // 根因：`runHygiene()` 旧判据「message_count = 0 且无流水且非情景」把复盘清空
    // 流水后的骨架行当空会话删掉，`corrections` 随外键（foreign_keys=ON）级联被
    // 物理清空 —— 09-23 起每天的复盘行全成孤儿、错题本回退到 09-13。
    // 新判据：「学员没发过言、也没复盘过」才可删。

    /// 复盘过的随口练会话（scenario 为空 —— 旧判据下恰好全中「空会话」）：
    /// 开库后骨架行必须幸存，纠错绝不能随级联消失。
    func testHygieneKeepsReviewedFreeTalkSkeletonAndItsCorrections() async throws {
        let db = try makeDB()
        let session = ChatSession(mode: .freeTalk)
        try await db.createSession(session)
        try await db.appendMessage(
            ChatMessage(role: .user, content: "I go to school yesterday"), sessionID: session.id
        )
        try await db.appendCorrection(
            GrammarCorrection(original: "I go", corrected: "I went", explanation: "过去式"),
            sessionID: session.id
        )
        try await db.saveReview(SessionReview(sessionID: session.id, messageCount: 1, headline: "不错"))
        let purged = try await db.purgeSessionMessages(sessionID: session.id)
        XCTAssertEqual(purged, 1, "前提：复盘收尾确实清空了流水（骨架行此刻正是旧判据眼里的「空会话」）")

        try db.runHygiene()

        let summary = try await db.sessionSummary(id: session.id)
        XCTAssertNotNil(summary, "复盘骨架行必须幸存 —— 记录页的时长与轮次全靠它兜底")
        let corrections = try await db.corrections(sessionID: session.id)
        XCTAssertEqual(corrections.count, 1, "纠错是学习记忆，绝不能随会话删除被级联清空")
    }

    /// 开屏生成的「只有一句招呼、学员没接话」的空段：开库清理，别在最近练习里刷屏。
    func testHygieneRemovesGreetingOnlySessions() async throws {
        let db = try makeDB()
        let greeting = ChatSession(mode: .conversation)
        try await db.createSession(greeting)
        try await db.appendMessage(ChatMessage(role: .assistant, content: "Welcome back!"), sessionID: greeting.id)

        try db.runHygiene()

        let summary = try await db.sessionSummary(id: greeting.id)
        XCTAssertNil(summary, "学员没参与过的空段不算一次练习 —— 下一句招呼每次都会重新生成")
    }

    /// 一条消息都没有的真空会话：照旧清理（原有行为不许退化）。
    func testHygieneStillRemovesTrulyEmptySessions() async throws {
        let db = try makeDB()
        let empty = ChatSession(mode: .conversation)
        try await db.createSession(empty)

        try db.runHygiene()

        let summary = try await db.sessionSummary(id: empty.id)
        XCTAssertNil(summary)
    }

    /// 学员发过言、还没复盘的会话：正在练，绝不能清。
    func testHygieneKeepsSessionWithLearnerMessages() async throws {
        let db = try makeDB()
        let live = ChatSession(mode: .conversation)
        try await db.createSession(live)
        try await db.appendMessage(ChatMessage(role: .assistant, content: "hi"), sessionID: live.id)
        try await db.appendMessage(ChatMessage(role: .user, content: "hello"), sessionID: live.id)

        try db.runHygiene()

        let summary = try await db.sessionSummary(id: live.id)
        XCTAssertNotNil(summary, "只清「学员从未参与」的会话，练到一半的不动")
    }

    /// 情景会话（哪怕只有开场白）也不清 —— 情景绑定是用户的选择。
    func testHygieneKeepsScenarioSessions() async throws {
        let db = try makeDB()
        let scenario = ChatSession(mode: .conversation, scenarioID: "restaurant")
        try await db.createSession(scenario)
        try await db.appendMessage(ChatMessage(role: .assistant, content: "Welcome!"), sessionID: scenario.id)

        try db.runHygiene()

        let summary = try await db.sessionSummary(id: scenario.id)
        XCTAssertNotNil(summary)
    }

    // MARK: - 按指纹删 / 改纠错（#595 单条记忆可控）

    /// 造一条会话 + 若干纠错，返回库。
    private func dbWithCorrections(_ corrections: [(original: String, corrected: String, explanation: String)]) async throws -> LearningDatabase {
        let db = try makeDB()
        let session = ChatSession()
        try await db.createSession(session)
        for item in corrections {
            try await db.appendCorrection(
                GrammarCorrection(original: item.original, corrected: item.corrected, explanation: item.explanation),
                sessionID: session.id
            )
        }
        return db
    }

    /// 忘记一处错 = 删掉它在库里的**全部**记录（界面显示的「×N」就是 N 条）。
    func testDeleteCorrectionsRemovesEveryOccurrence() async throws {
        let db = try await dbWithCorrections([
            ("He go to school", "He goes to school", "三单"),
            ("he go to school", "He goes to school", ""),
            ("a apple", "an apple", "冠词"),
        ])

        let deleted = try await db.deleteCorrections(matchingOriginal: "He go to school", corrected: "He goes to school")
        XCTAssertEqual(deleted, 2, "同一处错的两条记录必须一起删")

        let remaining = try await db.correctionRecords(since: .distantPast)
        XCTAssertEqual(remaining.count, 1, "删完只剩那一处不同的错")
        XCTAssertEqual(remaining.first?.correction.original, "a apple", "不同指纹的记录一条都不许被带走")
    }

    /// 指纹口径与 `MemoryRetriever.matchKey` 一致：大小写 / 连续空白 / 标点都不算差异。
    /// 界面把这三条显示成「同一处 ×3」，删除就必须命中三条。
    func testDeleteCorrectionsFingerprintIgnoresCaseWhitespaceAndPunctuation() async throws {
        let db = try await dbWithCorrections([
            ("He go home.", "He goes home.", ""),
            ("he  go home", "He goes home", ""),
            ("HE GO HOME", "he goes home", ""),
            ("She go home", "She goes home", "另一处"),
        ])

        let deleted = try await db.deleteCorrections(matchingOriginal: "he go home", corrected: "he goes home")
        XCTAssertEqual(deleted, 3, "归一后同指纹的三条必须全中")

        let remaining = try await db.correctionRecords(since: .distantPast)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.correction.original, "She go home")
    }

    /// 改正不同 = 不同的错：只删指定那一处，改正略不一样的记录必须留下。
    func testDeleteCorrectionsDoesNotTouchDifferentCorrection() async throws {
        let db = try await dbWithCorrections([
            ("I have went there", "I went there", ""),
            ("I have went there", "I have gone there", ""),
        ])

        let deleted = try await db.deleteCorrections(matchingOriginal: "I have went there", corrected: "I went there")
        XCTAssertEqual(deleted, 1, "只有原句→改正都相同的才算同一处")

        let remaining = try await db.correctionRecords(since: .distantPast)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.correction.corrected, "I have gone there")
    }

    /// 空原句 / 空改正没有教学信息：不许匹配任何东西，也不许误删。
    func testDeleteCorrectionsReturnsZeroForEmptyInput() async throws {
        let db = try await dbWithCorrections([("He go home", "He goes home", "")])

        let emptyOriginal = try await db.deleteCorrections(matchingOriginal: "", corrected: "He goes home")
        XCTAssertEqual(emptyOriginal, 0)
        let emptyCorrected = try await db.deleteCorrections(matchingOriginal: "He go home", corrected: "  ")
        XCTAssertEqual(emptyCorrected, 0)
        let remainingCount = try await db.correctionRecords(since: .distantPast).count
        XCTAssertEqual(remainingCount, 1, "空输入不许删掉任何东西")
    }

    /// 更新一处错：全部记录拿到同一份新文本，**原句与创建时间不动**。
    func testUpdateCorrectionsRewritesEveryOccurrenceKeepingOriginalAndTimestamp() async throws {
        let db = try await dbWithCorrections([
            ("I have went to London", "I went to London", "past tense"),
            ("i have went  to london", "I went to London", ""),
            ("She go home", "She goes home", "三单"),
        ])

        let before = try await db.correctionRecords(since: .distantPast)
        let targetBefore = before.filter { $0.correction.corrected == "I went to London" }
        XCTAssertEqual(targetBefore.count, 2)
        let timestampsBefore = targetBefore.map(\.createdAt).sorted()
        let idsBefore = Set(targetBefore.map(\.correction.id))

        let updated = try await db.updateCorrections(
            matchingOriginal: "I have went to London",
            corrected: "I went to London",
            newCorrected: "I have been to London",
            explanation: "去过某地要用 have been to"
        )
        XCTAssertEqual(updated, 2, "两条同指纹记录必须一起改")

        let after = try await db.correctionRecords(since: .distantPast)
        XCTAssertEqual(after.count, 3, "更新不是插入也不是删除，总数不变")
        let targetAfter = after.filter { $0.correction.corrected == "I have been to London" }
        XCTAssertEqual(targetAfter.count, 2)
        // 原句是学员当时真实说出的话：一个字都不能改。
        XCTAssertEqual(Set(targetAfter.map(\.correction.original)),
                       ["I have went to London", "i have went  to london"],
                       "原句必须原样保留（改了就是伪造历史）")
        // 「什么时候犯的」也不是可编辑字段。
        XCTAssertEqual(targetAfter.map(\.createdAt).sorted(), timestampsBefore, "created_at 不许被更新动")
        // id 不变：错题本、复盘里指向这条记录的引用才不会断。
        // ⚠️ 取 `correction.id`（库主键）而不是 `CorrectionRecord.id` ——
        // 后者是读取时新生成的 UUID，两次读必然不同。
        XCTAssertEqual(Set(targetAfter.map(\.correction.id)), idsBefore, "记录 id 必须保持稳定")
        // 说明按新文本写入（含空说明的那条也被覆盖）。
        XCTAssertTrue(targetAfter.allSatisfy { $0.correction.explanation == "去过某地要用 have been to" })
        // 不同指纹的记录一条都不许被扫到。
        XCTAssertEqual(after.filter { $0.correction.corrected == "She goes home" }.count, 1)
    }

    /// 没有匹配时更新返回 0，且库里什么都不能变。
    func testUpdateCorrectionsReturnsZeroWhenNothingMatches() async throws {
        let db = try await dbWithCorrections([("He go home", "He goes home", "三单")])

        // 改正换成一个库里没有的指纹（原句相同、改正不同 = 另一处错）。
        let updated = try await db.updateCorrections(
            matchingOriginal: "He go home",
            corrected: "He went home",
            newCorrected: "He goes home",
            explanation: ""
        )
        XCTAssertEqual(updated, 0, "指纹对不上就不改任何东西")

        let remaining = try await db.correctionRecords(since: .distantPast)
        XCTAssertEqual(remaining.first?.correction.corrected, "He goes home")
    }

    /// 改正为空 = 把这条错改成「没错」：那是删不是改，服务层必须挡住。
    func testUpdateCorrectionsRejectsEmptyCorrected() async throws {
        let db = try await dbWithCorrections([("He go home", "He goes home", "三单")])

        do {
            _ = try await db.updateCorrections(
                matchingOriginal: "He go home",
                corrected: "He goes home",
                newCorrected: "   ",
                explanation: ""
            )
            XCTFail("改正为空必须被挡住（那是删不是改）")
        } catch {
            XCTAssertEqual(error as? AppError, .database("改正后的句子不能为空。"))
        }
        let remaining = try await db.correctionRecords(since: .distantPast)
        XCTAssertEqual(remaining.first?.correction.corrected, "He goes home", "被挡下的更新不许留下半截状态")
    }
}
