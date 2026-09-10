import AIDomain
import AIInterfaces
import AIInfrastructure
import AIProviders
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 本轮「开场招呼 / 预设提问 / 按需翻译 / 启停弹框」的回归测试。
///
/// 全部走 Mock Provider，**不依赖任何本地模型或网络**。
@MainActor
final class ChatExperienceTests: XCTestCase {

    // MARK: - 工具

    /// Mock LLM 的固定回复（由 `MockLLMProvider` 提供，与本测试无关）。
    private let mockReply = "Hello! Let's practice together."

    private func makeServices(model: String = "mock-model") async throws -> (CoachServices, URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-experience-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: model)
        )
        try await store.selectModel(model, for: .llm)
        let services = CoachServices(config: store, databasePath: ":memory:")
        return (services, fileURL)
    }

    private func waitUntil(_ condition: @MainActor @escaping () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    // MARK: - 优化 3：服务就绪后老师先开口

    /// 打开应用：老师主动打招呼（不等学员先说话）。
    func testTeacherGreetsFirstOnLaunch() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let chat = ChatService(services: services)
        chat.greetIfNeeded()
        await waitUntil { chat.messages.contains { $0.role == .assistant } }

        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1, "开场招呼应当只有一条")
        XCTAssertTrue(chat.messages.allSatisfy { $0.role == .assistant }, "开场时不该凭空出现学员消息")
        XCTAssertNil(chat.errorMessage)
    }

    /// 每次打开应用只开场一次，重复调用不叠加。
    func testGreetingHappensOnlyOncePerLaunch() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let chat = ChatService(services: services)
        chat.greetIfNeeded()
        await waitUntil { !chat.messages.isEmpty }
        chat.greetIfNeeded()
        chat.greetIfNeeded()
        await waitUntil { chat.isGenerating == false }

        XCTAssertEqual(chat.messages.count, 1, "重复调用不得叠加招呼")
    }

    /// 学员抢话：招呼被撤掉，学员这句**必须**拿到回复（不能两败俱伤）。
    func testUserMessageInterruptsGreetingAndStillGetsReply() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let chat = ChatService(services: services)
        chat.greetIfNeeded()
        chat.send("I want to practise ordering coffee.")
        await waitUntil { chat.messages.contains { $0.role == .assistant } }
        await waitUntil { chat.isGenerating == false }

        XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, 1)
        XCTAssertTrue(chat.messages.contains { $0.role == .assistant }, "抢话后学员这句仍要有回复")
        XCTAssertFalse(chat.isGenerating, "抢话后状态必须收干净")
    }

    /// 情景对话有自己的开场白，不再额外插一句招呼。
    func testGreetingSkippedInsideScenario() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let chat = ChatService(services: services)
        let scenario = Scenario(
            id: "test.coffee", title: "Coffee", titleZh: "咖啡店", category: "日常",
            difficulty: 2, level: "A2",
            objective: "Order a drink", aiRole: "barista", learnerRole: "customer",
            opening: "Hi! What can I get you?",
            targetVocabulary: [], targetGrammar: [], maxTurns: 4,
            correctionMode: .gentle, icon: "cup.and.saucer.fill"
        )
        chat.startScenario(scenario)
        chat.greetIfNeeded()
        await waitUntil { chat.isGenerating == false }

        XCTAssertEqual(chat.messages.count, 1, "情景开场白之外不得再插招呼")
    }

    // MARK: - 新增 1：预设提问（数据驱动）

    func testStarterQuestionsParseAndDropJunk() {
        let data = Data(#"{"questions": ["How are you?", "  ", "How are you?", 42]}"#.utf8)
        let parsed = StarterQuestionCatalog.parse(data)
        XCTAssertEqual(parsed, ["How are you?"], "空串与非字符串应被忽略，并去重")
        XCTAssertNil(StarterQuestionCatalog.parse(Data("not json".utf8)))
        XCTAssertNil(StarterQuestionCatalog.parse(nil))
    }

    func testStarterQuestionsLoadFromBundle() async {
        let questions = StarterQuestionCatalog.bundled()
        XCTAssertFalse(questions.isEmpty, "随包资源里应当有预设提问")
        XCTAssertTrue(questions.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func testServicesExposeStarterQuestions() async {
        let questions = await CoachServices(config: ConfigStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-sq-\(UUID().uuidString).json")), databasePath: ":memory:").starterQuestions()
        XCTAssertFalse(questions.isEmpty)
    }

    // MARK: - 新增 2：按需翻译 + 有界缓存

    func testTranslationRuleStripsFencesQuotesAndPrefix() {
        XCTAssertEqual(TranslationRule.clean("```\n你好\n```"), "你好")
        XCTAssertEqual(TranslationRule.clean("\"你好，今天好吗？\""), "你好，今天好吗？")
        XCTAssertEqual(TranslationRule.clean("译文：你好"), "你好")
        XCTAssertEqual(TranslationRule.clean("  Translation: Hello  "), "Hello")
    }

    func testTranslationCacheServesRepeatClicksAndIsBounded() async throws {
        let manager = LLMManager()
        let provider = MockLLMProvider(scriptedResponse: "你好，今天过得怎么样？")
        try await provider.initialize(config: ProviderConfig(id: "mock.llm", kind: .llm, enabled: true,
                                                            runtime: .mock, model: "mock-model"))
        await manager.register(provider)
        let service = TranslationService(llm: manager)

        let first = try await service.translate("How was your day?", targetLanguage: "Chinese", options: .init())
        XCTAssertEqual(first, "你好，今天过得怎么样？")
        let after1 = await service.cachedCount
        XCTAssertEqual(after1, 1)

        // 再点一次（收起后再展开）必须命中缓存，不再请求模型
        let second = try await service.translate("How was your day?", targetLanguage: "Chinese", options: .init())
        XCTAssertEqual(second, first)
        let after2 = await service.cachedCount
        XCTAssertEqual(after2, 1, "同文本同语言必须命中缓存")

        // 换目标语言要重新翻译
        _ = try await service.translate("How was your day?", targetLanguage: "Japanese", options: .init())
        let after3 = await service.cachedCount
        XCTAssertEqual(after3, 2)

        // 缓存必须有界：灌远超上限的条目后仍不超过上限
        for index in 0..<(TranslationService.cacheLimit + 30) {
            _ = try await service.translate("sentence \(index)", targetLanguage: "Chinese", options: .init())
        }
        let after4 = await service.cachedCount
        XCTAssertLessThanOrEqual(after4, TranslationService.cacheLimit, "缓存必须是有界的")
    }

    func testTranslateShowsThenHidesTranslation() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let chat = ChatService(services: services)
        chat.send("Let's start")
        await waitUntil { chat.messages.contains { $0.role == .assistant } }

        let target = try XCTUnwrap(chat.messages.first)
        XCTAssertNil(chat.translationsByMessage[target.id], "译文默认不展示")

        await chat.translate(messageID: target.id)
        XCTAssertEqual(chat.translationsByMessage[target.id], mockReply)
        XCTAssertNil(chat.translationError)

        // 再点一次收起
        await chat.translate(messageID: target.id)
        XCTAssertNil(chat.translationsByMessage[target.id], "再点一次应收起译文")
    }

    func testTranslateReportsFailureWithModelName() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        _ = try await services.setModelRunning(.llm, running: false)
        let chat = ChatService(services: services)
        chat.send("Hi")
        await waitUntil { chat.messages.contains { $0.role == .assistant } }
        let target = try XCTUnwrap(chat.messages.first)

        await chat.translate(messageID: target.id)
        let message = try XCTUnwrap(chat.translationError, "翻译失败必须给出提示，不能静默")
        XCTAssertTrue(message.contains("mock-model"), "提示要点明是哪个模型：\(message)")
    }

    // MARK: - 优化 1：顶部启停弹框

    func testModelToastSuccessThenAutoDismiss() async {
        let state = AppState()
        state.showModelToast("本地模型 · qwen3:8b 已启动：后台服务已拉起。", isSuccess: true)
        let toast = try? XCTUnwrap(state.modelToast)
        XCTAssertTrue(toast?.isSuccess == true)
        XCTAssertTrue(toast?.message.contains("已启动") == true)

        await waitUntil({ state.modelToast == nil }, timeout: 4)
        XCTAssertNil(state.modelToast, "成功弹框应当在约 2 秒后自动收起")
    }

    func testModelToastFailureStaysLongerAndIsRed() async {
        let state = AppState()
        state.showModelToast("启动失败 · 本地模型 · qwen3:8b 服务未启动或不可达", isSuccess: false)
        XCTAssertFalse(state.modelToast?.isSuccess ?? true)
        // 失败文案更长：2 秒时应当还在，4 秒后才收起
        try? await Task.sleep(nanoseconds: 2_400_000_000)
        XCTAssertNotNil(state.modelToast, "失败提示需要更长的阅读时间")
        state.dismissModelToast()
        XCTAssertNil(state.modelToast)
    }

    func testSetModelRunningPopsToastInsteadOfInlineMessage() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        // 必须注入 mock 服务：默认 AppState 会去启停本机真实模型服务。
        let state = AppState(services: services)

        // 用 .llm（mock runtime ⇒ 只做应用层开关）避免触碰本机真实服务。
        await state.setModelRunning(.llm, running: false)
        let toast = try XCTUnwrap(state.modelToast)
        XCTAssertTrue(toast.isSuccess, "关闭成功应弹绿色框")
        XCTAssertTrue(toast.message.contains("已关闭"), toast.message)
        XCTAssertFalse(state.isModelRunning(.llm))
        state.dismissModelToast()
    }

    // MARK: - 优化 2：卡片右上角状态行

    func testProviderStatusLineMarksLocalOrCloud() async {
        let state = AppState()
        // 未配置 Provider 时默认按本地呈现，且带 .llm 后缀
        let line = state.llmProviderStatusLine
        XCTAssertTrue(line.hasPrefix("local.llm") || line.hasPrefix("cloud.llm"), line)
        XCTAssertEqual(state.llmLocationLabel, state.isActiveProviderRemote ? "cloud" : "local")
    }

    // MARK: - 确定性短任务必须关掉推理模型的思考段

    /// `LLMRequest` 默认不干预推理档位（对话/老师回复要尊重用户设置）。
    func testLLMRequestLeavesReasoningEffortUntouchedByDefault() {
        XCTAssertNil(LLMRequest(messages: []).reasoningEffort)
        XCTAssertEqual(LLMRequest.noThinkingEffort, "none")
    }

    /// 翻译请求必须带 `reasoningEffort = "none"`。
    /// 回归背景：不关思考时 qwen3:8b 会先吐 1596 字符思考，同一句翻译 24.8s → 1.4s。
    func testTranslationRequestDisablesReasoning() async throws {
        let manager = LLMManager()
        let provider = RecordingLLMProvider()
        try await provider.initialize(config: ProviderConfig(id: "rec.llm", kind: .llm, enabled: true,
                                                             runtime: .mock, model: "rec-model"))
        await manager.register(provider)

        let service = TranslationService(llm: manager)
        _ = try await service.translate("Good morning", targetLanguage: "Chinese", options: .init())

        let recorded = await provider.lastRequest
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.reasoningEffort, "none", "翻译必须关掉思考段")
        XCTAssertEqual(request.temperature, 0)
    }

    /// 拼写纠正同样是确定性短任务，必须关思考。
    func testSpellingCorrectionRequestDisablesReasoning() async throws {
        let manager = LLMManager()
        let provider = RecordingLLMProvider()
        try await provider.initialize(config: ProviderConfig(id: "rec.llm", kind: .llm, enabled: true,
                                                             runtime: .mock, model: "rec-model"))
        await manager.register(provider)

        let service = SpellingCorrectionService(llm: manager)
        _ = await service.correct("I have a apple", options: .init())

        let recorded = await provider.lastRequest
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.reasoningEffort, "none", "拼写纠正必须关掉思考段")
    }
}

