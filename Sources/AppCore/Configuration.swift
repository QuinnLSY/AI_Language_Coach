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

/// 云端语音合成的**请求形态**：各家协议不同，由配置文件决定（`speech_request_style`），
/// 代码里不猜任何厂商的字段名。
///
/// 为什么必须可配：网关类服务（如 Edge TTS 代理）的字段名与 OpenAI 兼容接口不同——
/// 它要 `text` 而不是 `input`，且**没有 `model` 概念**。字段名猜错的表现是
/// 服务端 422 `Field required`，而错误信息里根本看不出是字段名的问题。
public enum SpeechRequestStyle: String, Codable, Sendable, CaseIterable {
    /// OpenAI 兼容：`POST <speech_path>`，JSON `{model, input, voice, response_format}`。
    case openAISpeech
    /// 文本 JSON：`POST <speech_path>`，JSON `{text, voice, rate}`。
    case textJSON
    /// 文本查询串：`GET <speech_path>?text=…&voice=…&rate=…`。
    case textQuery

    public var displayName: String {
        switch self {
        case .openAISpeech: "OpenAI 兼容（POST JSON）"
        case .textJSON: "文本 JSON（POST）"
        case .textQuery: "文本查询串（GET）"
        }
    }

    /// 该协议是否需要传 `model`：只有 OpenAI 兼容接口有这个概念。
    public var usesModelField: Bool { self == .openAISpeech }

    /// 中性语速参数。
    ///
    /// ⚠️ 朗读语速由**播放侧**统一控制（`ProductConfig.speechRate` → `AudioPlayback` 的时间拉伸），
    /// 合成时再传一次就会双重变速。所以这里固定中性值，不做语速映射。
    public static let neutralRate = "+0%"
}

