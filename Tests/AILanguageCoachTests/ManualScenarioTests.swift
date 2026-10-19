import AIDomain
import AIInfrastructure
import AIInterfaces
import AIProviders
import AIServices
import AppCore
import XCTest

/// 发布清单 manual 项的**逻辑层**脚本化（#596）。
///
/// 背景：`ReleaseChecklist` 有 11 条 manual（只能真机 / 人工验的）。清单的原则是
/// 「宁可写成 manual，也不要写一个永远返回 true 的自动检查」—— 所以这里**不**
/// 去把 manual 项标成 `automated`（TCC 权限、真麦克风、真 30 分钟，CI 上验不了），
/// 而是把 manual 项背后的**逻辑**写成场景级 XCTest：验得了的在这里钉死，
/// 真机那部分继续由人按 `item.guidance` 跑。
///
/// 覆盖的 manual 项（其余 manual 项的逻辑已由既有单测覆盖，见清单 guidance 注明）：
/// - `ai.fallback`（老师必回）：流式死了而非流式活着 / 全死两种形态；
/// - `audio.permission`：权限被拒 → 引导文案逐字正确（权限探针走协议缝注入 stub）；
/// - `perf.longSession`：60 轮长会话的决策上下文有界 + 图片内联只带最近 1 轮。
///
/// 另外三条 `generateGreeting` 失败提示（#613）：开场链路与主路径同构，
/// 三条失败分支都必须「有话可说」，不许无声无息地空白。
@MainActor
final class ManualScenarioTests: XCTestCase {

    // MARK: - 测试基建

    private struct Fixture {
        let services: CoachServices
        let attachments: AttachmentStore
        /// 整个临时目录（配置 + 附件 + 素材源文件），`defer` 里一次删干净。
        let directory: URL
    }

    /// 临时配置 + 临时附件目录 + `:memory:` 学习库。
    ///
    /// 附件目录**必须可注入**：图片内联要读真实文件，而 `AttachmentStore.defaultDirectory`
    /// 指向用户数据目录（启动时缓存、运行中改不了）—— 场景断言往真实数据里写测试图片，
    /// 比不测更糟。`AttachmentStore(directory:)` 就是为这个缝准备的。
    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-manual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await store.updateProvider(
            ProviderConfig(id: "mock.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        let attachments = AttachmentStore(
            directory: directory.appendingPathComponent("attachments", isDirectory: true)
        )
        let services = CoachServices(
            config: store, databasePath: ":memory:", attachmentStore: attachments
        )
        return Fixture(services: services, attachments: attachments, directory: directory)
    }

    /// 造一个图片附件（内容不需要是合法 PNG：这条链路上没有任何解码，只有搬运与 base64）。
    private func importImage(
        _ store: AttachmentStore, name: String, into directory: URL
    ) async throws -> ChatAttachment {
        let sources = directory.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source = sources.appendingPathComponent(name)
        try Data("pretend-png-bytes-\(name)".utf8).write(to: source)
        return try await store.importFile(at: source)
    }

    /// 等到条件成立（最多 5 秒），不靠固定 sleep 猜。
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 等到这一轮的老师回复落定（**且退出生成态**——只数消息数不够：
    /// 消息 append 与 defer 清 `isGenerating` 之间有个窗口，此刻发下一句会被
    /// `guard !isGenerating` 静默丢掉，测试就会永远等不到下一条）。
    private func waitForAssistantReply(_ chat: ChatService, expected: Int) async {
        await waitUntil {
            !chat.isGenerating && chat.messages.filter { $0.role == .assistant }.count >= expected
        }
    }

    // MARK: - ai.fallback：老师必回

    /// 流式一个字都没拿到（SSE 失效的形态：不抛错、就是没字）→ 必须退回非流式再要一次。
    ///
    /// ⚠️ 注意桩的形态：stream 是「无字无错地结束」，不是抛错 ——
    /// 抛错会走 ④ 错误分支，兜底根本不会触发（判据是 `finalText.isEmpty, failure == nil`）。
    /// 这个区别本身就是用例钉住的事实之一。
    func testStreamDeadButGenerateAliveTeacherStillReplies() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.services.bootstrapLLM()
        await fixture.services.llm.register(HalfDeadLLMProvider())

