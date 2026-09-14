import AIDomain
import AIInfrastructure
import AIInterfaces
import AIProviders
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 朗读投递方式（云端整段 / 本地分句）的纯函数规则。
///
/// 产品口径：本地模型合成慢，必须分句流水线把首句等待降下来；
/// 云端响应快，再分句只会把一句句话拆成独立请求、割裂韵律，所以整段一次合成。
final class SpeechDeliveryTests: XCTestCase {

    func testRemoteRuntimeUsesWholeText() {
        XCTAssertEqual(SpeechDelivery.forRuntime(.remoteAPI), .whole)
    }

    func testLocalRuntimesKeepSegmentedPipeline() {
        for runtime in [RuntimeKind.ollama, .externalLocalRuntime, .pythonProcess, .embedded, .pipeline, .mock] {
            XCTAssertEqual(SpeechDelivery.forRuntime(runtime), .segmented,
                           "\(runtime.rawValue) 是本地/内置 runtime，应保持分句流水线")
        }
    }

    func testWholeTextAllowsLongerInput() {
        XCTAssertGreaterThan(SpeechDelivery.whole.maxCharacters, SpeechDelivery.segmented.maxCharacters)
        // 本地那 400 字符是为了控制等待，不能悄悄放宽。
        XCTAssertEqual(SpeechDelivery.segmented.maxCharacters, 400)
    }

    /// 清洗函数的截断上限要真的跟着投递方式走。
    func testCleanForSpeechHonoursLimit() {
        let long = String(repeating: "a", count: 2500)
        XCTAssertEqual(VoiceService.cleanForSpeech(long).count, 400, "默认按本地分句上限截断")
        XCTAssertEqual(
            VoiceService.cleanForSpeech(long, limit: SpeechDelivery.whole.maxCharacters).count,
            SpeechDelivery.whole.maxCharacters,
            "云端上限更宽松，长段落能一次读完"
        )
        // 短文本不被截断
        XCTAssertEqual(VoiceService.cleanForSpeech("Hello there."), "Hello there.")
    }

    // MARK: - Manager 真的按注册的 Provider 报告投递方式

    func testManagerReportsDeliveryFromRegisteredProvider() async throws {
        let manager = TTSManager()

        // 没有 Provider：按本地处理（不能凭空整段合成）。
        var delivery = await manager.delivery
        XCTAssertEqual(delivery, .segmented)

        let remote = RemoteTTSAdapter(providerID: "remote.test-tts")
        try await remote.initialize(config: ProviderConfig(
            id: "remote.test-tts", kind: .tts, runtime: .remoteAPI,
            endpoint: "https://example.invalid/v1", apiKey: "sk-test"
        ))
        await manager.register(remote)
        delivery = await manager.delivery
        XCTAssertEqual(delivery, .whole, "云端 TTS 生效时应当整段合成")

        let local = Qwen3TTSAdapter(providerID: "local.test-tts")
        try await local.initialize(config: ProviderConfig(
            id: "local.test-tts", kind: .tts, runtime: .externalLocalRuntime, endpoint: "http://127.0.0.1:8855"
        ))
        await manager.register(local)
        delivery = await manager.delivery
        XCTAssertEqual(delivery, .segmented, "切回本地模型要回到分句流水线")

        await manager.unregister()
        delivery = await manager.delivery
        XCTAssertEqual(delivery, .segmented)
    }
}

/// 「重开设置不用重来一遍」：外部模型的 API Key / 模型列表 / 选中供应商都要能回填。
@MainActor
final class ExternalModelPrefillTests: XCTestCase {

    private func makeServices() -> (services: CoachServices, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefill-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let services = CoachServices(
            config: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            databasePath: ":memory:"
        )
        return (services, directory)
    }

    /// 用户上次已经配好云端语音：重开设置必须能直接看到「已保存的 Key + 可选模型 + 选中的那家」。
    func testPrefillRestoresSavedKeyModelsAndSelectedProvider() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefill-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let providerID = "remote.siliconflow-asr"
        let apiKey = "sk-saved-key-abcdef"
        let model = "XingChenAGI/XingChenASR-Diarize-V3.0"
        let other = "openai/whisper-large-v3"
        // 走正常写入路径「先配好一次」，模拟用户上次已经接好了云端语音。
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await store.mutateProvider(id: providerID) { provider in
            provider.apiKey = apiKey
            provider.model = model
            provider.candidateModels = [model, other]
        }
        try await store.mutateProduct { product in
            product.activateProvider(providerID, for: .asr)
            product.selectModel(model, for: .asr)
        }

        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        await state.prefillExternalDrafts()

