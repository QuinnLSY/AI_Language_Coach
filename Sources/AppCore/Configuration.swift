import Foundation

// MARK: - 用户可见的产品级枚举

public enum ThemeMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case day
    case night
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .day: "白天"
        case .night: "夜晚"
        case .system: "跟随系统"
        }
    }
}

public enum PracticeMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case conversation
    case pronunciation
    case shadowing
    case freeTalk

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .conversation: "情景对话"
        case .pronunciation: "发音练习"
        case .shadowing: "跟读模仿"
        case .freeTalk: "自由聊天"
        }
    }
}

public enum AIProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case llm
    case asr
    case tts
    case vad
    case embedding
    case pronunciation

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .llm: "AI 大脑"
        case .asr: "语音识别"
        case .tts: "教师语音"
        case .vad: "说话检测"
        case .embedding: "记忆索引"
        case .pronunciation: "发音评测"
        }
    }
}

public enum RuntimeKind: String, Codable, Sendable, CaseIterable {
    case embedded
    case ollama
    case pythonProcess
    case externalLocalRuntime
    case pipeline
    case mock
}

// MARK: - Provider 配置

/// Provider 配置。**所有字段来自配置文件**，代码里不得出现端点 / 模型名字面量。
public struct ProviderConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: AIProviderKind
    public var enabled: Bool
    public var runtime: RuntimeKind
    /// 端点（如本地 runtime 的 base URL）。AUTO_MANAGED：默认由应用解析。
    public var endpoint: String?
    /// 当前选中的模型。USER_VISIBLE：UI 可填可选。
    public var model: String?
    /// runtime 不可用时降级展示的候选模型列表。
    public var candidateModels: [String]
    public var streaming: Bool
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    public var requestTimeout: TimeInterval?

    public init(
        id: String,
        kind: AIProviderKind,
        enabled: Bool = true,
        runtime: RuntimeKind = .mock,
        endpoint: String? = nil,
        model: String? = nil,
        candidateModels: [String] = [],
        streaming: Bool = false,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        requestTimeout: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.runtime = runtime
        self.endpoint = endpoint
        self.model = model
        self.candidateModels = candidateModels
        self.streaming = streaming
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.requestTimeout = requestTimeout
    }
}

// MARK: - 产品配置

public struct ProductConfig: Codable, Sendable, Equatable {
    public var learningLanguage: String
    public var nativeLanguage: String
    public var teacherVoice: String
    public var practiceMode: PracticeMode
    public var themeMode: ThemeMode
    /// 各能力当前选中的模型（`AIProviderKind.rawValue -> model`）。**由 UI 填写**。
    public var selectedModels: [String: String]

    public init(
        learningLanguage: String = "en-US",
        nativeLanguage: String = "zh-CN",
        teacherVoice: String = "Serena",
        practiceMode: PracticeMode = .conversation,
        themeMode: ThemeMode = .day,
        selectedModels: [String: String] = [:]
    ) {
        self.learningLanguage = learningLanguage
        self.nativeLanguage = nativeLanguage
        self.teacherVoice = teacherVoice
        self.practiceMode = practiceMode
        self.themeMode = themeMode
        self.selectedModels = selectedModels
    }

    public func selectedModel(for kind: AIProviderKind) -> String? { selectedModels[kind.rawValue] }
    public mutating func selectModel(_ model: String?, for kind: AIProviderKind) {
        selectedModels[kind.rawValue] = model
    }
}

// MARK: - 顶层配置

public struct AppConfiguration: Codable, Sendable, Equatable {
    public var product: ProductConfig
    public var providers: [ProviderConfig]

    public init(product: ProductConfig = ProductConfig(), providers: [ProviderConfig] = []) {
        self.product = product
        self.providers = providers
    }

    public func provider(id: String) -> ProviderConfig? { providers.first { $0.id == id } }

    public func enabledProvider(for kind: AIProviderKind) -> ProviderConfig? {
        providers.first { $0.kind == kind && $0.enabled }
    }

    /// 解析某能力最终使用的模型：产品层选择 > Provider 默认 > 候选列表首个。
    public func resolvedModel(for kind: AIProviderKind) -> String? {
        if let picked = product.selectedModel(for: kind) { return picked }
        guard let provider = enabledProvider(for: kind) else { return nil }
        return provider.model ?? provider.candidateModels.first
    }
}