/// 语音相关的**泛化能力位**（Implementation Plan §28 Phase 24）。
///
/// 刻意只有这四个通用名，没有任何厂商概念：供应商在配置里声明「我能做音色克隆 /
/// 风格 / 情感 / 音高控制」，应用据此决定是否开放对应入口。
/// 需求原文就是「expose generic capabilities … and not expose provider-specific APIs」——
/// 一旦这里出现 `gpt_sovits` 之类的名字，红线就破了。
public enum VoiceCapability: String, Codable, Sendable, CaseIterable, Identifiable {
    case voiceCloning
    case style
    case emotion
    case pitchControl

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .voiceCloning: "音色克隆"
        case .style: "风格控制"
        case .emotion: "情感控制"
        case .pitchControl: "音高控制"
        }
    }
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
    /// 音色展示名（id → 友好名，如 `zh-CN-XiaoxiaoNeural` → 「晓晓（女，温柔）」）。
    /// 由音色目录探测写入，UI 优先展示它；同样**不出现任何音色名字面量**。
    public var voiceNames: [String: String]?
    /// 语音合成路径（相对端点）。nil = OpenAI 兼容默认 `v1/audio/speech`。
    public var speechPath: String?
    /// 云端嵌入路径（相对端点）。nil = OpenAI 兼容默认 `v1/embeddings`。
    public var embeddingsPath: String?
    /// 语音请求形态。nil = OpenAI 兼容。
    public var speechRequestStyle: SpeechRequestStyle?
    /// 音色目录路径（相对端点，如 `voices`）。
    /// 配了它，这个 Provider 就**自报音色清单**（而不是靠 OpenAI 的 `/models`），
    /// 界面可以拉取并按友好名展示。
    public var voiceListPath: String?
    /// 健康检查路径（相对端点，如 `health`）。配了它就用它探活，
    /// 而不是去拉模型/音色列表（省一次请求，也更贴近服务本身的就绪语义）。
    public var healthPath: String?
    /// 是否需要 API Key。nil = 按 runtime 推断（云端默认需要）。
    /// 免密钥的公共服务（如本机代理的 Edge TTS）显式配 `false`。
    public var apiKeyRequired: Bool?
    /// 该 Provider 的调用**是否会产生费用**。nil = 视为计费。
    ///
    /// 免密钥的公共服务配 `false`：审计里就会记成「免费调用」而不是「计费请求」，
    /// 免得用户在自己的对账卡片上看到一堆没花过的钱，反而以为失控了。
    public var billable: Bool?
    /// 向量维度（embedding）。nil = 由首次响应推断。
    public var dimensions: Int?
    /// **泛化能力声明**（第 24 步）：该供应商自报支持哪些通用能力，取值见 `VoiceCapability`。
    ///
    /// 应用据此开放 / 关闭克隆音色这类入口，**不暴露任何厂商专属 API**。
    /// 缺省 nil = 什么都不声明（等于这些能力全关）—— 保守默认，绝不替用户假设「应该支持」。
    public var capabilities: [String]?
    /// 该模型能否**直接读图**（多模态输入）。缺省 nil = 不能。
    ///
    /// 保守默认的理由很实际：对纯文本模型内联 `image_url` 会稳定 400，
    /// 而错误信息看起来像「请求格式错误」，用户根本想不到是「这个模型不吃图」。
    /// 没声明时，图片会退化成一句「附了一张图 xxx.png」的说明，对话照常能继续。
    public var vision: Bool?

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
        dimensions: Int? = nil,
        voiceNames: [String: String]? = nil,
        speechPath: String? = nil,
        embeddingsPath: String? = nil,
        speechRequestStyle: SpeechRequestStyle? = nil,
        voiceListPath: String? = nil,
        healthPath: String? = nil,
        apiKeyRequired: Bool? = nil,
        billable: Bool? = nil,
        capabilities: [String]? = nil,
        vision: Bool? = nil
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
        self.voiceNames = voiceNames
        self.speechPath = speechPath
        self.embeddingsPath = embeddingsPath
        self.speechRequestStyle = speechRequestStyle
        self.voiceListPath = voiceListPath
        self.healthPath = healthPath
        self.apiKeyRequired = apiKeyRequired
        self.billable = billable
        self.capabilities = capabilities
        self.vision = vision
    }

    public var userFacingName: String { displayName ?? id }

    /// 配置声明的泛化语音能力（未声明的名字一律忽略，不报错也不猜测）。
    public var declaredVoiceCapabilities: Set<VoiceCapability> {
        Set((capabilities ?? []).compactMap(VoiceCapability.init(rawValue:)))
    }

    public func supportsVoiceCapability(_ capability: VoiceCapability) -> Bool {
        declaredVoiceCapabilities.contains(capability)
    }

    /// 是否需要 API Key：配置里的显式声明优先，否则云端 OpenAI 兼容接口一律需要。
    public var requiresAPIKey: Bool { apiKeyRequired ?? (runtime == .remoteAPI) }

    /// 这次调用会不会产生费用（审计归类用）。
    public var isBillable: Bool { billable ?? true }

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

    /// 语音合成路径：配置文件优先，缺省用 OpenAI 兼容默认路径。
    public var resolvedSpeechPath: String { speechPath ?? "v1/audio/speech" }

    /// 云端嵌入路径：配置文件优先，缺省用 OpenAI 兼容默认路径。
    public var resolvedEmbeddingsPath: String { embeddingsPath ?? "v1/embeddings" }

    /// 语音请求形态（默认 OpenAI 兼容）。
    public var resolvedSpeechRequestStyle: SpeechRequestStyle { speechRequestStyle ?? .openAISpeech }

    /// 音色的展示名（没有友好名时返回 nil，由 UI 决定怎么显示 id）。
    public func voiceLabel(for voice: String) -> String? {
        guard let label = voiceNames?[voice] else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 密钥指纹：只暴露末 4 位（如 `••••1a2b`）。
    ///
    /// 用途：让用户一眼确认**应用当前拿的是哪一把** Key——换 Key 之后如果指纹没变，
    /// 说明改的不是当前生效的那一条 Provider，而不是「改了没用」。
    /// 绝不回显完整密钥（日志、截图、UI 都不允许）。
    public var keyFingerprint: String? {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), key.count >= 4 else { return nil }
        return "••••" + String(key.suffix(4))
    }
}

