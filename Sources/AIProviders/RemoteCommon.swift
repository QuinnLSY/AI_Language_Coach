import AIDomain
import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

/// 云端 OpenAI 兼容接口的公共部分：鉴权、端点拼接、模型发现、错误映射。
///
/// 各家云端厂商（OpenAI / Groq / SiliconFlow / DeepSeek / OpenRouter …）协议同构，
/// 差异只在 Adapter 内消化；**端点与密钥一律来自配置**，本文件不出现任何厂商地址。
public enum RemoteCommon {

    public struct Resolved: Sendable {
        public let config: ProviderConfig
        public let base: URL
        public let apiKey: String

        public init(config: ProviderConfig, base: URL, apiKey: String) {
            self.config = config
            self.base = base
            self.apiKey = apiKey
        }
    }

    /// 端点 + Key 校验（云端调用前的统一前置检查）。
    ///
    /// 免密钥服务（配置声明 `apiKey_required = false`，如自建 Edge TTS 代理）
    /// 不要求 Key：`apiKey` 为空串，`request` 也就不会带上 Authorization 头。
    public static func resolve(_ config: ProviderConfig) throws -> Resolved {
        guard let endpoint = config.endpoint, !endpoint.isEmpty else {
            throw AIProviderError.invalidConfiguration("缺少 API 端点")
        }
        guard let base = RemoteEndpoint.base(endpoint) else {
            throw AIProviderError.invalidConfiguration("端点不是合法 URL")
        }
        // Key 统一走粘贴清洗：厂商控制台复制出来的引号 / 「Bearer 」前缀 / 夹带的换行，
        // 发出去就是 `Bearer "sk-…"`，服务端回「Invalid token」而用户看不出哪里不对。
        let apiKey = CredentialText.normalizedKey(config.apiKey ?? "")
        if config.requiresAPIKey, apiKey.isEmpty {
            throw AIProviderError.invalidConfiguration("未填写 API Key")
        }
        return Resolved(config: config, base: base, apiKey: apiKey)
    }

    /// 带鉴权的请求（云端一律走系统代理，否则出不了网）。
    /// Key 为空（免密钥服务）时不带 Authorization 头——带一个空 Bearer 反而可能被拒。
    public static func request(
        url: URL,
        apiKey: String,
        method: String = "GET",
        contentType: String? = nil
    ) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    /// 模型列表地址（路径来自配置，兼容端点已含 `/v1` 的厂商）。
    public static func modelsURL(config: ProviderConfig, base: URL) -> URL {
        RemoteEndpoint.url(base: base, path: config.resolvedModelsPath)
    }

    /// 语音合成地址（路径来自配置：OpenAI 兼容 `/v1/audio/speech`，网关类可能是 `/tts`）。
    public static func speechURL(config: ProviderConfig, base: URL) -> URL {
        RemoteEndpoint.url(base: base, path: config.resolvedSpeechPath)
    }

    /// 音色目录地址（配置了 `voice_list_path` 的供应商自报音色清单）。
    public static func voicesURL(config: ProviderConfig, base: URL) -> URL? {
        guard let path = config.voiceListPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return RemoteEndpoint.url(base: base, path: path)
    }

    /// 健康检查地址（配置了 `health_path` 就用它探活，省一次列表请求）。
    public static func healthURL(config: ProviderConfig, base: URL) -> URL? {
        guard let path = config.healthPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return RemoteEndpoint.url(base: base, path: path)
    }

    // MARK: - 云端调用闸门（所有计费请求的唯一入口）
    //
    // 铁律：**一次操作 = 一个模型、一次请求**。
    // 任何发往云端、会产生费用的请求，都必须先过 `beginBillableCall`（准入）与
    // `endBillableCall`（记账）。没有例外，也不允许在 Adapter 里自己发计费请求。
    // 这样「只调用用户选定的模型」就是结构性保证，而不是靠自觉。

