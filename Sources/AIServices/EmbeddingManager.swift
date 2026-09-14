import AIDomain
import AIInterfaces
import AppCore
import Foundation

/// 语义索引（Embedding）统一入口。所有调用方只认 Manager，不认具体 Adapter。
///
/// 存在的理由：`EmbeddingProvider` 契约从 Phase 2 就在，但一直**没有装配、也没有消费方**
/// —— 学习记忆只能靠结构化查询。这里把它接上，让「按当前话题取回最相关的历史」成为可能。
///
/// **未注册时 `isUsable == false`**：调用方据此退回结构化路径，绝不假装可用。
public actor EmbeddingManager {

    private var provider: (any EmbeddingProvider)?
    /// 最近一次真实嵌入的时间（与其它 Manager 一致，便于将来纳入资源管理）。
    public private(set) var lastUsedAt: Date?

    public init() {}

    public func register(_ provider: any EmbeddingProvider) {
        self.provider = provider
    }

    public func unregister() {
        provider = nil
    }

    /// 当前注册的 Provider（供需要拿到实例的能力使用）。
    public var current: (any EmbeddingProvider)? { provider }

    /// 是否已装配可用 Provider。
    public var isUsable: Bool { provider != nil }

    /// 当前 Provider 自报的向量维度（未注册为 0）。
    public var dimensions: Int { provider?.dimensions ?? 0 }

    /// 当前 Provider 自报的 runtime（nil = 未注册）。
    public var runtime: RuntimeKind? { provider?.metadata().runtime }

    /// 能否做**真正的语义**排序。
    ///
    /// mock 的向量是字符值的桶计数，不是语义 —— 按它算余弦等于乱排，
    /// 会把相关的历史错误随机丢掉。因此语义裁剪只在真实 runtime 上启用。
    public var supportsSemanticRanking: Bool {
        guard let runtime else { return false }
        return runtime != .mock
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let provider else { throw AIProviderError.notInitialized }
        lastUsedAt = Date()
        return try await provider.embed(texts)
    }

    public func healthCheck() async -> ProviderHealth {
        guard let provider else { return .configurationInvalid(reason: "未注册 Embedding Provider") }
        return await provider.healthCheck()
    }
}