// MARK: - 产品配置

/// 每日目标的档位（#225）。
///
/// - `baseline`：**保底 5 分钟** —— 计划缩到两轮对话 + 一句跟读 + 至多 3 个到期词，
///   忙的时候 5 分钟内能做完，做完同样算「今日完成」（保住连续）。
/// - `advanced`：**进阶目标** —— 按 `dailyGoalMinutes` 排计划（原有行为）。
public enum DailyGoalMode: String, Sendable, Codable, CaseIterable, Equatable {
    case baseline
    case advanced

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .baseline: "保底 5 分钟"
        case .advanced: "进阶目标"
        }
    }

    /// 保底档下判定「目标达成」的时长口径（分钟）——与计划的量对得上。
    public static let baselineMinutes = 5
}

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
    /// 老师人格档位（`TeacherPersona.rawValue` 字符串，UI 层映射）。默认 `standard`。
    ///
    /// 存字符串而不是枚举，理由同 `teacherAnimal`：AppCore 是最底层，不认识 AIDomain 的类型。
    public var teacherPersona: String
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
    /// 每日目标档位：保底 5 分钟 / 进阶目标（按 `dailyGoalMinutes` 排任务）。
    ///
    /// 保底档的存在理由：默认计划合计约半小时，门槛偏高 —— 忙的时候连打开的欲望都没了。
    /// 保底档达成同样算「今日完成」（保住连续），进阶目标留给状态好的日子。
    public var dailyGoalMode: DailyGoalMode
    /// 本地定时练习提醒开关（#226）。关 = 不排任何通知。
    public var practiceReminderEnabled: Bool
    /// 提醒时刻（24 小时制的小时，0...23）。
    public var practiceReminderHour: Int
    /// 提醒时刻的分钟（0...59）。
    public var practiceReminderMinute: Int
    /// 当前启用的**克隆音色档案 id**（第 24 步；nil = 用内置音色 `teacherVoice`）。
    ///
    /// 这里只存 id —— 档案本体（参考音频路径 + 授权记录）在 `VoiceProfileStore` 里。
    /// 在配置里再放一份拷贝，迟早会与档案本体不一致，而那种不一致正是「明明没授权却在用」的雏形。
    public var activeVoiceProfileID: String?

    public init(
        learningLanguage: String = "en-US",
        nativeLanguage: String = "zh-CN",
        teacherVoice: String = "Serena",
        practiceMode: PracticeMode = .conversation,
        themeMode: ThemeMode = .day,
        selectedModels: [String: String] = [:],
        teacherAnimal: String = "panda",
        teacherPersona: String = "standard",
        studentAnimal: String = "bear",
        activeProviders: [String: String] = [:],
        teacherBubbles: Bool = true,
        animalBubbles: Bool = true,
        animalActivity: Bool = true,
        animalActivityFrequency: Double = 0.5,
        voicePreview: Bool = true,
        autoSpeak: Bool = true,
        speechRate: Double = SpeechRate.x1.rawValue,
        dailyGoalMinutes: Int = 15,
        dailyGoalMode: DailyGoalMode = .advanced,
        practiceReminderEnabled: Bool = false,
        practiceReminderHour: Int = 20,
        practiceReminderMinute: Int = 0,
        activeVoiceProfileID: String? = nil
    ) {
        self.learningLanguage = learningLanguage
        self.nativeLanguage = nativeLanguage
        self.teacherVoice = teacherVoice
        self.practiceMode = practiceMode
        self.themeMode = themeMode
        self.selectedModels = selectedModels
        self.teacherAnimal = teacherAnimal
        self.teacherPersona = teacherPersona
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
        self.dailyGoalMode = dailyGoalMode
        self.practiceReminderEnabled = practiceReminderEnabled
        self.practiceReminderHour = min(max(practiceReminderHour, 0), 23)
        self.practiceReminderMinute = min(max(practiceReminderMinute, 0), 59)
        self.activeVoiceProfileID = activeVoiceProfileID
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
        case selectedModels, teacherAnimal, teacherPersona, studentAnimal, activeProviders
        case teacherBubbles, animalBubbles, animalActivity
        case animalActivityFrequency, voicePreview, autoSpeak, speechRate
        case dailyGoalMinutes, dailyGoalMode
        case practiceReminderEnabled, practiceReminderHour, practiceReminderMinute
        case activeVoiceProfileID
    }

    /// 向后兼容解码：**缺省值表就是 `ProductConfig()` 本身**。
    ///
    /// 早先这里把每个默认值在解码器里手抄了一遍（`?? "en-US"`、`?? 15`、`?? true`…），
    /// 于是「结构体默认 init」与「解码兜底」成了两份可以各自漂移的真相：
    /// 改了默认值、忘了改解码，老配置升级后拿到的还是旧口径，**而且没有任何编译错误**。
    /// 现在兜底一律取自 `fallback`（= 默认 init），只此一份。
    ///
    /// ⚠️ 需要**取值变换**的字段（语速取最近档、时长/时刻夹取）仍单独写，并把「为什么」
    /// 留在注释里 —— 那些是有意与默认值不同的行为，不是抄漏。
    ///
    /// 解码 / 编码 / 属性三处漂移由 `ConfigurationTests.testProductConfigRoundTripCoversEveryField`
    /// 兜底：它把每个字段都设成非默认值再往返一次，漏改任何一侧都会红。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ProductConfig()
        func value<T: Decodable>(_ key: CodingKeys, _ fallbackValue: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallbackValue
        }
        learningLanguage = try value(.learningLanguage, fallback.learningLanguage)
        nativeLanguage = try value(.nativeLanguage, fallback.nativeLanguage)
        teacherVoice = try value(.teacherVoice, fallback.teacherVoice)
        practiceMode = try value(.practiceMode, fallback.practiceMode)
        themeMode = try value(.themeMode, fallback.themeMode)
        selectedModels = try value(.selectedModels, fallback.selectedModels)
        teacherAnimal = try value(.teacherAnimal, fallback.teacherAnimal)
        // ⚠️ 缺字段的老配置一律落回 `standard` —— 那正是加档位之前的行为，
        // 不能因为升级就把老用户的教学口径改掉。
        teacherPersona = try value(.teacherPersona, fallback.teacherPersona)
        studentAnimal = try value(.studentAnimal, fallback.studentAnimal)
        activeProviders = try value(.activeProviders, fallback.activeProviders)
        teacherBubbles = try value(.teacherBubbles, fallback.teacherBubbles)
        animalBubbles = try value(.animalBubbles, fallback.animalBubbles)
        animalActivity = try value(.animalActivity, fallback.animalActivity)
        animalActivityFrequency = try value(.animalActivityFrequency, fallback.animalActivityFrequency)
        voicePreview = try value(.voicePreview, fallback.voicePreview)
        autoSpeak = try value(.autoSpeak, fallback.autoSpeak)
        speechRate = SpeechRate.nearest(to: try value(.speechRate, fallback.speechRate)).rawValue
        dailyGoalMinutes = min(max(try value(.dailyGoalMinutes, fallback.dailyGoalMinutes), 5), 180)
        // ⚠️ 老配置一律落回 advanced —— 那是保底档引入前的唯一行为，升级不改口径。
        dailyGoalMode = try value(.dailyGoalMode, fallback.dailyGoalMode)
        practiceReminderEnabled = try value(.practiceReminderEnabled, fallback.practiceReminderEnabled)
        practiceReminderHour = min(max(try value(.practiceReminderHour, fallback.practiceReminderHour), 0), 23)
        practiceReminderMinute = min(max(try value(.practiceReminderMinute, fallback.practiceReminderMinute), 0), 59)
        activeVoiceProfileID = try container.decodeIfPresent(String.self, forKey: .activeVoiceProfileID)
    }

    /// 写入侧仍是显式列举：`activeVoiceProfileID` 要 `encodeIfPresent`（缺省不写空值），
    /// 而**新增字段必须在这里补一行**，否则往返测试会红。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(learningLanguage, forKey: .learningLanguage)
        try container.encode(nativeLanguage, forKey: .nativeLanguage)
        try container.encode(teacherVoice, forKey: .teacherVoice)
        try container.encode(practiceMode, forKey: .practiceMode)
        try container.encode(themeMode, forKey: .themeMode)
        try container.encode(selectedModels, forKey: .selectedModels)
        try container.encode(teacherAnimal, forKey: .teacherAnimal)
        try container.encode(teacherPersona, forKey: .teacherPersona)
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
        try container.encode(dailyGoalMode, forKey: .dailyGoalMode)
        try container.encode(practiceReminderEnabled, forKey: .practiceReminderEnabled)
        try container.encode(practiceReminderHour, forKey: .practiceReminderHour)
        try container.encode(practiceReminderMinute, forKey: .practiceReminderMinute)
        try container.encodeIfPresent(activeVoiceProfileID, forKey: .activeVoiceProfileID)
    }
}

