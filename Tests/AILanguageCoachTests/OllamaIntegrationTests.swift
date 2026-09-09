import AIInterfaces
import AIInfrastructure
import AIProviders
import AppCore
import XCTest

/// 依赖本机 Ollama 的集成测试。运行时不可用时 **Skip 而非 Fail**（AGENTS.md §0.1 / §3B.9）。
final class OllamaIntegrationTests: XCTestCase {

    private func makeAdapter(modelOverride: String? = nil) async throws -> (OllamaLLMAdapter, ProviderConfig) {
        let configuration = try DefaultConfiguration.load()
        var providerConfig = try XCTUnwrap(configuration.enabledProvider(for: .llm))
        if let modelOverride { providerConfig.model = modelOverride }
        let adapter = OllamaLLMAdapter()
        try await adapter.initialize(config: providerConfig)
        return (adapter, providerConfig)
    }

    private func requireRuntime(_ adapter: OllamaLLMAdapter) async throws {
        let health = await adapter.healthCheck()
        if case .runtimeUnavailable = health {
            throw XCTSkip("本地模型服务未启动，跳过集成测试")
        }
        if case .requestFailed = health {
            throw XCTSkip("本地模型服务不可达，跳过集成测试")
        }
    }

    func testHealthCheckAgainstRealRuntime() async throws {
        let (adapter, _) = try await makeAdapter()
        try await requireRuntime(adapter)
        let health = await adapter.healthCheck()
        XCTAssertTrue(health.isUsable, "健康检查未通过：\(health)")
    }

    func testGenerateAgainstRealRuntime() async throws {
        let (adapter, config) = try await makeAdapter()
        try await requireRuntime(adapter)

        let response = try await adapter.generate(
            LLMRequest(
                messages: [LLMMessage(role: .user, content: "Reply with the single word: OK")],
                model: config.model,
                maxTokens: 1024
            )
        )
        // 推理模型（deepseek-r1）可能把预算全部用在 reasoning 上，正文为空属正常。
        let hasOutput = !response.text.isEmpty || !(response.reasoning ?? "").isEmpty
        XCTAssertTrue(hasOutput, "真实模型既没有正文也没有推理内容")
        XCTAssertEqual(response.model, config.model)
    }

    func testStreamAgainstRealRuntime() async throws {
        let (adapter, config) = try await makeAdapter()
        try await requireRuntime(adapter)

        let stream = adapter.stream(
            LLMRequest(
                messages: [LLMMessage(role: .user, content: "Count from 1 to 5.")],
                model: config.model,
                maxTokens: 128
            )
        )
        var text = ""
        var reasoning = ""
        for try await chunk in stream {
            text += chunk.textDelta
            reasoning += chunk.reasoningDelta ?? ""
        }
        XCTAssertTrue(!text.isEmpty || !reasoning.isEmpty, "流式既没有正文也没有推理内容")
    }

    func testMissingModelMapsToModelUnavailable() async throws {
        // [MOCK] 名字刻意指向不存在的模型，用于验证错误映射，不是真实模型名。
        let (adapter, _) = try await makeAdapter(modelOverride: "definitely-not-installed-alc:7b")
        try await requireRuntime(adapter)

        do {
            _ = try await adapter.generate(
                LLMRequest(messages: [LLMMessage(role: .user, content: "hi")], maxTokens: 8)
            )
            XCTFail("应当抛出错误")
        } catch let error as AIProviderError {
            guard case .modelUnavailable = error else {
                return XCTFail("错误映射不符：\(error)")
            }
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testDiscoverModelsReturnsRuntimeList() async throws {
        let (adapter, _) = try await makeAdapter()
        try await requireRuntime(adapter)
        let models = try await adapter.discoverModels()
        XCTAssertFalse(models.isEmpty)
    }
}
