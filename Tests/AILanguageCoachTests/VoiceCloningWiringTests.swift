import AIDomain
import AIInterfaces
import AIInfrastructure
import AIProviders
import AIServices
import AppCore
import Foundation
import XCTest

/// 第 24 步（续）：克隆音色的**接线**。
///
/// 合规地基（`VoiceCloningPolicyTests`）管的是「能不能启用」；这里管的是启用之后
/// 「声音到底有没有真的换掉」。两者分开是因为最容易出的错不是规则写错，
/// 而是**规则都对、开关也亮了，声音却没变**：
/// - 只把本地生成的档案 id 交给 provider，任何 runtime 都无法据此还原音色；
/// - 参考音频没随请求发出去，克隆永远只是「看起来启用了」；
/// - 云端供应商收到参考音频后「尽量忽略」—— 那等于把用户声音上传给第三方。
///
/// 注：`await` 不能写进 `XCTAssert*` 的 autoclosure（那里不接受 async），
/// 所以下面一律先算到局部量再断言。
@MainActor
final class VoiceCloningWiringTests: XCTestCase {

    // MARK: - 替身

    /// 记录发出去的请求，用于断言请求体形状与「有没有真的发」。
    ///
    /// 只交出 `Data`：`[String: Any]` 不是 `Sendable`，让 actor 直接返回它会被编译器拦下。
    private actor CallRecorder {
        private(set) var requests: [URLRequest] = []
        func record(_ request: URLRequest) { requests.append(request) }
        var count: Int { requests.count }
        var lastBody: Data? { requests.last?.httpBody }
    }

    private final class StubTTSProvider: TTSProvider, @unchecked Sendable {
        let providerID = "stub.tts"
        let kind: AIProviderKind = .tts
        private let state = ProviderStateBox()
        private let cloning: Bool

        init(cloning: Bool) { self.cloning = cloning }

        func initialize(config: ProviderConfig) async throws { await state.setConfig(config) }
        func load() async throws {}
        func unload() async {}
        func healthCheck() async -> ProviderHealth { .connected(model: nil) }
        func capabilities() -> ProviderCapabilities { ProviderCapabilities(voiceCloning: cloning) }
        func metadata() -> ProviderMetadata {
            ProviderMetadata(id: providerID, displayName: "Stub TTS", runtime: .ollama)
        }
        func synthesize(_ request: TTSRequest) async throws -> TTSResult {
            TTSResult(audioSamples: [], sampleRate: 16_000)
        }
    }

    /// 本机路径在**运行期**拼出来：仓库里不出现 `/Users/...` 字面量（发布静态检查会扫）。
    private var referencePath: String { NSHomeDirectory() + "/voices/my-voice.wav" }