    /// 端点主机名（审计展示用，不含路径与密钥）。
    public static func host(of base: URL) -> String { base.host ?? base.absoluteString }

    /// 计费调用的统一前置：模型必须是**显式选定**的那个、必须**属于这家供应商**，且必须通过费用护栏。
    ///
    /// 三道门，缺一不可（都是真实事故留下的教训）：
    /// 1. **操作 ↔ 能力必须匹配**：朗读只能打语音端点、识别只能打识别端点、对话只能打对话端点。
    ///    结构上杜绝「点了语音，却产生了语言模型账单」这类串线。
    /// 2. **模型必须显式选定**：没选就拒绝，绝不回退候选列表（那可以是账号里任意一个模型）。
    /// 3. **模型必须属于这个 Provider**：白名单以**探测到的候选清单**为准
    ///    （它才是这家账号真的暴露过的模型）；候选清单为空时才退回 `providerModel`。
    ///    本地模型名（如 `ggml-small.en`）因此不可能被发去云端——哪怕它被旧 bug
    ///    写进了 `provider.model` 也一样：被污染的名字不能给自己背书。
    ///
    /// - Returns: 审计用的调用意图（请求结束后原样传回 `endBillableCall`）。
    /// - Throws: 以上任一不满足时抛错——**此时请求一定没有发出去**。
    public static func beginBillableCall(
        kind: AIProviderKind,
        providerID: String,
        selectedModel: String?,
        providerModel: String?,
        candidateModels: [String] = [],
        base: URL,
        operation: RemoteCallPolicy.Operation,
        endpoint: String? = nil,
        billable: Bool = true
    ) async throws -> RemoteCallPolicy.Intent {
        guard RemoteCallPolicy.operationMatches(kind: kind, operation: operation) else {
            throw AIProviderError.invalidRequest(
                "内部错误：\(operation.displayName)不能由「\(kind.displayName)」发起，已阻止这次云端调用。"
            )
        }
        guard let model = RemoteCallPolicy.resolvedModel(selected: selectedModel, providerDefault: providerModel),
              !model.isEmpty else {
            throw AIProviderError.invalidConfiguration(
                "未选择\(operation.displayName)模型：请先在设置里选定要调用的模型（应用不会自动改用候选列表里的其它模型）。"
            )
        }
        guard RemoteCallPolicy.isModelAllowed(model, providerModel: providerModel, candidates: candidateModels) else {
            throw AIProviderError.invalidConfiguration("""
                「\(model)」不属于当前供应商（\(providerID)）的模型列表，已阻止这次云端调用。\
                本地模型与云端模型不能混用，请到设置里重新选择模型后再试。
                """)
        }
        let intent = RemoteCallPolicy.Intent(
            kind: kind, providerID: providerID, model: model,
            host: host(of: base), operation: operation,
            endpoint: endpoint ?? "", billable: billable
        )
        if case .denied(let reason) = await RemoteCallAudit.shared.authorize(intent) {
            throw AIProviderError.invalidRequest(reason)
        }
        return intent
    }

    /// 记账：把这次调用的最终结果写进审计（成功 / 服务端拒绝 / 失败）。
    public static func endBillableCall(
        _ intent: RemoteCallPolicy.Intent,
        outcome: RemoteCallRecord.Outcome,
        httpStatus: Int? = nil
    ) async {
        await RemoteCallAudit.shared.record(intent, outcome: outcome, httpStatus: httpStatus)
    }

    /// 记账一次只读的模型列表探测（不计费，仅留痕，便于完整对账）。
    public static func noteDiscovery(kind: AIProviderKind, providerID: String, base: URL) async {
        let intent = RemoteCallPolicy.Intent(
            kind: kind, providerID: providerID, model: "",
            host: host(of: base), operation: .models
        )
        await RemoteCallAudit.shared.record(intent, outcome: .ok)
    }

