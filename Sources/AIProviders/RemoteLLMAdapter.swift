import AIDomain
import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

/// 云端 OpenAI 兼容 LLM Adapter（DeepSeek / OpenRouter 等）。
///
/// 三家协议差异只在 Adapter 内消化：
/// - 认证：`Authorization: Bearer <apiKey>`；
/// - 模型发现：`GET {base}/v1/models`（OpenRouter 额外返回 name / context_length）；
/// - 推理强度：`reasoning_effort`（low / medium / high），仅在用户选择时发送；
/// - 推理模型思考段：DeepSeek 用 `reasoning_content`，OpenRouter 用 `reasoning`，两者都解。
/// 配置来源：`remote.deepseek` / `remote.openrouter`（default-config.json）。
public final class RemoteLLMAdapter: LLMProvider, @unchecked Sendable {

    public let providerID: String
    public let kind: AIProviderKind = .llm

    private let state = ProviderStateBox()
    private let client: HTTPClient

    public init(providerID: String, client: HTTPClient = HTTPClient(useSystemProxy: true)) {
        self.providerID = providerID
        self.client = client
    }

    // MARK: - 生命周期

    public func initialize(config: ProviderConfig) async throws {
        guard let endpoint = config.endpoint, !endpoint.isEmpty else {
            throw AIProviderError.invalidConfiguration("缺少 API 端点")
        }
        guard URL(string: endpoint) != nil else {
            throw AIProviderError.invalidConfiguration("端点不是合法 URL")
        }
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw AIProviderError.invalidConfiguration("缺少 API Key")
        }
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }

    /// 云端 API 无需加载权重；load 只做可达性 + 模型可用性校验。
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
        guard let endpoint = config.endpoint, let base = Self.normalizedBase(endpoint) else {
            return .configurationInvalid(reason: "端点缺失或非法")
        }
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            return .configurationInvalid(reason: "未填写 API Key")
        }

        var request = URLRequest(url: base.appendingPathComponent("v1/models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await client.perform(request, timeout: config.requestTimeout ?? 15)
            if response.statusCode == 401 {
                return .configurationInvalid(reason: "API Key 无效或已过期")
            }
            guard (200..<300).contains(response.statusCode) else {
                return .requestFailed(reason: "HTTP \(response.statusCode)")
            }
            let list = try Self.decode(ModelList.self, from: data)
            let ids = Set(list.data.map(\.id))
            if let model = config.model, !model.isEmpty {
                return ids.contains(model) ? .connected(model: model) : .modelUnavailable(model: model)
            }
            return .connected(model: nil)
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
        ProviderCapabilities(streaming: true, structuredOutput: false, multilingual: true)
    }

    public func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "云端大模型", runtime: .remoteAPI)
    }

    public func llmCapabilities() -> LLMCapabilities {
        LLMCapabilities(streaming: true, structuredOutput: false, multilingual: true)
    }

    // MARK: - 生成

    public func generate(_ request: LLMRequest) async throws -> LLMResponse {
        let (config, base, apiKey) = try await resolved()
        // 铁律：只调用用户选定的模型（没选就拒绝），并留痕。
        let intent = try await RemoteCommon.beginBillableCall(
            kind: .llm,
            providerID: providerID,
            selectedModel: request.model ?? config.model,
            providerModel: config.model,
            base: base,
            operation: .chat
        )
        var urlRequest = try Self.chatRequest(
            base: base, apiKey: apiKey, request: request, config: config, stream: false
        )
        urlRequest.httpBody = try Self.makeEncoder().encode(
            Self.chatBody(request: request, config: config, stream: false, model: intent.model)
        )
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.perform(urlRequest, timeout: config.requestTimeout ?? 120)
        } catch {
            await RemoteCommon.endBillableCall(intent, outcome: .failed)
            throw error
        }
        do {
            try Self.ensureSuccess(statusCode: response.statusCode, data: data)
        } catch {
            await RemoteCommon.endBillableCall(intent, outcome: .httpError, httpStatus: response.statusCode)
            throw error
        }
        await RemoteCommon.endBillableCall(intent, outcome: .ok, httpStatus: response.statusCode)

        let decoded = try Self.decode(ChatCompletion.self, from: data)
        guard let choice = decoded.choices.first else {
            throw AIProviderError.invalidResponse("响应中没有 choices")
        }
        guard let content = choice.message?.content else {
            throw AIProviderError.invalidResponse("响应中没有消息内容")
        }
        return LLMResponse(
            text: content,
            model: decoded.model,
            finishReason: choice.finishReason,
            usage: decoded.usage.map {
                LLMUsage(promptTokens: $0.promptTokens, completionTokens: $0.completionTokens, totalTokens: $0.totalTokens)
            },
            reasoning: choice.message?.reasoning ?? choice.message?.reasoningContent
        )
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var intent: RemoteCallPolicy.Intent?
                do {
                    let (config, base, apiKey) = try await resolved()
                    let started = try await RemoteCommon.beginBillableCall(
                        kind: .llm,
                        providerID: self.providerID,
                        selectedModel: request.model ?? config.model,
                        providerModel: config.model,
                        base: base,
                        operation: .chat
                    )
                    intent = started
                    var urlRequest = try Self.chatRequest(
                        base: base, apiKey: apiKey, request: request, config: config, stream: true
                    )
                    urlRequest.httpBody = try Self.makeEncoder().encode(
                        Self.chatBody(request: request, config: config, stream: true, model: started.model)
                    )

                    let decoder = Self.makeDecoder()
                    for try await payload in client.streamSSE(urlRequest, timeout: config.requestTimeout ?? 120) {
                        guard let payloadData = payload.data(using: .utf8) else { continue }
                        let chunk: ChatCompletion
                        do {
                            chunk = try decoder.decode(ChatCompletion.self, from: payloadData)
                        } catch {
                            throw AIProviderError.invalidResponse("流式块解析失败")
                        }
                        guard let choice = chunk.choices.first else { continue }
                        let role = choice.delta?.role.flatMap { ChatRole(rawValue: $0) }
                        continuation.yield(
                            LLMChunk(
                                textDelta: choice.delta?.content ?? "",
                                role: role,
                                finishReason: choice.finishReason,
                                reasoningDelta: choice.delta?.reasoning ?? choice.delta?.reasoningContent
                            )
                        )
                    }
                    if let intent { await RemoteCommon.endBillableCall(intent, outcome: .ok) }
                    continuation.finish()
                } catch {
                    if let intent { await RemoteCommon.endBillableCall(intent, outcome: .failed) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 模型发现：`GET /v1/models`。OpenRouter 附带 name / context_length。
    public func discoverModels() async throws -> [DiscoveredModel] {
        let (config, base, apiKey) = try await resolved()
        var request = URLRequest(url: base.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await client.perform(request, timeout: config.requestTimeout ?? 20)
        if response.statusCode == 401 {
            throw AIProviderError.invalidConfiguration("API Key 无效或已过期")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.serverError(status: response.statusCode, message: String(data: data, encoding: .utf8))
        }
        await RemoteCommon.noteDiscovery(kind: .llm, providerID: providerID, base: base)
        let list = try Self.decode(ModelList.self, from: data)
        return list.data.map {
            DiscoveredModel(id: $0.id, name: $0.name ?? $0.id, contextLength: $0.contextLength)
        }
    }

    // MARK: - 内部

    private func resolved() async throws -> (ProviderConfig, URL, String) {
        guard let config = await state.currentConfig else { throw AIProviderError.notInitialized }
        guard let endpoint = config.endpoint, let base = Self.normalizedBase(endpoint) else {
            throw AIProviderError.invalidConfiguration("端点缺失或非法")
        }
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw AIProviderError.invalidConfiguration("未填写 API Key")
        }
        return (config, base, apiKey)
    }

    private static func chatRequest(base: URL, apiKey: String, request: LLMRequest, config: ProviderConfig, stream: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return urlRequest
    }

    /// 构造请求体。
    ///
    /// ⚠️ `model` 必须由调用方**显式传入**（来自闸门 `beginBillableCall` 的判定结果）。
    /// 历史实现写成 `request.model ?? config.model ?? config.candidateModels.first`——
    /// 在没有选中模型时会静默拿候选列表的第一个去发请求，那是本次费用事故里
    /// 最必须杜绝的行为，这里不再保留任何回退分支。
    private static func chatBody(request: LLMRequest, config: ProviderConfig, stream: Bool, model: String) -> ChatRequestBody {
        ChatRequestBody(
            model: model,
            messages: request.messages.map { .init(role: $0.role.rawValue, content: $0.content) },
            stream: stream,
            temperature: request.temperature ?? config.temperature,
            topP: request.topP ?? config.topP,
            maxTokens: request.maxTokens ?? config.maxTokens,
            reasoningEffort: config.reasoningEffort
        )
    }

    private static func normalizedBase(_ endpoint: String) -> URL? {
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }

    private static func ensureSuccess(statusCode: Int, data: Data) throws {
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

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw AIProviderError.invalidResponse(error.localizedDescription)
        }
    }

    // MARK: - 传输结构（仅本文件可见）

    private struct ChatRequestBody: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let temperature: Double?
        let topP: Double?
        let maxTokens: Int?
        /// low / medium / high；nil 时不出现在 JSON 里（服务端走默认行为）。
        let reasoningEffort: String?

        struct Message: Encodable {
            let role: String
            let content: String
        }

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature, topP, maxTokens, reasoningEffort
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(messages, forKey: .messages)
            try container.encode(stream, forKey: .stream)
            try container.encodeIfPresent(temperature, forKey: .temperature)
            try container.encodeIfPresent(topP, forKey: .topP)
            try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
            try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        }
    }

    private struct ChatCompletion: Decodable {
        let model: String
        let choices: [Choice]
        let usage: Usage?

        struct Choice: Decodable {
            let message: Message?
            let delta: Delta?
            let finishReason: String?
        }

        struct Message: Decodable {
            let role: String?
            let content: String?
            let reasoning: String?
            let reasoningContent: String?
        }

        struct Delta: Decodable {
            let role: String?
            let content: String?
            let reasoning: String?
            let reasoningContent: String?
        }

        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let totalTokens: Int?
        }
    }

    private struct ModelList: Decodable {
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
