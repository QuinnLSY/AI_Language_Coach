import AIDomain
import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

/// 本地 Whisper（whisper.cpp server）语音识别 Adapter。
///
/// 契约（对 ~/AI_Models 部署的 whisper.cpp v1.9.2 实测所得）：
/// - `POST {endpoint}/inference` —— multipart/form-data，字段名 `file`；
///   可选字段 `response_format=json`、`language`、`temperature`。
/// - 响应：`{"text": "..."}`。
/// - `GET {endpoint}/health` —— 200 即 runtime 在线。
///
/// 模型权重由外部 runtime 持有，本进程**不加载任何模型文件**（AGENTS.md §3B / v2.0）。
/// 所有 whisper 专属细节（路径、字段名、音频封装格式）只允许出现在本文件内。
public final class WhisperASRAdapter: ASRProvider, @unchecked Sendable {

    public let providerID: String
    public let kind: AIProviderKind = .asr

    private let state = ProviderStateBox()
    private let client: HTTPClient

    /// 传输给 runtime 的音频采样率（whisper 家族一律 16kHz 单声道）。
    private let wireSampleRate = 16_000

    public init(providerID: String = "local.asr", client: HTTPClient = HTTPClient()) {
        self.providerID = providerID
        self.client = client
    }

    // MARK: - 生命周期

    public func initialize(config: ProviderConfig) async throws {
        guard let endpoint = config.endpoint, !endpoint.isEmpty else {
            throw AIProviderError.invalidConfiguration("缺少 runtime 端点")
        }
        guard URL(string: endpoint) != nil else {
            throw AIProviderError.invalidConfiguration("端点不是合法 URL")
        }
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }

    public func load() async throws {
        let health = await healthCheck()
        switch health {
        case .connected:
            await state.setLifecycle(.ready)
        case .runtimeUnavailable(let reason):
            await state.setLifecycle(.failed)
            throw AIProviderError.runtimeUnavailable(reason)
        default:
            await state.setLifecycle(.failed)
            throw AIProviderError.runtimeUnavailable(health.userFacingDescription)
        }
    }

    public func unload() async { await state.setLifecycle(.unloaded) }

    public func healthCheck() async -> ProviderHealth {
        guard let config = await state.currentConfig else {
            return .configurationInvalid(reason: "尚未初始化")
        }
        guard let endpoint = config.endpoint, let base = Self.normalizedBase(endpoint) else {
            return .configurationInvalid(reason: "端点缺失或非法")
        }
        let request = URLRequest(url: base.appendingPathComponent("health"))
        do {
            let (_, response) = try await client.perform(request, timeout: config.requestTimeout ?? 6)
            return (200..<300).contains(response.statusCode)
                ? .connected(model: config.model)
                : .requestFailed(reason: "HTTP \(response.statusCode)")
        } catch let error as AIProviderError {
            switch error {
            case .connectionFailed(let reason), .timeout(let reason):
                return .runtimeUnavailable(reason: reason)
            default:
                return .requestFailed(reason: error.localizedDescription)
            }
        } catch {
            return .requestFailed(reason: error.localizedDescription)
        }
    }

    public func capabilities() -> ProviderCapabilities {
        // wordTimestamp = true 是**实测**结论：本机 whisper.cpp v1.9.2 的
        // `response_format=verbose_json` 会返回 segments[] 与 words[]{start,end}。
        // streaming = false 同样是实测：该 runtime 没有流式端点，只有一次性的 /inference。
        ProviderCapabilities(streaming: false, structuredOutput: false,
                             multilingual: true, wordTimestamp: true)
    }

