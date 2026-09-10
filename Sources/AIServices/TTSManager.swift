import AIInterfaces
import Foundation

/// TTS 统一入口。所有调用方只认 Manager，不认具体 Adapter。
public actor TTSManager {

    private var provider: (any TTSProvider)?

    public init() {}

    public func register(_ provider: any TTSProvider) {
        self.provider = provider
    }

    public func unregister() {
        provider = nil
    }

    public func synthesize(_ request: TTSRequest) async throws -> TTSResult {
        guard let provider else { throw AIProviderError.notInitialized }
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