    /// 记账一次**失败**的模型列表探测。
    ///
    /// 只记成功会让「为什么验证不过」在审计里无迹可寻——用户反复重建 Key 时，
    /// 日志里连一条被拒记录都没有（2026-09-14 排查 Agnes 时就是这样）。
    public static func recordDiscoveryFailure(
        kind: AIProviderKind, providerID: String, base: URL, status: Int
    ) async {
        let intent = RemoteCallPolicy.Intent(
            kind: kind, providerID: providerID, model: "",
            host: host(of: base), operation: .models
        )
        await RemoteCallAudit.shared.record(intent, outcome: .httpError, httpStatus: status)
    }

    /// 服务端自己给的说明（OpenAI 兼容的 `{"error":{"message":…}}`，认不出就退回原文）。
    public static func serverMessage(from data: Data) -> String? {
        if let decoded = (try? makeDecoder().decode(ErrorPayload.self, from: data))?.error?.message,
           !decoded.isEmpty {
            return decoded
        }
        return String(data: data, encoding: .utf8)
    }

    /// 拉取模型列表并按能力归类（UI 只看到自己那类模型）。
    public static func discoverModels(
        config: ProviderConfig,
        kind: AIProviderKind,
        client: HTTPClient
    ) async throws -> [DiscoveredModel] {
        let resolved = try resolve(config)
        let request = self.request(
            url: modelsURL(config: config, base: resolved.base),
            apiKey: resolved.apiKey
        )
        let (data, response) = try await client.perform(request, timeout: config.requestTimeout ?? 20)
        if response.statusCode == 401 {
            // 探测失败也要留痕：以前只在成功时记账，于是「到底被拒了几次、被谁拒的」
            // 在审计里完全看不到，排查只能靠猜（2026-09-14 排查 Agnes 时踩到）。
            await recordDiscoveryFailure(
                kind: kind, providerID: config.id, base: resolved.base, status: response.statusCode
            )
            throw AIProviderError.invalidConfiguration(RemoteAuthDiagnostics.unauthorized(
                address: "\(resolved.base.host ?? "?")\(request.url?.path ?? "")",
                keyDescription: CredentialText.safeDescription(resolved.apiKey),
                serverMessage: serverMessage(from: data)
            ))
        }
        guard (200..<300).contains(response.statusCode) else {
            await recordDiscoveryFailure(
                kind: kind, providerID: config.id, base: resolved.base, status: response.statusCode
            )
            throw AIProviderError.serverError(
                status: response.statusCode,
                message: String(data: data, encoding: .utf8)
            )
        }
        await noteDiscovery(kind: kind, providerID: config.id, base: resolved.base)
        let list = try decode(ModelList.self, from: data)
        let all = list.data.map {
            DiscoveredModel(
                id: $0.id,
                name: $0.name ?? $0.id,
                isEmbeddingOnly: RemoteModelFilter.classify($0.id) == .embedding,
                contextLength: $0.contextLength
            )
        }
        let ids = RemoteModelFilter.filterIDs(all.map(\.id), for: kind)
        let kept = Set(ids)
        return all.filter { kept.contains($0.id) }
    }

