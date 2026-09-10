import AIInterfaces
import Foundation

/// ASR 统一入口。所有调用方只认 Manager，不认具体 Adapter。
public actor ASRManager {

    private var provider: (any ASRProvider)?

    public init() {}

    public func register(_ provider: any ASRProvider) {
        self.provider = provider
    }

    public func unregister() {
        provider = nil
    }

    /// 当前注册的 Provider（供「启动 / 关闭」这类需要拿到实例的能力使用）。
    public var current: (any ASRProvider)? { provider }

    public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        guard let provider else { throw AIProviderError.notInitialized }
        return try await provider.transcribe(request)
    }

    public func healthCheck() async -> ProviderHealth {
        guard let provider else { return .configurationInvalid(reason: "未注册 ASR Provider") }
        return await provider.healthCheck()
    }
}
