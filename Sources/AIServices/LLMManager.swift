import AIInterfaces
import Foundation

/// LLM 统一入口。所有调用方（Agent / Service）只认 Manager，不认具体 Adapter。
public actor LLMManager {

    private var provider: (any LLMProvider)?
    /// 最近一次真实调用的时间（资源管理据此算空闲时长，第 27 步）。
    public private(set) var lastUsedAt: Date?
    /// 当前 Provider 的**装配时刻**：从未用过时，空闲时长从这里起算。
    public private(set) var startedAt: Date?

    public init() {}

    /// 距上次「真实调用 / 装配」的秒数；nil 只代表**没有注册任何 Provider**（不可挂起）。
    ///
    /// ⚠️ 绝不能把「注册后还没调用过」报成 nil：`ResourcePolicy` 把 nil 当 ∞（最冷），
    /// 于是开屏刚装配好、还没等到第一句话的本地 LLM 会在第一次巡检就被挂起
    /// （开屏开场白那次调用正在途中时尤其明显）。注册即视为一次「起点事件」。
    public var idleSeconds: Double? {
        guard provider != nil, let baseline = lastUsedAt ?? startedAt else { return nil }
        return Date().timeIntervalSince(baseline)
    }

    private func noteUsed() {
        lastUsedAt = Date()
    }

    public func register(_ provider: any LLMProvider) {
        self.provider = provider
        startedAt = Date()
    }

    public var current: (any LLMProvider)? { provider }

    public func unregister() {
        provider = nil
        startedAt = nil
    }

    public func generate(_ request: LLMRequest) async throws -> LLMResponse {
        guard let provider else { throw AIProviderError.notInitialized }
        noteUsed()
        return try await provider.generate(request)
    }

    public func stream(_ request: LLMRequest) async -> AsyncThrowingStream<LLMChunk, Error> {
        guard let provider else {
            return AsyncThrowingStream { $0.finish(throwing: AIProviderError.notInitialized) }
        }
        noteUsed()
        return provider.stream(request)
    }

    public func healthCheck() async -> ProviderHealth {
        guard let provider else { return .configurationInvalid(reason: "未注册 LLM Provider") }
        return await provider.healthCheck()
    }
}
