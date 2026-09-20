import AIDomain
import AIInterfaces
import AIServices
import AIInfrastructure
import AppCore
import AppUI
import XCTest

/// 「学员可以中文问，老师只能用英文答」这条硬要求的**接线**回归。
///
/// 判据本身是纯函数（见 `TeacherLanguageGuardTests`），这里钉的是把它接进生成链路的那一段：
/// 模型整句用中文回话 → 自动**多要一次**英文重说 → 上屏的是英文；
/// 重写拿不到或不可信时 → 保留原文，**绝不能把这一轮回复弄丢**。
///
/// ⚠️ 用脚本化桩 Provider，不用真模型：真模型的回话不可控，
/// 测出来的是它的脾气而不是代码（而且这台机器上的远端 Key 会失效、本机还跑着 Ollama）。
@MainActor
final class TeacherEnglishOnlyTests: XCTestCase {

    private func makeServices() async throws -> (CoachServices, URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-lang-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        return (CoachServices(config: store, databasePath: ":memory:"), fileURL)
    }

    /// 装好桩：先把默认装配走完（`llmProvider` 就位），再把自己注册进去顶掉它。
    private func makeChat(scripts: [String]) async throws -> (ChatService, ScriptedLLMProvider, URL) {
        let (services, fileURL) = try await makeServices()
        try await services.bootstrapLLM()
        let provider = ScriptedLLMProvider(scripts: scripts)
        await services.llm.register(provider)
        return (ChatService(services: services), provider, fileURL)
    }

    private func waitForAssistant(_ chat: ChatService, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if chat.messages.contains(where: { $0.role == .assistant }), !chat.isGenerating { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    /// 模型整句用中文回话 → 多要一次英文重说，上屏的是英文。
    func testChineseReplyIsReplacedByEnglishRewrite() async throws {
        let (chat, provider, fileURL) = try await makeChat(scripts: [
            "那真是太好了！(That's great!) 不过，通常我们会说用 hands 或 fingers。",
            "That's great! Though we usually say \"hands\" or \"fingers\"."
        ])
        defer { try? FileManager.default.removeItem(at: fileURL) }

        chat.send("老师，这句话是什么意思？")
        await waitForAssistant(chat)

        XCTAssertEqual(chat.messages.count, 2, "只该有学员那一句 + 老师那一句")
        XCTAssertEqual(
            chat.messages.last?.content,
            "That's great! Though we usually say \"hands\" or \"fingers\"."
        )
        XCTAssertFalse(TeacherLanguageGuard.containsNativeScript(chat.messages.last?.content ?? ""))
        XCTAssertEqual(provider.generatedRequests.count, 1, "只多要**一次**重写")

        // ⚠️ 重写请求不能带对话历史，且要自带原文 —— 否则弱模型会去抄历史里那句英文
        // （实测：老师会答非所问地复读开场白）。
        let rewrite = try XCTUnwrap(provider.generatedRequests.first)
        XCTAssertEqual(rewrite.messages.count, 1, "重写请求只该有一条指令，不带历史")
        XCTAssertTrue(
            rewrite.messages[0].content.contains("fingers"),
            "重写指令必须自带要重说的原文"
        )
        XCTAssertEqual(provider.streamedRequests.count, 1)
    }

    /// 重写拿不到（桩返回空）→ 保留原文，回复绝不能消失。
    func testMissingRewriteKeepsTheOriginalReply() async throws {
        let (chat, _, fileURL) = try await makeChat(scripts: ["你好，我们来练英语吧。"])
        defer { try? FileManager.default.removeItem(at: fileURL) }

        chat.send("老师，这句话是什么意思？")
        await waitForAssistant(chat)

        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.last?.content, "你好，我们来练英语吧。", "宁可留着母语，也不能把回复弄丢")
    }

    /// 重写结果仍然带母语 → 不接受，保留原文。
    func testRewriteThatIsStillNativeIsRejected() async throws {
        let (chat, _, fileURL) = try await makeChat(scripts: [
            "你好，我们来练英语吧。",
            "好的，我们开始吧。"
        ])
        defer { try? FileManager.default.removeItem(at: fileURL) }

        chat.send("老师，这句话是什么意思？")
        await waitForAssistant(chat)

        XCTAssertEqual(chat.messages.last?.content, "你好，我们来练英语吧。")
    }

    /// ⚠️ 实测失败原样的回归：弱模型把**历史里那句英文**（开场白）照抄回来当重写结果。
    ///
    /// 这种结果一旦上屏，用户看到的就是「学员问了话，老师不回答，却又打了个招呼」。
    /// 必须判为不可信 → 保留原文。
    func testRewriteThatRepeatsAnEarlierReplyIsRejected() async throws {
        let greeting = "Welcome back to our cozy forest corner. What are you feeling like practicing today?"
        let (chat, provider, fileURL) = try await makeChat(scripts: [
            greeting,                     // ① 老师先打了个招呼
            "你好，我们来练英语吧。",        // ② 学员问了话，老师却用中文答
            greeting                      // ③ 重写这条指令被模型拿去复读了开场白
        ])
        defer { try? FileManager.default.removeItem(at: fileURL) }

        chat.send("Good evening!")
        await waitForAssistant(chat)
        XCTAssertEqual(chat.messages.last?.content, greeting)

        chat.send("老师，这句话是什么意思？")
        await waitForAssistant(chat)

        XCTAssertEqual(provider.generatedRequests.count, 1, "确实发过一次重写")
        XCTAssertEqual(
            chat.messages.last?.content,
            "你好，我们来练英语吧。",
            "复读历史回复的结果不可信，必须丢掉它、保留老师真正说的话"
        )
        XCTAssertEqual(chat.messages.filter { $0.content == greeting }.count, 1, "开场白不许出现两次")
    }
}

// MARK: - 桩：按调用次序吐脚本

/// 脚本化 LLM：`stream` 取一个脚本、`generate` 取下一个（按调用先后排队），
/// 并把每次请求原样记下来供断言（比如「重写请求不带历史」）。
final class ScriptedLLMProvider: LLMProvider, @unchecked Sendable {

