import AIDomain
import AIInfrastructure
import AIInterfaces
import AIProviders
import AIServices
import AppCore
@testable import AppUI
import Foundation
import XCTest

/// 云端调用「只调指定模型」的结构性回归。
///
/// 背景（2026-09-13 第二次事故反馈）：用户在**语音**场景下，账单里却出现大量语言模型
/// （`zai-org/glm-5.3`）的 token 计费；同时配置里出现「本地模型名被写进云端供应商」
/// （`remote.siliconflow-asr` 的 model 变成了 `ggml-small.en`）。
///
/// 这个文件把三类根因钉死在测试里：
/// 1. **操作 ↔ 能力必须匹配**（语音操作不可能打到对话端点）；
/// 2. **模型必须属于这家供应商**（本地模型名不可能被发去云端）；
/// 3. **语音链路不产生任何语言模型费用**（拼写纠正只在本地 LLM 上执行，
///    云端 ASR 不做流式中间识别）；
/// 外加两条 UI 语义：切本地要真的关掉云端、空 Key 框不再被当成旧密钥。
///
/// 全部用例只碰本机/非法地址，**不产生任何真实计费**。
@MainActor
final class CloudCallIsolationTests: XCTestCase {

    /// `nonisolated`：`setUp` / `tearDown` 重写的是 XCTest 里**非隔离**的方法，
    /// 从那里读主 actor 静态属性会被判越界。它本身只是个路径常量，跟隔离状态无关。
    private nonisolated static let isolatedLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("alc-isolation-remote-calls.jsonl")

