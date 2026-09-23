// [MOCK] NOT FOR PRODUCTION
// 全链路 Mock：用于在没有真实模型的情况下验证架构与流程（AGENTS.md §8）。
import AIInterfaces
import AppCore
import Foundation

// MARK: - Mock LLM

public final class MockLLMProvider: LLMProvider, @unchecked Sendable {

    public let providerID: String
    public let kind: AIProviderKind = .llm

    private let state = ProviderStateBox()
    private let scriptedResponse: String
    private let chunkDelayNanoseconds: UInt64
    /// 需要「按请求内容给不同回复」的测试用它 —— 返回 nil 就落回 `scriptedResponse`。
    ///
    /// 用例：**漏行追问**（`ChatService.probeMissedCorrection`）—— 主回复那条不带 `[[FIX]]`、
    /// 追问那条要带回一行，同一次会话里两种产物必须来自同一个 provider。固定脚本做不到这件事，
    /// 于是给它一个看请求内容的出口。生产路径永不传它。
    public let responder: (@Sendable (LLMRequest) -> String?)?

    public init(
        providerID: String = "mock.llm",
        scriptedResponse: String = "Hello! Let's practice together.",
        chunkDelayNanoseconds: UInt64 = 20_000_000,
        responder: (@Sendable (LLMRequest) -> String?)? = nil
    ) {
        self.providerID = providerID
        self.scriptedResponse = scriptedResponse
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
        self.responder = responder
    }

    public func initialize(config: ProviderConfig) async throws {
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }

    public func load() async throws { await state.setLifecycle(.ready) }

    public func unload() async { await state.setLifecycle(.unloaded) }

    public func healthCheck() async -> ProviderHealth {
        await state.setLifecycle(.ready)
        return .connected(model: await state.currentConfig?.model)
    }

    public func capabilities() -> ProviderCapabilities {
        ProviderCapabilities(streaming: true, structuredOutput: true, multilingual: true)
    }

