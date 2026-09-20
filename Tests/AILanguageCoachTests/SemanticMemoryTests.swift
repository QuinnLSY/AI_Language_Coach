import AIDomain
import AIInterfaces
import AIInfrastructure
import AIProviders
import AIServices
import AppCore
import XCTest

/// 第 15 步（续）语义记忆：
/// - `SemanticRanking` 余弦相似度与排序（纯函数）；
/// - `MemoryRetriever.reranked` 的相关度裁剪；
/// - `EmbeddingManager` 的装配语义（mock **不**做语义排序）；
/// - 端到端：装配真实 runtime 的嵌入 Provider 后，不相关的历史被丢掉。
@MainActor
final class SemanticMemoryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 关键词驱动的确定性嵌入：维度 0 = 吃喝、维度 1 = 出行、维度 2 = 兜底常数。
    private final class StubEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
        let providerID = "stub.embedding"
        let kind: AIProviderKind = .embedding
        var dimensions: Int { 3 }
        private let state = ProviderStateBox()

        init(runtime: RuntimeKind = .ollama) { self.runtimeOverride = runtime }
        private let runtimeOverride: RuntimeKind

        func initialize(config: ProviderConfig) async throws { await state.setConfig(config) }
        func load() async throws {}
        func unload() async {}
        func healthCheck() async -> ProviderHealth { .connected(model: nil) }
        func capabilities() -> ProviderCapabilities { ProviderCapabilities(multilingual: true) }
        func metadata() -> ProviderMetadata {
            ProviderMetadata(id: providerID, displayName: "Stub", runtime: runtimeOverride)
        }

        func discoverModels() async throws -> [DiscoveredModel] {
            []
        }

        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { text in
                let lower = text.lowercased()
                var vector = [Float](repeating: 0, count: 3)
                if ["food", "eat", "apple", "restaurant", "lunch"].contains(where: lower.contains) { vector[0] = 1 }
                if ["travel", "trip", "london", "airport", "flight"].contains(where: lower.contains) { vector[1] = 1 }
                vector[2] = 0.1
                return vector
            }
        }
    }

    private func record(_ original: String, _ corrected: String, at date: Date) -> CorrectionRecord {
        CorrectionRecord(correction: GrammarCorrection(original: original, corrected: corrected, explanation: ""), createdAt: date)
    }

    // MARK: - 余弦相似度

    func testCosineSimilarityIdenticalAndOrthogonal() {
        XCTAssertEqual(SemanticRanking.cosineSimilarity([1, 0, 0], [1, 0, 0]), 1, accuracy: 1e-9)
        XCTAssertEqual(SemanticRanking.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 1e-9)
        XCTAssertEqual(SemanticRanking.cosineSimilarity([1, 0], [-1, 0]), -1, accuracy: 1e-9)
    }

    func testCosineSimilarityDegradesSafely() {
        // 维度不一致 / 零向量 → 0（无法比较），绝不能是 NaN。
        XCTAssertEqual(SemanticRanking.cosineSimilarity([1, 0, 0], [1, 0]), 0)
        XCTAssertEqual(SemanticRanking.cosineSimilarity([0, 0], [1, 1]), 0)
        XCTAssertEqual(SemanticRanking.cosineSimilarity([], []), 0)
    }

    func testRankingOrdersAndDropsBelowFloor() {
        let ranked = SemanticRanking.ranking(
            query: [1, 0],
            candidates: [(key: "far", vector: [0, 1]), (key: "near", vector: [1, 0])],
            floor: 0.5
        )
        XCTAssertEqual(ranked.map(\.key), ["near"], "低于 floor 的候选应被丢掉")
        XCTAssertEqual(ranked.first?.score ?? 0, 1, accuracy: 1e-9)
    }

    // MARK: - 相关度裁剪

    func testRerankedDropsIrrelevantAndKeepsRelevant() {
        let memory = LearningMemory(
            recurringErrors: [
                RecurringError(original: "I go to London", corrected: "I went to London", explanation: "", count: 1, lastSeen: now),
                RecurringError(original: "I eat apple", corrected: "I ate an apple", explanation: "", count: 1, lastSeen: now),
            ],
            focusWords: ["luggage", "lunch"]
        )
        let relevantID = memory.recurringErrors[1].id
        let pruned = MemoryRetriever.reranked(
            memory,
            relevance: [relevantID: 0.9, memory.recurringErrors[0].id: 0.01, "lunch": 0.8, "luggage": 0.0]
        )
        XCTAssertEqual(pruned.recurringErrors.map(\.corrected), ["I ate an apple"], "不相关的历史应被丢掉")
        XCTAssertEqual(pruned.focusWords, ["lunch"])
    }

    func testRerankedKeepsItemsMissingFromRelevance() {
        let memory = LearningMemory(
            recurringErrors: [RecurringError(original: "a", corrected: "b", explanation: "", count: 1, lastSeen: now)],
            focusWords: ["alpha"]
        )
        // 相关度字典缺失这两项：按 floor 保留、排最后，而不是误删。
        let pruned = MemoryRetriever.reranked(memory, relevance: ["other": 0.9])
        XCTAssertEqual(pruned.recurringErrors.count, 1)
        XCTAssertEqual(pruned.focusWords, ["alpha"])
    }

    func testRerankedNoopWithoutRelevance() {
        let memory = LearningMemory(focusWords: ["alpha"])
        XCTAssertEqual(MemoryRetriever.reranked(memory, relevance: [:]).focusWords, ["alpha"])
    }

    // MARK: - EmbeddingManager

    func testEmbeddingManagerRequiresRegistration() async {
        let manager = EmbeddingManager()
        let usable = await manager.isUsable
        let semantic = await manager.supportsSemanticRanking
        XCTAssertFalse(usable)
        XCTAssertFalse(semantic)
        do {
            _ = try await manager.embed(["hello"])
            XCTFail("未注册时应抛错")
        } catch {
            // 预期：不假装可用
        }
    }

    func testMockEmbeddingIsNotSemantic() async {
        let manager = EmbeddingManager()
        await manager.register(MockEmbeddingProvider())
        let usable = await manager.isUsable
        let semantic = await manager.supportsSemanticRanking
        XCTAssertTrue(usable)
        XCTAssertFalse(semantic, "mock 的向量没有语义，不得用于相关性排序")
    }

    func testRealRuntimeSupportsSemanticRanking() async {
        let manager = EmbeddingManager()
        await manager.register(StubEmbeddingProvider(runtime: .ollama))
        let semantic = await manager.supportsSemanticRanking
        let dimensions = await manager.dimensions
        XCTAssertTrue(semantic)
        XCTAssertEqual(dimensions, 3)
    }

    // MARK: - Adapter 配置校验

    func testOllamaEmbeddingAdapterRejectsMissingEndpoint() async {
        let adapter = OllamaEmbeddingAdapter(providerID: "ollama.embedding")
        do {
            try await adapter.initialize(config: ProviderConfig(id: "ollama.embedding", kind: .embedding, enabled: true, runtime: .ollama))
            XCTFail("缺少端点应报配置错误")
        } catch {
            // 预期
        }
    }

    // MARK: - 端到端：按当前话题裁剪历史

    func testServicesDropsOffTopicHistoryForQuery() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("semantic-probe-\(UUID().uuidString).json")
        )
        let services = CoachServices(config: store, databasePath: ":memory:")
        let opened = await services.learning
        let database = try XCTUnwrap(opened)
        let sessionID = UUID()
        try await database.createSessionIfAbsent(ChatSession(id: sessionID, startedAt: Date()))
        try await database.appendCorrection(
            GrammarCorrection(original: "I go to London", corrected: "I went to London", explanation: ""),
            sessionID: sessionID
        )
        try await database.appendCorrection(
            GrammarCorrection(original: "I eat apple", corrected: "I ate an apple", explanation: ""),
            sessionID: sessionID
        )
        // 装配一个**真实 runtime** 的嵌入 Provider（mock 会被自动排除）。
        await services.embedding.register(StubEmbeddingProvider(runtime: .ollama))

        let memory = await services.learningMemory(query: "I want to eat an apple for lunch")
        XCTAssertEqual(memory.recurringErrors.count, 1, "与吃喝无关的出行错误应被丢掉")
        XCTAssertEqual(memory.recurringErrors.first?.corrected, "I ate an apple")
    }

    func testServicesKeepsAllHistoryWithoutQuery() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("semantic-probe-\(UUID().uuidString).json")
        )
        let services = CoachServices(config: store, databasePath: ":memory:")
        let opened = await services.learning
        let database = try XCTUnwrap(opened)
        let sessionID = UUID()
        try await database.createSessionIfAbsent(ChatSession(id: sessionID, startedAt: Date()))
        try await database.appendCorrection(
            GrammarCorrection(original: "I go to London", corrected: "I went to London", explanation: ""),
            sessionID: sessionID
        )
        await services.embedding.register(StubEmbeddingProvider(runtime: .ollama))

        // 不给 query：结构化路径，不做任何语义裁剪。
        let memory = await services.learningMemory()
        XCTAssertEqual(memory.recurringErrors.count, 1)
    }
}
