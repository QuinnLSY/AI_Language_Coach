import AIDomain
import AIInterfaces
import AIInfrastructure
import AIProviders
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 「一段练习 = 一个会话」的归属回归。
///
/// 真机事故（2026-09-22 实机复现）：
/// 开屏流程先恢复上一段会话，再（可能）换一个新 id；而换 id 之前夹着一次复盘
/// （模型调用，几秒到几十秒）。学员在这段时间里说的话，落库时用的还是**上一段的 id** ——
/// 学员的话留在上一次练习里、老师的招呼落在这一次练习里，一段对话被劈成两半。
///
/// 症状：每次练习永远只有 1 条对话；复盘永远凑不够最低条数，
/// 于是错题本自 09-13、复盘自 09-14 起再没更新过。
///
/// 这一组用例锁的是**承重的那条守卫**：本会话已经写过消息之后，换段必须被拒绝。
@MainActor
final class PracticeSegmentTests: XCTestCase {

    // MARK: - 工具

    private func makeStore() async throws -> (ConfigStore, URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-segment-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        return (store, fileURL)
    }

    private func makeDatabasePath() throws -> (dir: URL, path: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-segment-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("learning.db").path)
    }

    private func waitUntil(_ condition: @MainActor @escaping () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    // MARK: - 承重守卫

    /// **学员开口之后不许换段**：这是「一段对话被劈成两半」的唯一防线。
    func testSessionSwitchIsRefusedOnceAnythingWasWritten() async throws {
        let (store, configURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: configURL) }

        let chat = ChatService(services: CoachServices(config: store, databasePath: ":memory:"))
        chat.send("Hello teacher, how are you today?")
        await waitUntil { chat.isGenerating == false }

        let before = chat.sessionID
        XCTAssertTrue(chat.hasWrittenInCurrentSession, "说过一句之后，这一段就算开始了")

        XCTAssertFalse(chat.beginNewSession(), "已经写过消息的会话不许被悄悄换掉")
        XCTAssertEqual(chat.sessionID, before, "被拒绝时 id 必须一动不动")
        XCTAssertFalse(chat.messages.isEmpty, "被拒绝时对话也不能被清空")
    }

    /// 还没写过东西时换段照常（开屏那条路要靠它开新段）。
    func testSessionSwitchIsAllowedBeforeAnythingIsWritten() async throws {
        let (store, configURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: configURL) }

        let chat = ChatService(services: CoachServices(config: store, databasePath: ":memory:"))
        let before = chat.sessionID

        XCTAssertTrue(chat.beginNewSession())
        XCTAssertNotEqual(chat.sessionID, before, "该换的时候必须换得动")
    }

    /// 学员**主动**开新练习（情景卡 / 考试 / 随口练）时允许覆盖守卫。
    func testUserInitiatedSwitchMayOverrideTheGuard() async throws {
        let (store, configURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: configURL) }

        let chat = ChatService(services: CoachServices(config: store, databasePath: ":memory:"))
        chat.send("I want to order a coffee.")
        await waitUntil { chat.isGenerating == false }
        let before = chat.sessionID

        XCTAssertTrue(chat.beginNewSession(allowWhenSessionHasContent: true))
        XCTAssertNotEqual(chat.sessionID, before)
    }

    // MARK: - 真机复现：学员抢在老师前面说话

    /// 复现并锁住真机事故：重启后学员**在开场之前**说话。
    ///
    /// 期望：那句话留在恢复出来的那一段会话里，且**换段被拒绝** —— 不允许出现
    /// 「学员的话在 A 会话、老师的招呼在 B 会话」这种两段各半句的结果。
    func testMessageSentBeforeOpenerStaysInTheRestoredSegment() async throws {
        let (dir, dbPath) = try makeDatabasePath()
        let (store, configURL) = try await makeStore()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: configURL)
        }

        // 第一轮运行：老师说一句、学员说两句，全部落在同一个会话里。
        let services1 = CoachServices(config: store, databasePath: dbPath)
        let chat1 = ChatService(services: services1)
        chat1.greetIfNeeded()
        await waitUntil { !chat1.messages.isEmpty }
        await waitUntil { chat1.isGenerating == false }
        for text in ["I want to order a coffee.", "And a croissant, please."] {
            chat1.send(text)
            await waitUntil { chat1.isGenerating == false }
        }
        try? await Task.sleep(for: .seconds(1))

        let firstRunSessions = await services1.recentSessions(limit: 10)
        XCTAssertEqual(firstRunSessions.count, 1, "一次运行只该有一个会话")
        let restoredID = try XCTUnwrap(firstRunSessions.first).sessionID
        let restoredCount = await services1.sessionSummary(id: restoredID)?.messageCount ?? 0
        XCTAssertEqual(restoredCount, 5, "招呼 + 两轮 = 5 条")

        // 第二轮运行：恢复上一段，学员**立刻**说话（那时开场还没跑完）。
        let services2 = CoachServices(config: store, databasePath: dbPath)
        let chat2 = ChatService(services: services2)
        await chat2.restoreLastSessionIfNeeded()
        XCTAssertEqual(chat2.sessionID, restoredID, "先把上一段恢复出来")
        XCTAssertFalse(chat2.hasWrittenInCurrentSession, "刚恢复的这一段，本轮还没写过")

        chat2.send("How much is it?")
        await waitUntil { chat2.isGenerating == false }
        XCTAssertTrue(chat2.hasWrittenInCurrentSession)

        XCTAssertFalse(chat2.beginNewSession(), "学员已经开口 → 这一段不许换")
        XCTAssertEqual(chat2.sessionID, restoredID, "那句话必须留在恢复出来的那一段里")

        try? await Task.sleep(for: .seconds(1))
        let sessions = await services2.recentSessions(limit: 10)
        XCTAssertEqual(sessions.count, 1, "不许出现「两段各半句对话」的第二个会话")
        let total = await services2.sessionSummary(id: restoredID)?.messageCount ?? 0
        XCTAssertEqual(total, 7, "5 条 + 学员一句 + 老师一句，全在同一个会话里")
    }

    /// 反过来：新一段开好之后说的话，必须落在**新**会话里（守卫不能把正常换段也堵死）。
    func testMessagesAfterAnAllowedSwitchLandInTheNewSegment() async throws {
        let (dir, dbPath) = try makeDatabasePath()
        let (store, configURL) = try await makeStore()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: configURL)
        }

        // 第一段：招呼 + 一轮对话。
        let services1 = CoachServices(config: store, databasePath: dbPath)
        let chat1 = ChatService(services: services1)
        chat1.greetIfNeeded()
        await waitUntil { !chat1.messages.isEmpty }
        await waitUntil { chat1.isGenerating == false }
        chat1.send("I want to order a coffee.")
        await waitUntil { chat1.isGenerating == false }
        try? await Task.sleep(for: .seconds(1))
        let firstID = chat1.sessionID

        // 第二段：重启后**还没写过任何消息** → 允许换段，之后的话归新段。
        let services2 = CoachServices(config: store, databasePath: dbPath)
        let chat2 = ChatService(services: services2)
        await chat2.restoreLastSessionIfNeeded()
        XCTAssertEqual(chat2.sessionID, firstID, "先恢复出上一段")
        XCTAssertTrue(chat2.beginNewSession(), "本轮还没写过东西 → 允许换段")
        XCTAssertNotEqual(chat2.sessionID, firstID)

        chat2.greetIfNeeded()
        await waitUntil { !chat2.messages.isEmpty }
        await waitUntil { chat2.isGenerating == false }
        chat2.send("Let's start again.")
        await waitUntil { chat2.isGenerating == false }
        try? await Task.sleep(for: .seconds(1))

        let sessions = await services2.recentSessions(limit: 10)
        XCTAssertEqual(sessions.count, 2, "两段各自一行")
        let newID = chat2.sessionID
        let oldCount = await services2.sessionSummary(id: firstID)?.messageCount ?? 0
        let newCount = await services2.sessionSummary(id: newID)?.messageCount ?? 0
        XCTAssertEqual(oldCount, 3, "上一段原封不动：招呼 + 学员一句 + 老师一句")
        XCTAssertEqual(newCount, 3, "新段同样 3 条，且不与上一段混在一起")
    }

    // MARK: - 复盘门槛（会话归属修好之后，它才可能成立）

    func testSegmentOfOneTurnIsNowWorthReviewing() {
        // 修好之前的真实形状：一段会话里只有老师的招呼 → 永远够不到最低条数。
        XCTAssertFalse(PracticeReviewPolicy.shouldAutoReview(messageCount: 1, lastReviewedMessageCount: 0))
        // 修好之后：招呼 + 学员一句 + 老师一句 = 3 条 → 该复盘了。
        XCTAssertTrue(PracticeReviewPolicy.shouldAutoReview(messageCount: 3, lastReviewedMessageCount: 0))
        XCTAssertFalse(
            PracticeReviewPolicy.shouldAutoReview(messageCount: 3, lastReviewedMessageCount: 3),
            "已经复盘过同样条数的不重复复盘"
        )
    }

    // MARK: - 会话时长口径（最近练习里 1180 分钟那条）

    func testSessionSummaryEndsAtItsLastMessageNotAtNow() async throws {
        let db = try LearningDatabase.inMemory()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ChatSession(id: UUID(), startedAt: start, mode: .conversation)
        try await db.createSession(session)
        for offset in [0.0, 60, 120] {
            try await db.appendMessage(
                ChatMessage(role: .user, content: "hi", createdAt: start.addingTimeInterval(offset)),
                sessionID: session.id
            )
        }

        let maybeSummary = try await db.sessionSummary(id: session.id)
        let summary = try XCTUnwrap(maybeSummary)
        XCTAssertEqual(
            summary.endedAt.timeIntervalSince(summary.startedAt), 120, accuracy: 0.5,
            "结束时刻 = 末条消息，不是「此刻」（否则时长会随刷新一直涨）"
        )
        let listed = try await db.recentSessions(limit: 1)
        XCTAssertEqual(
            try XCTUnwrap(listed.first).endedAt.timeIntervalSince(start), 120, accuracy: 0.5,
            "最近练习列表同一口径"
        )
    }

    func testSessionDurationIsCappedAndNeverGrowsWithWallClock() async throws {
        let db = try LearningDatabase.inMemory()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ChatSession(id: UUID(), startedAt: start, mode: .conversation)
        try await db.createSession(session)
        try await db.appendMessage(
            ChatMessage(role: .user, content: "hi", createdAt: start.addingTimeInterval(30)),
            sessionID: session.id
        )

        let maybeSummary = try await db.sessionSummary(id: session.id)
        let summary = try XCTUnwrap(maybeSummary)
        XCTAssertEqual(summary.endedAt.timeIntervalSince(start), 30, accuracy: 0.5)
        XCTAssertLessThan(
            summary.endedAt, Date().addingTimeInterval(-60),
            "老会话的结束时刻必须留在过去（不是 now）"
        )
    }

    // MARK: - 删流水前必须核对条数

    func testPurgeRefusesWhenMessagesArrivedDuringTheReview() async throws {
        let db = try LearningDatabase.inMemory()
        let session = ChatSession(id: UUID(), startedAt: Date(), mode: .conversation)
        try await db.createSession(session)
        for _ in 0..<4 {
            try await db.appendMessage(ChatMessage(role: .user, content: "hi"), sessionID: session.id)
        }

        // 复盘时看到 4 条，实际已经 4 条 —— 正常删。
        let tooEarly = try await db.purgeSessionMessages(sessionID: session.id, expectedCount: 3)
        XCTAssertEqual(tooEarly, -1, "条数对不上 → 拒绝")
        let afterRefusal = try await db.messageCount(sessionID: session.id)
        XCTAssertEqual(afterRefusal, 4, "拒绝时一条都不能少")

        let purged = try await db.purgeSessionMessages(sessionID: session.id, expectedCount: 4)
        XCTAssertEqual(purged, 4)
        let remaining = try await db.messageCount(sessionID: session.id)
        XCTAssertEqual(remaining, 0)
        let sessions = try await db.recentSessions(limit: 1)
        XCTAssertTrue(
            sessions.contains { $0.sessionID == session.id },
            "会话行要留着（上次练习卡片还要用它）"
        )
    }

    // MARK: - 开屏续聊

    func testCarryOverOpenerUsesTheReviewAndFallsBackWhenEmpty() throws {
        let review = SessionReview(
            sessionID: UUID(),
            duration: 600,
            messageCount: 6,
            correctionCount: 3,
            headline: "点单很顺，时态还差点",
            newWords: ["croissant"],
            strengths: ["敢开口"],
            improvements: ["过去时漏 -ed"],
            suggestion: "今天用过去时说三句"
        )
        let prompt = PromptBuilder.continuationOpenerPrompt(review: review)
        XCTAssertTrue(prompt.contains("点单很顺"), "开场指令必须带上上次的结论")
        XCTAssertTrue(prompt.contains("过去时漏 -ed"), "待改进项要进去")
        XCTAssertTrue(prompt.contains("croissant"), "上次的新词要进去")

        let block = PromptBuilder.continuationBlock(review)
        XCTAssertTrue(block.contains("点单很顺"), "整段会话都要知道上次发生了什么")

        // 空复盘：宁可不提，也不能给模型一个空槽位让它编一段「上次」。
        let empty = SessionReview(sessionID: UUID())
        let emptyPrompt = PromptBuilder.continuationOpenerPrompt(review: empty)
        XCTAssertFalse(emptyPrompt.contains("Last practice"), "没有复盘就不许出现「上次」")
        XCTAssertTrue(PromptBuilder.continuationBlock(empty).isEmpty)
        XCTAssertFalse(PracticeReviewPolicy.hasContent(empty))
        XCTAssertTrue(PracticeReviewPolicy.hasContent(review))
    }

    /// 续聊开场必须**真的开口**：`deliverOpener` 以前只认情景 / 随口练 / 考试，
    /// 续聊这条路会直接 return，老师一个字都不说。
    func testContinuationOpenerActuallySpeaks() async throws {
        let (store, configURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: configURL) }

        let chat = ChatService(services: CoachServices(config: store, databasePath: ":memory:"))
        let review = SessionReview(
            sessionID: UUID(), headline: "上次点单很顺", improvements: ["过去时漏 -ed"]
        )
        chat.beginContinuation(review: review)
        chat.deliverOpener()
        await waitUntil { !chat.messages.isEmpty || !chat.isGenerating }

        XCTAssertFalse(chat.messages.isEmpty, "续聊开场不能一声不吭")
        XCTAssertEqual(chat.messages.first?.role, .assistant)
    }
}
