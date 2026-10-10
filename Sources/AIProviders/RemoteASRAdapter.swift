import AIDomain
import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

/// 云端语音识别 Adapter（OpenAI 兼容 `POST /audio/transcriptions`）。
///
/// 与本地 `WhisperASRAdapter` 同构：都是「16kHz 单声道 WAV → 文字」，
/// 差别只在鉴权与路径（云端走 Bearer + `/v1/audio/transcriptions`）。
/// 端点 / 模型 / 超时全部来自配置，本文件不含任何厂商地址。
public final class RemoteASRAdapter: ASRProvider, @unchecked Sendable {

    public let providerID: String
    public let kind: AIProviderKind = .asr

    private let state = ProviderStateBox()
    private let client: HTTPClient

    /// 传输给云端的音频采样率（OpenAI 兼容接口普遍接受 16kHz WAV）。
    private let wireSampleRate = 16_000

    public init(providerID: String, client: HTTPClient = HTTPClient(useSystemProxy: true)) {
        self.providerID = providerID
        self.client = client
    }

    // MARK: - 生命周期

    public func initialize(config: ProviderConfig) async throws {
        guard config.kind == kind else {
            throw AIProviderError.invalidConfiguration(
                "配置不匹配：\(config.id) 是\(config.kind.displayName)供应商，不能用于\(kind.displayName)。"
            )
        }
        _ = try RemoteCommon.resolve(config) // 端点 / Key 缺失时立刻给出明确原因
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }

    /// 云端无需加载权重：只做一次模型列表可达性校验。
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
        return await RemoteCommon.health(config: config, kind: .asr, client: client)
    }

    public func capabilities() -> ProviderCapabilities {
        ProviderCapabilities(streaming: false, multilingual: true)
    }

    public func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "云端语音识别", runtime: .remoteAPI)
    }

    // MARK: - 转写

    public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        let resolved = try await resolved()
        guard !request.audioSamples.isEmpty else {
            throw AIProviderError.invalidRequest("没有可识别的音频")
        }
        // 铁律同上：只调用用户选定的识别模型，没选就拒绝（不回退候选列表）。
        let intent = try await RemoteCommon.beginBillableCall(
            kind: .asr,
            providerID: providerID,
            selectedModel: resolved.config.model,
            providerModel: resolved.config.model,
            candidateModels: resolved.config.candidateModels,
            base: resolved.base,
            operation: .transcriptions
        )
        let model = intent.model
        let wav = WhisperASRAdapter.wavData(samples: request.audioSamples, sampleRate: wireSampleRate)

        // 边界**每请求随机**：常量会被端点预知（见 `RemoteCommon.makeMultipartBoundary`）。
        let boundary = RemoteCommon.makeMultipartBoundary()
        var urlRequest = RemoteCommon.request(
            url: RemoteEndpoint.url(base: resolved.base, path: "v1/audio/transcriptions"),
            apiKey: resolved.apiKey,
            method: "POST",
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        var body = Data()
        body.append(RemoteCommon.multipartFileField(
            name: "file", filename: "speech.wav", mimeType: "audio/wav",
            data: wav, boundary: boundary
        ))
        body.append(RemoteCommon.multipartField(name: "model", value: model, boundary: boundary))
        // 语言要归一成主标签（en-US → en），云端接口不认区域后缀。
        if let language = RemoteEndpoint.primaryLanguageTag(request.language) {
            body.append(RemoteCommon.multipartField(name: "language", value: language, boundary: boundary))
        }
        body.append(RemoteCommon.multipartTerminator(boundary: boundary))
        urlRequest.httpBody = body

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.perform(urlRequest, timeout: resolved.config.requestTimeout ?? 60)
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
        let decoded = try RemoteCommon.decode(TranscriptionResponse.self, from: data)
        await RemoteCommon.endBillableCall(intent, outcome: .ok, httpStatus: response.statusCode)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ASRResult(text: text, language: request.language, confidence: nil)
    }

    // MARK: - 内部

    private func resolved() async throws -> RemoteCommon.Resolved {
        guard let config = await state.currentConfig else { throw AIProviderError.notInitialized }
        return try RemoteCommon.resolve(config)
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }
}
