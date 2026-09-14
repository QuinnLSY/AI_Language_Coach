import AIDomain
import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

/// Ollama LLM Adapter。
///
/// 契约来源：`AGENTS.md §0.2` —— 对 Ollama v0.33.3 真实 runtime 实测所得。
/// 所有 Ollama 专属细节（URL、JSON、模型名）只允许出现在本文件内。
public final class OllamaLLMAdapter: LLMProvider, @unchecked Sendable {

    public let providerID: String
    public let kind: AIProviderKind = .llm

    private let state = ProviderStateBox()
    private let client: HTTPClient

    /// 配置声明的视觉能力（多模态输入）。默认 false：没声明就不内联图片 ——
    /// 本地纯文本模型（qwen3:8b 这类）收到 `image_url` 会直接报错。
    /// 要用 llava / qwen2-vl 这类模型读图时，在配置里给该 Provider 声明 `"vision": true`。
    private nonisolated(unsafe) var declaredVision = false

    public init(providerID: String = "ollama.llm", client: HTTPClient = HTTPClient()) {
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
        declaredVision = config.vision ?? false
        await state.setConfig(config)
        await state.setLifecycle(.initialized)
    }

    /// Ollama 自己管理模型权重，这里只做「runtime 可达性 + 模型可用性校验 + 建连」，
    /// **禁止**在本进程重复加载模型文件（AGENTS.md §3B / v2.0）。
    public func load() async throws {
        guard let config = await state.currentConfig else { throw AIProviderError.notInitialized }
        let health = await healthCheck()
        switch health {
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
        _ = config
    }

    public func unload() async { await state.setLifecycle(.unloaded) }

    public func healthCheck() async -> ProviderHealth {
        guard let config = await state.currentConfig else {
            return .configurationInvalid(reason: "尚未初始化")
        }
        guard let endpoint = config.endpoint, let base = Self.normalizedBase(endpoint) else {
            return .configurationInvalid(reason: "端点缺失或非法")
        }

        let request = URLRequest(url: base.appendingPathComponent("v1/models"))
        do {
            let (data, response) = try await client.perform(request, timeout: config.requestTimeout ?? 10)
            guard (200..<300).contains(response.statusCode) else {
                return .requestFailed(reason: "HTTP \(response.statusCode)")
            }
            let list = try Self.makeDecoder().decode(OllamaModelList.self, from: data)
            let ids = Set(list.data.map(\.id))
            guard let model = config.model, !model.isEmpty else {
                return .connected(model: nil)
            }
            // Ollama 的 id 带 `:latest` 后缀，需做等价比较。
            if ids.contains(model) || ids.contains("\(model):latest") {
                return .connected(model: model)
            }
            return .modelUnavailable(model: model)
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
        ProviderCapabilities(
            streaming: true, structuredOutput: false,
            vision: declaredVision, multilingual: true
        )
    }

    public func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "本地大模型", runtime: .ollama)
    }

    public func llmCapabilities() -> LLMCapabilities {
        LLMCapabilities(
            streaming: true, structuredOutput: false,
            vision: declaredVision, multilingual: true
        )
    }

    // MARK: - 生成

    public func generate(_ request: LLMRequest) async throws -> LLMResponse {
        let (config, base) = try await resolvedEndpoint()
        let model = try resolvedModel(request: request, config: config)

        var urlRequest = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try Self.makeEncoder().encode(
            OllamaChatRequest(
                model: model,
                messages: request.messages.map {
                    .init(
                        role: $0.role.rawValue,
                        content: RemoteCommon.chatContent(for: $0, inlineImages: declaredVision)
                    )
                },
                stream: false,
                temperature: request.temperature ?? config.temperature,
                topP: request.topP ?? config.topP,
                maxTokens: request.maxTokens ?? config.maxTokens,
                reasoningEffort: request.reasoningEffort
            )
        )

        let (data, response) = try await client.perform(urlRequest, timeout: config.requestTimeout ?? 120)
        try Self.ensureSuccess(statusCode: response.statusCode, data: data)

        let decoded = try Self.decode(OllamaChatCompletion.self, from: data)
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
            reasoning: choice.message?.reasoning
        )
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (config, base) = try await resolvedEndpoint()
                    let model = try resolvedModel(request: request, config: config)

                    var urlRequest = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = try Self.makeEncoder().encode(
                        OllamaChatRequest(
                            model: model,
                            messages: request.messages.map {
                                .init(
                                    role: $0.role.rawValue,
                                    content: RemoteCommon.chatContent(for: $0, inlineImages: self.declaredVision)
                                )
                            },
                            stream: true,
                            temperature: request.temperature ?? config.temperature,
                            topP: request.topP ?? config.topP,
                            maxTokens: request.maxTokens ?? config.maxTokens,
                            reasoningEffort: request.reasoningEffort
                        )
                    )

