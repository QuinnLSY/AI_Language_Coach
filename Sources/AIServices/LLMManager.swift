import AIInterfaces
import Foundation

/// LLM 统一入口。所有调用方（Agent / Service）只认 Manager，不认具体 Adapter。
public actor LLMManager {

    private var provider: (any LLMProvider)?

    public init() {}

    public func register(_ provider: any LLMProvider) {
        self.provider = provider
    }

    public var current: (any LLMProvider)? { provider }

    public func unregister() {
        provider = nil
    }

    public func generate(_ request: LLMRequest) async throws -> LLMResponse {
        guard let provider else { throw AIProviderError.notInitialized }
        return try await provider.generate(request)
    }

    public func stream(_ request: LLMRequest) async -> AsyncThrowingStream<LLMChunk, Error> {
        guard let provider else {
            return AsyncThrowingStream { $0.finish(throwing: AIProviderError.notInitialized) }
        }
        return provider.stream(request)
    }

    public func healthCheck() async -> ProviderHealth {
        guard let provider else { return .configurationInvalid(reason: "未注册 LLM Provider") }
        return await provider.healthCheck()
    }
}
