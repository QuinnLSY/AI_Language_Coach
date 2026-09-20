import AIDomain
import AIInterfaces
import AppCore
import Foundation

/// ASR 统一入口。所有调用方只认 Manager，不认具体 Adapter。
public actor ASRManager {

    private var provider: (any ASRProvider)?
    /// 最近一次真实转写的时间（资源管理据此算空闲时长，第 27 步）。
    public private(set) var lastUsedAt: Date?
    /// 当前 Provider 的**装配时刻**：从未用过时，空闲时长从这里起算。
    public private(set) var startedAt: Date?

    public init() {}

    /// 距上次「真实转写 / 装配」的秒数；nil 只代表**没有注册任何 Provider**（不可挂起）。
    ///
    /// ⚠️ 绝不能把「注册后还没转过写」报成 nil：`ResourcePolicy` 把 nil 当 ∞（最冷），
    /// 于是随应用一起拉起的本地服务（开屏自动启动的 whisper）在**第一次巡检**就被挂起——
    /// 刚花十几秒载入的模型当场被杀，表现成「设置里明明开着、一用就连接失败」
    /// （2026-09-19 语音识别反馈）。注册即视为一次「起点事件」，空闲从那一刻起算。
    public var idleSeconds: Double? {
        guard provider != nil, let baseline = lastUsedAt ?? startedAt else { return nil }
        return Date().timeIntervalSince(baseline)
    }

    private func noteUsed() {
        lastUsedAt = Date()
    }

    public func register(_ provider: any ASRProvider) {
        self.provider = provider
        startedAt = Date()
    }

    public func unregister() {
        provider = nil
        startedAt = nil
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