    private func makeServices() -> CoachServices {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-wiring-\(UUID().uuidString).json")
        )
        // 音色档案仓库指到临时文件：默认是 `.shared`，会在用例之间互相污染。
        let profiles = VoiceProfileStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-wiring-profiles-\(UUID().uuidString).json")
        )
        return CoachServices(config: store, databasePath: ":memory:", voiceProfileStore: profiles)
    }

    private func clonedProfile(id: String = "my-voice") -> VoiceProfile {
        VoiceProfile(
            id: id,
            displayName: "我的声音",
            kind: .cloned,
            referenceAudioPath: referencePath,
            referenceText: "Hello, this is my voice.",
            consent: VoiceConsent(statement: "本人声音")
        )
    }

    /// 把捕获到的请求体解析成 JSON（`await` 不能进 `XCTUnwrap` 的 autoclosure，
    /// 所以参数先在外面 await 好再传进来）。
    private func jsonObject(_ body: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(body, "没有收到请求体")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 记录请求并返回可指定状态码的响应（默认 500：多数用例只关心发出去的请求体）。
    private func transport(recorder: CallRecorder, status: Int = 500) -> HTTPClient.Transport {
        { request, _ in
            await recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
    }

    // MARK: - 取值语义

    func testBuiltinSelectionCarriesNoReference() {
        let selection = SpeechVoiceSelection.builtin("Serena")
        XCTAssertEqual(selection.voice, "Serena")
        XCTAssertNil(selection.referenceAudioPath)
        XCTAssertFalse(selection.isCloned)
    }

    func testClonedSelectionIsCloned() {
        let selection = SpeechVoiceSelection(voice: "v1", referenceAudioPath: referencePath)
        XCTAssertTrue(selection.isCloned)
    }

    /// 空白参考路径等于「没有参考」——否则会发一个空字段，runtime 侧只能瞎猜。
    func testBlankReferenceIsNotCloned() {
        XCTAssertFalse(SpeechVoiceSelection(voice: "v1", referenceAudioPath: "   ").isCloned)
    }

    func testRequestCarriesSelection() {
        let request = TTSRequest(
            text: "Hi.",
            voice: SpeechVoiceSelection(voice: "v1", referenceAudioPath: referencePath, referenceText: "hello"),
            language: "English"
        )
        XCTAssertEqual(request.voice, "v1")
        XCTAssertEqual(request.referenceAudioPath, referencePath)
        XCTAssertEqual(request.referenceText, "hello")
        XCTAssertEqual(request.language, "English")
        XCTAssertTrue(request.usesClonedVoice)
    }

    // MARK: - 服务侧解析：克隆音色真正生效的落点

    func testSelectionFallsBackToBuiltinWithoutActiveProfile() async {
        let services = makeServices()
        let selection = await services.effectiveSpeechVoiceSelection()
        let name = await services.effectiveSpeechVoice()

        XCTAssertFalse(selection.isCloned, "没启用克隆音色就不该带参考音频")
        XCTAssertNil(selection.referenceAudioPath)
        XCTAssertFalse(selection.voice.isEmpty, "没启用也要有可用的内置音色名")
        XCTAssertEqual(name, selection.voice, "两个入口必须一致")
    }

    func testActiveClonedProfileYieldsReferenceAudio() async throws {
        let services = makeServices()
        await services.tts.register(StubTTSProvider(cloning: true))
        try await services.saveVoiceProfile(clonedProfile())
        try await services.activateVoiceProfile(id: "my-voice")

        let selection = await services.effectiveSpeechVoiceSelection()
        let name = await services.effectiveSpeechVoice()

        XCTAssertTrue(selection.isCloned, "启用克隆音色后必须把参考音频带上")
        XCTAssertEqual(selection.voice, "my-voice")
        XCTAssertEqual(selection.referenceAudioPath, referencePath)
        XCTAssertEqual(selection.referenceText, "Hello, this is my voice.")
        XCTAssertEqual(name, "my-voice")
    }

    /// 档案存在但**没启用** → 仍用内置音色（不能因为「库里有一份克隆」就自动走克隆）。
    func testSavedButInactiveProfileDoesNotTakeEffect() async throws {
        let services = makeServices()
        await services.tts.register(StubTTSProvider(cloning: true))
        try await services.saveVoiceProfile(clonedProfile())

        let selection = await services.effectiveSpeechVoiceSelection()

        XCTAssertFalse(selection.isCloned)
        XCTAssertNotEqual(selection.voice, "my-voice")
    }

    /// 停用后立刻回到内置音色：否则用户点了「停用」却还在被克隆声音念，
    /// 是最容易被当成 bug 的行为。
    func testDeactivateDropsReferenceAudio() async throws {
        let services = makeServices()
        await services.tts.register(StubTTSProvider(cloning: true))
        try await services.saveVoiceProfile(clonedProfile())
        try await services.activateVoiceProfile(id: "my-voice")

        let active = await services.effectiveSpeechVoiceSelection()
        XCTAssertTrue(active.isCloned)

        try await services.deactivateClonedVoice()
        let afterStop = await services.effectiveSpeechVoiceSelection()
        XCTAssertFalse(afterStop.isCloned)
    }

    // MARK: - 本地适配器：参考音频必须真的发出去

    func testLocalAdapterSendsReferenceAudio() async throws {
        let recorder = CallRecorder()
        let adapter = Qwen3TTSAdapter(
            providerID: "local.tts",
            client: HTTPClient(transport: transport(recorder: recorder))
        )
        try await adapter.initialize(
            config: ProviderConfig(
                id: "local.tts", kind: .tts, enabled: true, runtime: .externalLocalRuntime,
                endpoint: "http://127.0.0.1:18855", model: "serena",
                capabilities: ["voiceCloning"]
            )
        )

        _ = try? await adapter.synthesize(
            TTSRequest(
                text: "Nice to meet you!",
                voice: SpeechVoiceSelection(
                    voice: "my-voice", referenceAudioPath: referencePath, referenceText: "hello"
                ),
                language: "English"
            )
        )

        let json = try jsonObject(await recorder.lastBody)
        XCTAssertEqual(json["voice"] as? String, "my-voice")
        XCTAssertEqual(json["referenceAudio"] as? String, referencePath, "参考音频必须随请求发出")
        XCTAssertEqual(json["referenceText"] as? String, "hello")
    }

    /// 内置音色请求里**不该出现**参考字段：老 runtime 收到未知键未必无害。
    func testLocalAdapterOmitsReferenceForBuiltinVoice() async throws {
        let recorder = CallRecorder()
        let adapter = Qwen3TTSAdapter(
            providerID: "local.tts",
            client: HTTPClient(transport: transport(recorder: recorder))
        )
        try await adapter.initialize(
            config: ProviderConfig(
                id: "local.tts", kind: .tts, enabled: true, runtime: .externalLocalRuntime,
                endpoint: "http://127.0.0.1:18855", model: "serena"
            )
        )

        _ = try? await adapter.synthesize(
            TTSRequest(text: "Hi.", voice: SpeechVoiceSelection.builtin("serena"), language: "English")
        )

        let json = try jsonObject(await recorder.lastBody)
        XCTAssertNil(json["referenceAudio"])
        XCTAssertNil(json["referenceText"])
    }

    /// 适配器自报能力取自配置声明（`ttsSupportsVoiceCloning` 的第二个来源）。
    func testLocalAdapterReportsDeclaredCapability() async throws {
        let adapter = Qwen3TTSAdapter(providerID: "local.tts", client: HTTPClient())
        try await adapter.initialize(
            config: ProviderConfig(
                id: "local.tts", kind: .tts, enabled: true, runtime: .externalLocalRuntime,
                endpoint: "http://127.0.0.1:18855", capabilities: ["voiceCloning"]
            )
        )
        XCTAssertTrue(adapter.capabilities().voiceCloning)
    }

    // MARK: - 云端适配器：不接第三方克隆（结构防线）

    /// 参考音频落到云端供应商手里 = 用户声音被上传给第三方。必须**在发请求之前**拒绝。
    func testRemoteAdapterRefusesClonedReferenceWithoutSending() async throws {
        let recorder = CallRecorder()
        let adapter = RemoteTTSAdapter(
            providerID: "test.tts",
            client: HTTPClient(transport: transport(recorder: recorder))
        )
        try await adapter.initialize(
            config: ProviderConfig(
                id: "test.tts", kind: .tts, enabled: true, runtime: .remoteAPI,
                endpoint: "http://127.0.0.1:19999/v1", apiKey: "sk-test-only",
                model: "some-tts", candidateModels: ["some-tts"]
            )
        )

        do {
            _ = try await adapter.synthesize(
                TTSRequest(
                    text: "Hi.",
                    voice: SpeechVoiceSelection(voice: "v1", referenceAudioPath: referencePath)
                )
            )
            XCTFail("云端供应商必须拒绝参考音频")
        } catch {
            // 期望一个说明「不支持克隆」的错误，而不是碰巧撞上的别的失败。
            XCTAssertTrue("\(error)".contains("克隆"), "错误文案要说明原因，实际：\(error)")
        }

        let calls = await recorder.count
        XCTAssertEqual(calls, 0, "拒绝必须发生在发请求之前")
    }

    func testRemoteAdapterStillSynthesizesBuiltinVoice() async throws {
        let recorder = CallRecorder()
        let adapter = RemoteTTSAdapter(
            providerID: "test.tts",
            client: HTTPClient(transport: transport(recorder: recorder))
        )
        try await adapter.initialize(
            config: ProviderConfig(
                id: "test.tts", kind: .tts, enabled: true, runtime: .remoteAPI,
                endpoint: "http://127.0.0.1:19999/v1", apiKey: "sk-test-only",
                model: "some-tts", candidateModels: ["some-tts"]
            )
        )

        // 桩服务返回 500：合成会失败，但请求**已经发出** —— 这里只关心这一点。
        _ = try? await adapter.synthesize(
            TTSRequest(text: "Hi.", voice: SpeechVoiceSelection.builtin("some-tts"))
        )

        let calls = await recorder.count
        XCTAssertEqual(calls, 1, "内置音色照常发请求，不该被克隆防线误伤")
    }

    // MARK: - 默认配置：能力声明必须真的存在，否则整个功能不可达

    /// 修这条之前的真实状态：适配器会读 `config.declaredVoiceCapabilities`，
    /// 但**没有一份配置声明过它** → 启用闸门永远拦住 → 界面永远显示「不支持」，
    /// 整条克隆链路其实是死的。能力位必须有人声明。
    func testDefaultConfigDeclaresCloningOnLocalTTSOnly() throws {
        let configuration = try DefaultConfiguration.load()
        let ttsProviders = configuration.providers.filter { $0.kind == .tts }
        XCTAssertFalse(ttsProviders.isEmpty, "默认配置里应当有语音供应商")

        let cloning = ttsProviders.filter { $0.supportsVoiceCapability(.voiceCloning) }
        XCTAssertEqual(
            cloning.map(\.id), ["local.tts"],
            "只有本地运行时该声明克隆；云端声明它等于开了第三方克隆的口子"
        )
        XCTAssertEqual(cloning.first?.runtime, .externalLocalRuntime, "克隆必须是本地处理")
        XCTAssertEqual(cloning.first?.endpoint, "http://127.0.0.1:8855")
    }

    /// 云端语音供应商一个都不许声明克隆能力。
    func testNoRemoteTTSDeclaresCloning() throws {
        let configuration = try DefaultConfiguration.load()
        let offenders = configuration.providers
            .filter { $0.kind == .tts && $0.runtime == .remoteAPI }
            .filter { $0.supportsVoiceCapability(.voiceCloning) }
            .map(\.id)
        XCTAssertTrue(offenders.isEmpty, "这些云端供应商声明了克隆：\(offenders)")
    }

    /// 出厂默认必须**开箱即有声**。
    ///
    /// 早先默认启用的是本机 Qwen3（`local.tts` :8855）——它要求用户先跑
    /// `~/AI_Models/bin/start-tts.sh`，没跑则整条朗读链路不可用且没有回退。
    /// 现在默认启用免密钥的 Edge 代理（`remote.kina-tts` :8856，不需要本机服务、
    /// 不产生费用），本地那份降为「要克隆音色时再自己开」。
    func testDefaultConfigEnablesKeylessEdgeTTSByDefault() throws {
        let configuration = try DefaultConfiguration.load()
        let enabled = configuration.providers
            .filter { $0.kind == .tts && $0.enabled }
            .map(\.id)
        XCTAssertEqual(enabled, ["remote.kina-tts"], "默认只启用免密钥的 Edge 代理")

        let resolved = configuration.resolvedProvider(for: .tts)
        XCTAssertEqual(resolved?.id, "remote.kina-tts")
        XCTAssertEqual(resolved?.runtime, .remoteAPI)
        XCTAssertEqual(resolved?.apiKeyRequired, false, "免密钥才谈得上开箱可用")
        XCTAssertEqual(resolved?.billable, false)
    }
}
