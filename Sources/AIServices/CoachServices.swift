import AIDomain
import AIInfrastructure
import AIInterfaces
import AIProviders
import AppCore
import Foundation

/// 应用服务装配中心：根据配置创建并持有 Provider，UI / Agent 只依赖本类型。
public actor CoachServices {

    public let llm: LLMManager
    /// 学习数据库。打开失败时为 nil（功能降级为不持久化，不影响对话）。
    public private(set) var learning: LearningDatabase?
    private let config: ConfigStore
    private var llmProvider: (any LLMProvider)?

    public init(config: ConfigStore = .shared, llm: LLMManager = LLMManager(), databasePath: String? = nil) {
        self.config = config
        self.llm = llm
        let path = databasePath ?? LearningDatabase.defaultURL().path
        self.learning = try? LearningDatabase(path: path)
        if self.learning == nil {
            AppLog.warning("学习数据库打开失败，持久化已降级关闭: \(path)", category: "database")
        }
    }

    public var configuration: AppConfiguration {
        get async { await config.current }
    }
    public var configStore: ConfigStore { config }

    /// 按当前配置装配 LLM Provider（初始化 + 校验）。不抛错则可用。
    public func bootstrapLLM() async throws {
        let configuration = await config.current
        guard var providerConfig = configuration.enabledProvider(for: .llm) else {
            throw AppError.configuration("没有启用的 LLM Provider")
        }
        if let model = configuration.resolvedModel(for: .llm) {
            providerConfig.model = model
        }
        let provider = Self.makeLLMProvider(providerConfig)
        try await provider.initialize(config: providerConfig)
        // load 失败（如 runtime 未启动）不阻断启动：UI 需展示明确状态。
        try? await provider.load()
        llmProvider = provider
        await llm.register(provider)
    }

    /// 高级设置：修改 LLM Provider 的端点 / 温度后重新装配。
    public func setLLMProviderField(endpoint: String? = nil, temperature: Double? = nil) async throws {
        let configuration = await config.current
        guard var provider = configuration.enabledProvider(for: .llm) else {
            throw AppError.configuration("没有启用的 LLM Provider")
        }
        if let endpoint { provider.endpoint = endpoint }
        if let temperature { provider.temperature = temperature }
        try await config.updateProvider(provider)
        try await bootstrapLLM()
    }

    /// 统一的产品配置写入口（避免 UI 直接访问 ConfigStore）。
    public func updateProduct(_ product: ProductConfig) async throws {
        try await config.updateProduct(product)
    }

    public func switchLLMModel(_ model: String) async throws {
        try await config.selectModel(model, for: .llm)
        try await bootstrapLLM()
    }

    /// runtime 发现优先；不可用时降级为配置候选列表。
    public func availableLLMModels() async -> [DiscoveredModel] {
        var result: [DiscoveredModel] = []
        if let provider = llmProvider, let discovered = try? await provider.discoverModels() {
            result = discovered
        }
        if result.isEmpty {
            let configuration = await config.current
            let candidates = configuration.enabledProvider(for: .llm)?.candidateModels ?? []
            result = candidates.map { DiscoveredModel(id: $0, name: $0) }
        }
        return result
    }

    public func currentLLMModel() async -> String? {
        await config.current.resolvedModel(for: .llm)
    }

    public func llmHealth() async -> ProviderHealth {
        await llm.healthCheck()
    }

    // MARK: - 学习进度（数据库）

    /// 读进度；首次启动（无记录）时写入种子关卡并返回。
    public func loadProgress() async -> LearnerProgress {
        guard let learning else { return .seed() }
        if let saved = try? await learning.loadProgress() {
            return saved
        }
        let seed = LearnerProgress.seed()
        try? await learning.saveProgress(seed)
        return seed
    }

    public func saveProgress(_ progress: LearnerProgress) async {
        guard let learning else { return }
        try? await learning.saveProgress(progress)
    }

    // MARK: - 会话持久化（ChatService 使用）

    public func persistSession(_ session: ChatSession) async {
        guard let learning else { return }
        try? await learning.createSession(session)
    }

    public func persistMessage(_ message: ChatMessage, sessionID: UUID) async {
        guard let learning else { return }
        try? await learning.appendMessage(message, sessionID: sessionID)
    }

    public func finishSession(_ sessionID: UUID) async {
        guard let learning else { return }
        try? await learning.finishSession(id: sessionID)
    }

    public func persistCorrection(_ correction: GrammarCorrection, sessionID: UUID) async {
        guard let learning else { return }
        try? await learning.appendCorrection(correction, sessionID: sessionID)
    }

    public func recentCorrections(limit: Int = 50) async -> [GrammarCorrection] {
        guard let learning else { return [] }
        return (try? await learning.recentCorrections(limit: limit)) ?? []
    }

    public func recentSessions(limit: Int = 20) async -> [SessionSummary] {
        guard let learning else { return [] }
        return (try? await learning.recentSessions(limit: limit)) ?? []
    }

    public func sessionSummary(id: UUID) async -> SessionSummary? {
        guard let learning else { return nil }
        return try? await learning.sessionSummary(id: id)
    }

    // MARK: - 缓存管理（设置页）

    public func cacheSnapshot() async -> CacheSnapshot {
        CacheManager.snapshot()
    }

    /// 清理缓存，返回清理前的快照（供 UI 展示释放量）。
    @discardableResult
    public func clearCaches() async -> CacheSnapshot {
        await CacheManager.clearCaches(database: learning)
    }

    // MARK: - Provider 工厂（唯一允许 new 出 Adapter 的地方）

    private static func makeLLMProvider(_ config: ProviderConfig) -> any LLMProvider {
        switch config.runtime {
        case .ollama:
            OllamaLLMAdapter(providerID: config.id)
        case .mock:
            MockLLMProvider(providerID: config.id)
        default:
            // 其余 runtime（MLX / llama.cpp / python_process）V1 未实现 → 降级为 Mock，
            // 保证架构可跑通且不会编译期缺实现。
            MockLLMProvider(providerID: config.id)
        }
    }
}