// MARK: - 顶层配置

// MARK: - 资源管理策略（第 27 步）

/// 资源管理的阈值配置（AUTO_MANAGED 级别：不进普通 UI，仅存配置文件可调）。
///
/// 语义见 `AIDomain.ResourcePolicy`：空闲超时挂起 + 内存压力挂起；
/// TTS 重启成本高，默认 `ttsIdleUnloadMinutes = nil`（永不按空闲挂起，只在内存吃紧时让位）。
public struct ResourcePolicyConfig: Codable, Sendable, Equatable {
    /// LLM 空闲多久后挂起（分钟）。
    public var llmIdleUnloadMinutes: Double
    /// ASR 空闲多久后挂起（分钟）。
    public var asrIdleUnloadMinutes: Double
    /// TTS 空闲卸载阈值；nil = 永不按空闲挂起（只在内存压力下让位）。
    public var ttsIdleUnloadMinutes: Double?
    /// 对话活跃窗口（分钟）：窗口内用过的模型任何规则都不挂起。
    public var activeWindowMinutes: Double
    /// 内存预算下限（MB）：可用内存低于它 = 压力卸载生效。
    public var minAvailableMemoryMB: Double
    /// 巡检间隔（秒）。
    public var tickSeconds: Double

    public init(llmIdleUnloadMinutes: Double = 15,
                asrIdleUnloadMinutes: Double = 10,
                ttsIdleUnloadMinutes: Double? = nil,
                activeWindowMinutes: Double = 2,
                minAvailableMemoryMB: Double = 2048,
                tickSeconds: Double = 60) {
        self.llmIdleUnloadMinutes = llmIdleUnloadMinutes
        self.asrIdleUnloadMinutes = asrIdleUnloadMinutes
        self.ttsIdleUnloadMinutes = ttsIdleUnloadMinutes
        self.activeWindowMinutes = activeWindowMinutes
        self.minAvailableMemoryMB = minAvailableMemoryMB
        self.tickSeconds = tickSeconds
    }

