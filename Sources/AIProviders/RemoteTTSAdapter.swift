import AIDomain
import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

/// 云端教师语音 Adapter。
///
/// 支持**三种请求形态**（由配置 `speech_request_style` 决定，代码不猜厂商字段名）：
/// - `openAISpeech`（默认）：`POST <speech_path>`，JSON `{model, input, voice, response_format}`；
/// - `textJSON`：`POST <speech_path>`，JSON `{text, voice, rate}`（无 model 概念的网关服务）；
/// - `textQuery`：`GET <speech_path>?text=…&voice=…&rate=…`。
///
/// 与本地 `Qwen3TTSAdapter` 同构的部分：返回 runtime 原始音频（可能是 mp3），交播放链路按容器嗅探解码。
/// 鉴权：需要 Key 的走 Bearer；免密钥服务（`api_key_required = false`）不带 Authorization。
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
        let style = resolved.config.resolvedSpeechRequestStyle
        let speechPath = "/" + resolved.config.resolvedSpeechPath

        // 铁律：只调用**显式选定**的那一个（OpenAI 形态是模型，网关形态是音色）；
        // 没选就拒绝，绝不回退候选列表。这一次「朗读」= 一个模型 + 一次请求，全程留痕。
        let voice = await resolvedVoice(request: request)
        let intent = try await RemoteCommon.beginBillableCall(
            kind: .tts,
            providerID: providerID,
            selectedModel: style.usesModelField ? resolved.config.model : (voice ?? resolved.config.model),
            providerModel: resolved.config.model,
            // 白名单：探测到的候选清单 + 配置里的音色清单（语音服务的「模型」就是音色）。
            candidateModels: resolved.config.candidateModels + (resolved.config.voices ?? []),
            base: resolved.base,
            operation: .speech,
            endpoint: speechPath,
            billable: resolved.config.isBillable
        )

        var urlRequest: URLRequest
        switch style {
        case .openAISpeech:
            urlRequest = RemoteCommon.request(
                url: RemoteCommon.speechURL(config: resolved.config, base: resolved.base),
                apiKey: resolved.apiKey,
                method: "POST",
                contentType: "application/json"
            )
            let body = SpeechRequest(
                model: intent.model,
                input: text,
                voice: voice,
                responseFormat: "wav"
            )
            urlRequest.httpBody = try RemoteCommon.makeEncoder().encode(body)
        case .textJSON:
            urlRequest = RemoteCommon.request(
                url: RemoteCommon.speechURL(config: resolved.config, base: resolved.base),
                apiKey: resolved.apiKey,
                method: "POST",
                contentType: "application/json"
            )
            // 语速由播放侧统一控制（时间拉伸），合成侧固定中性值，避免双重变速。
            let body = TextSpeechRequest(text: text, voice: voice, rate: SpeechRequestStyle.neutralRate)
            urlRequest.httpBody = try RemoteCommon.makeEncoder().encode(body)
        case .textQuery:
            var components = URLComponents(
                url: RemoteCommon.speechURL(config: resolved.config, base: resolved.base),
                resolvingAgainstBaseURL: false
            )
            var items = [URLQueryItem(name: "text", value: text)]
            if let voice { items.append(URLQueryItem(name: "voice", value: voice)) }
            items.append(URLQueryItem(name: "rate", value: SpeechRequestStyle.neutralRate))
            components?.queryItems = items
            guard let url = components?.url else {
                await RemoteCommon.endBillableCall(intent, outcome: .failed)
                throw AIProviderError.invalidRequest("无法构造合成请求的查询串")
            }
            urlRequest = RemoteCommon.request(url: url, apiKey: resolved.apiKey, method: "GET")
        }

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

    /// 音色解析（三种形态通用）。
    ///
    /// 旧实现的问题：本地音色名（`serena`）在云端根本不存在，遇「不在清单里」就盲取第一个——
    /// 中文清单的第一个恰好是中文音色，于是英文朗读全被读成中文腔。
    /// 现在交给 `RemoteVoiceResolver`：命中就用、否则**按请求语言**挑、再否则清单第一个。
    private func resolvedVoice(request: TTSRequest) async -> String? {
        guard let config = await state.currentConfig else { return request.voice }
        return RemoteVoiceResolver.pick(
            requested: request.voice,
            language: request.language,
            voices: config.voices ?? []
        )
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

    /// 网关类（Edge TTS 代理等）的 JSON 形态：`{text, voice, rate}`。
    /// ⚠️ 字段名就是 `text`（不是 `input`）——实测服务端只认它，给 `input` 会读出空内容。
    private struct TextSpeechRequest: Encodable {
        let text: String
        let voice: String?
        let rate: String

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(voice, forKey: .voice)
            try container.encode(rate, forKey: .rate)
        }

        enum CodingKeys: String, CodingKey {
            case text, voice, rate
        }
    }
}
