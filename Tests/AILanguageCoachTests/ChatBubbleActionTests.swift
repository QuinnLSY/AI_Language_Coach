import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 气泡上的动作：**删除 / 编辑重发 / 重新生成**（复制是纯前端，这里不测）。
///
/// 这组用例锁的是三条**口径**（每一条都跟用户确认过）：
/// ① 删学员那一句，**它的老师回复一起删** —— 老师气泡没有删除按钮，
///    只删学员那条会留下一条没有提问的回复，而学员再也删不掉它；
/// ② 编辑重发 = **从此处重新开始对话**（这条之后的全部作废，纠错/复盘等产物不动）；
/// ③ 重新生成 = 换掉这条回复，**它之后的同样作废**（只换中间一条，
///    后面的对话就建立在一段已经不存在的话上了）。
///
/// ⚠️ 数据库侧另有一条不变量：删完消息必须把 `sessions.message_count` 对齐。
/// 那一列是**存储字段**（`appendMessage` 自增），不是实时 COUNT ——
/// 光删行不校数，计数会一直说谎（`hygiene()` 还拿它判「空会话」）。
@MainActor
final class ChatBubbleActionTests: XCTestCase {

    // MARK: - 工具

    private func makeStore() async throws -> (ConfigStore, URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-bubble-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        return (store, fileURL)
    }

    private func makeDatabasePath() throws -> (dir: URL, path: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-bubble-db-\(UUID().uuidString)", isDirectory: true)
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

    /// 开一段「招呼 + 两轮问答」的对话（5 条：a / u / a / u / a）。
    private func makeConversation(services: CoachServices) async throws -> ChatService {
        let chat = ChatService(services: services)
        chat.greetIfNeeded()
        await waitUntil { !chat.messages.isEmpty }
        await waitUntil { chat.isGenerating == false }
        for text in ["I want to order a coffee.", "And a croissant, please."] {
            chat.send(text)
            await waitUntil { chat.isGenerating == false }
        }
        return chat
    }

    private func storedMessages(_ dbPath: String, sessionID: UUID) async throws -> [ChatMessage] {
        // 每次新开一个连接读盘：写是 `persist` 里 fire-and-forget 的 Task 干的，
        // 复用同一个句柄读不到「另一次打开」看到的东西。
        try await LearningDatabase(path: dbPath).messages(sessionID: sessionID)
    }

    // MARK: - 删除：成对

    func testDeletingALearnerBubbleTakesItsReplyWithIt() async throws {
        let (store, configURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: configURL) }
        let services = CoachServices(config: store, databasePath: ":memory:")
        let chat = try await makeConversation(services: services)

        let snapshot = chat.messages
        XCTAssertEqual(snapshot.count, 5, "招呼 + 两轮 = 5 条")
        let target = try XCTUnwrap(snapshot.first { $0.role == .user })
        let targetIndex = try XCTUnwrap(snapshot.firstIndex { $0.id == target.id })
        let reply = snapshot[targetIndex + 1]
        XCTAssertEqual(reply.role, .assistant, "问题后面紧跟着的就是它的回答")

        chat.deleteMessage(target.id)

        XCTAssertFalse(chat.messages.contains { $0.id == target.id }, "学员那一句没了")
        XCTAssertFalse(chat.messages.contains { $0.id == reply.id }, "它的老师回复也必须一起走")
        XCTAssertEqual(chat.messages.count, 3, "5 条减一轮问答 = 3 条")
        XCTAssertEqual(chat.messages.first?.role, .assistant, "招呼还在")
    }

    /// 删中间一轮**不许牵连别轮**：剩下的顺序与内容必须原样。
    func testDeletingTheMiddleTurnLeavesTheOtherTurnsIntact() async throws {
        let (store, configURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: configURL) }
        let services = CoachServices(config: store, databasePath: ":memory:")
        let chat = try await makeConversation(services: services)

        let snapshot = chat.messages
        let firstUser = try XCTUnwrap(snapshot.first { $0.role == .user })
        let index = try XCTUnwrap(snapshot.firstIndex { $0.id == firstUser.id })
        let firstReply = snapshot[index + 1]
        XCTAssertEqual(firstReply.role, .assistant)
        let survivors = snapshot.filter { $0.id != firstUser.id && $0.id != firstReply.id }

        chat.deleteMessage(firstUser.id)