    public static let standard = ResourcePolicyConfig()

    private enum CodingKeys: String, CodingKey {
        case llmIdleUnloadMinutes, asrIdleUnloadMinutes, ttsIdleUnloadMinutes
        case activeWindowMinutes, minAvailableMemoryMB, tickSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 逐字段兜底：老配置文件没有这一节，或只写了部分字段，都用标准值补齐。
        self.init()
        llmIdleUnloadMinutes = try container.decodeIfPresent(Double.self, forKey: .llmIdleUnloadMinutes) ?? llmIdleUnloadMinutes
        asrIdleUnloadMinutes = try container.decodeIfPresent(Double.self, forKey: .asrIdleUnloadMinutes) ?? asrIdleUnloadMinutes
        ttsIdleUnloadMinutes = try container.decodeIfPresent(Double?.self, forKey: .ttsIdleUnloadMinutes) ?? ttsIdleUnloadMinutes
        activeWindowMinutes = try container.decodeIfPresent(Double.self, forKey: .activeWindowMinutes) ?? activeWindowMinutes
        minAvailableMemoryMB = try container.decodeIfPresent(Double.self, forKey: .minAvailableMemoryMB) ?? minAvailableMemoryMB
        tickSeconds = try container.decodeIfPresent(Double.self, forKey: .tickSeconds) ?? tickSeconds
    }
}

