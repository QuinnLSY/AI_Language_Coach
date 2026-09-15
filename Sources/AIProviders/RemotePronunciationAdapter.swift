import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

/// 云端发音评测 Adapter（Azure Speech · Pronunciation Assessment）。
///
/// 这条通道回答的是「声学上，你每个音到底发得怎么样」——`PronunciationProvider`
/// 契约里的**声学实测**一侧；没有它时 `PronunciationService` 会退化成规则推断。
///
/// 厂商差异全部在本文件内消化（AGENTS.md §3）：
/// - 认证走 `Ocp-Apim-Subscription-Key` 头，**不是** Bearer，也不做 token 交换；
/// - 请求体是 16k 单声道 PCM WAV（服务端不认别的格式）；
/// - 「参考文本 + 评分粒度」通过 base64 的 `Pronunciation-Assessment` 头传递；
/// - 返回的是 `NBest[0].Words[].Phonemes[]`，逐词逐音素都带 `AccuracyScore`。
///
/// 端点与语言一律来自配置（`endpoint` / `model`），本文件不出现任何厂商地址常量。
public final class RemotePronunciationAdapter: PronunciationProvider, @unchecked Sendable {

    public let providerID: String
    public let kind: AIProviderKind = .pronunciation

    private let state = ProviderStateBox()
    private let client: HTTPClient

    /// 免费额度/连通性探测用的静音时长（秒）。够服务端把「认证 + 音频格式」验完，
    /// 又短到不产生可感知的费用。
    static let probeSeconds = 1.0

    public init(providerID: String, client: HTTPClient = HTTPClient(useSystemProxy: true)) {
        self.providerID = providerID
        self.client = client
    }

    // MARK: - 生命周期

    public func initialize(config: ProviderConfig) async throws {
        // 结构防线：发音评测的配置只能装配成发音 Provider（防止被拿去打对话 / 识别端点）。
        guard config.kind == kind else {
            throw AIProviderError.invalidConfiguration(
                "配置不匹配：\(config.id) 是\(config.kind.displayName)供应商，不能用于\(kind.displayName)。"
            )
        }
        guard let endpoint = config.endpoint, !endpoint.isEmpty else {
            throw AIProviderError.invalidConfiguration("缺少发音评测端点")
        }
        guard URL(string: endpoint) != nil else {
            throw AIProviderError.invalidConfiguration("端点不是合法 URL")
        }
        // 这里的 `model` 承载的是**评测语言**（如 `en-US`）——发音评估是按语言建模的，
        // 交给同一个「显式选定模型」闸门来管，避免出现「没选语言就发请求」。
        guard let locale = config.model, !locale.isEmpty else {
            throw AIProviderError.invalidConfiguration("未选择评测语言（如 en-US）")
        }
        _ = locale
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }

    public func load() async throws {
        guard await state.currentConfig != nil else { throw AIProviderError.notInitialized }
        switch await healthCheck() {
        case .connected:
            await state.setLifecycle(.ready)
        case .configurationInvalid(let reason):
            await state.setLifecycle(.failed)
            throw AIProviderError.invalidConfiguration(reason)
        case .modelUnavailable(let model):
            await state.setLifecycle(.failed)
            throw AIProviderError.modelUnavailable(model)
        case .runtimeUnavailable(let reason):
            await state.setLifecycle(.failed)
            throw AIProviderError.runtimeUnavailable(reason)
        case .requestFailed(let reason):
            await state.setLifecycle(.failed)
            throw AIProviderError.connectionFailed(reason)
        }
    }

    public func unload() async { await state.setLifecycle(.unloaded) }

