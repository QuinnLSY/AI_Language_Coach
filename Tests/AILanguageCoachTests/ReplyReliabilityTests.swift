import AIInterfaces
import AIServices
import AIInfrastructure
import AppCore
import AppUI
import XCTest

/// 「老师必须回复学员的每一句话」——本轮修复的启动竞态与静默失败回归测试。
///
/// 背景：用户报「打开应用后跟老师打招呼，老师从来不回」。实测根因是
/// **应用还没装配好 LLM Provider 时用户就发了消息**，`llm.stream` 直接抛
/// `notInitialized`，回复就此消失。这里用 Mock Provider 把这条路径钉死。
@MainActor
final class ReplyReliabilityTests: XCTestCase {

    private func makeServices(
        runtime: RuntimeKind = .mock,
        model: String = "mock-model"
    ) async throws -> (CoachServices, URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-reply-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "ollama.llm", kind: .llm, enabled: true, runtime: runtime, model: model)
        )
        try await store.selectModel(model, for: .llm)
        let services = CoachServices(config: store, databasePath: ":memory:")
        return (services, fileURL)
    }

    private func waitForReply(_ chat: ChatService, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if chat.messages.contains(where: { $0.role == .assistant }) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 启动尚未完成就发消息：应当自己补齐装配并给出回复（曾经的 bug 场景）。
    func testRepliesWhenMessageSentBeforeBootstrap() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let chat = ChatService(services: services)
        chat.send("Hello teacher, how are you today?")
        await waitForReply(chat)

        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1,
                       "启动未完成时发消息，老师也必须回复")
        XCTAssertNil(chat.errorMessage)
    }

    /// 正常顺序（先装配后发送）同样要有回复。
    func testRepliesAfterBootstrap() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await services.bootstrapLLM()
        let chat = ChatService(services: services)
        chat.send("Good evening!")
        await waitForReply(chat)

        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertNil(chat.errorMessage)
    }

    /// 模型被关闭：不发请求，并给出**带模型名**的可操作提示。
    func testStoppedModelBlocksSendingWithModelSpecificHint() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await services.bootstrapLLM()
        _ = try await services.setModelRunning(.llm, running: false)
        let chat = ChatService(services: services)
        chat.send("Are you there?")
        await waitForReply(chat)

        XCTAssertTrue(chat.messages.filter { $0.role == .assistant }.isEmpty,
                      "模型关闭时不应产生回复")
        let message = try XCTUnwrap(chat.errorMessage)
        XCTAssertTrue(message.contains("mock-model"), "提示必须点明是哪个模型：\(message)")
        XCTAssertTrue(message.contains("已关闭"), "提示必须说清状态：\(message)")
        XCTAssertTrue(message.contains("启动"), "提示必须告诉用户怎么恢复：\(message)")
    }

    /// 关闭 → 重新启动后，对话恢复正常。
    func testRestartingModelRestoresConversation() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await services.bootstrapLLM()
        _ = try await services.setModelRunning(.llm, running: false)
        _ = try await services.setModelRunning(.llm, running: true)

        let chat = ChatService(services: services)
        chat.send("Back again")
        await waitForReply(chat)

        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertNil(chat.errorMessage)
    }

    /// 应用打开时所有模型默认是启动态。
    func testAllModelsDefaultToRunning() async {
        let state = AppState()
        for kind in AIProviderKind.allCases {
            XCTAssertTrue(state.isModelRunning(kind), "\(kind.rawValue) 默认应为启动态")
        }
        XCTAssertNil(state.llmStoppedNotice)
    }

    /// 不支持真实启停的模型（内置模拟 / 云端）走应用层面开关，并如实说明。
    func testMockModelToggleIsAppLevelOnly() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let stopNote = try await services.setModelRunning(.llm, running: false)
        XCTAssertTrue(stopNote.contains("应用层面"), "内置/云端模型应说明是应用层面关闭：\(stopNote)")
        let isRunning = await services.isModelRunning(.llm)
        XCTAssertFalse(isRunning)

        let startNote = try await services.setModelRunning(.llm, running: true)
        let runningAgain = await services.isModelRunning(.llm)
        XCTAssertTrue(runningAgain)
        XCTAssertTrue(startNote.contains("已启动"), startNote)
    }
}