public struct AppConfiguration: Codable, Sendable, Equatable {
    public var product: ProductConfig
    public var providers: [ProviderConfig]
    /// 资源管理策略（第 27 步）。老配置缺省时用标准值，不影响解码。
    public var resourcePolicy: ResourcePolicyConfig

    public init(product: ProductConfig = ProductConfig(), providers: [ProviderConfig] = [],
                resourcePolicy: ResourcePolicyConfig = .standard) {
        self.product = product
        self.providers = providers
        self.resourcePolicy = resourcePolicy
    }

    public func provider(id: String) -> ProviderConfig? { providers.first { $0.id == id } }

    // ⚠️ 不能用合成 Codable：`resourcePolicy` 是后加的非可选字段，合成版会对老配置文件
    // 直接抛 keyNotFound → **整份配置解码回退**（default-config 漏键教训的同款事故）。
    // 这里自定义解码：缺 resourcePolicy 一节时用标准值兜底，其余字段照常。
    private enum TopLevelKeys: String, CodingKey { case product, providers, resourcePolicy }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TopLevelKeys.self)
        product = try container.decode(ProductConfig.self, forKey: .product)
        providers = try container.decode([ProviderConfig].self, forKey: .providers)
        resourcePolicy = try container.decodeIfPresent(ResourcePolicyConfig.self, forKey: .resourcePolicy) ?? .standard
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TopLevelKeys.self)
        try container.encode(product, forKey: .product)
        try container.encode(providers, forKey: .providers)
        try container.encode(resourcePolicy, forKey: .resourcePolicy)
    }

    /// 该能力下**启用的**那条 provider（只看 `enabled`，不看可用性）。
    ///
    /// ⚠️ **仅供测试**：生产代码一律走 `resolvedProvider(for:)`（它还要过 Key 与激活态）。
    /// 留着是因为若干用例要直接断言「配置里到底有没有这条、有没有启用」，
    /// 拿 `resolvedProvider` 断言会把「没启用」和「没填 Key」两种失败混成一个 nil。
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

    /// 解析某能力最终使用的模型：产品层选择 > Provider 默认模型。
    ///
    /// ⚠️ **绝不回退到 `candidateModels.first`**（29 步费用事故的同一类隐患）。
    /// `candidateModels` 是「探测到的可选清单」，可能装着几十个账号里的模型；
    /// 在用户没显式选定、Provider 也没配默认模型时，唯一正确的答案是 nil ——
    /// 让云端 Adapter 的闸门拒绝发请求并提示用户去选，而不是替用户猜一个。
    /// （历史上这里写过 `?? provider.candidateModels.first`，正是那次事故的形态。）
    public func resolvedModel(for kind: AIProviderKind) -> String? {
        if let picked = product.selectedModel(for: kind), !picked.isEmpty { return picked }
        guard let provider = resolvedProvider(for: kind) else { return nil }
        guard let model = provider.model, !model.isEmpty else { return nil }
        return model
    }

    /// 当前生效 Provider 的上下文窗口长度（token）。nil = 未知。
    public func contextWindow(for kind: AIProviderKind) -> Int? {
        resolvedProvider(for: kind)?.contextLength
    }
}