    /// **配置级**健康检查。
    ///
    /// 故意不发请求：发音评估没有「只读探测」端点，验证连通性就必须发一段音频，
    /// 那就等于每次打开设置都偷偷花一次钱。真实连通性在**第一次跟读**时验证
    /// （那一刻本来就有音频、本来就要计费，多这一次不算额外开销）。
    public func healthCheck() async -> ProviderHealth {
        guard let config = await state.currentConfig else {
            return .configurationInvalid(reason: "尚未初始化")
        }
        guard let endpoint = config.endpoint, !endpoint.isEmpty,
              RemoteEndpoint.base(endpoint) != nil else {
            return .configurationInvalid(reason: "端点缺失或非法")
        }
        if config.requiresAPIKey, CredentialText.normalizedKey(config.apiKey ?? "").isEmpty {
            return .configurationInvalid(reason: "未填写 API Key")
        }
        guard let locale = config.model, !locale.isEmpty else {
            return .configurationInvalid(reason: "未选择评测语言（如 en-US）")
        }
        return .connected(model: locale)
    }

    public func capabilities() -> ProviderCapabilities {
        // 返回的是**结构化**的逐音素结果（不是一段自然语言），语言由配置决定。
        ProviderCapabilities(structuredOutput: true, multilingual: true)
    }

