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
            ProviderConfig(id: "remote.llm", kind: .llm, enabled: false, runtime: .remoteAPI)
        ]
        // 未激活时选首个启用的
        XCTAssertEqual(configuration.resolvedProvider(for: .llm)?.id, "local.llm")
        // 激活云端后（即使 enabled=false 也能被激活逻辑选中）
        configuration.product.activateProvider("remote.llm", for: .llm)
        XCTAssertEqual(configuration.resolvedProvider(for: .llm)?.id, "remote.llm")
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

    func testContextWindowFromResolvedProvider() {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(id: "remote.llm", kind: .llm, runtime: .remoteAPI, contextLength: 65536)
        ]
        configuration.product.activateProvider("remote.llm", for: .llm)
        XCTAssertEqual(configuration.contextWindow(for: .llm), 65536)
    }
}
