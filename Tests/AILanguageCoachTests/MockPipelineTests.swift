import AIInterfaces
import AIProviders
import AIServices
import AIInfrastructure
import AppCore
import XCTest

// [MOCK] 全链路 Mock 测试：不依赖任何真实模型（AGENTS.md §8）。
final class MockPipelineTests: XCTestCase {

    func testMockLLMStreamsWithoutRealModel() async throws {
        let provider = MockLLMProvider(scriptedResponse: "Hello there friend")
        try await provider.initialize(config: ProviderConfig(id: "mock.llm", kind: .llm, runtime: .mock))
        try await provider.load()

        let health = await provider.healthCheck()
        XCTAssertTrue(health.isUsable)

        let manager = LLMManager()
        await manager.register(provider)

        let stream = await manager.stream(
            LLMRequest(messages: [LLMMessage(role: .user, content: "hi")], streaming: true)
        )
        var text = ""
        for try await chunk in stream { text += chunk.textDelta }
        XCTAssertTrue(text.contains("Hello"))
    }

    func testMockLLMGenerateReturnsScriptedText() async throws {
        let provider = MockLLMProvider(scriptedResponse: "Nice work!")
        try await provider.initialize(config: ProviderConfig(id: "mock.llm", kind: .llm, runtime: .mock))
        let response = try await provider.generate(
            LLMRequest(messages: [LLMMessage(role: .user, content: "hi")], model: "mock")
        )
        XCTAssertEqual(response.text, "Nice work!")
    }

    func testUnregisteredManagerFailsTyped() async {
        let manager = LLMManager()
        do {
            _ = try await manager.generate(LLMRequest(messages: []))
            XCTFail("应当抛出 notInitialized")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, .notInitialized)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testCoachServicesBootstrapsMockProviderEndToEnd() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-mock-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        // 产品层选择优先级高于 Provider 默认值，必须同步设置
        try await store.selectModel("mock-model", for: .llm)
        // 产品层选择优先级高于 Provider 默认值，必须同步设置
        try await store.selectModel("mock-model", for: .llm)

        let services = CoachServices(config: store)
        try await services.bootstrapLLM()

        let health = await services.llmHealth()
        XCTAssertTrue(health.isUsable)

        let model = await services.currentLLMModel()
        XCTAssertEqual(model, "mock-model")

        try? FileManager.default.removeItem(at: fileURL)
    }

    func testMockPipelineCoversAllSixCapabilities() async throws {
        let config = ProviderConfig(id: "mock", kind: .asr, runtime: .mock)

        let asr = MockASRProvider()
        try await asr.initialize(config: config)
        let transcript = try await asr.transcribe(ASRRequest(audioSamples: [0.1, 0.2]))
        XCTAssertFalse(transcript.text.isEmpty)

        let tts = MockTTSProvider()
        try await tts.initialize(config: config)
        let speech = try await tts.synthesize(TTSRequest(text: "hello"))
        XCTAssertFalse(speech.audioSamples.isEmpty)

        let vad = MockVADProvider()
        try await vad.initialize(config: config)
        let segments = try await vad.detectSpeech(in: [0.1, 0.2, 0.3])
        XCTAssertEqual(segments.count, 1)

        let embedding = MockEmbeddingProvider(dimensions: 8)
        try await embedding.initialize(config: config)
        let vectors = try await embedding.embed(["hello"])
        XCTAssertEqual(vectors.first?.count, 8)

        let pronunciation = MockPronunciationProvider()
        try await pronunciation.initialize(config: config)
        let score = try await pronunciation.evaluate(audioSamples: [0.1], referenceText: "hello")
        XCTAssertGreaterThan(score.overall, 0)
    }
}
