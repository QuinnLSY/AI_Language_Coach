import AIDomain
import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

/// 云端教师语音 Adapter（OpenAI 兼容 `POST /audio/speech`）。
///
/// 与本地 `Qwen3TTSAdapter` 同构（同一个 OpenAI 风格路径），差别在：
/// - 鉴权：Bearer API Key；
/// - 音色：来自配置的 `voices`（本地音色名在云端不一定存在，见 `resolvedVoice`）；
/// - 返回：直接把 runtime 原始音频交给播放链路（可能是 mp3），不再解码成采样。
public final class RemoteTTSAdapter: TTSProvider, VoiceCatalogProvider, RuntimeInfoProvider, @unchecked Sendable {

    public let providerID: String
    public let kind: AIProviderKind = .tts

    private let state = ProviderStateBox()
    private let client: HTTPClient

    public init(providerID: String, client: HTTPClient = HTTPClient(useSystemProxy: true)) {
        self.providerID = providerID
        self.client = client
    }

    // MARK: - 生命周期

    public func initialize(config: ProviderConfig) async throws {
        // 结构防线：语音合成的配置**只能**装配成语音合成 Provider。
        // 若哪天错把别的能力的配置传进来，这里立刻失败，而不是拿着它去打 /audio/speech。
        guard config.kind == kind else {
            throw AIProviderError.invalidConfiguration(
                "配置不匹配：\(config.id) 是\(config.kind.displayName)供应商，不能用于\(kind.displayName)。"
            )
        }
        _ = try RemoteCommon.resolve(config)
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }

    public func load() async throws {
        guard await state.currentConfig != nil else { throw AIProviderError.notInitialized }
        switch await healthCheck() {
        case .connected:
            await state.setLifecycle(.ready)
        case .modelUnavailable(let model):
            await state.setLifecycle(.failed)
            throw AIProviderError.modelUnavailable(model)
        case .runtimeUnavailable(let reason):
            await state.setLifecycle(.failed)
            throw AIProviderError.runtimeUnavailable(reason)
        case .configurationInvalid(let reason):
            await state.setLifecycle(.failed)
            throw AIProviderError.invalidConfiguration(reason)
        case .requestFailed(let reason):
            await state.setLifecycle(.failed)
            throw AIProviderError.connectionFailed(reason)
        }
    }

    public func unload() async { await state.setLifecycle(.unloaded) }

    public func healthCheck() async -> ProviderHealth {
        guard let config = await state.currentConfig else {
            return .configurationInvalid(reason: "尚未初始化")
        }
        return await RemoteCommon.health(config: config, kind: .tts, client: client)
    }

    public func capabilities() -> ProviderCapabilities {
        ProviderCapabilities(streaming: false, multilingual: true)
    }

    public func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "云端教师语音", runtime: .remoteAPI)
    }

    // MARK: - 合成

    public func synthesize(_ request: TTSRequest) async throws -> TTSResult {
        let resolved = try await resolved()
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIProviderError.invalidRequest("没有可朗读的文本") }

        // 铁律：只调用**用户选定的那个**模型；没选就拒绝，绝不回退候选列表。
        // 这一次「朗读」= 一个模型 + 一次请求，且全程留痕（见 RemoteCallAudit）。
        let intent = try await RemoteCommon.beginBillableCall(
            kind: .tts,
            providerID: providerID,
            selectedModel: resolved.config.model,
            // 这家供应商的模型 = 配置里的那一个。闸门的白名单以**探测到的候选清单**为准
            // （它才是这家账号真的暴露过的模型）；候选清单为空时才退回 providerModel。
            providerModel: resolved.config.model,
            candidateModels: resolved.config.candidateModels,
            base: resolved.base,
            operation: .speech
        )

        var urlRequest = RemoteCommon.request(
            url: RemoteEndpoint.url(base: resolved.base, path: "v1/audio/speech"),
            apiKey: resolved.apiKey,
            method: "POST",
            contentType: "application/json"
        )
        let body = SpeechRequest(
            model: intent.model,
            input: text,
            voice: await resolvedVoice(request: request),
            responseFormat: "wav"
        )
        urlRequest.httpBody = try RemoteCommon.makeEncoder().encode(body)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.perform(urlRequest, timeout: resolved.config.requestTimeout ?? 180)
        } catch {
            await RemoteCommon.endBillableCall(intent, outcome: .failed)
            throw error
        }
        do {
            try RemoteCommon.ensureSuccess(statusCode: response.statusCode, data: data)
        } catch {
            await RemoteCommon.endBillableCall(intent, outcome: .httpError, httpStatus: response.statusCode)
            throw error
        }
        guard !data.isEmpty else {
            await RemoteCommon.endBillableCall(intent, outcome: .failed, httpStatus: response.statusCode)
            throw AIProviderError.invalidResponse("云端没有返回音频")
        }
        await RemoteCommon.endBillableCall(intent, outcome: .ok, httpStatus: response.statusCode)
        // 云端音频格式由厂商决定（wav / mp3），原样交给播放链路，由它按容器嗅探解码。
        return TTSResult(audioSamples: [], sampleRate: 24_000, audioData: data)
    }

    /// 云端可用音色：来自配置（各家音色名不同，代码里不写字面量）。
    public func availableVoices() async -> [String] {
        await state.currentConfig?.voices ?? []
    }

    public func runtimeDescription() async -> String? {
        guard let config = await state.currentConfig else { return nil }
        return "\(config.userFacingName) · 云端"
    }

    // MARK: - 内部

    private func resolved() async throws -> RemoteCommon.Resolved {
        guard let config = await state.currentConfig else { throw AIProviderError.notInitialized }
        return try RemoteCommon.resolve(config)
    }

    /// 本地音色名在云端未必存在（如 `serena`）：命中配置里的音色就用它，
    /// 否则退回该供应商的第一个可用音色，避免切换云端后一句话都读不出来。
    private func resolvedVoice(request: TTSRequest) async -> String? {
        let voices = await state.currentConfig?.voices ?? []
        if let voice = request.voice, voices.contains(voice) { return voice }
        if let first = voices.first { return first }
        return request.voice
    }

    private struct SpeechRequest: Encodable {
        let model: String
        let input: String
        let voice: String?
        let responseFormat: String

        enum CodingKeys: String, CodingKey {
            case model, input, voice, responseFormat
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(input, forKey: .input)
            try container.encodeIfPresent(voice, forKey: .voice)
            try container.encode(responseFormat, forKey: .responseFormat)
        }
    }
}