    public func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "本地语音识别", runtime: .externalLocalRuntime)
    }

    // MARK: - 识别

    public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        let config = try await resolvedConfig()
        let base = try Self.base(config)
        guard !request.audioSamples.isEmpty else {
            throw AIProviderError.invalidRequest("没有可识别的音频")
        }
        let wav = Self.wavData(samples: request.audioSamples, sampleRate: wireSampleRate)

        var urlRequest = URLRequest(url: base.appendingPathComponent("inference"))
        urlRequest.httpMethod = "POST"
        let boundary = "AILanguageCoach-\(UUID().uuidString)"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Self.multipartField(name: "file", filename: "speech.wav",
                                        mimeType: "audio/wav", data: wav, boundary: boundary))
        if let language = request.language, !language.isEmpty {
            body.append(Self.multipartField(name: "language", value: language, boundary: boundary))
        }
        // verbose_json 才能拿到时间戳；字段缺失的老 runtime 只会回落成「有 text、无 segments」，
        // 不会让整段转写失败（见 `WhisperInferenceResponse` 的可选字段）。
        body.append(Self.multipartField(name: "response_format", value: "verbose_json", boundary: boundary))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        urlRequest.httpBody = body

        let (data, response) = try await client.perform(urlRequest, timeout: config.requestTimeout ?? 60)
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.serverError(
                status: response.statusCode,
                message: String(data: data, encoding: .utf8)
            )
        }
        let decoded = try Self.decode(WhisperInferenceResponse.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = decoded.segments?.compactMap { segment -> ASRSegment? in
            // 时间戳缺一半就没法用：宁可丢掉这一段，也不要拿 0 冒充真实位置。
            guard let start = segment.start, let end = segment.end else { return nil }
            let words = (segment.words ?? []).compactMap { word -> ASRWord? in
                guard let text = word.word, let ws = word.start, let we = word.end else { return nil }
                return ASRWord(word: text, start: ws, end: we, confidence: word.probability)
            }
            return ASRSegment(text: (segment.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              start: start, end: end, words: words)
        }
        // 空数组退化成 nil：调用方看到 nil 才知道「这次没有时间戳」，
        // 而不是误读成「转写结果为空」。
        let usableSegments = (segments?.isEmpty ?? true) ? nil : segments
        return ASRResult(text: text, language: request.language,
                         confidence: nil, segments: usableSegments)
    }

    // MARK: - 内部

    private func resolvedConfig() async throws -> ProviderConfig {
        guard let config = await state.currentConfig else { throw AIProviderError.notInitialized }
        return config
    }

    private static func base(_ config: ProviderConfig) throws -> URL {
        guard let endpoint = config.endpoint, let base = normalizedBase(endpoint) else {
            throw AIProviderError.invalidConfiguration("端点缺失或非法")
        }
        return base
    }

    private static func normalizedBase(_ endpoint: String) -> URL? {
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AIProviderError.invalidResponse(error.localizedDescription)
        }
    }

    /// 16bit PCM WAV 封装（runtime 只吃 WAV，不依赖服务端 ffmpeg）。
    ///
    /// 实现已收敛到 `AudioPCM.wav16`：发音评测适配器也要发音频，两份实现
    /// 一旦在位深 / 字节序 / 头长度上走偏，表现都是「服务端说格式不对」，
    /// 而错误信息指不到根因。
    public static func wavData(samples: [Float], sampleRate: Int) -> Data {
        AudioPCM.wav16(samples: samples, sampleRate: sampleRate)
    }

    // MARK: multipart

    private static func multipartField(name: String, value: String, boundary: String) -> Data {
        var body = "--\(boundary)\r\n".data(using: .utf8)!
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
        return body
    }

    private static func multipartField(name: String, filename: String, mimeType: String,
                                       data: Data, boundary: String) -> Data {
        var body = "--\(boundary)\r\n".data(using: .utf8)!
        body.append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        return body
    }

    /// whisper.cpp `/inference` 响应体（**逐字段实测**，未实测的一律不写）。
    ///
    /// 只有 `text` 是必需的：老 runtime 或别的响应形态只给 `{"text": "..."}` 时，
    /// 解码照样成功，只是 `segments` 为 nil —— 时间戳拿不到不影响拿到文字。
    private struct WhisperInferenceResponse: Decodable {
        let text: String
        let segments: [Segment]?

        struct Segment: Decodable {
            let text: String?
            let start: Double?
            let end: Double?
            let words: [Word]?
        }

        struct Word: Decodable {
            let word: String?
            let start: Double?
            let end: Double?
            let probability: Float?
        }
    }
}

// MARK: - 本地模型服务的后台启停（设置页「启动 / 关闭」按钮）

extension WhisperASRAdapter: ModelServiceControlling {
    public func startModelService() async throws {
        try await LocalServiceControl.start(config: resolvedConfig())
    }

    public func stopModelService() async throws {
        try await LocalServiceControl.stop(config: resolvedConfig())
    }
}
