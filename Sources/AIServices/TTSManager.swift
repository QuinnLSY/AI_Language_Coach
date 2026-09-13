import AIDomain
import AIInterfaces
import Foundation

/// TTS 统一入口。所有调用方只认 Manager，不认具体 Adapter。
public actor TTSManager {

    private var provider: (any TTSProvider)?
    /// 最近一次真实合成的时间（资源管理据此算空闲时长，第 27 步）。
    public private(set) var lastUsedAt: Date?

    public init() {}

    /// 距上次真实合成的秒数；nil = 注册后从未调用过（资源管理按「最冷」处理）。
    public var idleSeconds: Double? {
        lastUsedAt.map { Date().timeIntervalSince($0) }
    }

    private func noteUsed() {
        lastUsedAt = Date()
    }

    public func register(_ provider: any TTSProvider) {
        self.provider = provider
    }

    public func unregister() {
        provider = nil
    }

    /// 当前注册的 Provider（供「启动 / 关闭」这类需要拿到实例的能力使用）。
    public var current: (any TTSProvider)? { provider }

    /// 当前 Provider 的朗读投递方式：云端整段、本地分句（见 `SpeechDelivery`）。
    ///
    /// 判断依据是 Provider 自报的 runtime，而不是「用户选了什么」——
    /// 用户切到云端后装配链路会换掉 Provider 实例，这里自然跟着变。
    public var delivery: SpeechDelivery {
        guard let provider else { return .segmented }
        return SpeechDelivery.forRuntime(provider.metadata().runtime)
    }

    public func synthesize(_ request: TTSRequest) async throws -> TTSResult {
        guard let provider else { throw AIProviderError.notInitialized }
        noteUsed()
        return try await provider.synthesize(request)
    }

    public func healthCheck() async -> ProviderHealth {
        guard let provider else { return .configurationInvalid(reason: "未注册 TTS Provider") }
        return await provider.healthCheck()
    }

    /// 可用音色：仅当 Adapter 支持自报时返回，否则空数组（UI 用内置预设兜底）。
    public func availableVoices() async -> [String] {
        guard let catalog = provider as? VoiceCatalogProvider else { return [] }
        return await catalog.availableVoices()
    }

    /// runtime 自报描述（如「Qwen3-TTS 0.6B · mps」）；不支持或未知时为 nil。
    public func runtimeDescription() async -> String? {
        guard let info = provider as? RuntimeInfoProvider else { return nil }
        return await info.runtimeDescription()
    }
}