    public func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "云端发音评测", runtime: .remoteAPI)
    }

    // MARK: - 评测

    public func evaluate(audioSamples: [Float], referenceText: String) async throws -> PronunciationScore {
        let payload = try await send(samples: audioSamples, reference: referenceText)
        return try Self.score(from: payload)
    }

    /// 连通性 + 认证探测：发 1 秒静音。
    ///
    /// 只在用户点「验证」时调用（**一次**明确动作），不在打开设置 / 启动应用时静默调用：
    /// 发音评估没有只读探测端点，任何连通性验证都必须发音频，也就一定会产生一次调用。
    /// 1 秒音频的费用可以忽略，但「悄悄花钱」这件事本身不可接受，所以把它做成显式动作。
    ///
    /// - Returns: 服务端的 `RecognitionStatus`（静音通常是 `NoMatch`，这**不算失败**——
    ///   它恰好证明「认证通过、端点正确、音频格式被接受」）。
    public func probe() async throws -> String {
        let payload = try await send(
            samples: AudioPCM.silence(seconds: Self.probeSeconds, sampleRate: Int(MicrophoneSampleRate.rate)),
            reference: "probe"
        )
        return payload.recognitionStatus ?? "Success"
    }

    /// 发一次评测请求（`evaluate` 与 `probe` 共用，保证两者走的闸门与头部完全一致）。
    private func send(samples: [Float], reference: String) async throws -> AssessmentResponse {
        guard let config = await state.currentConfig else { throw AIProviderError.notInitialized }
        let resolved = try RemoteCommon.resolve(config)
        let locale = config.model ?? "en-US"
        let path = Self.assessmentPath(locale: locale)
        guard let url = URL(string: resolved.base.absoluteString + path) else {
            throw AIProviderError.invalidConfiguration("发音评测地址无法拼接")
        }

        // 计费闸门：一次跟读 = 一次请求，且必须打的是发音端点。
        let intent = try await RemoteCommon.beginBillableCall(
            kind: .pronunciation,
            providerID: providerID,
            selectedModel: config.model,
            providerModel: config.model,
            candidateModels: config.candidateModels,
            base: resolved.base,
            operation: .pronunciation,
            endpoint: path,
            billable: config.billable ?? true
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(resolved.apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue(
            "audio/wav; codecs=audio/pcm; samplerate=\(Int(MicrophoneSampleRate.rate))",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(Self.assessmentHeader(reference: reference), forHTTPHeaderField: "Pronunciation-Assessment")
        request.httpBody = AudioPCM.wav16(samples: samples, sampleRate: Int(MicrophoneSampleRate.rate))

        do {
            let (data, response) = try await client.perform(request, timeout: config.requestTimeout ?? 30)
            try RemoteCommon.ensureSuccess(
                statusCode: response.statusCode, data: data, url: url, apiKey: resolved.apiKey
            )
            let payload = try Self.decode(AssessmentResponse.self, from: data)
            await RemoteCommon.endBillableCall(intent, outcome: .ok, httpStatus: response.statusCode)
            return payload
        } catch {
            let status = (error as? AIProviderError).flatMap(Self.httpStatus(of:))
            let outcome: RemoteCallRecord.Outcome = status == nil ? .failed : .httpError
            await RemoteCommon.endBillableCall(intent, outcome: outcome, httpStatus: status)
            throw error
        }
    }

    // MARK: - 厂商细节（只在本文件出现）

    /// 评测路径。语言作为查询参数，服务端据此选择声学模型。
    static func assessmentPath(locale: String) -> String {
        "/speech/recognition/conversation/cognitiveservices/v1"
            + "?language=\(locale)&format=detailed"
    }

    /// 评分参数头（base64 后的 JSON）。
    ///
    /// `Granularity=Phoneme` 是这一整套功能的关键：没有它，服务端只回词级分数，
    /// 「哪个音念错了」就无从谈起。
    static func assessmentHeader(reference: String) -> String {
        let payload: [String: String] = [
            "ReferenceText": reference,
            "GradingSystem": "HundredMark",
            "Granularity": "Phoneme",
            "Dimension": "Comprehensive",
            "EnableMiscue": "True",
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return json.base64EncodedString()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AIProviderError.invalidResponse(error.localizedDescription)
        }
    }

    /// 响应 → 统一得分（0...1）。
    static func score(from payload: AssessmentResponse) throws -> PronunciationScore {
        let status = payload.recognitionStatus ?? ""
        guard status.isEmpty || status == "Success" else {
            // 不是错误，而是「这段音频里没有可用语音」——按没说话处理，别伪装成在线故障。
            throw AIProviderError.invalidResponse(Self.explain(recognitionStatus: status))
        }
        guard let best = payload.nBest?.first else {
            throw AIProviderError.invalidResponse("评测服务没有返回结果")
        }

        var words: [PronunciationScore.WordPhonemes] = []
        var flat: [PhonemeScore] = []
        for word in best.words ?? [] {
            let phonemes = (word.phonemes ?? []).compactMap { item -> PhonemeScore? in
                guard let symbol = item.phoneme, !symbol.isEmpty else { return nil }
                return PhonemeScore(
                    phoneme: symbol,
                    score: Self.normalized(item.pronunciationAssessment?.accuracyScore)
                )
            }
            guard !phonemes.isEmpty else { continue }
            flat.append(contentsOf: phonemes)
            words.append(.init(word: word.word ?? "", phonemes: phonemes))
        }

        let overall = Self.normalized(
            best.pronunciationAssessment?.accuracyScore
                ?? best.pronunciationAssessment?.pronScore
        )
        return PronunciationScore(overall: overall * 100, phonemes: flat, words: words)
    }

    /// 百分制 → 0...1（服务端返回 0...100）。
    static func normalized(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(max(value / 100, 0), 1)
    }

    /// 把服务端的 `RecognitionStatus` 翻成用户能懂的话。
    static func explain(recognitionStatus status: String) -> String {
        switch status {
        case "NoMatch": "这次没听清（录音里没有识别到有效语音），请贴近麦克风重读一次"
        case "InitialSilenceTimeout": "录音开头是静音，说完请再点一次「停止」"
        case "BabbleTimeout": "背景噪声太大，没听清，换个安静点的地方再试"
        case "Error": "评测服务返回错误，请稍后重试"
        default: "评测未成功（服务端状态：\(status)）"
        }
    }

    static func httpStatus(of error: AIProviderError) -> Int? {
        if case .serverError(let status, _) = error { return status }
        return nil
    }
}

/// 采样率的口径只有一处（麦克风链路固定 16k）。
///
/// 放在这里而不是散落的字面量：云端发音评测对采样率很敏感，
/// 写错一个数字的表现是「服务端拒绝音频」，而错误信息指不到根因。
enum MicrophoneSampleRate {
    static let rate: Double = 16_000
}

// MARK: - 响应模型（实测字段，可选字段一律可选解）

/// Azure 发音评估的响应体。
///
/// 全部字段可选解：服务端在 `NoMatch` 之类的状态下只回一个 `RecognitionStatus`，
/// 强解会让「没听清」变成解码崩溃，看不出真正原因。
struct AssessmentResponse: Decodable {

    var recognitionStatus: String?
    var displayText: String?
    var nBest: [Best]?

    struct Best: Decodable {
        var display: String?
        var pronunciationAssessment: Assessment?
        var words: [Word]?

        struct Word: Decodable {
            var word: String?
            var pronunciationAssessment: Assessment?
            var phonemes: [Phoneme]?

            struct Phoneme: Decodable {
                var phoneme: String?
                var pronunciationAssessment: Assessment?
            }
        }
    }

    struct Assessment: Decodable {
        var accuracyScore: Double?
        var fluencyScore: Double?
        var completenessScore: Double?
        var pronScore: Double?
        var errorType: String?
    }

    private enum CodingKeys: String, CodingKey {
        case recognitionStatus = "RecognitionStatus"
        case displayText = "DisplayText"
        case nBest = "NBest"
    }

    enum BestKeys: String, CodingKey {
        case display = "Display"
        case pronunciationAssessment = "PronunciationAssessment"
        case words = "Words"
    }

    enum WordKeys: String, CodingKey {
        case word = "Word"
        case pronunciationAssessment = "PronunciationAssessment"
        case phonemes = "Phonemes"
    }

    enum PhonemeKeys: String, CodingKey {
        case phoneme = "Phoneme"
        case pronunciationAssessment = "PronunciationAssessment"
    }

    enum AssessmentKeys: String, CodingKey {
        case accuracyScore = "AccuracyScore"
        case fluencyScore = "FluencyScore"
        case completenessScore = "CompletenessScore"
        case pronScore = "PronScore"
        case errorType = "ErrorType"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recognitionStatus = try container.decodeIfPresent(String.self, forKey: .recognitionStatus)
        displayText = try container.decodeIfPresent(String.self, forKey: .displayText)
        nBest = try container.decodeIfPresent([Best].self, forKey: .nBest)
    }
}

extension AssessmentResponse.Best {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AssessmentResponse.BestKeys.self)
        display = try container.decodeIfPresent(String.self, forKey: .display)
        pronunciationAssessment = try container
            .decodeIfPresent(AssessmentResponse.Assessment.self, forKey: .pronunciationAssessment)
        words = try container.decodeIfPresent([Word].self, forKey: .words)
    }
}

