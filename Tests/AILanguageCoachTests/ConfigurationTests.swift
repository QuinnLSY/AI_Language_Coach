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
}
