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

    public init(
        streaming: Bool = false,
        structuredOutput: Bool = false,
        toolCalling: Bool = false,
        vision: Bool = false,
        multilingual: Bool = false
    ) {
        self.streaming = streaming
        self.structuredOutput = structuredOutput
        self.toolCalling = toolCalling
        self.vision = vision
        self.multilingual = multilingual
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