        // ① Key 回填：界面上的框不再是空的，用户不用重新输。
        XCTAssertEqual(state.externalKeyDrafts[providerID], apiKey)
        XCTAssertTrue(state.hasKeyDraft(providerID), "输入框里有 Key 才点亮小绿点")
        // ② 模型列表回填：选择器直接可用，能切换。
        let models = try XCTUnwrap(state.externalModels[providerID])
        XCTAssertEqual(models.first?.id, model, "当前模型排在最前")
        XCTAssertTrue(models.contains { $0.id == other }, "历史候选也要在")
        // ③ 选中标签落在用户上次真正用的那家。
        XCTAssertEqual(state.externalSelectedProvider["asr"], providerID)
    }

    /// 草稿里正在输入的内容不能被配置覆盖（只补空）。
    func testPrefillNeverOverwritesUserTyping() async throws {
        let (services, directory) = makeServices()
        defer { try? FileManager.default.removeItem(at: directory) }

        let providerID = "remote.openai-asr"
        try await services.persistRemoteProvider(
            providerID: providerID, apiKey: "sk-saved", model: "whisper-1", kind: .asr
        )
        let state = AppState(services: services)
        state.setKeyDraft("sk-typing-now", providerID: providerID, kind: .asr)
        await state.prefillExternalDrafts()

        XCTAssertEqual(state.externalKeyDrafts[providerID], "sk-typing-now")
        XCTAssertTrue(state.hasKeyDraft(providerID), "框里有 Key 就该点亮绿点")
    }

    /// 选中的模型会被记进候选集，且探测到的整份列表会覆盖保存下来。
    func testAppliedModelAndDiscoveredListAreRemembered() async throws {
        let (services, directory) = makeServices()
        defer { try? FileManager.default.removeItem(at: directory) }

        let providerID = "remote.siliconflow-tts"
        try await services.persistRemoteProvider(
            providerID: providerID, apiKey: "sk-tts", model: "FunAudioLLM/CosyVoice2-0.5B", kind: .tts
        )
        var configuration = await services.configuration
        var provider = try XCTUnwrap(configuration.providers.first { $0.id == providerID })
        XCTAssertTrue(provider.candidateModels.contains("FunAudioLLM/CosyVoice2-0.5B"),
                      "选中的模型要进候选集，否则下次打不开选择器")

        await services.rememberRemoteModels(
            [DiscoveredModel(id: "fishaudio/fish-speech-1.5", name: "fishaudio/fish-speech-1.5")],
            providerID: providerID, kind: .tts
        )
        configuration = await services.configuration
        provider = try XCTUnwrap(configuration.providers.first { $0.id == providerID })
        XCTAssertEqual(provider.candidateModels, ["fishaudio/fish-speech-1.5"], "探测结果要留下来")
    }

    /// ⚠️ **非**生效 Provider 不能继承产品层「按能力」存的当前模型。
    ///
    /// `product.selectedModel(for:)` 是**按能力**存的全局值，不看 Provider：
    /// 无脑并进候选，用户打开 DeepSeek 面板就会看到本地 Ollama 的 `qwen3:8b`
    /// 被列成「DeepSeek 可用模型」，页脚还写着「共 1 个可用模型」——
    /// 既误导选择，也可能真的选中它去发一个必然失败的请求。
    func testPrefillDoesNotLeakProductModelIntoOtherRemoteProviders() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefill-leak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        // 产品层当前生效的是**本地**模型；DeepSeek 只是「可选的另一家」。
        try await store.mutateProduct { product in
            product.selectModel("qwen3:8b", for: .llm)
        }
        let services = CoachServices(config: store, databasePath: ":memory:")

        var configuration = await services.configuration
        XCTAssertEqual(configuration.resolvedProvider(for: .llm)?.id, "ollama.llm",
                       "前置条件：生效的是本地 Provider，不是 DeepSeek")

        let state = AppState(services: services)
        await state.prefillExternalDrafts()

        let leaked = state.externalModels["remote.deepseek"] ?? []
        XCTAssertFalse(
            leaked.contains { $0.id == "qwen3:8b" },
            "本地模型不该出现在云端厂商的候选里（会让用户以为 DeepSeek 能跑 qwen3:8b）"
        )
    }

    /// 反过来：**生效的就是那家云端**时，当前模型必须出现在它的候选里 —— 否则选择器是空的。
    /// 这一条与上一条是同一个判断的两面，一起钉住才说明「按生效 Provider 判定」真的成立。
    func testPrefillShowsCurrentModelForActiveRemoteProvider() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefill-active-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        // 有 Key 才是 isUsable —— 否则 resolvedProvider 会跳过云端、回退本地。
        _ = try await store.mutateProvider(id: "remote.deepseek") { $0.apiKey = "sk-test" }
        try await store.mutateProduct { product in
            product.activateProvider("remote.deepseek", for: .llm)
            product.selectModel("deepseek-chat", for: .llm)
        }
        let services = CoachServices(config: store, databasePath: ":memory:")

        let configuration = await services.configuration
        XCTAssertEqual(configuration.resolvedProvider(for: .llm)?.id, "remote.deepseek",
                       "前置条件：生效的应当是 DeepSeek")

        let state = AppState(services: services)
        await state.prefillExternalDrafts()

        XCTAssertTrue(
            (state.externalModels["remote.deepseek"] ?? []).contains { $0.id == "deepseek-chat" },
            "生效 Provider 的当前模型必须还在，否则下拉框会空"
        )
    }
}