        let chat = ChatService(services: fixture.services)
        chat.send("Hello teacher, how are you today?")
        await waitForAssistantReply(chat, expected: 1)

        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1,
                       "流式全空时必须退回非流式再要一次 —— 老师不能沉默")
        XCTAssertNil(chat.errorMessage, "兜底成功就不该留错误提示")
        XCTAssertFalse(chat.isGenerating, "兜底成功也要正常收尾")
    }

    /// 全死（stream 与 generate 都连不上）→ 带模型名的可读错误，且绝不卡在生成态。
    func testFullyDeadRuntimeSurfacesActionableErrorAndNeverSpins() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.services.bootstrapLLM()
        await fixture.services.llm.register(FullyDeadLLMProvider())

        let chat = ChatService(services: fixture.services)
        chat.send("Are you still there?")
        await waitUntil { !chat.isGenerating }

        XCTAssertTrue(chat.messages.filter { $0.role == .assistant }.isEmpty,
                      "全死时不该产出任何回复")
        let message = try XCTUnwrap(chat.errorMessage, "全死必须给出可读错误，而不是转圈到底")
        XCTAssertTrue(message.contains("mock-model"), "错误要点名是哪个模型：\(message)")
        XCTAssertTrue(message.contains("连接失败"), "错误要落在连接失败这一档：\(message)")
        // 不断言「请确认该模型的服务已启动」：中文 Locale 下 URLError 的原因文案
        // 匹配不上 hint 的英文关键词（#616 已记缺口）—— 钉一句现在并不成立的话，
        // 只会让这条用例天天红，直到有人误删断言。
        XCTAssertFalse(chat.isGenerating, "失败后必须退出生成态（否则界面永远转圈）")
    }

    // MARK: - generateGreeting 失败补提示（#613）

    /// 开场请求抛错 → 与主路径 ④ 同构的可读提示（曾经是 `try?` 静默吞掉）。
    func testGreetingFailureSurfacesReadableHint() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.services.bootstrapLLM()
        await fixture.services.llm.register(FullyDeadLLMProvider())

        let chat = ChatService(services: fixture.services)
        chat.greetIfNeeded()
        await waitUntil { !chat.isGreeting && !chat.isGenerating }

        XCTAssertTrue(chat.messages.isEmpty, "开场失败不该留下半条招呼")
        let message = try XCTUnwrap(chat.errorMessage, "开场失败必须给出可读提示（曾经是静默的）")
        XCTAssertTrue(message.contains("mock-model"), "提示要点名模型：\(message)")
        XCTAssertTrue(message.contains("连接失败"), "提示要落在连接失败这一档：\(message)")
    }

    /// 开场正文为空（推理模型把预算全用在思考上）→ 明说「这次没有给出开场招呼」。
    func testGreetingEmptyBodySurfacesHint() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.services.bootstrapLLM()
        await fixture.services.llm.register(EmptyBodyLLMProvider())

        let chat = ChatService(services: fixture.services)
        chat.greetIfNeeded()
        await waitUntil { !chat.isGreeting && !chat.isGenerating }

        XCTAssertTrue(chat.messages.isEmpty, "空正文不该产出消息")
        let message = try XCTUnwrap(chat.errorMessage, "空正文必须给出可读提示")
        XCTAssertTrue(message.contains("这次没有给出开场招呼"), "提示要明说发生了什么：\(message)")
        XCTAssertTrue(message.contains("换个模型"), "提示要给出下一步动作：\(message)")
    }

    /// 开场只吐了 [[FIX]] 行（剥完纠错块后正文空了）→ 同样要有可读提示。
    func testGreetingWithOnlyCorrectionLinesSurfacesHint() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.services.bootstrapLLM()
        await fixture.services.llm.register(OnlyFixLineLLMProvider())

        let chat = ChatService(services: fixture.services)
        chat.greetIfNeeded()
        await waitUntil { !chat.isGreeting && !chat.isGenerating }

        XCTAssertTrue(chat.messages.isEmpty, "剥完纠错块为空的正文不该上屏")
        let message = try XCTUnwrap(chat.errorMessage, "这种失败也必须给出可读提示")
        XCTAssertTrue(message.contains("这次没有给出开场招呼"), "提示要明说发生了什么：\(message)")
    }

    // MARK: - audio.permission：权限被拒 → 引导文案

    /// 权限被拒：`lastError` **逐字**等于引导文案，且不进入录音态。
    ///
    /// 为什么走 stub：CI 上 `AVCaptureDevice.authorizationStatus` 没法可靠置成
    /// `.denied`（TCC 限制），真机现象单测验不了 —— 协议缝（`MicrophonePermissionChecking`）
    /// 就是为这条链路开的。
    func testDeniedMicrophonePermissionBlocksRecordingWithGuidance() async {
        let voice = VoiceService(permissions: StubPermission(granted: false))

        await voice.startRecording()

        let error = await voice.lastError
        // ⚠️ 两句断言各管一件事，缺一句都是假绿：
        // ① 逐字钉住**文案本体** —— 只跟常量比是 tautology（常量改坏了断言照样绿，
        //    而「少了『隐私与安全性 → 麦克风』」正是最可能发生、又最没人发现的改法）；
        // ② 钉住 **startRecording 用的就是这个常量**（不是别处另写的一句）。
        XCTAssertEqual(error, "没有麦克风权限，请在「系统设置 → 隐私与安全性 → 麦克风」中开启",
                       "被拒后的引导文案必须逐字正确：用户靠它去找系统设置")
        XCTAssertEqual(error, VoiceService.permissionDeniedMessage,
                       "startRecording 必须用统一常量，不许别处另写一句")
        // ⚠️ `await` 不能进 XCTAssert 的 autoclosure，先落局部变量。
        let recording = await voice.isRecording
        XCTAssertFalse(recording, "被拒时不该进入录音态")
    }

    /// 权限探针的转发正确性：授不授权、问了几次，都要原样传上来。
    func testRequestMicrophonePermissionForwardsProbeResult() async {
        let granted = StubPermission(granted: true)
        let voice = VoiceService(permissions: granted)
        let grantedResult = await voice.requestMicrophonePermission()
        XCTAssertTrue(grantedResult, "授权结果要原样上传")
        let grantedCalls = await granted.callCount
        XCTAssertEqual(grantedCalls, 1, "问一次就是一次，不许重复弹窗")

        let denied = StubPermission(granted: false)
        let voice2 = VoiceService(permissions: denied)
        let deniedResult = await voice2.requestMicrophonePermission()
        XCTAssertFalse(deniedResult, "拒绝结果也要原样上传")
        let deniedCalls = await denied.callCount
        XCTAssertEqual(deniedCalls, 1)
    }

    // MARK: - perf.longSession：长会话有界性

    /// 60 轮对话：消息全留（历史要能翻），但**决策上下文**仍是有界窗口。
    ///
    /// 反方向断言（不许出现 "turn 54"）同样重要：一个「其实没裁剪」的实现
    /// 会让 count 也等于 12 附近的值糊弄过去，窗口滑动的证据在这里。
    func testLongConversationKeepsDecisionContextBounded() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.services.bootstrapLLM()
        await fixture.services.llm.register(
            MockLLMProvider(scriptedResponse: "Ok.", chunkDelayNanoseconds: 1_000_000)
        )

        let chat = ChatService(services: fixture.services)
        for round in 1...60 {
            chat.send("This is my turn \(round).")
            await waitForAssistantReply(chat, expected: round)
        }

        XCTAssertEqual(chat.messages.count, 120, "60 轮 = 120 条消息，历史本身不裁")
        let turns = chat.engine.context.recentTurns
        XCTAssertEqual(turns.count, ConversationContext.turnWindow,
                       "决策上下文必须停在窗口上限（\(ConversationContext.turnWindow)）")
        XCTAssertEqual(turns.first?.speaker, .learner)
        XCTAssertTrue(turns.first?.text.contains("turn 55") ?? false,
                      "窗口保留最新：最早一轮应是第 55 轮")
        XCTAssertEqual(turns.last?.speaker, .teacher)
        XCTAssertTrue(turns.last(where: { $0.speaker == .learner })?.text.contains("turn 60") ?? false,
                      "最后一轮学员发言必须还在窗口里")
        XCTAssertFalse(turns.contains { $0.text.contains("turn 54") },
                       "第 54 轮必须已被滑出窗口（证明窗口真的在动）")
        XCTAssertGreaterThan(chat.estimatedContextTokens, 0)
    }

    /// 图片内联只带最近 1 轮：更早的图片退化成文件名说明。
    ///
    /// 这是**真场景**断言（不是配置常量断言）：附件目录注入了临时目录，
    /// 桩 provider 捕获主请求，直接看历史消息里哪些带 `images`。
    /// 判据背后的代价：图片以 base64 内联，而每轮都重发全部历史 ——
    /// 全量内联会让请求体随图片数近似平方增长（用户看到「越聊越慢」）。
    func testImageInliningStopsAtTheMostRecentTurn() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.services.bootstrapLLM()
        let box = RequestBox()
        await fixture.services.llm.register(MockLLMProvider(responder: { request in
            box.append(request)
            return "Noted, thanks for the picture."
        }))

        let chat = ChatService(services: fixture.services)
        let first = try await importImage(fixture.attachments, name: "first.png", into: fixture.directory)
        chat.send("Look at this screenshot.", attachments: [first])
        await waitForAssistantReply(chat, expected: 1)
        let second = try await importImage(fixture.attachments, name: "second.png", into: fixture.directory)
        chat.send("And this one.", attachments: [second])
        await waitForAssistantReply(chat, expected: 2)
        let third = try await importImage(fixture.attachments, name: "third.png", into: fixture.directory)
        chat.send("And the last one.", attachments: [third])
        await waitForAssistantReply(chat, expected: 3)

        // 追问请求不带历史（只有一条消息），按「多于一条消息」过滤出主请求。
        let request = try XCTUnwrap(box.all().last { $0.messages.count > 1 },
                                    "要抓到带完整历史的主请求")
        let userMessages = request.messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 3, "三轮学员发言都应在历史里")

        XCTAssertEqual(userMessages[2].images.count, 1, "最近一轮的图片必须内联发给模型")
        XCTAssertTrue(userMessages[2].referencedFileNames.isEmpty,
                      "最近一轮的图片不该同时退化成文件名说明")

        XCTAssertTrue(userMessages[0].images.isEmpty, "更早的图片不许再内联：请求体会平方增长")
        XCTAssertEqual(userMessages[0].referencedFileNames, ["first.png"],
                       "更早的图片要退化成文件名说明，让模型知道用户提到过它")
        XCTAssertTrue(userMessages[1].images.isEmpty)
        XCTAssertEqual(userMessages[1].referencedFileNames, ["second.png"])
    }
}

