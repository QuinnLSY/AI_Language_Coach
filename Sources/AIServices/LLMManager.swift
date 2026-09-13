import AIInterfaces
import Foundation

/// LLM 统一入口。所有调用方（Agent / Service）只认 Manager，不认具体 Adapter。
public actor LLMManager {

    private var provider: (any LLMProvider)?
    /// 最近一次真实调用的时间（资源管理据此算空闲时长，第 27 步）。
    public private(set) var lastUsedAt: Date?

    public init() {}

    /// 距上次真实调用的秒数；nil = 注册后从未调用过（资源管理按「最冷」处理）。
    public var idleSeconds: Double? {
        lastUsedAt.map { Date().timeIntervalSince($0) }
    }

    private func noteUsed() {
        lastUsedAt = Date()
    }

    public func register(_ provider: any LLMProvider) {
        self.provider = provider
    }

    public var current: (any LLMProvider)? { provider }

    public func unregister() {
        provider = nil
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