    let providerID: String
    let kind: AIProviderKind = .llm

    private let lock = NSLock()
    private var scripts: [String]
    private var config: ProviderConfig?
    private var streamed: [LLMRequest] = []
    private var generated: [LLMRequest] = []

    init(providerID: String = "stub.llm", scripts: [String]) {
        self.providerID = providerID
        self.scripts = scripts
    }

    var streamedRequests: [LLMRequest] { lock.withLock { streamed } }
    var generatedRequests: [LLMRequest] { lock.withLock { generated } }

    func initialize(config: ProviderConfig) async throws { lock.withLock { self.config = config } }
    func load() async throws {}
    func unload() async {}
    func healthCheck() async -> ProviderHealth { .connected(model: lock.withLock { config?.model }) }
    func capabilities() -> ProviderCapabilities {
        ProviderCapabilities(streaming: true, structuredOutput: true, multilingual: true)
    }
    func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "脚本桩", runtime: .mock, version: "1.0")
    }
    func llmCapabilities() -> LLMCapabilities {
        LLMCapabilities(streaming: true, structuredOutput: true, multilingual: true)
    }
    func discoverModels() async throws -> [DiscoveredModel] { [] }

    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        let text = lock.withLock { () -> String in
            generated.append(request)
            return takeNextScript()
        }
        return LLMResponse(text: text, model: request.model, finishReason: "stop")
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error> {
        let text = lock.withLock { () -> String in
            streamed.append(request)
            return takeNextScript()
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMChunk(textDelta: "", role: .assistant))
            if !text.isEmpty { continuation.yield(LLMChunk(textDelta: text)) }
            continuation.yield(LLMChunk(textDelta: "", finishReason: "stop"))
            continuation.finish()
        }
    }

    /// 脚本用完就吐空串（等价于「这个模型这次什么都没给」）。
    private func takeNextScript() -> String {
        scripts.isEmpty ? "" : scripts.removeFirst()
    }
}
