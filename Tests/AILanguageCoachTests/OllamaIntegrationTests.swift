import AIInterfaces
import AIInfrastructure
import AIProviders
import AIServices
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

    /// 真实模型生成练习复盘：要求输出可解析 JSON（解析失败即退化路径，不算失败但要点名）。
    func testSessionReviewAgainstRealRuntime() async throws {
        let (adapter, config) = try await makeAdapter()
        try await requireRuntime(adapter)

        let transcript = """
        Practice length: 95 seconds.
        Transcript (learner / coach):
        Learner: I go to park yesterday with my friend
        Coach: Almost perfect! Say "I went to the park yesterday with my friend". What did you do there?
        Learner: We play basketball and eat ice cream
        Coach: Great! Remember past tense: "We played basketball and ate ice cream".
        Teacher corrections:
        - I go => I went (过去式)
        - We play ... eat => We played ... ate (过去式)
        Now output the JSON review.
        """
        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: PromptBuilder.sessionReviewPrompt(
                    learningLanguage: "en-US", nativeLanguage: "zh-CN", proficiency: "beginner")),
                LLMMessage(role: .user, content: transcript),
            ],
            model: config.model,
            temperature: 0.3,
            maxTokens: 2048,
            streaming: false
        )
        let response = try await adapter.generate(request)
        let parsed = SessionReviewService.parse(response.text)
        if let parsed {
            XCTAssertFalse(parsed.headline.isEmpty, "复盘应有一句话总结")
            XCTAssertFalse(parsed.improvements.isEmpty || parsed.strengths.isEmpty,
                           "优点/待改进至少应有一项")
        } else {
            // 推理模型可能把 token 全花在思考上；此时产品层会走规则兜底，测试点名即可。
            print("[review] 真实模型输出不可解析（reasoning=\((response.reasoning ?? "").count) chars），走兜底")
        }
    }
}
