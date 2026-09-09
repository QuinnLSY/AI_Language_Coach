import AIDomain
import AIInfrastructure
import AIInterfaces
import AIProviders
import AppCore
import Foundation

/// 应用服务装配中心：根据配置创建并持有 Provider，UI / Agent 只依赖本类型。
public actor CoachServices {

    public let llm: LLMManager
    /// 语音识别（ASR）统一入口。
    public let asr: ASRManager
    /// 语音合成（TTS）统一入口。
    public let tts: TTSManager
    /// 语音能力（录音/识别/朗读）——UI 只认它。
    public let voice: VoiceService

    /// 学习数据库。打开失败时为 nil（功能降级为不持久化，不影响对话）。
    public private(set) var learning: LearningDatabase?
    private let config: ConfigStore
    private var llmProvider: (any LLMProvider)?

    public init(config: ConfigStore = .shared, llm: LLMManager = LLMManager(), databasePath: String? = nil) {
        self.config = config
        self.llm = llm
        self.asr = ASRManager()
        self.tts = TTSManager()
        self.voice = VoiceService(asr: self.asr, tts: self.tts)
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
        guard var providerConfig = configuration.resolvedProvider(for: .llm) else {
            throw AppError.configuration("没有可用的 LLM Provider")
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

    /// 装配语音能力（ASR + TTS）。**语音是可选能力**：runtime 没启动也不阻断应用。
    @discardableResult
    public func bootstrapVoice() async -> (asr: ProviderHealth, tts: ProviderHealth) {
        let configuration = await config.current
        let asrHealth = await bootstrapASR(configuration)
        let ttsHealth = await bootstrapTTS(configuration)
        if ttsHealth.isUsable { _ = await voice.refreshVoices() }
        return (asrHealth, ttsHealth)
    }

    private func bootstrapASR(_ configuration: AppConfiguration) async -> ProviderHealth {
        guard let providerConfig = Self.preferredProvider(.asr, in: configuration) else {
            return .configurationInvalid(reason: "没有启用的语音识别 Provider")
        }
        let provider = Self.makeASRProvider(providerConfig)
        do {
            try await provider.initialize(config: providerConfig)
        } catch {
            return .configurationInvalid(reason: error.localizedDescription)
        }
        try? await provider.load()
        await asr.register(provider)
        return await provider.healthCheck()
    }

    private func bootstrapTTS(_ configuration: AppConfiguration) async -> ProviderHealth {
        guard let providerConfig = Self.preferredProvider(.tts, in: configuration) else {
            return .configurationInvalid(reason: "没有启用的教师语音 Provider")
        }
        let provider = Self.makeTTSProvider(providerConfig)
        do {
            try await provider.initialize(config: providerConfig)
        } catch {
            return .configurationInvalid(reason: error.localizedDescription)
        }
        try? await provider.load()
        await tts.register(provider)
        return await provider.healthCheck()
    }

    /// 同类 Provider 中优先选真实 runtime；只有 mock 时才用 mock。
    private static func preferredProvider(_ kind: AIProviderKind, in configuration: AppConfiguration) -> ProviderConfig? {
        let candidates = configuration.providers.filter { $0.kind == kind && $0.enabled }
        return candidates.first { $0.runtime != .mock } ?? candidates.first
    }

    public func asrHealth() async -> ProviderHealth { await asr.healthCheck() }
    public func ttsHealth() async -> ProviderHealth { await tts.healthCheck() }
    public func availableVoices() async -> [String] { await voice.refreshVoices() }

    /// 高级设置：修改 LLM Provider 的端点 / 温度后重新装配。
    public func setLLMProviderField(endpoint: String? = nil, temperature: Double? = nil) async throws {
        let configuration = await config.current
        guard var provider = configuration.resolvedProvider(for: .llm) else {
            throw AppError.configuration("没有可用的 LLM Provider")
        }
        if let endpoint { provider.endpoint = endpoint }
        if let temperature { provider.temperature = temperature }
        try await config.updateProvider(provider)
        try await bootstrapLLM()
    }

    /// 切换激活的 LLM Provider（本地 / 云端并存，二选一生效）。
    /// 同时把产品层选中模型对齐到该 Provider 的默认模型，避免跨 Provider 串模型名。
    public func switchLLMProvider(_ providerID: String) async throws {
        let configuration = await config.current
        guard let target = configuration.providers.first(where: { $0.id == providerID && $0.kind == .llm }) else {
            throw AppError.configuration("找不到 LLM Provider：\(providerID)")
        }
        var product = configuration.product
        for var provider in configuration.providers where provider.kind == .llm {
            provider.enabled = provider.id == providerID
            try await config.updateProvider(provider)
        }
        product.activateProvider(providerID, for: .llm)
        product.selectModel(target.model ?? target.candidateModels.first, for: .llm)
        try await config.updateProduct(product)
        try await bootstrapLLM()
    }

    /// 校验云端 API Key 并拉取可用模型（不落盘，仅探测）。
    public func fetchRemoteModels(providerID: String, apiKey: String) async throws -> [DiscoveredModel] {
        let configuration = await config.current
        guard var providerConfig = configuration.providers.first(where: { $0.id == providerID && $0.kind == .llm }) else {
            throw AppError.configuration("找不到 LLM Provider：\(providerID)")
        }
        providerConfig.apiKey = apiKey
        let provider = RemoteLLMAdapter(providerID: providerConfig.id)
        try await provider.initialize(config: providerConfig)
        return try await provider.discoverModels()
    }

    /// 保存云端 Provider 的 API Key / 模型 / 推理强度，并激活 + 重装配。
    public func applyRemoteLLM(providerID: String, apiKey: String, model: String, reasoningEffort: String?) async throws {
        let configuration = await config.current
        guard var provider = configuration.providers.first(where: { $0.id == providerID && $0.kind == .llm }) else {
            throw AppError.configuration("找不到 LLM Provider：\(providerID)")
        }
        provider.apiKey = apiKey
        provider.model = model
        provider.reasoningEffort = reasoningEffort
        try await config.updateProvider(provider)
        try await switchLLMProvider(providerID)
    }

    /// 当前生效 LLM 的上下文窗口（token）。nil = 未知。
    public func contextWindow() async -> Int? {
        await config.current.contextWindow(for: .llm)
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
            let candidates = configuration.resolvedProvider(for: .llm)?.candidateModels ?? []
            result = candidates.map { DiscoveredModel(id: $0, name: $0) }
        }
        return result
    }

    /// 当前激活的 LLM Provider 配置（供 UI 展示名称 / 运行时类型）。
    public func activeLLMProvider() async -> ProviderConfig? {
        await config.current.resolvedProvider(for: .llm)
    }

    public func currentLLMModel() async -> String? {
        await config.current.resolvedModel(for: .llm)
    }

    /// 上次会话（含消息），供启动时恢复聊天框。没有历史时返回 nil。
    public func latestChatSession() async -> (session: ChatSession, messages: [ChatMessage])? {
        guard let learning else { return nil }
        return try? await learning.latestSession()
    }

    /// 当前生效 LLM 的推理强度（low / medium / high；nil = 标准）。
    public func activeReasoningEffort() async -> String? {
        await config.current.resolvedProvider(for: .llm)?.reasoningEffort
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

    private static func makeASRProvider(_ config: ProviderConfig) -> any ASRProvider {
        switch config.runtime {
        case .externalLocalRuntime:
            WhisperASRAdapter(providerID: config.id)
        default:
            MockASRProvider()
        }
    }

    private static func makeTTSProvider(_ config: ProviderConfig) -> any TTSProvider {
        switch config.runtime {
        case .externalLocalRuntime:
            Qwen3TTSAdapter(providerID: config.id)
        default:
            MockTTSProvider()
        }
    }

    private static func makeLLMProvider(_ config: ProviderConfig) -> any LLMProvider {
        switch config.runtime {
        case .ollama:
            OllamaLLMAdapter(providerID: config.id)
        case .remoteAPI:
            RemoteLLMAdapter(providerID: config.id)
        case .mock:
            MockLLMProvider(providerID: config.id)
        default:
            // 其余 runtime（MLX / llama.cpp / python_process）V1 未实现 → 降级为 Mock，
            // 保证架构可跑通且不会编译期缺实现。
            MockLLMProvider(providerID: config.id)
        }
    }
}