// MARK: - 桩

/// 流式链路死了、非流式还活着：`stream` 无字无错地结束（某些 runtime 的 SSE
/// 失效就是这样），`generate` 正常返回 —— ③「流式全空 → 非流式兜底」救的正是这个形态。
private final class HalfDeadLLMProvider: LLMProvider, @unchecked Sendable {
    let providerID = "stub.half-dead.llm"
    let kind: AIProviderKind = .llm

    func initialize(config: ProviderConfig) async throws {}
    func load() async throws {}
    func unload() async {}
    func healthCheck() async -> ProviderHealth { .connected(model: "mock-model") }
    func capabilities() -> ProviderCapabilities {
        ProviderCapabilities(streaming: true, structuredOutput: true, multilingual: true)
    }
    func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "半死桩", runtime: .mock, version: "1.0")
    }
    func discoverModels() async throws -> [DiscoveredModel] { [] }
    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: "Hello! Nice to meet you.", model: request.model, finishReason: "stop")
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// 全死：stream 与 generate 都连不上（kill 掉本地 runtime 的形态）。
///
/// ⚠️ 抛的是 `connectionFailed(URLError.localizedDescription)` —— 与生产链路**同形**：
/// `HTTPClient.perform`（HTTPClient.swift:232）就是把 URLError 包装成这个形态上浮的。
/// 桩不忠于这条路径的话，测到的错误分档会与真机上看到的不一样。
///
/// 顺带记一个已存在的缺口（#616，不在本任务范围内修）：中文 Locale 下
/// `URLError.localizedDescription` 是「未能完成操作。（NSURLErrorDomain错误-1009。）」，
/// `ModelDiagnostics.hint(for:)` 只匹配英文关键词 → 「请确认该模型的服务已启动」
/// 这句可操作建议不触发。本用例因此只钉「模型名 + 失败分档 + 不卡圈」。
private final class FullyDeadLLMProvider: LLMProvider, @unchecked Sendable {
    let providerID = "stub.fully-dead.llm"
    let kind: AIProviderKind = .llm

