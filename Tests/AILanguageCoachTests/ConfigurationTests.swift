import AIInfrastructure
import AppCore
import XCTest

final class ConfigurationTests: XCTestCase {

    func testDefaultConfigurationLoadsAndResolvesLLMModel() throws {
        let configuration = try DefaultConfiguration.load()

        let provider = try XCTUnwrap(configuration.enabledProvider(for: .llm))
        XCTAssertEqual(provider.runtime, .ollama)
        XCTAssertNotNil(provider.endpoint)

        let model = try XCTUnwrap(configuration.resolvedModel(for: .llm))
        XCTAssertFalse(model.isEmpty)
    }

    func testDefaultConfigurationCoversAllSixCapabilities() throws {
        let configuration = try DefaultConfiguration.load()
        for kind in AIProviderKind.allCases {
            XCTAssertNotNil(configuration.enabledProvider(for: kind), "缺少 \(kind.rawValue) 的 provider 配置")
        }
    }

    func testProductSelectionOverridesProviderDefault() {
        var configuration = AppConfiguration()
        configuration.product.selectModel("custom-model", for: .llm)
        XCTAssertEqual(configuration.resolvedModel(for: .llm), "custom-model")
    }

    func testResolvedModelFallsBackToProviderDefault() {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(id: "x.llm", kind: .llm, runtime: .ollama, model: "provider-default")
        ]
        XCTAssertEqual(configuration.resolvedModel(for: .llm), "provider-default")
    }

    func testConfigStorePersistsUserOverride() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-config-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.selectModel("user-picked", for: .llm)

        let reloaded = ConfigStore(fileURL: fileURL)
        let model = await reloaded.current.resolvedModel(for: .llm)
        XCTAssertEqual(model, "user-picked")
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testPromptBuilderSubstitutesPlaceholders() {
        let prompt = PromptBuilder.teacherSystemPrompt(
            learningLanguage: "en-US",
            nativeLanguage: "zh-CN",
            proficiency: "萌新",
            practiceMode: .conversation
        )
        XCTAssertFalse(prompt.contains("{learning_language}"))
        XCTAssertTrue(prompt.contains("en-US"))
        XCTAssertTrue(prompt.contains("zh-CN"))
    }

    // MARK: - 本地 / 云端 Provider 并存

    func testDefaultConfigurationContainsRemoteProviders() throws {
        let configuration = try DefaultConfiguration.load()
        let deepseek = try XCTUnwrap(configuration.providers.first { $0.id == "remote.deepseek" })
        let openrouter = try XCTUnwrap(configuration.providers.first { $0.id == "remote.openrouter" })
        XCTAssertEqual(deepseek.runtime, .remoteAPI)
        XCTAssertEqual(openrouter.runtime, .remoteAPI)
        // 默认不启用、不带密钥
        XCTAssertFalse(deepseek.enabled)
        XCTAssertNil(deepseek.apiKey)
        XCTAssertEqual(deepseek.userFacingName, "DeepSeek")
    }

    func testResolvedProviderPrefersActiveProductSelection() {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(id: "local.llm", kind: .llm, enabled: true, runtime: .ollama),
            ProviderConfig(id: "remote.llm", kind: .llm, enabled: false, runtime: .remoteAPI, apiKey: "sk-test")
        ]
        // 未激活时选首个启用的
        XCTAssertEqual(configuration.resolvedProvider(for: .llm)?.id, "local.llm")
        // 激活云端后（即使 enabled=false 也能被激活逻辑选中）
        configuration.product.activateProvider("remote.llm", for: .llm)
        XCTAssertEqual(configuration.resolvedProvider(for: .llm)?.id, "remote.llm")
    }

    /// 激活了一个**没填 API Key** 的云端 Provider 时，不能让整个能力一起废掉：
    /// 应当自动回退到可用的本地模型（否则语音识别 / 对话会直接不可用）。
    func testResolvedProviderSkipsCloudWithoutAPIKey() {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(id: "local.asr", kind: .asr, enabled: false, runtime: .externalLocalRuntime,
                           model: "ggml-small.en"),
            ProviderConfig(id: "remote.openai-asr", kind: .asr, enabled: true, runtime: .remoteAPI,
                           endpoint: "https://api.openai.com/v1", model: "whisper-1")
        ]
        configuration.product.activateProvider("remote.openai-asr", for: .asr)

        // 云端没 Key → 不算可用，回退到本地
        XCTAssertEqual(configuration.resolvedProvider(for: .asr)?.id, "local.asr")
        XCTAssertFalse(configuration.providers[1].isUsable)
        XCTAssertTrue(configuration.providers[0].isUsable)

        // 填上 Key 后立刻生效（无需重启）
        configuration.providers[1].apiKey = "sk-test"
        XCTAssertTrue(configuration.providers[1].isUsable)
        XCTAssertEqual(configuration.resolvedProvider(for: .asr)?.id, "remote.openai-asr")
    }

    func testSwitchingProviderAlignsSelectedModel() throws {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(id: "local.llm", kind: .llm, enabled: true, runtime: .ollama, model: "qwen3:8b"),
            ProviderConfig(id: "remote.llm", kind: .llm, enabled: false, runtime: .remoteAPI, model: "deepseek-chat")
        ]
        configuration.product.selectModel("qwen3:8b", for: .llm)
        // 模拟 switchLLMProvider 的产品层对齐（激活 + 选中模型跟随 Provider 默认值）
        let target = try XCTUnwrap(configuration.providers.first { $0.id == "remote.llm" })
        configuration.product.activateProvider(target.id, for: .llm)
        configuration.product.selectModel(target.model, for: .llm)
        XCTAssertEqual(configuration.resolvedModel(for: .llm), "deepseek-chat")
    }

    func testProviderConfigCodableRoundTripsRemoteFields() throws {
        let provider = ProviderConfig(
            id: "remote.test", kind: .llm, enabled: true, runtime: .remoteAPI,
            displayName: "Test", endpoint: "https://example.com",
            apiKey: "sk-test", reasoningEffort: "high", contextLength: 65536,
            model: "test-model"
        )
        let data = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        XCTAssertEqual(decoded, provider)
    }

    func testLegacyConfigWithoutNewFieldsStillDecodes() throws {
        // 只保留旧版就有的字段（candidateModels / streaming 是必填，旧配置一直带）
        let legacy = """
        {"id":"old.llm","kind":"llm","enabled":true,"runtime":"ollama","model":"m","candidateModels":[],"streaming":true}
        """
        let provider = try JSONDecoder().decode(ProviderConfig.self, from: Data(legacy.utf8))
        XCTAssertNil(provider.apiKey)
        XCTAssertNil(provider.reasoningEffort)
        XCTAssertNil(provider.contextLength)
        XCTAssertEqual(provider.model, "m")
    }

    func testForestTogglesDefaultOnAndRoundTrip() throws {
        // 旧 product 配置缺少新开关 → 默认全开
        let legacy = """
        {"learning_language":"en-US","teacher_animal":"panda"}
        """
        let old = try JSONDecoder().decode(ProductConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(old.teacherBubbles)
        XCTAssertTrue(old.animalBubbles)
        XCTAssertTrue(old.animalActivity)

        // 关闭后编码 → 再解码，值应保留（全局记忆的基础）
        var product = ProductConfig()
        product.teacherBubbles = false
        product.animalBubbles = false
        product.animalActivity = false
        let data = try JSONEncoder().encode(product)
        let restored = try JSONDecoder().decode(ProductConfig.self, from: data)
        XCTAssertFalse(restored.teacherBubbles)
        XCTAssertFalse(restored.animalBubbles)
        XCTAssertFalse(restored.animalActivity)
    }

    func testContextWindowFromResolvedProvider() {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(id: "remote.llm", kind: .llm, runtime: .remoteAPI, contextLength: 65536)
        ]
        configuration.product.activateProvider("remote.llm", for: .llm)
        XCTAssertEqual(configuration.contextWindow(for: .llm), 65536)
    }

    // MARK: - 自动朗读（默认开，且可持久化关掉）

    func testAutoSpeakDefaultsToOn() {
        XCTAssertTrue(ProductConfig().autoSpeak, "老师回复后自动朗读默认勾选")
    }

    func testAutoSpeakBackwardCompatibleDecode() throws {
        // 旧配置文件没有 autoSpeak 字段 → 补默认值 true（不整体作废）
        let legacy = Data(#"{"learningLanguage":"en-US","themeMode":"night"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: legacy)
        XCTAssertTrue(decoded.autoSpeak)
        XCTAssertEqual(decoded.themeMode, .night)

        // 关掉后能往返
        var config = ProductConfig()
        config.autoSpeak = false
        let data = try JSONEncoder().encode(config)
        XCTAssertFalse(try JSONDecoder().decode(ProductConfig.self, from: data).autoSpeak)
    }
}