    /// 拉取供应商自报的音色清单（`voice_list_path`，如 Edge TTS 代理的 `/voices`）。
    ///
    /// 与 `discoverModels` 的差别：**形态各家不同**，解析交给 `RemoteVoiceCatalog`（宽容解析，
    /// 认不出返回空数组而不抛错）；且音色列表是只读探测，失败不该打断朗读主链路。
    public static func discoverVoices(
        config: ProviderConfig,
        client: HTTPClient
    ) async throws -> [RemoteVoiceCatalog.Voice] {
        let resolved = try resolve(config)
        guard let url = voicesURL(config: config, base: resolved.base) else { return [] }
        let request = self.request(url: url, apiKey: resolved.apiKey)
        let (data, response) = try await client.perform(request, timeout: config.requestTimeout ?? 20)
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.serverError(
                status: response.statusCode,
                message: String(data: data, encoding: .utf8)
            )
        }
        await noteDiscovery(kind: .tts, providerID: config.id, base: resolved.base)
        return RemoteVoiceCatalog.decode(data)
    }

    /// 云端健康检查。
    ///
    /// 优先级（配置决定，代码不猜）：
    /// 1. 配了 `health_path` → 探它（最贴近服务本身的就绪语义，也最省）；
    /// 2. 配了 `voice_list_path` 的语音供应商 → 能拉到音色清单就算就绪
    ///    （这类网关服务往往没有 OpenAI 的 `/models`，拿它探活必然 404）；
    /// 3. 其余 → 沿用模型列表探测 + 选中模型归属检查。
    public static func health(
        config: ProviderConfig,
        kind: AIProviderKind,
        client: HTTPClient
    ) async -> ProviderHealth {
        do {
            let resolved = try resolve(config)
            if let url = healthURL(config: config, base: resolved.base) {
                let request = self.request(url: url, apiKey: resolved.apiKey)
                let (_, response) = try await client.perform(request, timeout: config.requestTimeout ?? 20)
                guard (200..<300).contains(response.statusCode) else {
                    return .runtimeUnavailable(reason: "健康检查返回 HTTP \(response.statusCode)")
                }
                return .connected(model: config.model)
            }
            if kind == .tts, voicesURL(config: config, base: resolved.base) != nil {
                // 选中音色不在自报清单里也算就绪：合成时 `RemoteVoiceResolver` 会按语言回退，
                // 这里若报「模型不可用」反而会把一个能用的服务挡在门外。
                _ = try await discoverVoices(config: config, client: client)
                return .connected(model: config.model)
            }
            let models = try await discoverModels(config: config, kind: kind, client: client)
            if let model = config.model, !model.isEmpty {
                let ids = Set(models.map(\.id))
                return ids.contains(model) ? .connected(model: model) : .modelUnavailable(model: model)
            }
            return .connected(model: nil)
        } catch let error as AIProviderError {
            switch error {
            case .invalidConfiguration(let reason):
                return .configurationInvalid(reason: reason)
            case .connectionFailed(let reason), .timeout(let reason):
                return .runtimeUnavailable(reason: reason)
            default:
                return .requestFailed(reason: error.localizedDescription)
            }
        } catch {
            return .requestFailed(reason: error.localizedDescription)
        }
    }

    /// 统一错误映射（401 / 402 / 404 / 429 各有各的说法，别让用户看 HTTP 数字）。
    public static func ensureSuccess(
        statusCode: Int, data: Data, url: URL? = nil, apiKey: String? = nil
    ) throws {
        guard !(200..<300).contains(statusCode) else { return }
        let body = String(data: data, encoding: .utf8)
        let message = serverMessage(from: data) ?? body
        switch statusCode {
        case 401:
            if let url, let apiKey {
                throw AIProviderError.invalidConfiguration(RemoteAuthDiagnostics.unauthorized(
                    address: "\(url.host ?? "?")\(url.path)",
                    keyDescription: CredentialText.safeDescription(apiKey),
                    serverMessage: message
                ))
            }
            throw AIProviderError.invalidConfiguration("API Key 无效或已过期")
        case 402: throw AIProviderError.invalidConfiguration("账户余额不足")
        case 404: throw AIProviderError.modelUnavailable(message ?? "模型不存在")
        case 408: throw AIProviderError.timeout(message ?? "请求超时")
        case 429: throw AIProviderError.serverError(status: statusCode, message: "请求过于频繁或额度受限")
        default: throw AIProviderError.serverError(status: statusCode, message: message)
        }
    }

    // MARK: - 多模态消息内容（第 3 项需求：图片 / 视频 / 文件附件）
    //
    // 铁律：**厂商 JSON 形态只出现在 Adapter 这一层**。这里承载 OpenAI 兼容的
    // `message.content`（纯文本 = 字符串，带图片 = parts 数组），
    // 上层（ChatService / UI）只交 `LLMInlineImage`，不认识 `image_url` 这种字段名。

    /// OpenAI 兼容的 `message.content`。
    public enum ChatMessageContent: Encodable {
        case text(String)
        case parts([Part])

        public struct Part: Encodable {
            public let type: String
            public let text: String?
            public let imageURL: ImageURL?

            // 显式写死最终键名，不依赖 keyEncodingStrategy 对驼峰的分词结果
            // （`imageURL` 被自动转出来是 `image_url` 还是 `image_ur_l` 全靠算法实现，不值得赌）。
            private enum CodingKeys: String, CodingKey {
                case type, text
                case imageURL = "image_url"
            }

            public struct ImageURL: Encodable {
                public let url: String
            }

            static func text(_ value: String) -> Part {
                Part(type: "text", text: value, imageURL: nil)
            }

            static func image(_ dataURL: String) -> Part {
                Part(type: "image_url", text: nil, imageURL: ImageURL(url: dataURL))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value): try container.encode(value)
            case .parts(let parts): try container.encode(parts)
            }
        }
    }

    /// 把图片字节包成 `data:` URL（OpenAI 兼容接口接受的内联形式）。
    ///
    /// 用 base64 内联而不是先上传拿 URL：这条路不需要任何额外的文件托管服务，
    /// 也不会把用户的图片留在一个我们不掌控的地方 —— 发完即弃。
    public static func dataURL(mimeType: String, data: Data) -> String {
        let type = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = type.isEmpty ? "application/octet-stream" : type
        return "data:\(resolved);base64,\(data.base64EncodedString())"
    }

    /// 组装一条消息的 `content`。
    ///
    /// - Parameter inlineImages: 该供应商是否声明了视觉能力。**没有声明就绝不内联图片**：
    ///   对纯文本模型发 `image_url` 只会稳定 400，而错误信息看起来像「请求格式错误」，
    ///   用户根本想不到是「这个模型不吃图」。这时改为一句可读的说明，对话照常能继续。
    public static func chatContent(
        for message: LLMMessage,
        inlineImages: Bool
    ) -> ChatMessageContent {
        let inlined = inlineImages ? message.images : []
        let skipped = inlineImages ? [] : message.images
        // 没内联的图片（含「模型不吃图」）+ 视频 / 普通文件：都只用文件名告知模型。
        let noteNames = skipped.map(\.fileName) + message.referencedFileNames
        let note = PromptBuilder.attachmentNoteBlock(fileNames: noteNames)

        if inlined.isEmpty {
            let joined = [message.content, note]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            return .text(joined)
        }

        var parts: [ChatMessageContent.Part] = []
        let body = [message.content, note]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        // 文本 part 在图片 part **之前**：部分网关按「第一个 part」决定上下文的处理方式，
        // 先给文字再给图更稳（反过来在少数网关上会被当成纯图请求，丢掉文本指令）。
        if !body.isEmpty { parts.append(.text(body)) }
        parts.append(contentsOf: inlined.map { .image(dataURL(mimeType: $0.mimeType, data: $0.data)) })
        return .parts(parts)
    }

    // MARK: - multipart（语音上传）

    /// 构造 multipart 字段（文本字段与文件字段共用一套边界格式）。
    public static func multipartField(
        name: String,
        value: String,
        boundary: String
    ) -> Data {
        var field = "--\(boundary)\r\n"
        field += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        field += "\(value)\r\n"
        return Data(field.utf8)
    }

    public static func multipartFileField(
        name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String
    ) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
        return body
    }

    // MARK: - 编解码

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw AIProviderError.invalidResponse(error.localizedDescription)
        }
    }

    // MARK: - 传输结构（仅本文件可见）

    struct ModelList: Decodable {
        let data: [Item]

        struct Item: Decodable {
            let id: String
            let name: String?
            let contextLength: Int?
        }
    }

    private struct ErrorPayload: Decodable {
        let error: Detail?

        struct Detail: Decodable {
            let message: String?
        }
    }
}
