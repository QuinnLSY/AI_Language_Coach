import AIDomain
import Foundation

// MARK: - 传输模型（放 Interfaces，不放 Adapter；厂商 JSON 不得泄漏到这里）

public struct LLMMessage: Sendable, Equatable {
    public var role: ChatRole
    public var content: String

    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

public enum LLMResponseFormat: Sendable, Equatable {
    case text
    case jsonObject
}

public struct LLMRequest: Sendable {
    public var messages: [LLMMessage]
    public var model: String?
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    public var streaming: Bool
    public var responseFormat: LLMResponseFormat
    /// 单次请求覆盖推理强度（`none` / `low` / `medium` / `high`）。
    ///
    /// 用途：**确定性短任务**（翻译、拼写纠正）显式传 `"none"`。
    /// 推理模型（qwen3:8b / deepseek-r1）默认会先吐一大段思考，实测同一句翻译
    /// **24.8s（思考 1596 字符）→ 1.4s（无思考）**，而译文完全一致——思考在这里纯属浪费，
    /// 冷加载或显存紧张时还会把请求顶到超时。
    ///
    /// nil = 不干预，由 Provider 自己的配置决定（对话/老师回复就走这条，尊重用户的推理档位）。
    public var reasoningEffort: String?

    public init(
        messages: [LLMMessage],
        model: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        streaming: Bool = false,
        responseFormat: LLMResponseFormat = .text,
        reasoningEffort: String? = nil
    ) {
        self.messages = messages
        self.model = model
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.streaming = streaming
        self.responseFormat = responseFormat
        self.reasoningEffort = reasoningEffort
    }

    /// `reasoningEffort` 的「关掉思考」取值。
    ///
    /// 确定性短任务（翻译、拼写纠正）用它：推理模型（qwen3:8b / deepseek-r1）默认会先吐
    /// 一大段思考，实测同一句翻译 **24.8s（思考 1596 字符）→ 1.4s（无思考）**，译文完全一致。
    /// 不支持的模型会忽略该字段（实测 Mistral:7b 无副作用）。
    public static let noThinkingEffort = "none"
}

public struct LLMUsage: Sendable, Equatable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public struct LLMResponse: Sendable, Equatable {
    public var text: String
    public var model: String?
    public var finishReason: String?
    public var usage: LLMUsage?
    /// 推理模型的思考过程（如 deepseek-r1 的 `message.reasoning`）。**不直接展示给用户**。
    public var reasoning: String?

    public init(text: String, model: String? = nil, finishReason: String? = nil, usage: LLMUsage? = nil, reasoning: String? = nil) {
        self.text = text
        self.model = model
        self.finishReason = finishReason
        self.usage = usage
        self.reasoning = reasoning
    }
}

public struct LLMChunk: Sendable, Equatable {
    public var textDelta: String
    public var role: ChatRole?
    public var finishReason: String?
    /// 推理增量（如 deepseek-r1 的 `delta.reasoning`）。
    public var reasoningDelta: String?

    public init(textDelta: String, role: ChatRole? = nil, finishReason: String? = nil, reasoningDelta: String? = nil) {
        self.textDelta = textDelta
        self.role = role
        self.finishReason = finishReason
        self.reasoningDelta = reasoningDelta
    }
}

public struct LLMCapabilities: Sendable, Equatable {
    public var streaming: Bool
    public var structuredOutput: Bool
    public var toolCalling: Bool
    public var vision: Bool
    public var multilingual: Bool

    public init(
        streaming: Bool = true,
        structuredOutput: Bool = false,
        toolCalling: Bool = false,
        vision: Bool = false,
        multilingual: Bool = true
    ) {
        self.streaming = streaming
        self.structuredOutput = structuredOutput
        self.toolCalling = toolCalling
        self.vision = vision
        self.multilingual = multilingual
    }
}

// MARK: - LLM Provider 契约

public protocol LLMProvider: AIProvider {
    func generate(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error>
    func llmCapabilities() -> LLMCapabilities
    /// runtime 提供发现接口时返回已装模型；不支持时抛 `unsupportedCapability`。
    func discoverModels() async throws -> [DiscoveredModel]
}
