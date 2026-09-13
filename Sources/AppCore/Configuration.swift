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

/// 教师朗读语速（播放倍速）。**保持音高不变**，只是快放/慢放。
public enum SpeechRate: Double, Codable, Sendable, CaseIterable, Identifiable {
    case x0_5 = 0.5
    case x1 = 1.0
    case x1_5 = 1.5
    case x2 = 2.0
    case x2_5 = 2.5
    case x3 = 3.0

    public var id: Double { rawValue }

    /// 「1×」「1.5×」——整数不带小数点，看着干净。
    public var label: String {
        rawValue == rawValue.rounded() ? "\(Int(rawValue))×" : "\(rawValue)×"
    }

    /// 把任意取值落到最接近的档位（配置文件被手改时也能自愈）。
    public static func nearest(to value: Double) -> SpeechRate {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .x1
    }
}

public enum RuntimeKind: String, Codable, Sendable, CaseIterable {
    case embedded
    case ollama
    case pythonProcess
    case externalLocalRuntime
    case pipeline
    /// 云端 OpenAI 兼容 API（DeepSeek / OpenRouter 等），凭 API Key 调用。
    case remoteAPI
    case mock
}

// MARK: - Provider 配置

/// Provider 配置。**所有字段来自配置文件**，代码里不得出现端点 / 模型名字面量。
public struct ProviderConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: AIProviderKind
    public var enabled: Bool
    public var runtime: RuntimeKind
    /// 用户可见的 Provider 名称（如「本地模型」「DeepSeek」）。缺省时 UI 用 id 展示。
    public var displayName: String?
    /// 端点（如本地 runtime 的 base URL）。AUTO_MANAGED：默认由应用解析。
    public var endpoint: String?
    /// 云端 API 密钥（remoteAPI runtime 必需）。随用户配置存本地，不进 git。
    public var apiKey: String?
    /// 模型推理强度（low / medium / high；nil = 不发送，由服务端默认）。
    public var reasoningEffort: String?
    /// 上下文窗口长度（token），用于界面展示占用。nil = 未知，只展示估算用量。
    public var contextLength: Int?
    /// 当前选中的模型。USER_VISIBLE：UI 可填可选。
    public var model: String?
    /// runtime 不可用时降级展示的候选模型列表。
    public var candidateModels: [String]
    public var streaming: Bool
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    public var requestTimeout: TimeInterval?
    /// 本地模型服务的「启动」命令（shell）。空 = 该 Provider 不支持真实启停
    /// （应用层开关兜底）。命令只来自配置文件，代码里不出现任何服务路径字面量。
    public var serviceStartCommand: String?
    /// 本地模型服务的「停止」命令（shell）。含义同上。
    public var serviceStopCommand: String?
    /// 云端模型列表路径（相对端点）。nil = 用 Adapter 的默认路径。
    /// 各家端点前缀不同（有的已含 `/v1`，有的没有），配在文件里而不是代码里猜。
    public var modelsPath: String?
    /// 云端 TTS 可用音色。来自配置文件，代码里不出现任何音色名字面量。
    public var voices: [String]?
    /// 向量维度（embedding）。nil = 由首次响应推断。
    public var dimensions: Int?

    public init(
        id: String,
        kind: AIProviderKind,
        enabled: Bool = true,
        runtime: RuntimeKind = .mock,
        displayName: String? = nil,
        endpoint: String? = nil,
        apiKey: String? = nil,
        reasoningEffort: String? = nil,
        contextLength: Int? = nil,
        model: String? = nil,
        candidateModels: [String] = [],
        streaming: Bool = false,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        requestTimeout: TimeInterval? = nil,
        serviceStartCommand: String? = nil,
        serviceStopCommand: String? = nil,
        modelsPath: String? = nil,
        voices: [String]? = nil,
        dimensions: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.runtime = runtime
        self.displayName = displayName
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.reasoningEffort = reasoningEffort
        self.contextLength = contextLength
        self.model = model
        self.candidateModels = candidateModels
        self.streaming = streaming
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.requestTimeout = requestTimeout
        self.serviceStartCommand = serviceStartCommand
        self.serviceStopCommand = serviceStopCommand
        self.modelsPath = modelsPath
        self.voices = voices
        self.dimensions = dimensions
    }

    public var userFacingName: String { displayName ?? id }

    /// 是否需要 API Key（云端 OpenAI 兼容接口一律需要）。
    public var requiresAPIKey: Bool { runtime == .remoteAPI }

    /// 配置是否**真的能用**：云端 Provider 必须已经填了 API Key。
    ///
    /// 只有 `enabled` 不足以说明能用——没填 Key 的云端会被装配链路判为「配置无效」，
    /// 若还让它占着生效位，整个能力就废了（实测症状：卡片写「配置有误：未填写 API Key」，
    /// 对话时语音直接不可用）。有了这个判断，解析生效 Provider 时会自动跳过它、回退到能用的本地模型。
    public var isUsable: Bool {
        guard requiresAPIKey else { return true }
        return !(apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 是否为云端 Provider（UI 用来区分「本地 / 云端」）。
    public var isRemote: Bool { runtime == .remoteAPI }

    /// 模型列表路径：配置文件优先，缺省用 OpenAI 兼容默认路径。
    public var resolvedModelsPath: String { modelsPath ?? "v1/models" }
}

// MARK: - 产品配置

public struct ProductConfig: Sendable, Equatable {
    public var learningLanguage: String
    public var nativeLanguage: String
    public var teacherVoice: String
    public var practiceMode: PracticeMode
    public var themeMode: ThemeMode
    /// 各能力当前选中的模型（`AIProviderKind.rawValue -> model`）。**由 UI 填写**。
    public var selectedModels: [String: String]
    /// 老师形象（`AnimalKind.rawValue` 字符串，UI 层映射）。默认小熊猫。
    public var teacherAnimal: String
    /// 小学员形象（`AnimalKind.rawValue` 字符串，UI 层映射）。默认小熊。
    public var studentAnimal: String
    /// 每类能力当前激活的 Provider（`AIProviderKind.rawValue -> provider id`）。
    /// 本地模型与云端 Provider 并存时，由它决定实际用谁。
    public var activeProviders: [String: String]
    /// 老师头顶的督促/鼓励气泡（设置可关，默认开）。
    public var teacherBubbles: Bool
    /// 小动物点击/自发冒泡（设置可关，默认开）。
    public var animalBubbles: Bool
    /// 小动物自由活动（游走/跳/摇/飞枝）。夜晚 UI 层自动停，配置值不变。
    public var animalActivity: Bool
    /// 小动物活动频率（0...1，0 = 安静，1 = 最活跃）。仅活动开启时生效。
    public var animalActivityFrequency: Double
    /// 音色切换时自动试听（设置里小喇叭控制，默认开）。
    public var voicePreview: Bool
    /// 教师回复后自动朗读（设置里可关，**默认开**）。
    public var autoSpeak: Bool
    /// 教师朗读语速（1 = 正常）。可选档位见 `SpeechRate`，非法取值落回 1。
    public var speechRate: Double
    /// 每日练习目标（分钟）。Dashboard 的「Learning goals」用它算完成度。
    public var dailyGoalMinutes: Int

    public init(
        learningLanguage: String = "en-US",
        nativeLanguage: String = "zh-CN",
        teacherVoice: String = "Serena",
        practiceMode: PracticeMode = .conversation,
        themeMode: ThemeMode = .day,
        selectedModels: [String: String] = [:],
        teacherAnimal: String = "panda",
        studentAnimal: String = "bear",
        activeProviders: [String: String] = [:],
        teacherBubbles: Bool = true,
        animalBubbles: Bool = true,
        animalActivity: Bool = true,
        animalActivityFrequency: Double = 0.5,
        voicePreview: Bool = true,
        autoSpeak: Bool = true,
        speechRate: Double = SpeechRate.x1.rawValue,
        dailyGoalMinutes: Int = 15
    ) {
        self.learningLanguage = learningLanguage
        self.nativeLanguage = nativeLanguage
        self.teacherVoice = teacherVoice
        self.practiceMode = practiceMode
        self.themeMode = themeMode
        self.selectedModels = selectedModels
        self.teacherAnimal = teacherAnimal
        self.studentAnimal = studentAnimal
        self.activeProviders = activeProviders
        self.teacherBubbles = teacherBubbles
        self.animalBubbles = animalBubbles
        self.animalActivity = animalActivity
        self.animalActivityFrequency = min(max(animalActivityFrequency, 0), 1)
        self.voicePreview = voicePreview
        self.autoSpeak = autoSpeak
        self.speechRate = SpeechRate.nearest(to: speechRate).rawValue
        self.dailyGoalMinutes = min(max(dailyGoalMinutes, 5), 180)
    }

    public func selectedModel(for kind: AIProviderKind) -> String? { selectedModels[kind.rawValue] }
    public mutating func selectModel(_ model: String?, for kind: AIProviderKind) {
        selectedModels[kind.rawValue] = model
    }

    public func activeProvider(for kind: AIProviderKind) -> String? { activeProviders[kind.rawValue] }
    public mutating func activateProvider(_ id: String?, for kind: AIProviderKind) {
        activeProviders[kind.rawValue] = id
    }
}

// MARK: - 向后兼容解码：旧配置文件缺少新字段时用默认值补齐，不整体作废。

extension ProductConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case learningLanguage, nativeLanguage, teacherVoice, practiceMode, themeMode
        case selectedModels, teacherAnimal, studentAnimal, activeProviders
        case teacherBubbles, animalBubbles, animalActivity
        case animalActivityFrequency, voicePreview, autoSpeak, speechRate
        case dailyGoalMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        learningLanguage = try container.decodeIfPresent(String.self, forKey: .learningLanguage) ?? "en-US"
        nativeLanguage = try container.decodeIfPresent(String.self, forKey: .nativeLanguage) ?? "zh-CN"
        teacherVoice = try container.decodeIfPresent(String.self, forKey: .teacherVoice) ?? "Serena"
        practiceMode = try container.decodeIfPresent(PracticeMode.self, forKey: .practiceMode) ?? .conversation
        themeMode = try container.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? .day
        selectedModels = try container.decodeIfPresent([String: String].self, forKey: .selectedModels) ?? [:]
        teacherAnimal = try container.decodeIfPresent(String.self, forKey: .teacherAnimal) ?? "panda"
        studentAnimal = try container.decodeIfPresent(String.self, forKey: .studentAnimal) ?? "bear"
        activeProviders = try container.decodeIfPresent([String: String].self, forKey: .activeProviders) ?? [:]
        teacherBubbles = try container.decodeIfPresent(Bool.self, forKey: .teacherBubbles) ?? true
        animalBubbles = try container.decodeIfPresent(Bool.self, forKey: .animalBubbles) ?? true
        animalActivity = try container.decodeIfPresent(Bool.self, forKey: .animalActivity) ?? true
        animalActivityFrequency = try container.decodeIfPresent(Double.self, forKey: .animalActivityFrequency) ?? 0.5
        voicePreview = try container.decodeIfPresent(Bool.self, forKey: .voicePreview) ?? true
        autoSpeak = try container.decodeIfPresent(Bool.self, forKey: .autoSpeak) ?? true
        speechRate = SpeechRate.nearest(
            to: try container.decodeIfPresent(Double.self, forKey: .speechRate) ?? SpeechRate.x1.rawValue
        ).rawValue
        dailyGoalMinutes = min(max(try container.decodeIfPresent(Int.self, forKey: .dailyGoalMinutes) ?? 15, 5), 180)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(learningLanguage, forKey: .learningLanguage)
        try container.encode(nativeLanguage, forKey: .nativeLanguage)
        try container.encode(teacherVoice, forKey: .teacherVoice)
        try container.encode(practiceMode, forKey: .practiceMode)
        try container.encode(themeMode, forKey: .themeMode)
        try container.encode(selectedModels, forKey: .selectedModels)
        try container.encode(teacherAnimal, forKey: .teacherAnimal)
        try container.encode(studentAnimal, forKey: .studentAnimal)
        try container.encode(activeProviders, forKey: .activeProviders)
        try container.encode(teacherBubbles, forKey: .teacherBubbles)
        try container.encode(animalBubbles, forKey: .animalBubbles)
        try container.encode(animalActivity, forKey: .animalActivity)
        try container.encode(animalActivityFrequency, forKey: .animalActivityFrequency)
        try container.encode(voicePreview, forKey: .voicePreview)
        try container.encode(autoSpeak, forKey: .autoSpeak)
        try container.encode(speechRate, forKey: .speechRate)
        try container.encode(dailyGoalMinutes, forKey: .dailyGoalMinutes)
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

    /// 解析某能力实际生效的 Provider：产品层激活的 id 优先，其次首个**可用**的启用的。
    ///
    /// 「可用」= 本地 runtime 一律可用；云端必须已填 API Key（见 `ProviderConfig.isUsable`）。
    /// 否则会出现「激活了一个没填 Key 的云端，整个能力（含本可用的本地模型）一起不可用」的死角。
    public func resolvedProvider(for kind: AIProviderKind) -> ProviderConfig? {
        let candidates = providers.filter { $0.kind == kind }

        // ① 产品层激活的那个——前提是真的可用
        if let activeID = product.activeProvider(for: kind),
           let active = candidates.first(where: { $0.id == activeID && $0.isUsable }) {
            return active
        }
        // ② 启用的里面挑可用的（无 Key 的云端会被跳过，自动回退到本地模型）
        let enabled = candidates.filter(\.enabled)
        if let usable = enabled.first(where: \.isUsable) { return usable }
        if let usable = candidates.first(where: \.isUsable) { return usable }
        // ③ 一个可用的都没有：仍然返回激活的 / 首个启用的，
        //    让上层拿到它并报出「未填写 API Key」这类**具体**原因，而不是笼统的「没有 Provider」。
        if let activeID = product.activeProvider(for: kind),
           let active = candidates.first(where: { $0.id == activeID }) {
            return active
        }
        return enabled.first
    }

    /// 解析某能力最终使用的模型：产品层选择 > Provider 默认 > 候选列表首个。
    public func resolvedModel(for kind: AIProviderKind) -> String? {
        if let picked = product.selectedModel(for: kind) { return picked }
        guard let provider = resolvedProvider(for: kind) else { return nil }
        return provider.model ?? provider.candidateModels.first
    }

    /// 当前生效 Provider 的上下文窗口长度（token）。nil = 未知。
    public func contextWindow(for kind: AIProviderKind) -> Int? {
        resolvedProvider(for: kind)?.contextLength
    }
}
