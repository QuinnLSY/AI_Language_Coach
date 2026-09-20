import AppCore
import Foundation

// MARK: - 生命周期 / 健康

public enum ProviderLifecycle: String, Sendable, Equatable {
    case created
    case initialized
    case ready
    case running
    case unloaded
    case failed
}

public enum ProviderHealth: Sendable, Equatable {
    case connected(model: String?)
    case runtimeUnavailable(reason: String)
    case modelUnavailable(model: String)
    case configurationInvalid(reason: String)
    case requestFailed(reason: String)

    public var isUsable: Bool {
        if case .connected = self { return true }
        return false
    }

    /// 面向用户的描述（不含堆栈、路径、敏感内容）。
    public var userFacingDescription: String {
        switch self {
        case .connected: "已就绪"
        case .runtimeUnavailable: "服务未启动或不可达"
        case .modelUnavailable(let m): "模型 \(m) 不可用"
        case .configurationInvalid(let r): "配置有误：\(r)"
        case .requestFailed(let r): "连接失败：\(r)"
        }
    }
}

public struct ProviderCapabilities: Sendable, Equatable {
    public var streaming: Bool
    public var structuredOutput: Bool
    public var toolCalling: Bool
    public var vision: Bool
    public var multilingual: Bool
    /// 是否真的给得出**词级**时间戳（Phase 12 计划的必测项之一）。
    ///
    /// 只声明「能 / 不能」：拿不到就 false，调用方据此决定要不要读 `ASRResult.words`，
    /// 绝不许拿段级区间冒充词级对齐。
    public var wordTimestamp: Bool
    /// 语音能力（第 24 步）：**只声明能/不能，不暴露任何供应商专属 API**。
    /// 应用层据此决定是否开放克隆 / 风格 / 情感 / 音高控制。
    public var voiceCloning: Bool
    public var style: Bool
    public var emotion: Bool
    public var pitchControl: Bool

    public init(
        streaming: Bool = false,
        structuredOutput: Bool = false,
        toolCalling: Bool = false,
        vision: Bool = false,
        multilingual: Bool = false,
        wordTimestamp: Bool = false,
        voiceCloning: Bool = false,
        style: Bool = false,
        emotion: Bool = false,
        pitchControl: Bool = false
    ) {
        self.streaming = streaming
        self.structuredOutput = structuredOutput
        self.toolCalling = toolCalling
        self.vision = vision
        self.multilingual = multilingual
        self.wordTimestamp = wordTimestamp
        self.voiceCloning = voiceCloning
        self.style = style
        self.emotion = emotion
        self.pitchControl = pitchControl
    }
}

extension ProviderCapabilities {
    /// 用**配置声明的**泛化语音能力补齐这些位（第 24 步）。
    ///
    /// 为什么能力来自配置而不是适配器硬编码：同一个适配器可以连不同的 runtime 部署，
    /// 有的部署开了克隆、有的没开。把「这个部署能不能克隆」写在配置里，
    /// 换部署就不用改代码，也不会出现「适配器说有、运行时其实没有」的假能力。
    public func applyingVoiceCapabilities(_ declared: Set<VoiceCapability>) -> ProviderCapabilities {
        var result = self
        if declared.contains(.voiceCloning) { result.voiceCloning = true }
        if declared.contains(.style) { result.style = true }
        if declared.contains(.emotion) { result.emotion = true }
        if declared.contains(.pitchControl) { result.pitchControl = true }
        return result
    }

    /// 该类 runtime 的适配器**结构上做不了**的能力：配置写了也不该生效。
    ///
    /// 这是「实现为权威」的那一半。配置声明能表达「这个部署开没开」，
    /// 却表达不了「这套实现根本做不到」—— 只靠配置，一句
    /// `capabilities: ["voiceCloning"]` 就能让界面显示「支持克隆」，
    /// 点下去才发现合成失败（false capability）。
    ///
    /// 目前唯一一条结构事实：**云端语音一律拒收参考音频**
    /// （Phase 24 红线，见 `RemoteTTSAdapter.synthesize` 里那道 `guard`）。
    /// 本地 runtime 不吃这条限制 —— 参考音频只在本机流转。
    public static func unsupportedVoiceCapabilities(for runtime: RuntimeKind) -> Set<VoiceCapability> {
        switch runtime {
        case .externalLocalRuntime:
            []
        default:
            // remoteAPI / ollama / mock：不上传用户声音。
            [.voiceCloning]
        }
    }

