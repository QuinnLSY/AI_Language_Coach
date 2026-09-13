import AIDomain
import AIInterfaces
import AppCore
import Foundation

/// ASR 统一入口。所有调用方只认 Manager，不认具体 Adapter。
public actor ASRManager {

    private var provider: (any ASRProvider)?
    /// 最近一次真实转写的时间（资源管理据此算空闲时长，第 27 步）。
    public private(set) var lastUsedAt: Date?

    public init() {}

    /// 距上次真实转写的秒数；nil = 注册后从未调用过（资源管理按「最冷」处理）。
    public var idleSeconds: Double? {
        lastUsedAt.map { Date().timeIntervalSince($0) }
    }

    private func noteUsed() {
        lastUsedAt = Date()
    }

    public func register(_ provider: any ASRProvider) {
        self.provider = provider
    }

    public func unregister() {
        provider = nil
    }

    /// 当前注册的 Provider（供「启动 / 关闭」这类需要拿到实例的能力使用）。
    public var current: (any ASRProvider)? { provider }

    /// 当前 Provider 自报的 runtime（nil = 未注册）。
    ///
    /// 录音链路据此决定**开不开流式中间识别**：云端每一次中间识别都是一次完整计费请求
    /// （见 `VoiceCapturePolicy`），所以云端不做流式。
    public var runtime: RuntimeKind? { provider?.metadata().runtime }

    /// 是否允许录音期间做流式中间识别（本地 true / 云端 false）。
    public var allowsStreamingPartials: Bool {
        guard let runtime else { return true }
        return VoiceCapturePolicy.allowsStreamingPartials(for: runtime)
    }

    public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        guard let provider else { throw AIProviderError.notInitialized }
        noteUsed()
        return try await provider.transcribe(request)
    }

    public func healthCheck() async -> ProviderHealth {
        guard let provider else { return .configurationInvalid(reason: "未注册 ASR Provider") }
        return await provider.healthCheck()
    }
}