extension AssessmentResponse.Best.Word {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AssessmentResponse.WordKeys.self)
        word = try container.decodeIfPresent(String.self, forKey: .word)
        pronunciationAssessment = try container
            .decodeIfPresent(AssessmentResponse.Assessment.self, forKey: .pronunciationAssessment)
        phonemes = try container.decodeIfPresent([Phoneme].self, forKey: .phonemes)
    }
}

extension AssessmentResponse.Best.Word.Phoneme {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AssessmentResponse.PhonemeKeys.self)
        phoneme = try container.decodeIfPresent(String.self, forKey: .phoneme)
        pronunciationAssessment = try container
            .decodeIfPresent(AssessmentResponse.Assessment.self, forKey: .pronunciationAssessment)
    }
}

extension AssessmentResponse.Assessment {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AssessmentResponse.AssessmentKeys.self)
        accuracyScore = try container.decodeIfPresent(Double.self, forKey: .accuracyScore)
        fluencyScore = try container.decodeIfPresent(Double.self, forKey: .fluencyScore)
        completenessScore = try container.decodeIfPresent(Double.self, forKey: .completenessScore)
        pronScore = try container.decodeIfPresent(Double.self, forKey: .pronScore)
        errorType = try container.decodeIfPresent(String.self, forKey: .errorType)
    }
}