        XCTAssertEqual(chat.messages.map(\.id), survivors.map(\.id), "只少了那一轮的一问一答")
        XCTAssertEqual(chat.messages.last?.id, snapshot.last?.id, "最后一条（老师第二轮）不受影响")
    }

    /// 删完必须落库，并且 `message_count` 要跟着对齐。
    func testDeletingPersistsAndRealignsTheStoredCount() async throws {
        let (dir, dbPath) = try makeDatabasePath()
        let (store, configURL) = try await makeStore()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: configURL)
        }
        let services = CoachServices(config: store, databasePath: dbPath)
        let chat = try await makeConversation(services: services)
        let sessionID = chat.sessionID
        try? await Task.sleep(for: .seconds(1))
        let beforeSummary = await services.sessionSummary(id: sessionID)
        XCTAssertEqual(try XCTUnwrap(beforeSummary).messageCount, 5)

        let target = try XCTUnwrap(chat.messages.first { $0.role == .user })
        chat.deleteMessage(target.id)
        try? await Task.sleep(for: .seconds(1))

        let afterSummary = await services.sessionSummary(id: sessionID)
        XCTAssertEqual(
            try XCTUnwrap(afterSummary).messageCount, 3,
            "计数必须跟着删 —— 它是存储字段，不会自己变"
        )
        let rows = try await storedMessages(dbPath, sessionID: sessionID)
        XCTAssertEqual(rows.count, 3, "库里也只剩 3 条")
        XCTAssertFalse(rows.contains { $0.id == target.id })
    }

    // MARK: - 编辑重发：从此处重新开始

    func testEditingTruncatesEverythingAfterAndAsksAgain() async throws {
        let (dir, dbPath) = try makeDatabasePath()
        let (store, configURL) = try await makeStore()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: configURL)
        }
        let services = CoachServices(config: store, databasePath: dbPath)
        let chat = try await makeConversation(services: services)
        let sessionID = chat.sessionID

        let target = try XCTUnwrap(chat.messages.first { $0.role == .user })
        chat.resendEditedMessage(target.id, text: "I would like a large latte, please.")

        // ① 这条之后的一切当场作废；**这条之前的不动**（老师那句招呼还在它前面）。
        XCTAssertEqual(chat.messages.count, 2, "招呼 + 改写后的这一句")
        XCTAssertEqual(chat.messages.last?.id, target.id, "还是同一个 id（不是「删一条又冒一条」）")
        XCTAssertEqual(chat.messages.last?.content, "I would like a large latte, please.")

        // ② 老师确实被重新问了一次。
        XCTAssertTrue(chat.isGenerating, "编辑后要重新生成老师回复")
        await waitUntil { chat.isGenerating == false }
        XCTAssertEqual(chat.messages.count, 3, "招呼 + 改后的问 + 老师的新回复")
        XCTAssertEqual(chat.messages.last?.role, .assistant)

        // ③ 库里同步：被作废的那几条不能还躺在数据库中。
        try? await Task.sleep(for: .seconds(1))
        let rows = try await storedMessages(dbPath, sessionID: sessionID)
        XCTAssertEqual(rows.count, 3, "库里只剩招呼、改后的问与新的答")
        XCTAssertEqual(
            rows.first { $0.id == target.id }?.content,
            "I would like a large latte, please.",
            "改写过的正文要落库"
        )
    }

    /// 编辑到空白的输入不该被当成「清空这一句」：一个空消息会把上下文搅坏。
    func testEditingToWhitespaceIsIgnored() async throws {
        let (store, configURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: configURL) }
        let services = CoachServices(config: store, databasePath: ":memory:")
        let chat = try await makeConversation(services: services)

        let snapshot = chat.messages
        let target = try XCTUnwrap(snapshot.first { $0.role == .user })
        chat.resendEditedMessage(target.id, text: "   \n  ")

        XCTAssertEqual(chat.messages.map(\.id), snapshot.map(\.id), "空白编辑 = 什么都没发生")
        XCTAssertEqual(
            chat.messages.first { $0.id == target.id }?.content, target.content,
            "原文必须一字不动"
        )
    }

    // MARK: - 重新生成

    func testRegeneratingReplacesTheReplyAndDropsWhatFollowed() async throws {
        let (store, configURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: configURL) }
        let services = CoachServices(config: store, databasePath: ":memory:")
        let chat = try await makeConversation(services: services)

        let oldReply = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(oldReply.role, .assistant)
        let questionBefore = try XCTUnwrap(chat.messages.last { $0.role == .user })

        chat.regenerateReply(to: oldReply.id)
        XCTAssertFalse(chat.messages.contains { $0.id == oldReply.id }, "旧回复先下桌")
        XCTAssertTrue(chat.messages.contains { $0.id == questionBefore.id }, "问题留着，重跑的是回答")
        await waitUntil { chat.isGenerating == false }

        let newReply = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(newReply.role, .assistant)
        XCTAssertNotEqual(newReply.id, oldReply.id, "重新生成 = 换一条新的回复")
    }

    /// 老师主动开场那一条前面没有学员发言 → 没有可重跑的对象，必须原地不动。
    func testRegeneratingTheOpeningGreetingDoesNothing() async throws {
        let (store, configURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: configURL) }
        let services = CoachServices(config: store, databasePath: ":memory:")
        let chat = ChatService(services: services)
        chat.greetIfNeeded()
        await waitUntil { !chat.messages.isEmpty }
        await waitUntil { chat.isGenerating == false }

        let greeting = try XCTUnwrap(chat.messages.first)
        let snapshot = chat.messages
        chat.regenerateReply(to: greeting.id)

        XCTAssertEqual(chat.messages.map(\.id), snapshot.map(\.id), "没有可重跑的问题 → 一条都不许动")
        XCTAssertFalse(chat.isGenerating, "也不该起一轮生成")
    }

    // MARK: - 生成中不许改流水

    /// ⚠️ 断言能成立是**确定的**：`send` 里 `isGenerating` 是同步置位的，
    /// 而生成体在同一个 actor 上排队 —— 只要中间不 `await`，它就还没开始跑。
    func testMutationsAreRefusedWhileGenerating() async throws {
        let (store, configURL) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: configURL) }
        let services = CoachServices(config: store, databasePath: ":memory:")
        let chat = ChatService(services: services)
        chat.greetIfNeeded()
        await waitUntil { !chat.messages.isEmpty }
        await waitUntil { chat.isGenerating == false }

        let greeting = try XCTUnwrap(chat.messages.first)
        chat.send("Let me try something.")
        let snapshot = chat.messages
        XCTAssertTrue(chat.isGenerating, "刚发出去，这一轮还在生成（上面不 await，这里必然为真）")

        chat.deleteMessage(greeting.id)
        chat.resendEditedMessage(snapshot[0].id, text: "changed")
        chat.regenerateReply(to: snapshot[0].id)

        XCTAssertEqual(chat.messages.map(\.id), snapshot.map(\.id), "生成期间一条都不许动")
        await waitUntil { chat.isGenerating == false }
    }
}