    override func setUp() {
        super.setUp()
        setenv("ALC_REMOTE_CALL_LOG", Self.isolatedLog.path, 1)
        try? FileManager.default.removeItem(at: Self.isolatedLog)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: Self.isolatedLog)
        super.tearDown()
    }

    // MARK: - 纯规则：操作必须与能力匹配

    func testOperationMustMatchCapability() {
        XCTAssertTrue(RemoteCallPolicy.operationMatches(kind: .llm, operation: .chat))
        XCTAssertTrue(RemoteCallPolicy.operationMatches(kind: .tts, operation: .speech))
        XCTAssertTrue(RemoteCallPolicy.operationMatches(kind: .asr, operation: .transcriptions))

        // 这两条是本次事故的关键：语音能力**不可能**打出对话请求。
        XCTAssertFalse(RemoteCallPolicy.operationMatches(kind: .tts, operation: .chat))
        XCTAssertFalse(RemoteCallPolicy.operationMatches(kind: .asr, operation: .chat))
        XCTAssertFalse(RemoteCallPolicy.operationMatches(kind: .llm, operation: .speech))
        XCTAssertFalse(RemoteCallPolicy.operationMatches(kind: .tts, operation: .transcriptions))

        // 只读探测不设限（健康检查要用）。
        for kind in AIProviderKind.allCases {
            XCTAssertTrue(RemoteCallPolicy.operationMatches(kind: kind, operation: .models))
        }
    }

    /// 端点口径：每条记录都能对上服务商账单里的计费项。
    func testOperationEndpointPaths() {
        XCTAssertEqual(RemoteCallPolicy.Operation.chat.endpointPath, "/v1/chat/completions")
        XCTAssertEqual(RemoteCallPolicy.Operation.speech.endpointPath, "/v1/audio/speech")
        XCTAssertEqual(RemoteCallPolicy.Operation.transcriptions.endpointPath, "/v1/audio/transcriptions")
        XCTAssertEqual(RemoteCallPolicy.Operation.models.endpointPath, "/v1/models")
        let intent = RemoteCallPolicy.Intent(kind: .tts, providerID: "p", model: "m", host: "h", operation: .speech)
        XCTAssertEqual(intent.endpoint, "/v1/audio/speech")
    }

    // MARK: - 纯规则：模型必须属于这家供应商

    func testModelOwnershipRule() {
        // 云端供应商名单里没有本地模型名 → 拒绝（这正是把 ggml-small.en 发给 SiliconFlow 的场景）
        XCTAssertFalse(RemoteCallPolicy.isModelAllowed(
            "ggml-small.en", providerModel: nil, candidates: ["fnlp/MOSS-TTSD-v0.5"]
        ))
        // 名单里有 → 放行
        XCTAssertTrue(RemoteCallPolicy.isModelAllowed(
            "fnlp/MOSS-TTSD-v0.5", providerModel: nil, candidates: ["fnlp/MOSS-TTSD-v0.5", "other/model"]
        ))
        // Provider 自己配的模型同样算「属于」
        XCTAssertTrue(RemoteCallPolicy.isModelAllowed(
            "Qwen3-TTS-12Hz-0.6B-CustomVoice",
            providerModel: "Qwen3-TTS-12Hz-0.6B-CustomVoice",
            candidates: []
        ))
        // 空白与未知名单一律拒绝（fail closed：宁可让用户去选一次）
        XCTAssertFalse(RemoteCallPolicy.isModelAllowed("  ", providerModel: "m", candidates: ["m"]))
        XCTAssertFalse(RemoteCallPolicy.isModelAllowed("m", providerModel: nil, candidates: []))

        // ⭐ 关键回归：`provider.model` 被旧 bug 写成**本地模型名**时，候选清单必须压过它。
        // 若允许集合把 provider.model 也算进去，这个名字就自己给自己背书、顺利发去云端计费。
        XCTAssertFalse(
            RemoteCallPolicy.isModelAllowed(
                "ggml-small.en", providerModel: "ggml-small.en", candidates: ["fnlp/MOSS-TTSD-v0.5"]
            ),
            "候选清单非空时，被污染的 provider.model 不能给自己背书"
        )
        XCTAssertEqual(
            RemoteCallPolicy.allowedModelSet(providerModel: "ggml-small.en", candidates: []),
            ["ggml-small.en"],
            "没有候选清单时才退回 provider.model（用户手填的自定义模型）"
        )
        XCTAssertEqual(
            RemoteCallPolicy.allowedModelSet(providerModel: "ggml-small.en", candidates: ["cloud/model"]),
            ["cloud/model"]
        )
    }

    /// 语音合配送来一个「不属于这家」的模型名时，必须在**发请求之前**就拒绝。
    /// 端点故意指向无人监听的端口：若真的发了请求，错误会是连接失败而不是配置错误。
    func testSpeechAdapterRefusesForeignModelBeforeAnyRequest() async throws {
        let config = ProviderConfig(
            id: "test.tts", kind: .tts, enabled: true, runtime: .remoteAPI,
            endpoint: "http://127.0.0.1:1/v1", apiKey: "sk-test-only",
            model: "fnlp/MOSS-TTSD-v0.5",
            candidateModels: ["fnlp/MOSS-TTSD-v0.5"]
        )
        let adapter = RemoteTTSAdapter(providerID: "test.tts", client: HTTPClient(useSystemProxy: false))
        try await adapter.initialize(config: config)

        // 把「选中模型」换成本地模型名（模拟历史上被串线的配置）。
        var wrong = config
        wrong.model = "ggml-small.en"
        let wrongAdapter = RemoteTTSAdapter(providerID: "test.tts", client: HTTPClient(useSystemProxy: false))
        try await wrongAdapter.initialize(config: wrong)

        do {
            _ = try await wrongAdapter.synthesize(TTSRequest(text: "Hello!"))
            XCTFail("本地模型名不该被发给云端语音接口")
        } catch let error as AIProviderError {
            guard case .invalidConfiguration(let reason) = error else {
                return XCTFail("应当是配置类错误（发请求前就拒绝），实际：\(error)")
            }
            XCTAssertTrue(reason.contains("不属于当前供应商"), "要说清原因：\(reason)")
        }
    }

    /// 结构防线：能力与配置错配时，适配器连初始化都不该通过。
    func testAdapterRefusesConfigurationOfAnotherCapability() async throws {
        let asrConfig = ProviderConfig(
            id: "remote.siliconflow-tts", kind: .asr, enabled: true, runtime: .remoteAPI,
            endpoint: "https://api.siliconflow.cn/v1", apiKey: "sk-test-only", model: "m"
        )
        let ttsAdapter = RemoteTTSAdapter(providerID: "remote.siliconflow-tts", client: HTTPClient(useSystemProxy: false))
        do {
            try await ttsAdapter.initialize(config: asrConfig)
            XCTFail("语音合成 Provider 不能吃语音识别的配置")
        } catch let error as AIProviderError {
            guard case .invalidConfiguration(let reason) = error else {
                return XCTFail("应当是配置类错误，实际：\(error)")
            }
            XCTAssertTrue(reason.contains("配置不匹配"), reason)
        }

        let ttsConfig = ProviderConfig(
            id: "remote.siliconflow-tts", kind: .tts, enabled: true, runtime: .remoteAPI,
            endpoint: "https://api.siliconflow.cn/v1", apiKey: "sk-test-only", model: "m"
        )
        let llmAdapter = RemoteLLMAdapter(providerID: "remote.siliconflow-tts", client: HTTPClient(useSystemProxy: false))
        do {
            try await llmAdapter.initialize(config: ttsConfig)
            XCTFail("对话 Provider 不能吃语音合成的配置——这条正是「语音操作却调了语言模型」的结构入口")
        } catch let error as AIProviderError {
            guard case .invalidConfiguration = error else {
                return XCTFail("应当是配置类错误，实际：\(error)")
            }
        }
    }

    // MARK: - 语音链路不产生语言模型费用

    /// 云端 ASR：不做流式中间识别（每次中间识别都是一次完整计费请求）。
    func testVoiceCapturePolicyDisablesCloudPartials() {
        XCTAssertFalse(VoiceCapturePolicy.allowsStreamingPartials(for: .remoteAPI))
        XCTAssertTrue(VoiceCapturePolicy.allowsStreamingPartials(for: .externalLocalRuntime))
        XCTAssertTrue(VoiceCapturePolicy.allowsStreamingPartials(for: .ollama))
        XCTAssertFalse(VoiceCapturePolicy.explanation(for: .remoteAPI).isEmpty)
    }

    /// 语言模型在云端时：**语音输入后的拼写纠正一律跳过**，不发任何请求。
    func testCloudLLMSkipsSpellingCorrectionEntirely() async throws {
        let (services, directory) = try await makeServices { store in
            // 语言模型配成云端（带 Key，因此"可用"），端点指向无人监听的本地端口。
            try await store.mutateProviders(kind: .llm) { $0.enabled = ($0.id == "remote.deepseek") }
            try await store.mutateProvider(id: "remote.deepseek") { p in
                p.apiKey = "sk-never-used"
                p.model = "some/chat-model"
                p.candidateModels = ["some/chat-model"]
                p.endpoint = "http://127.0.0.1:1/v1"
            }
            try await store.mutateProduct { $0.activateProvider("remote.deepseek", for: .llm) }
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = await services.remoteCallSummary().billableTotal
        let corrected = await services.correctSpelling("helo wrld")
        let after = await services.remoteCallSummary().billableTotal

        XCTAssertEqual(corrected, "helo wrld", "云端语言模型下必须原样返回，不做纠正")
        XCTAssertEqual(after, before, "语音输入的纠错不能产生任何云端请求")
        let note = await services.spellingCorrectionNote()
        XCTAssertTrue(note.contains("跳过"), note)
    }

    // MARK: - 切到本地：必须真的关掉外部模型接口

    func testSwitchingCapabilityToLocalDisablesCloudAndKeepsModelsSeparate() async throws {
        let (services, directory) = try await makeServices { store in
            try await store.mutateProvider(id: "remote.siliconflow-asr") { p in
                p.apiKey = "sk-cloud"
                p.model = "XingChenAGI/XingChenASR-Diarize-V3.0"
                p.candidateModels = ["XingChenAGI/XingChenASR-Diarize-V3.0"]
            }
            try await store.mutateProviders(kind: .asr) { $0.enabled = ($0.id == "remote.siliconflow-asr") }
            try await store.mutateProduct { $0.activateProvider("remote.siliconflow-asr", for: .asr) }
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        try await services.setCapabilityProvider(.asr, providerID: "local.asr")

        let configuration = await services.configuration
        let cloud = try XCTUnwrap(configuration.providers.first { $0.id == "remote.siliconflow-asr" })
        let local = try XCTUnwrap(configuration.providers.first { $0.id == "local.asr" })
        XCTAssertFalse(cloud.enabled, "切到本地后，外部模型接口必须被关掉")
        XCTAssertTrue(local.enabled)
        XCTAssertEqual(configuration.resolvedProvider(for: .asr)?.id, "local.asr")
        // 云端那份配置里的模型名不许被本地模型污染，反之亦然。
        XCTAssertEqual(cloud.model, "XingChenAGI/XingChenASR-Diarize-V3.0")
        XCTAssertNotEqual(configuration.resolvedModel(for: .asr), cloud.model)
    }

    /// 回归（截图里的状态）：选本地模型时，本地模型名**绝不能**被写进云端供应商。
    func testSelectingLocalModelNeverWritesIntoCloudProvider() async throws {
        let (store, directory) = try await makeServicesStore { store in
            try await store.mutateProvider(id: "remote.siliconflow-asr") { p in
                p.apiKey = "sk-cloud"
                p.model = "XingChenAGI/XingChenASR-Diarize-V3.0"
                p.candidateModels = ["XingChenAGI/XingChenASR-Diarize-V3.0"]
            }
            try await store.mutateProviders(kind: .asr) { $0.enabled = ($0.id == "remote.siliconflow-asr") }
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let services = CoachServices(config: store, databasePath: ":memory:")
        let state = AppState(services: services)
        await state.selectLocalModel(.asr, name: "ggml-small.en")

        let configuration = await store.current
        let cloud = try XCTUnwrap(configuration.providers.first { $0.id == "remote.siliconflow-asr" })
        let local = try XCTUnwrap(configuration.providers.first { $0.id == "local.asr" })
        XCTAssertEqual(cloud.model, "XingChenAGI/XingChenASR-Diarize-V3.0",
                       "本地模型名 ggml-small.en 不该出现在云端供应商上")
        XCTAssertFalse(cloud.enabled)
        XCTAssertTrue(local.enabled, "选本地模型应当切到本地 Provider")
        XCTAssertEqual(configuration.product.selectedModel(for: .asr), "ggml-small.en")
        XCTAssertEqual(configuration.resolvedProvider(for: .asr)?.id, "local.asr")
    }

    /// 云端 Provider 没有 Key 时不允许被激活（避免「已启用却调不动」）。
    func testCloudProviderWithoutKeyCannotBeActivated() async throws {
        let (services, directory) = try await makeServices { store in
            try await store.mutateProviders(kind: .tts) { $0.enabled = ($0.id == "remote.openai-tts") }
            try await store.mutateProduct { $0.activateProvider("remote.openai-tts", for: .tts) }
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try await services.setCapabilityProvider(.tts, providerID: "remote.openai-tts")
            XCTFail("没有 Key 的云端 Provider 不该被激活")
        } catch {
            XCTAssertTrue("\(error)".contains("API Key"), "\(error)")
        }
    }

    /// 免密钥供应商（`api_key_required = false`，如自建 Edge TTS 代理）：
    /// 没有 Key 也能走「验证 → 应用」链路激活，且费用护栏把它的调用记为免费。
    func testKeylessProviderActivatesWithoutKeyAndAppliesVoice() async throws {
        let (services, directory) = try await makeServices { store in
            try await store.mutateProvider(id: "remote.kina-tts") { p in
                p.model = "en-US-AriaNeural"
            }
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyless = await services.isKeyless(providerID: "remote.kina-tts", kind: .tts)
        XCTAssertTrue(keyless)

        // 无 Key 激活 + 选音色（applyRemoteProvider 对空 Key 不再拒绝）
        try await services.applyRemoteProvider(
            providerID: "remote.kina-tts", apiKey: "", model: "en-US-AriaNeural", kind: .tts
        )
        let configuration = await services.configuration
        let kina = try XCTUnwrap(configuration.providers.first { $0.id == "remote.kina-tts" })
        XCTAssertTrue(kina.enabled)
        XCTAssertNil(kina.apiKey)
        XCTAssertEqual(kina.model, "en-US-AriaNeural")
        XCTAssertEqual(configuration.resolvedProvider(for: .tts)?.id, "remote.kina-tts")
        XCTAssertEqual(configuration.resolvedModel(for: .tts), "en-US-AriaNeural")
    }

    // MARK: - 空 API Key 框不再被当成旧密钥

    /// 输入框为空 = 清除已保存的密钥；有内容才保存。
    func testEmptyKeyClearsStoredKeyAndNonEmptySaves() async throws {
        let (services, directory) = try await makeServices { store in
            try await store.mutateProvider(id: "remote.siliconflow-asr") { p in
                p.apiKey = "sk-old-key"
                p.model = "m"
            }
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = await services.configuration
        XCTAssertEqual(configuration.providers.first { $0.id == "remote.siliconflow-asr" }?.apiKey, "sk-old-key")

        // 空输入框 → 清除
        let kept = try await services.setRemoteProviderKey(providerID: "remote.siliconflow-asr", apiKey: "   ", kind: .asr)
        XCTAssertFalse(kept)
        configuration = await services.configuration
        let cleared = try XCTUnwrap(configuration.providers.first { $0.id == "remote.siliconflow-asr" })
        XCTAssertNil(cleared.apiKey, "输入框为空时必须清掉旧密钥")
        XCTAssertFalse(cleared.isUsable, "没有 Key 的云端 Provider 不再算可用")
        XCTAssertNil(configuration.product.selectedModel(for: .asr), "不该继续指向一个没有 Key 的云端供应商")

        // 填了新内容 → 保存
        let saved = try await services.setRemoteProviderKey(providerID: "remote.siliconflow-asr", apiKey: " sk-new ", kind: .asr)
        XCTAssertTrue(saved)
        configuration = await services.configuration
        XCTAssertEqual(configuration.providers.first { $0.id == "remote.siliconflow-asr" }?.apiKey, "sk-new")
    }

    /// 界面层：框里有 Key 才算「已配置」；清空后指纹与绿点都不该再出现。
    func testKeyStateFollowsTheInputBoxOnly() async throws {
        let (services, directory) = try await makeServices { store in
            try await store.mutateProvider(id: "remote.siliconflow-tts") { p in
                p.apiKey = "sk-saved-key-1234"
                p.model = "fnlp/MOSS-TTSD-v0.5"
            }
            try await store.mutateProduct { $0.activateProvider("remote.siliconflow-tts", for: .tts) }
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = AppState(services: services)
        await state.prefillExternalDrafts()
        XCTAssertTrue(state.hasKeyDraft("remote.siliconflow-tts"), "配置里有 Key 时应当回填到输入框")
        XCTAssertNotNil(state.externalKeyFingerprints["remote.siliconflow-tts"])

        // 用户清空输入框
        state.setKeyDraft("", providerID: "remote.siliconflow-tts", kind: .tts)
        XCTAssertFalse(state.hasKeyDraft("remote.siliconflow-tts"))
        XCTAssertNil(state.externalKeyFingerprints["remote.siliconflow-tts"], "框空了就不该再说「当前使用的密钥」")

        // 重开设置也不许把旧 Key「复活」回来
        await state.prefillExternalDrafts()
        XCTAssertFalse(state.hasKeyDraft("remote.siliconflow-tts"))
    }

    // MARK: - 历史坏配置：本地模型名被写进云端供应商

    /// 截图里的真实状态：`remote.siliconflow-asr` 的 model 是本地模型 `ggml-small.en`。
    /// 这种配置在云端不可能成立，必须被就地清掉（否则界面一直显示错误、调用必然失败）。
    func testHealingClearsLocalModelNameWrittenIntoCloudProvider() async throws {
        let (services, directory) = try await makeServices { store in
            try await store.mutateProvider(id: "remote.siliconflow-asr") { p in
                p.model = "ggml-small.en"          // 本地模型名，被旧版本写进了云端
                p.apiKey = "sk-cloud"
            }
            try await store.mutateProvider(id: "remote.siliconflow-tts") { p in
                p.model = "fnlp/MOSS-TTSD-v0.5"    // 真正的云端模型，不能被误清
            }
            try await store.mutateProduct { $0.selectModel("ggml-small.en", for: .asr) }
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        // 注入「本机装了哪些模型」，避免依赖测试机器的 ~/AI_Models
        let healed = await services.healCrossProviderModels { kind in
            kind == .asr ? ["ggml-small.en"] : []
        }

        XCTAssertEqual(healed, [.asr])
        let configuration = await services.configuration
        let asr = try XCTUnwrap(configuration.providers.first { $0.id == "remote.siliconflow-asr" })
        let tts = try XCTUnwrap(configuration.providers.first { $0.id == "remote.siliconflow-tts" })
        XCTAssertNil(asr.model, "云端供应商上的本地模型名必须被清掉")
        XCTAssertFalse(asr.enabled, "这个云端接口也必须被关掉（用户反馈：切本地却没关外部接口）")
        XCTAssertEqual(tts.model, "fnlp/MOSS-TTSD-v0.5", "真正的云端模型不能被误伤")
        XCTAssertNil(configuration.product.selectedModel(for: .asr), "产品层选择也要跟着清掉")
        XCTAssertNil(configuration.product.activeProvider(for: .asr), "不该继续指向一个被关掉的云端 Provider")
        // 修完之后生效的应当是本地 Provider —— 而不是继续显示「SiliconFlow 语音识别 · ggml-small.en」
        let local = try XCTUnwrap(configuration.providers.first { $0.id == "local.asr" })
        XCTAssertTrue(local.enabled, "「切本地」没做完的那一半要补上：本地 Provider 必须被打开")
        let effective = try XCTUnwrap(configuration.resolvedProvider(for: .asr))
        XCTAssertEqual(effective.id, "local.asr")
        XCTAssertFalse(effective.isRemote, "修复后不该再把云端那家解析成生效 Provider")
        XCTAssertEqual(configuration.resolvedModel(for: .asr), "ggml-small.en", "本地 Provider 自己的模型是合法的")

        // 幂等：再跑一次不会重复处理
        let again = await services.healCrossProviderModels { kind in kind == .asr ? ["ggml-small.en"] : [] }
        XCTAssertTrue(again.isEmpty)
    }

    /// 例外：供应商**自己广告过**的模型名不能被当成「误写的本地模型名」清掉。
    ///
    /// 真实场景：用户本地也部署了 `Qwen3-TTS-12Hz-0.6B-CustomVoice`（它是公开可下载的模型），
    /// 同时从 SiliconFlow 的模型列表里正当地选了同名模型。两家名字撞车时，
    /// 「在候选清单里」就是「这是合法云端选择」的证据，绝不能误伤。
    func testHealingDoesNotTouchModelTheProviderAdvertised() async throws {
        let model = "Qwen3-TTS-12Hz-0.6B-CustomVoice"
        let (services, directory) = try await makeServices { store in
            try await store.mutateProvider(id: "remote.siliconflow-tts") { p in
                p.apiKey = "sk-cloud"
                p.model = model
                p.candidateModels = [model, "fnlp/MOSS-TTSD-v0.5"]   // 云端真的探测到过它
            }
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let healed = await services.healCrossProviderModels { kind in
            kind == .tts ? [model] : []      // 本地恰好装了同名模型
        }

        XCTAssertTrue(healed.isEmpty, "候选清单里有的模型是合法选择，不该被清掉")
        let configuration = await services.configuration
        let tts = try XCTUnwrap(configuration.providers.first { $0.id == "remote.siliconflow-tts" })
        XCTAssertEqual(tts.model, model)
        XCTAssertEqual(tts.apiKey, "sk-cloud", "清模型时也不能顺手把 Key 抹掉")
    }

    /// 界面口径：修复之后，卡片必须按**新的**生效 Provider 来描述。
    ///
    /// 实测过的错误显示：切回本地之后，卡片仍写着「配置有误：API Key 无效或已过期」——
    /// 那是上一个（云端）Provider 留下的旧体检结果。切换 Provider 必须重取健康状态。
    func testCapabilityInfoDescribesTheLocalProviderAfterRepair() async throws {
        let (services, directory) = try await makeServices { store in
            try await store.mutateProvider(id: "remote.siliconflow-asr") { p in
                p.model = "ggml-small.en"
                p.apiKey = "sk-cloud"
            }
            try await store.mutateProviders(kind: .asr) { $0.enabled = ($0.id == "remote.siliconflow-asr") }
            try await store.mutateProduct { $0.activateProvider("remote.siliconflow-asr", for: .asr) }
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        // 先按「本机装了 ggml-small.en」把坏配置修掉，让后续断言与测试机无关。
        _ = await services.healCrossProviderModels { kind in kind == .asr ? ["ggml-small.en"] : [] }

        let state = AppState(services: services)
        await state.refreshCapabilityInfos()

        let info = try XCTUnwrap(state.capabilityInfos[.asr])
        XCTAssertFalse(info.isRemote, "修复后卡片不该再显示成云端 Provider")
        XCTAssertEqual(info.currentModel, "ggml-small.en")
        XCTAssertNil(state.modelHealNotice, "已经修过了就不该再提示一次（幂等）")
    }

    // MARK: - 审计留痕带上端点

    func testAuditRecordCarriesEndpoint() async {
        let intent = RemoteCallPolicy.Intent(
            kind: .tts, providerID: "p", model: "fnlp/MOSS-TTSD-v0.5", host: "api.example.com", operation: .speech
        )
        await RemoteCallAudit.shared.record(intent, outcome: .ok, httpStatus: 200)
        let record = await RemoteCallAudit.shared.recent(limit: 1).first
        XCTAssertEqual(record?.endpoint, "/v1/audio/speech")
        XCTAssertEqual(record?.model, "fnlp/MOSS-TTSD-v0.5")
        XCTAssertEqual(record?.detail, "HTTP 200")
    }

    // MARK: - 辅助

    private func makeServices(
        _ configure: (ConfigStore) async throws -> Void
    ) async throws -> (CoachServices, URL) {
        let store = try await makeServicesStore(configure)
        let services = CoachServices(config: store.store, databasePath: ":memory:")
        return (services, store.directory)
    }

    private func makeServicesStore(
        _ configure: (ConfigStore) async throws -> Void
    ) async throws -> (store: ConfigStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await configure(store)
        return (store, directory)
    }
}