    public func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "Mock 大脑", runtime: .mock, version: "1.0")
    }

    // `llmCapabilities()` 走协议默认实现（= `capabilities().llmView`）。

    public func generate(_ request: LLMRequest) async throws -> LLMResponse {
        guard await state.currentConfig != nil else { throw AIProviderError.notInitialized }
        return LLMResponse(
            text: responder?(request) ?? scriptedResponse,
            model: request.model,
            finishReason: "stop"
        )
    }

    /// 脚本回放：默认固定文本，`responder` 在场时按请求内容现算。
    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error> {
        let text = responder?(request) ?? scriptedResponse
        let pieces = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let delay = chunkDelayNanoseconds
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(LLMChunk(textDelta: "", role: .assistant))
                for piece in pieces {
                    if Task.isCancelled {
                        continuation.finish(throwing: AIProviderError.cancelled)
                        return
                    }
                    try? await Task.sleep(nanoseconds: delay)
                    continuation.yield(LLMChunk(textDelta: piece + " "))
                }
                continuation.yield(LLMChunk(textDelta: "", finishReason: "stop"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func discoverModels() async throws -> [DiscoveredModel] {
        let models = await state.currentConfig?.candidateModels ?? []
        return models.map { DiscoveredModel(id: $0, name: $0) }
    }
}

// MARK: - Mock ASR

public final class MockASRProvider: ASRProvider, @unchecked Sendable {
    public let providerID: String = "mock.asr"
    public let kind: AIProviderKind = .asr
    private let state = ProviderStateBox()

    public init() {}

    public func initialize(config: ProviderConfig) async throws {
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }
    public func load() async throws { await state.setLifecycle(.ready) }
    public func unload() async { await state.setLifecycle(.unloaded) }
    public func healthCheck() async -> ProviderHealth { .connected(model: nil) }
    public func capabilities() -> ProviderCapabilities { ProviderCapabilities(multilingual: true) }
    public func metadata() -> ProviderMetadata { ProviderMetadata(id: providerID, displayName: "Mock 语音识别", runtime: .mock) }
    public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        ASRResult(text: "This is a mock transcription.", language: request.language, confidence: 0.9)
    }
}

// MARK: - Mock TTS

public final class MockTTSProvider: TTSProvider, @unchecked Sendable {
    public let providerID: String = "mock.tts"
    public let kind: AIProviderKind = .tts
    private let state = ProviderStateBox()

    public init() {}

    public func initialize(config: ProviderConfig) async throws {
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }
    public func load() async throws { await state.setLifecycle(.ready) }
    public func unload() async { await state.setLifecycle(.unloaded) }
    public func healthCheck() async -> ProviderHealth { .connected(model: nil) }
    public func capabilities() -> ProviderCapabilities { ProviderCapabilities() }
    public func metadata() -> ProviderMetadata { ProviderMetadata(id: providerID, displayName: "Mock 教师语音", runtime: .mock) }
    public func synthesize(_ request: TTSRequest) async throws -> TTSResult {
        // 生成一段静音，长度按文本量估算，保证下游管线可跑通。
        let count = max(1, request.text.count * 240)
        return TTSResult(audioSamples: [Float](repeating: 0, count: count), sampleRate: 24_000)
    }
}

// MARK: - Mock VAD

public final class MockVADProvider: VADProvider, @unchecked Sendable {
    public let providerID: String = "mock.vad"
    public let kind: AIProviderKind = .vad
    private let state = ProviderStateBox()

    public init() {}

    public func initialize(config: ProviderConfig) async throws {
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }
    public func load() async throws { await state.setLifecycle(.ready) }
    public func unload() async { await state.setLifecycle(.unloaded) }
    public func healthCheck() async -> ProviderHealth { .connected(model: nil) }
    public func capabilities() -> ProviderCapabilities { ProviderCapabilities() }
    public func metadata() -> ProviderMetadata { ProviderMetadata(id: providerID, displayName: "Mock 说话检测", runtime: .mock) }
    public func detectSpeech(in samples: [Float]) async throws -> [VADSegment] {
        samples.isEmpty ? [] : [VADSegment(start: 0, end: Double(samples.count) / 16_000)]
    }
}

// MARK: - Mock Embedding

public final class MockEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public let providerID: String = "mock.embedding"
    public let kind: AIProviderKind = .embedding
    public let dimensions: Int
    private let state = ProviderStateBox()

    public init(dimensions: Int = 8) { self.dimensions = dimensions }

    public func initialize(config: ProviderConfig) async throws {
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }
    public func load() async throws { await state.setLifecycle(.ready) }
    public func unload() async { await state.setLifecycle(.unloaded) }
    public func healthCheck() async -> ProviderHealth { .connected(model: nil) }
    public func capabilities() -> ProviderCapabilities { ProviderCapabilities() }
    public func metadata() -> ProviderMetadata { ProviderMetadata(id: providerID, displayName: "Mock 记忆索引", runtime: .mock) }
    public func discoverModels() async throws -> [DiscoveredModel] {
        let models = await state.currentConfig?.candidateModels ?? []
        return models.map { DiscoveredModel(id: $0, name: $0) }
    }
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: dimensions)
            for (index, scalar) in text.unicodeScalars.enumerated() {
                vector[index % dimensions] += Float(scalar.value) / 1000
            }
            return vector
        }
    }
}

// MARK: - Mock Pronunciation

public final class MockPronunciationProvider: PronunciationProvider, @unchecked Sendable {
    public let providerID: String = "mock.pronunciation"
    public let kind: AIProviderKind = .pronunciation
    private let state = ProviderStateBox()

    public init() {}

    public func initialize(config: ProviderConfig) async throws {
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }
    public func load() async throws { await state.setLifecycle(.ready) }
    public func unload() async { await state.setLifecycle(.unloaded) }
    public func healthCheck() async -> ProviderHealth { .connected(model: nil) }
    public func capabilities() -> ProviderCapabilities { ProviderCapabilities() }
    public func metadata() -> ProviderMetadata { ProviderMetadata(id: providerID, displayName: "Mock 发音评测", runtime: .mock) }
    /// 分数只由参考句词数派生，音频内容不参与（协议要求带 `audioSamples`，标注不用它）。
    public func evaluate(audioSamples _: [Float], referenceText: String) async throws -> PronunciationScore {
        let score = min(100, max(0, 60 + Double(referenceText.count % 40)))
        return PronunciationScore(overall: score, phonemes: [])
    }
}