/// 记录最近一次请求的测试替身（用于断言「请求带了哪些参数」）。
final class RecordingLLMProvider: LLMProvider, @unchecked Sendable {

    public let providerID = "recording.llm"
    public let kind: AIProviderKind = .llm

    private let box = RecordingBox()

    public init() {}

    /// 最近一次收到的请求。
    var lastRequest: LLMRequest? { get async { await box.request } }

    public func initialize(config: ProviderConfig) async throws {}
    public func load() async throws {}
    public func unload() async {}
    public func healthCheck() async -> ProviderHealth { .connected(model: nil) }
    public func capabilities() -> ProviderCapabilities { ProviderCapabilities(streaming: true) }
    public func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "记录用大脑", runtime: .mock)
    }
    public func llmCapabilities() -> LLMCapabilities { LLMCapabilities(streaming: true) }
    public func discoverModels() async throws -> [DiscoveredModel] { [] }

    public func generate(_ request: LLMRequest) async throws -> LLMResponse {
        await box.record(request)
        return LLMResponse(text: "你好", model: request.model, finishReason: "stop")
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await box.record(request)
                continuation.yield(LLMChunk(textDelta: "你好", role: .assistant))
                continuation.yield(LLMChunk(textDelta: "", finishReason: "stop"))
                continuation.finish()
            }
        }
    }
}

private actor RecordingBox {
    private(set) var request: LLMRequest?
    func record(_ request: LLMRequest) { self.request = request }
}
