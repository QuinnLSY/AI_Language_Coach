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
    public static func resolve(_ config: ProviderConfig) throws -> Resolved {
        guard let endpoint = config.endpoint, !endpoint.isEmpty else {
            throw AIProviderError.invalidConfiguration("缺少 API 端点")
        }
        guard let base = RemoteEndpoint.base(endpoint) else {
            throw AIProviderError.invalidConfiguration("端点不是合法 URL")
        }
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw AIProviderError.invalidConfiguration("未填写 API Key")
        }
        return Resolved(config: config, base: base, apiKey: apiKey)
    }

    /// 带 Bearer 鉴权的请求（云端一律走系统代理，否则出不了网）。
    public static func request(
        url: URL,
        apiKey: String,
        method: String = "GET",
        contentType: String? = nil
    ) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    /// 模型列表地址（路径来自配置，兼容端点已含 `/v1` 的厂商）。
    public static func modelsURL(config: ProviderConfig, base: URL) -> URL {
        RemoteEndpoint.url(base: base, path: config.resolvedModelsPath)
    }

    // MARK: - 云端调用闸门（所有计费请求的唯一入口）
    //
    // 铁律：**一次操作 = 一个模型、一次请求**。
    // 任何发往云端、会产生费用的请求，都必须先过 `beginBillableCall`（准入）与
    // `endBillableCall`（记账）。没有例外，也不允许在 Adapter 里自己发计费请求。
    // 这样「只调用用户选定的模型」就是结构性保证，而不是靠自觉。

    /// 端点主机名（审计展示用，不含路径与密钥）。
    public static func host(of base: URL) -> String { base.host ?? base.absoluteString }

    /// 计费调用的统一前置：模型必须是**显式选定**的那个，且必须通过费用护栏。
    ///
    /// - Returns: 审计用的调用意图（请求结束后原样传回 `endBillableCall`）。
    /// - Throws: 没选模型 / 触发护栏时抛错——**此时请求一定没有发出去**。
    public static func beginBillableCall(
        kind: AIProviderKind,
        providerID: String,
        selectedModel: String?,
        providerModel: String?,
        base: URL,
        operation: RemoteCallPolicy.Operation
    ) async throws -> RemoteCallPolicy.Intent {
        guard let model = RemoteCallPolicy.resolvedModel(selected: selectedModel, providerDefault: providerModel),
              !model.isEmpty else {
            throw AIProviderError.invalidConfiguration(
                "未选择\(operation.displayName)模型：请先在设置里选定要调用的模型（应用不会自动改用候选列表里的其它模型）。"
            )
        }
        let intent = RemoteCallPolicy.Intent(
            kind: kind, providerID: providerID, model: model,
            host: host(of: base), operation: operation
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
            throw AIProviderError.invalidConfiguration("API Key 无效或已过期")
        }
        guard (200..<300).contains(response.statusCode) else {
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

    /// 云端健康检查：模型列表能拉到且（若已选模型）在列表里，才算就绪。
    public static func health(
        config: ProviderConfig,
        kind: AIProviderKind,
        client: HTTPClient
    ) async -> ProviderHealth {
        do {
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
    public static func ensureSuccess(statusCode: Int, data: Data) throws {
        guard !(200..<300).contains(statusCode) else { return }
        let body = String(data: data, encoding: .utf8)
        let message = (try? makeDecoder().decode(ErrorPayload.self, from: data))?.error?.message ?? body
        switch statusCode {
        case 401: throw AIProviderError.invalidConfiguration("API Key 无效或已过期")
        case 402: throw AIProviderError.invalidConfiguration("账户余额不足")
        case 404: throw AIProviderError.modelUnavailable(message ?? "模型不存在")
        case 408: throw AIProviderError.timeout(message ?? "请求超时")
        case 429: throw AIProviderError.serverError(status: statusCode, message: "请求过于频繁或额度受限")
        default: throw AIProviderError.serverError(status: statusCode, message: message)
        }
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
