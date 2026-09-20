import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

/// Ollama Embedding Adapter（本地语义索引）。
///
/// 走 Ollama 原生 `POST /api/embed`（一次可传多句，比逐句 `/api/embeddings` 省往返）。
/// 所有 Ollama 专属细节（URL、JSON、模型名）只允许出现在本文件内。
///
/// 维度：不同嵌入模型维度不同（nomic-embed-text 768 / bge-m3 1024 …），
/// 因此先给一个保守默认值，**首次成功嵌入后按实际长度校准**，不写死。
public final class OllamaEmbeddingAdapter: EmbeddingProvider, @unchecked Sendable {

    public let providerID: String
    public let kind: AIProviderKind = .embedding
    public private(set) var dimensions: Int

    private let state = ProviderStateBox()
    private let client: HTTPClient

    public init(
        providerID: String = "ollama.embedding",
        dimensions: Int = 768,
        client: HTTPClient = HTTPClient()
    ) {
        self.providerID = providerID
        self.dimensions = max(dimensions, 1)
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

    /// Ollama 自己管理模型，这里只做「runtime 可达 + 模型可用」校验，不在本进程加载权重。
    public func load() async throws {
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
        let request = URLRequest(url: base.appendingPathComponent("v1/models"))
        do {
            let (data, response) = try await client.perform(request, timeout: config.requestTimeout ?? 10)
            guard (200..<300).contains(response.statusCode) else {
                return .requestFailed(reason: "HTTP \(response.statusCode)")
            }
            let ids = Set(try Self.decode(OllamaEmbedModelList.self, from: data).data.map(\.id))
            guard let model = config.model, !model.isEmpty else { return .connected(model: nil) }
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
        ProviderCapabilities(multilingual: true)
    }

    public func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "本地记忆索引", runtime: .ollama)
    }

    // MARK: - 模型发现（与 OllamaLLMAdapter 同构）

    /// 列出本机 Ollama 中**可用于记忆索引**的模型：从 `/v1/models` 取全量，
    /// 再用 `/api/tags` 的 `capabilities` 过滤出 embedding-only 的模型。
    ///
    /// 这样设置页的「本地模型」下拉框就能直接看到 `nomic-embed-text` 这类嵌入模型，
    /// 与「AI 大脑」卡片的本地检测逻辑完全一致（区别只在过滤条件）。
    public func discoverModels() async throws -> [DiscoveredModel] {
        let (_, base) = try await resolvedEndpoint()
        var request = URLRequest(url: base.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"

        let (data, response) = try await client.perform(request, timeout: 10)
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.serverError(status: response.statusCode, message: String(data: data, encoding: .utf8))
        }
        let list = try Self.decode(OllamaEmbedModelList.self, from: data)

        // 补充能力信息：Ollama 原生 `/api/tags` 带 capabilities / context_length，失败则忽略。
        var embeddingOnly = Set<String>()
        var contextLengths: [String: Int] = [:]
        if let tags = try? await fetchTags(base: base) {
            for model in tags.models {
                if let capabilities = model.capabilities,
                   capabilities.contains("embedding"), !capabilities.contains("completion") {
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

    private func fetchTags(base: URL) async throws -> OllamaTagsResponse {
        let request = URLRequest(url: base.appendingPathComponent("api/tags"))
        let (data, response) = try await client.perform(request, timeout: 10)
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.serverError(status: response.statusCode, message: nil)
        }
        return try Self.decode(OllamaTagsResponse.self, from: data)
    }

    // MARK: - 嵌入

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let (config, base) = try await resolvedEndpoint()
        guard let model = config.model ?? config.candidateModels.first, !model.isEmpty else {
            throw AIProviderError.invalidConfiguration("未指定嵌入模型")
        }

        var request = URLRequest(url: base.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeEncoder().encode(OllamaEmbedRequest(model: model, input: texts))

        let (data, response) = try await client.perform(request, timeout: config.requestTimeout ?? 60)
        try Self.ensureSuccess(statusCode: response.statusCode, data: data)

        let decoded = try Self.decode(OllamaEmbedResponse.self, from: data)
        guard decoded.embeddings.count == texts.count else {
            throw AIProviderError.invalidResponse("嵌入数量与输入不一致")
        }
        // 按真实返回值校准维度（首次调用即可纠正默认值）。
        if let first = decoded.embeddings.first, !first.isEmpty {
            dimensions = first.count
        }
        return decoded.embeddings
    }

    // MARK: - 内部

    private func resolvedEndpoint() async throws -> (ProviderConfig, URL) {
        guard let config = await state.currentConfig else { throw AIProviderError.notInitialized }
        guard let endpoint = config.endpoint, let base = Self.normalizedBase(endpoint) else {
            throw AIProviderError.invalidConfiguration("端点缺失或非法")
        }
        return (config, base)
    }

    private static func normalizedBase(_ endpoint: String) -> URL? {
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }

    private static func ensureSuccess(statusCode: Int, data: Data) throws {
        guard !(200..<300).contains(statusCode) else { return }
        let message = (try? makeDecoder().decode(OllamaEmbedErrorPayload.self, from: data))?.error.message
            ?? String(data: data, encoding: .utf8)
        switch statusCode {
        case 400: throw AIProviderError.invalidRequest(message ?? "请求无效")
        case 404:
            if let message, message.localizedCaseInsensitiveContains("not found") {
                throw AIProviderError.modelUnavailable(message)
            }
            throw AIProviderError.invalidRequest(message ?? "资源不存在")
        case 408: throw AIProviderError.timeout(message ?? "请求超时")
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

    private struct OllamaEmbedRequest: Encodable {
        let model: String
        let input: [String]
    }

    private struct OllamaEmbedResponse: Decodable {
        let embeddings: [[Float]]
    }

    private struct OllamaEmbedModelList: Decodable {
        let data: [Item]

        struct Item: Decodable {
            let id: String
        }
    }

    /// Ollama `/api/tags` 返回（用于补齐 embedding-only 标记与上下文长度）。
    private struct OllamaTagsResponse: Decodable {
        let models: [Item]

        struct Item: Decodable {
            let name: String
            let capabilities: [String]?
            let contextLength: Int?
        }
    }

    private struct OllamaEmbedErrorPayload: Decodable {
        let error: Detail

        struct Detail: Decodable {
            let message: String
        }
    }
}
