import AIDomain
import Foundation

// MARK: - 传输模型（放 Interfaces，不放 Adapter；厂商 JSON 不得泄漏到这里）

/// 随消息一起送进模型的**图片**字节（多模态输入）。
///
/// ⚠️ 只承载图片：OpenAI 兼容的 `/chat/completions` 的 `image_url` 部分吃的是
/// 图片（含 `data:` URL），**不接受视频字节** —— 视频有自己的理解 / 生成端点。
/// 把视频也塞进这里只会得到一个 400，或者更糟：一个几十 MB 的请求体在超时前跑完全程。
public struct LLMInlineImage: Sendable, Equatable {
    public var mimeType: String
    public var data: Data
    /// 原始文件名（仅用于「非视觉模型」时拼一句可读的说明）。
    public var fileName: String

    public init(mimeType: String, data: Data, fileName: String) {
        self.mimeType = mimeType
        self.data = data
        self.fileName = fileName
    }
}

public struct LLMMessage: Sendable, Equatable {
    public var role: ChatRole
    public var content: String
    /// 图片附件（可为空）。**只有声明了视觉能力的供应商才会真正内联发出**，
    /// 否则 Adapter 会把它降级成一句「附了一张图 xxx.png」的文本说明。
    public var images: [LLMInlineImage]
    /// 不能内联的附件名（视频 / 普通文件）：让模型知道用户提到了它们，
    /// 也避免「界面上明明有附件、模型却完全不知道」的割裂。
    public var referencedFileNames: [String]

    public init(
        role: ChatRole,
        content: String,
        images: [LLMInlineImage] = [],
        referencedFileNames: [String] = []
    ) {
        self.role = role
        self.content = content
        self.images = images
        self.referencedFileNames = referencedFileNames
    }

    /// 图片 + 非内联附件都算「有附件」。
    public var hasAttachments: Bool { !images.isEmpty || !referencedFileNames.isEmpty }
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

/// LLM 视角的能力视图。
///
/// ⚠️ 它的字段是 `ProviderCapabilities` 的**子集**，不是另一套能力。
/// 两个结构曾经各自被适配器实现一遍（`RemoteLLMAdapter` 里两个方法逐字等价），
/// 改一处忘一处就会漂移 —— 现在只有 `capabilities()` 一个真源，
/// 本视图由 `ProviderCapabilities.llmView` 投影出来（见下）。
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

public extension ProviderCapabilities {
    /// 投影出 LLM 视角（`capabilities()` 是唯一真源）。
    ///
    /// 为什么不直接删掉 `llmCapabilities()` 而保留一个投影：调用点（对话引擎 / 选型提示）
    /// 只关心「这个模型支不支持流式、结构化输出、看图」，拿到 `ProviderCapabilities` 全量
    /// 反而要在一堆与 LLM 无关的位（wordTimestamp / voiceCloning …）里挑。投影让调用点
    /// 只依赖自己真正需要的那 5 位，同时**不再有第二份真源**。
    var llmView: LLMCapabilities {
        LLMCapabilities(
            streaming: streaming,
            structuredOutput: structuredOutput,
            toolCalling: toolCalling,
            vision: vision,
            multilingual: multilingual
        )
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

public extension LLMProvider {
    /// 默认实现 = 从 `capabilities()` 投影。
    ///
    /// 适配器**不需要**再写一遍：那两个方法曾经逐字等价，改一处忘一处就漂移。
    /// 特殊适配器（测试替身等）仍可自行覆写。
    func llmCapabilities() -> LLMCapabilities { capabilities().llmView }
}