    /// 某个部署**实际开放**的语音能力 = 配置声明 ∩ 实现天花板。
    ///
    /// 配置可以**收紧**实现（声明里少写一项就等于关掉），但**不许放宽**。
    /// 适配器与「当前供应商支不支持克隆」这类判定共用它，避免两处各判一套。
    public static func effectiveVoiceCapabilities(
        declared: Set<VoiceCapability>,
        runtime: RuntimeKind
    ) -> Set<VoiceCapability> {
        declared.subtracting(unsupportedVoiceCapabilities(for: runtime))
    }
}

public struct ProviderMetadata: Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var runtime: RuntimeKind
    public var version: String?

    public init(id: String, displayName: String, runtime: RuntimeKind, version: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.runtime = runtime
        self.version = version
    }
}

/// runtime 发现到的模型（Adapter 转成应用层模型后才可交给 UI）。
public struct DiscoveredModel: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var isEmbeddingOnly: Bool
    /// 上下文窗口长度（token）；runtime 未上报时为 nil。
    public var contextLength: Int?

    public init(id: String, name: String, isEmbeddingOnly: Bool = false, contextLength: Int? = nil) {
        self.id = id
        self.name = name
        self.isEmbeddingOnly = isEmbeddingOnly
        self.contextLength = contextLength
    }
}

/// Adapter 的共享状态盒（内部可变状态一律走 actor，避免手工加锁）。
public actor ProviderStateBox {
    // periphery:ignore —— 规范 v2.0 §27 要求维护这条状态机（Created→…→Unloaded），
    // 各适配器在 initialize/load/unload 里如实写入。**目前只写不读**（读侧候选：设置页健康面），
    // 故显式保留，别让扫描当死代码清掉。
    private(set) var lifecycle: ProviderLifecycle = .created
    private(set) var config: ProviderConfig?

    public init() {}

    public func setConfig(_ config: ProviderConfig) {
        self.config = config
    }

    public func setLifecycle(_ lifecycle: ProviderLifecycle) {
        self.lifecycle = lifecycle
    }

    public var currentConfig: ProviderConfig? { config }
}

// MARK: - 基类契约（v2.0 §5）

public protocol AIProvider: Sendable {
    var providerID: String { get }
    var kind: AIProviderKind { get }

    func initialize(config: ProviderConfig) async throws
    func load() async throws
    func unload() async
    func healthCheck() async -> ProviderHealth
    func capabilities() -> ProviderCapabilities
    func metadata() -> ProviderMetadata
}

// MARK: - 可选能力：本地模型服务的后台启停

/// **可选能力**：该 Provider 背后的模型服务能被应用真正启停。
///
/// - 本地模型（Ollama / whisper.cpp / Qwen3-TTS）：`stop` 让服务在后台下线、不再占用显存，
///   `start` 把它重新拉起来向应用提供服务。
/// - 云端模型（DeepSeek / OpenRouter 等）**不实现本协议** —— 外部服务无法被终止，
///   它的「关闭」只能发生在应用层（见 `CoachServices.setModelRunning`）。
/// - 内置模拟能力（VAD / Embedding / Pronunciation）同样不实现。
///
/// 上层只依据「是否实现了本协议」来决定说的是「真的帮你把服务停了」还是「应用层面关了」。
public protocol ModelServiceControlling: Sendable {
    /// 启动模型服务（幂等：已在运行应当直接成功）。
    func startModelService() async throws
    /// 停止模型服务（幂等：已停止应当直接成功）。
    func stopModelService() async throws
}