    func initialize(config: ProviderConfig) async throws {}
    func load() async throws {}
    func unload() async {}
    func healthCheck() async -> ProviderHealth { .connected(model: "mock-model") }
    func capabilities() -> ProviderCapabilities {
        ProviderCapabilities(streaming: true, structuredOutput: true, multilingual: true)
    }
    func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "全死桩", runtime: .mock, version: "1.0")
    }
    func discoverModels() async throws -> [DiscoveredModel] { [] }
    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        throw AIProviderError.connectionFailed(URLError(.notConnectedToInternet).localizedDescription)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error> {
        AsyncThrowingStream {
            $0.finish(throwing: AIProviderError.connectionFailed(
                URLError(.notConnectedToInternet).localizedDescription
            ))
        }
    }
}

/// 正文为空（推理模型把输出预算全用在思考上的形态）。
private final class EmptyBodyLLMProvider: LLMProvider, @unchecked Sendable {
    let providerID = "stub.empty-body.llm"
    let kind: AIProviderKind = .llm

    func initialize(config: ProviderConfig) async throws {}
    func load() async throws {}
    func unload() async {}
    func healthCheck() async -> ProviderHealth { .connected(model: "mock-model") }
    func capabilities() -> ProviderCapabilities {
        ProviderCapabilities(streaming: true, structuredOutput: true, multilingual: true)
    }
    func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "空正文桩", runtime: .mock, version: "1.0")
    }
    func discoverModels() async throws -> [DiscoveredModel] { [] }
    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: "", model: request.model, finishReason: "stop")
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// 只吐一条 [[FIX]] 行（剥完纠错块后正文为空的形态）。
private final class OnlyFixLineLLMProvider: LLMProvider, @unchecked Sendable {
    let providerID = "stub.only-fix.llm"
    let kind: AIProviderKind = .llm

