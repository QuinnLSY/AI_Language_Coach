import AIDomain
import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

/// 云端 Embedding Adapter（记忆索引的远程调用）。
///
/// 与「AI 大脑 / 语音」的远端适配器同构：
/// - 模型列表发现复用 `RemoteCommon.discoverModels`（按能力过滤出 embedding-only）；
/// - **任何会产生费用的 `embed` 调用都必须过 `RemoteCommon.beginBillableCall` 闸门**，
///   这是架构红线（AGENTS.md §1）——绝不允许在适配器里自己发计费请求、绕过选模型 /
///   模型归属 / 频率护栏三道门。
///
/// 所有厂商地址、路径、模型名只允许出现在配置文件里；本文件不出现任何厂商字面量。
public final class RemoteEmbeddingAdapter: EmbeddingProvider, @unchecked Sendable {

    public let providerID: String
    public let kind: AIProviderKind = .embedding
    public private(set) var dimensions: Int

    private let state = ProviderStateBox()
    private let client: HTTPClient

    public init(
        providerID: String = "remote.embedding",
        dimensions: Int = 0,
        client: HTTPClient = HTTPClient(useSystemProxy: true)
    ) {
        self.providerID = providerID
        self.dimensions = max(dimensions, 1)
        self.client = client
    }

    // MARK: - 生命周期

    public func initialize(config: ProviderConfig) async throws {
        guard let endpoint = config.endpoint, !endpoint.isEmpty else {
            throw AIProviderError.invalidConfiguration("缺少 API 端点")
        }
        guard RemoteEndpoint.base(endpoint) != nil else {
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
        return await RemoteCommon.health(config: config, kind: .embedding, client: client)
    }

    public func capabilities() -> ProviderCapabilities {
        ProviderCapabilities(multilingual: true)
    }

    public func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "云端记忆索引", runtime: .remoteAPI)
    }

    // MARK: - 模型发现

    public func discoverModels() async throws -> [DiscoveredModel] {
        guard let config = await state.currentConfig else {
            throw AIProviderError.notInitialized
        }
        return try await RemoteCommon.discoverModels(config: config, kind: .embedding, client: client)
    }

    // MARK: - 嵌入（计费调用，必须过闸门）

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let config = try await resolvedConfig()
        let resolved = try RemoteCommon.resolve(config)
        // 闸门：模型必须显式选定且属于这家供应商，且通过费用护栏。
        // 没选模型 / 选了别家的 / 频率超限 —— 这里就拦下，绝不自作主张。
        let intent = try await RemoteCommon.beginBillableCall(
            kind: .embedding,
            providerID: providerID,
            selectedModel: config.model,
            providerModel: config.model,
            candidateModels: config.candidateModels,
            base: resolved.base,
            operation: .embeddings,
            billable: config.isBillable
        )

        var urlRequest = RemoteCommon.request(
            url: RemoteEndpoint.url(base: resolved.base, path: config.resolvedEmbeddingsPath),
            apiKey: resolved.apiKey,
            method: "POST",
            contentType: "application/json"
        )
        urlRequest.httpBody = try RemoteCommon.makeEncoder().encode(
            EmbedRequest(
                input: texts,
                model: intent.model ?? "",
                dimensions: config.dimensions
            )
        )

        let (data, response) = try await client.perform(urlRequest, timeout: config.requestTimeout ?? 60)

        let outcome: RemoteCallRecord.Outcome
        if (200..<300).contains(response.statusCode) {
            outcome = .ok
        } else {
            outcome = .httpError
            try RemoteCommon.ensureSuccess(
                statusCode: response.statusCode, data: data,
                url: urlRequest.url, apiKey: resolved.apiKey
            )
        }
        await RemoteCommon.endBillableCall(intent, outcome: outcome, httpStatus: response.statusCode)

        let decoded = try RemoteCommon.decode(EmbedResponse.self, from: data)
        let vectors = decoded.data.map(\.embedding)
        // 按真实返回值校准维度（首次调用即可纠正默认值）。
        if let first = vectors.first, !first.isEmpty {
            dimensions = first.count
        }
        // OpenAI 兼容接口：单条输入返回单条向量；多条输入返回等长数组。
        // 个别网关对多句也只回一条聚合向量，这里规整成与输入对齐。
        if vectors.count == 1, texts.count > 1 {
            return Array(repeating: vectors[0], count: texts.count)
        }
        return vectors
    }

    // MARK: - 内部

    private func resolvedConfig() async throws -> ProviderConfig {
        guard let config = await state.currentConfig else { throw AIProviderError.notInitialized }
        return config
    }

    private struct EmbedRequest: Encodable {
        let input: [String]
        let model: String
        let dimensions: Int?

        enum CodingKeys: String, CodingKey {
            case input, model, dimensions
        }
    }

    private struct EmbedResponse: Decodable {
        struct Item: Decodable {
            let embedding: [Float]
        }
        let data: [Item]
    }
}