                    let decoder = Self.makeDecoder()
                    for try await payload in client.streamSSE(urlRequest, timeout: config.requestTimeout ?? 120) {
                        guard let payloadData = payload.data(using: .utf8) else { continue }
                        let chunk: OllamaChatCompletion
                        do {
                            chunk = try decoder.decode(OllamaChatCompletion.self, from: payloadData)
                        } catch {
                            throw AIProviderError.invalidResponse("流式块解析失败")
                        }
                        guard let choice = chunk.choices.first else { continue }
                        let role = choice.delta?.role.flatMap { ChatRole(rawValue: $0) }
                        let text = choice.delta?.content ?? ""
                        continuation.yield(
                            LLMChunk(
                                textDelta: text,
                                role: role,
                                finishReason: choice.finishReason,
                                reasoningDelta: choice.delta?.reasoning
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func discoverModels() async throws -> [DiscoveredModel] {
        let (_, base) = try await resolvedEndpoint()
        var request = URLRequest(url: base.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"

        let (data, response) = try await client.perform(request, timeout: 10)
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.serverError(status: response.statusCode, message: String(data: data, encoding: .utf8))
        }
        let list = try Self.decode(OllamaModelList.self, from: data)

        // 补充能力信息（Ollama 原生 /api/tags 带 capabilities / context_length），失败则忽略。
        var embeddingOnly = Set<String>()
        var contextLengths: [String: Int] = [:]
        if let tags = try? await fetchTags(base: base) {
            for model in tags.models {
                if let capabilities = model.capabilities, capabilities.contains("embedding"), !capabilities.contains("completion") {
                    embeddingOnly.insert(model.name)
                }
                if let length = model.contextLength, length > 0 {
                    contextLengths[model.name] = length
                }
            }
        }

        return list.data.map { item in
            DiscoveredModel(
                id: item.id,
                name: item.id,
                isEmbeddingOnly: embeddingOnly.contains(item.id),
                contextLength: contextLengths[item.id] ?? contextLengths["\(item.id):latest"]
            )
        }
    }

    // MARK: - 内部

    private func fetchTags(base: URL) async throws -> OllamaTagsResponse {
        let request = URLRequest(url: base.appendingPathComponent("api/tags"))
        let (data, response) = try await client.perform(request, timeout: 10)
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.serverError(status: response.statusCode, message: nil)
        }
        return try Self.decode(OllamaTagsResponse.self, from: data)
    }

    private func resolvedEndpoint() async throws -> (ProviderConfig, URL) {
        guard let config = await state.currentConfig else { throw AIProviderError.notInitialized }
        guard let endpoint = config.endpoint, let base = Self.normalizedBase(endpoint) else {
            throw AIProviderError.invalidConfiguration("端点缺失或非法")
        }
        return (config, base)
    }

    private func resolvedModel(request: LLMRequest, config: ProviderConfig) throws -> String {
        let model = request.model ?? config.model ?? config.candidateModels.first
        guard let model, !model.isEmpty else {
            throw AIProviderError.invalidConfiguration("未指定模型")
        }
        return model
    }

    private static func normalizedBase(_ endpoint: String) -> URL? {
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }

    private static func ensureSuccess(statusCode: Int, data: Data) throws {
        guard !(200..<300).contains(statusCode) else { return }
        let message = (try? makeDecoder().decode(OllamaErrorPayload.self, from: data))?.error.message
            ?? String(data: data, encoding: .utf8)
        switch statusCode {
        case 400: throw AIProviderError.invalidRequest(message ?? "请求无效")
        case 404:
            if let message, message.localizedCaseInsensitiveContains("not found") {
                throw AIProviderError.modelUnavailable(message)
            }
            throw AIProviderError.invalidRequest(message ?? "资源不存在")
        case 408: throw AIProviderError.timeout(message ?? "请求超时")
        case 500..<600: throw AIProviderError.serverError(status: statusCode, message: message)
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

    // MARK: - Ollama 传输结构（仅本文件可见）

    private struct OllamaChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let temperature: Double?
        let topP: Double?
        let maxTokens: Int?
        /// 推理强度覆盖。`"none"` 会让推理模型跳过思考段——实测同一句翻译
        /// 24.8s → 1.4s（见 `LLMRequest.reasoningEffort`）。nil 时不发该字段。
        let reasoningEffort: String?

        struct Message: Encodable {
            let role: String
            /// 纯文本是字符串；带图片时是 parts 数组（Ollama 的 OpenAI 兼容层同样接受）。
            let content: RemoteCommon.ChatMessageContent
        }
    }

    /// 实测字段（Ollama 0.33.3，见 AGENTS.md §0.2）。可选字段一律可选解。
    private struct OllamaChatCompletion: Decodable {
        let id: String?
        let object: String?
        let created: Int?
        let model: String
        let systemFingerprint: String?
        let choices: [Choice]
        let usage: Usage?

        struct Choice: Decodable {
            let index: Int?
            let message: Message?
            let delta: Delta?
            let finishReason: String?
        }

        struct Message: Decodable {
            let role: String?
            let content: String?
            // 实测：推理模型会额外返回 reasoning（deepseek-r1:7b / Ollama 0.33.3）
            let reasoning: String?
        }

        struct Delta: Decodable {
            let role: String?
            let content: String?
            let reasoning: String?
        }

        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let totalTokens: Int?
        }
    }

    private struct OllamaModelList: Decodable {
        let object: String?
        let data: [Item]

        struct Item: Decodable {
            let id: String
            let object: String?
            let ownedBy: String?
        }
    }

    private struct OllamaTagsResponse: Decodable {
        let models: [Item]

        struct Item: Decodable {
            let name: String
            let capabilities: [String]?
            let contextLength: Int?
        }
    }

    private struct OllamaErrorPayload: Decodable {
        let error: Detail

        struct Detail: Decodable {
            let message: String
            let type: String?
            let param: String?
            let code: String?
        }
    }
}

// MARK: - 本地模型服务的后台启停（设置页「启动 / 关闭」按钮）
//
// 实测（Ollama 0.33.3，2026-09-10）：
//   POST /api/generate  {"model":"qwen3:8b","keep_alive":0}      → 立即卸载，done_reason="unload"
//   POST /api/generate  {"model":"qwen3:8b","keep_alive":"30m"}  → 载入显存，done_reason="load"（约 1.4s）
// 不带 prompt 时不会产生任何推理开销，正是「启动 / 关闭」需要的语义。

extension OllamaLLMAdapter: ModelServiceControlling {

    /// 让 Ollama 把模型权重载入内存，随时可以对话。
    /// 若 Ollama 本身没在运行，用配置里的启动命令把它拉起来后重试一次。
    public func startModelService() async throws {
        do {
            try await setKeepAlive(.duration(Self.loadKeepAlive))
            return
        } catch {
            let config = try await resolvedEndpoint().0
            let command = (config.serviceStartCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { throw error }
            // 拉起本机服务（并等它开始接受连接），然后再载入模型。
            try await LocalServiceControl.start(config: config)
            try await setKeepAlive(.duration(Self.loadKeepAlive))
        }
    }

    /// 让 Ollama 立即卸载模型：后台下线、不再占用显存。
    /// 服务本来就没在跑 = 已经处于关闭状态，视为成功（幂等）。
    public func stopModelService() async throws {
        do {
            try await setKeepAlive(.seconds(0))
        } catch let error as AIProviderError {
            switch error {
            case .connectionFailed, .timeout, .runtimeUnavailable: return
            default: throw error
            }
        }
    }

    private func setKeepAlive(_ keepAlive: OllamaKeepAlive) async throws {
        let (config, base) = try await resolvedEndpoint()
        guard let model = config.model ?? config.candidateModels.first, !model.isEmpty else {
            throw AIProviderError.invalidConfiguration("未指定模型")
        }
        var request = URLRequest(url: base.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeEncoder().encode(
            OllamaLoadRequest(model: model, keepAlive: keepAlive)
        )
        let (data, response) = try await client.perform(request, timeout: config.requestTimeout ?? 120)
        try Self.ensureSuccess(statusCode: response.statusCode, data: data)
    }

    /// 启动后的保留时长：够长，避免刚启动就被回收（用户还能手动关闭）。
    private static let loadKeepAlive = "30m"
}

/// Ollama 载入 / 卸载请求体（仅本文件可见）。
private struct OllamaLoadRequest: Encodable {
    let model: String
    let keepAlive: OllamaKeepAlive
}

/// `keep_alive` 允许数字（秒，0 = 立即卸载）或时长字符串（"30m"）。
private enum OllamaKeepAlive: Encodable {
    case seconds(Int)
    case duration(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .seconds(let value): try container.encode(value)
        case .duration(let value): try container.encode(value)
        }
    }
}