    func initialize(config: ProviderConfig) async throws {}
    func load() async throws {}
    func unload() async {}
    func healthCheck() async -> ProviderHealth { .connected(model: "mock-model") }
    func capabilities() -> ProviderCapabilities {
        ProviderCapabilities(streaming: true, structuredOutput: true, multilingual: true)
    }
    func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "只有纠错行桩", runtime: .mock, version: "1.0")
    }
    func discoverModels() async throws -> [DiscoveredModel] { [] }
    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(
            text: "[[FIX]] I go school => I go to school => missing preposition",
            model: request.model,
            finishReason: "stop"
        )
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// 权限探针桩：授权结果可控，调用次数可数。
///
/// ⚠️ 是 **actor** 而不是「class + NSLock」：`requestPermission()` 是 async 的，
/// Swift 6 禁止在异步上下文里用 `NSLock`（`NS_SWIFT_UNAVAILABLE_FROM_ASYNC`）。
/// actor 的隔离域天然把计数器护住，桩本身也更接近真实调用形态。
private actor StubPermission: MicrophonePermissionChecking {
    private let granted: Bool
    private var calls = 0

    init(granted: Bool) { self.granted = granted }

    func requestPermission() async -> Bool {
        calls += 1
        return granted
    }

    var callCount: Int { calls }
}

/// 请求捕获盒：桩 provider 的 `responder` 是 `@Sendable` 的，收集要过锁。
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [LLMRequest] = []

    func append(_ request: LLMRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }

    func all() -> [LLMRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}
