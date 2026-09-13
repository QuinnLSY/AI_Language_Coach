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
    /// 练习复盘（学习记忆：一次练习 → 一份结构化总结）。
    private let reviewer: SessionReviewService
    /// 语音输入专用的拼写纠正（只作用于语音识别结果，手打不改）。
    private let spellingCorrector: SpellingCorrectionService
    /// 气泡翻译（按需 + 有界缓存）。
    private let translator: TranslationService
    /// 跟读（Shadowing，第 22 步）：示范 / 录音 / 回放 / 评测 / 落库。
    public let shadowing: ShadowingService
    /// 发音评测（Pronunciation，第 23 步）：从录音量语速 / 停顿 / 音高 / 音量起伏。
    public let pronunciation: PronunciationService
    /// 词汇本（Vocabulary，第 24 步）：生词导入 / 复习 / 按需释义。
    public let vocabulary: VocabularyService
    /// 学习进度（Dashboard，第 25 步）：会话 / 纠错 / 跟读 / 词汇按天汇总。
    public let progress: ProgressService

    /// 学习数据库。打开失败时为 nil（功能降级为不持久化，不影响对话）。
    public private(set) var learning: LearningDatabase?
    private let config: ConfigStore
    private var llmProvider: (any LLMProvider)?
    /// 场景目录缓存（资源文件，进程内读一次即可）。
    private var scenarioCache: [Scenario]?
    /// 进行中的 LLM 装配任务：并发调用只装配一次（见 `ensureLLMReady`）。
    private var llmReadyTask: Task<Void, Error>?
    /// 被用户显式「关闭」的模型能力。**仅进程内有效**：应用打开时全部为启动态。
    private var stoppedKinds: Set<AIProviderKind> = []
    /// 被资源管理**自动挂起**的能力（第 27 步）：与用户关闭语义不同——
    /// 挂起是省内存的临时状态，下次被使用时自动恢复（`resumeIfSuspended`）；
    /// 用户关闭是明确意图，绝不自动拉起。两者都让 `isModelRunning` 变 false。
    private var suspendedKinds: Set<AIProviderKind> = []

    public init(config: ConfigStore = .shared, llm: LLMManager = LLMManager(), databasePath: String? = nil) {
        self.config = config
        self.llm = llm
        self.asr = ASRManager()
        self.tts = TTSManager()
        self.voice = VoiceService(asr: self.asr, tts: self.tts)
        let path = databasePath ?? LearningDatabase.defaultURL().path
        let database = try? LearningDatabase(path: path)
        self.learning = database
        self.reviewer = SessionReviewService(llm: self.llm, learning: database)
        self.spellingCorrector = SpellingCorrectionService(llm: self.llm)
        self.translator = TranslationService(llm: self.llm)
        // 发音评测（第 23 步）：首版纯声学 + 文本对齐，不依赖任何发音模型；
        // 将来接入音素模型时，把 provider 从工厂装进 PronunciationService 即可。
        self.pronunciation = PronunciationService()
        self.shadowing = ShadowingService(voice: self.voice, pronunciation: self.pronunciation, learning: database)
        self.vocabulary = VocabularyService(llm: self.llm, learning: database)
        self.progress = ProgressService(learning: database)
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
        providerConfig = Self.fillServiceCommands(providerConfig)
        let provider = Self.makeLLMProvider(providerConfig)
        try await provider.initialize(config: providerConfig)
        // load 失败（如 runtime 未启动）不阻断启动：UI 需展示明确状态。
        try? await provider.load()
        llmProvider = provider
        await llm.register(provider)
    }

    /// **确保 LLM 已装配**。用户可能在应用还没启动完就发了消息 —— 那时 Provider 尚未注册，
    /// 请求会直接以「尚未初始化」失败，表现就是「老师说啥都不回」。
    /// 这里做一次幂等的装配（并发调用共享同一个任务），让首条消息自己把自己救回来。
    public func ensureLLMReady() async throws {
        if llmProvider != nil { return }
        if let existing = llmReadyTask {
            try await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { throw AIProviderError.notInitialized }
            try await self.bootstrapLLM()
        }
        llmReadyTask = task
        do {
            try await task.value
        } catch {
            // 失败不缓存：下次发送时应当重新尝试装配（例如用户刚启动了本地服务）。
            llmReadyTask = nil
            throw error
        }
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
        guard let raw = Self.preferredProvider(.asr, in: configuration) else {
            return .configurationInvalid(reason: "没有启用的语音识别 Provider")
        }
        var providerConfig = Self.fillServiceCommands(raw)
        if let model = configuration.resolvedModel(for: .asr) { providerConfig.model = model }
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
        guard let raw = Self.preferredProvider(.tts, in: configuration) else {
            return .configurationInvalid(reason: "没有启用的教师语音 Provider")
        }
        var providerConfig = Self.fillServiceCommands(raw)
        if let model = configuration.resolvedModel(for: .tts) { providerConfig.model = model }
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

    /// 某能力实际要装配的 Provider：**先认用户选中的那个（本地 / 云端二选一）**，
    /// 没选过再从启用的里面挑真实 runtime；只有 mock 时才用 mock。
    ///
    /// 这一步很关键：否则用户在设置里切到云端后，语音链路仍会挑到本地 runtime，
    /// 表现为「界面显示已启用云端，实际还是本地（或反过来的鬼打墙）」。
    private static func preferredProvider(_ kind: AIProviderKind, in configuration: AppConfiguration) -> ProviderConfig? {
        if let chosen = configuration.resolvedProvider(for: kind) { return chosen }
        let candidates = configuration.providers.filter { $0.kind == kind && $0.enabled }
        return candidates.first { $0.runtime != .mock } ?? candidates.first
    }

    public func asrHealth() async -> ProviderHealth { await asr.healthCheck() }
    public func ttsHealth() async -> ProviderHealth { await tts.healthCheck() }
    public func availableVoices() async -> [String] { await voice.refreshVoices() }

    /// 语音识别结果的拼写纠正（**仅语音输入使用**；手打内容一律不经过这里）。
    ///
    /// 失败/模型不可用时返回原文——语音输入不能被纠正步骤卡住。
    ///
    /// ⚠️ **只在本地语言模型上执行**。拼写纠正是「用户说完一句话」之后**自动**发生的，
    /// 用户既看不到、也不会预期它产生费用。如果语言模型是云端（按 token 计费），
    /// 一次语音输入就会多打一次云端请求 —— 本次事故里「点的是语音，账单里却出现
    /// 大量语言模型（glm 之类）」正是这条链路。所以云端一律跳过（直接返回原文），
    /// 语音输入的云端费用因此变得可推算：一次录音 = 一次识别，仅此而已。
    public func correctSpelling(_ text: String) async -> String {
        guard isModelRunning(.llm) else { return text }
        let configuration = await config.current
        let provider = configuration.resolvedProvider(for: .llm)
        guard provider?.isRemote != true else { return text }
        let options = SpellingCorrectionService.Options(
            model: configuration.resolvedModel(for: .llm),
            temperature: 0,
            maxTokens: min(provider?.maxTokens ?? 256, 256)
        )
        return await spellingCorrector.correct(text, options: options)
    }

    /// 拼写纠正当前的执行口径（设置页展示用，让「为什么没有纠正」有据可查）。
    public func spellingCorrectionNote() async -> String {
        let configuration = await config.current
        guard let provider = configuration.resolvedProvider(for: .llm) else {
            return "语音输入暂不做拼写纠正：还没有可用的语言模型。"
        }
        if provider.isRemote {
            return "已跳过拼写纠正：它发生在语音输入之后，云端按 token 计费会产生你看不见的费用。切到本地语言模型后自动启用。"
        }
        return "拼写纠正使用本地语言模型，不产生云端费用。"
    }

    /// 把一条对话内容翻译成学员的母语（**按需**：点翻译按钮才调用）。
    /// 结果有界缓存，重复点开不再产生请求；译文不进对话历史，不占上下文。
    public func translate(_ text: String, targetLanguage: String) async throws -> String {
        guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
        try await ensureLLMReady()
        let configuration = await config.current
        let provider = configuration.resolvedProvider(for: .llm)
        let options = TranslationService.Options(
            model: configuration.resolvedModel(for: .llm),
            temperature: 0,
            maxTokens: min(provider?.maxTokens ?? 512, 512)
        )
        return try await translator.translate(text, targetLanguage: targetLanguage, options: options)
    }

    /// 输入框的预设学员提问（数据来自资源文件，代码零硬编码）。
    public func starterQuestions() async -> [String] {
        StarterQuestionCatalog.bundled()
    }

    /// 高级设置：修改 LLM Provider 的端点 / 温度后重新装配。
    public func setLLMProviderField(endpoint: String? = nil, temperature: Double? = nil) async throws {
        let configuration = await config.current
        guard let provider = configuration.resolvedProvider(for: .llm) else {
            throw AppError.configuration("没有可用的 LLM Provider")
        }
        // 原子更新：只动高级设置里这两个字段，避免整条写回覆盖 apiKey 等。
        try await config.mutateProvider(id: provider.id) { p in
            if let endpoint { p.endpoint = endpoint }
            if let temperature { p.temperature = temperature }
        }
        try await bootstrapLLM()
    }

    /// 切换激活的 LLM Provider（本地 / 云端并存，二选一生效）。
    /// 同时把产品层选中模型对齐到该 Provider 的默认模型，避免跨 Provider 串模型名。
    public func switchLLMProvider(_ providerID: String) async throws {
        try await setCapabilityProvider(.llm, providerID: providerID)
    }

    /// 把**任意能力**切换到指定 Provider（本地或云端），同类其它 Provider 一律停用。
    ///
    /// 这是「切到本地模型后没有关掉外部模型接口」的修复点。旧行为是：选本地模型时
    /// 只把模型名写进**当前生效**的 Provider——而当前生效的往往是云端那家，
    /// 于是云端既没被关掉，还被写进了一个本地模型名（实测 `remote.siliconflow-asr`
    /// 的 model 变成了 `ggml-small.en`），界面也就显示成「SiliconFlow 语音识别 · ggml-small.en」。
    ///
    /// 现在「切换」= 真正换 Provider：
    /// - 同类只留目标这一个 `enabled`，其余全部停用（**外部模型接口就此关闭**）；
    /// - 云端 Provider 没有 Key 时直接拒绝，不允许出现「已启用却调不动」的状态；
    /// - 产品层选中模型对齐到该 Provider 自己配的模型，没配就清空
    ///   （交给云端闸门拒绝并提示用户去选，而不是拿候选清单第一个顶替）。
    public func setCapabilityProvider(_ kind: AIProviderKind, providerID: String) async throws {
        guard let target = await config.current.providers.first(where: { $0.id == providerID && $0.kind == kind }) else {
            throw AppError.configuration("找不到\(kind.displayName) Provider：\(providerID)")
        }
        let hasKey = !((target.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if target.isRemote, !hasKey {
            throw AppError.configuration(
                "请先填写 API Key 再启用「\(target.userFacingName)」：输入框为空时，应用不会使用任何已保存的旧密钥。"
            )
        }
        try await config.mutateProviders(kind: kind) { p in
            p.enabled = (p.id == providerID)
        }
        let aligned = (target.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try await config.mutateProduct { product in
            product.activateProvider(providerID, for: kind)
            product.selectModel(aligned.isEmpty ? nil : aligned, for: kind)
        }
        await rebootstrap(kind: kind)
    }

    /// 只更新某个 Provider 的 API Key（空 = 清除），不动 enabled / model / 产品层选择。
    ///
    /// 「记住密钥」的唯一形式是**用户把它填进了输入框**。输入框为空即视为不配置：
    /// 这里会把配置里的旧 Key 一并清掉，并让产品层不再指向一个没有 Key 的云端 Provider。
    @discardableResult
    public func setRemoteProviderKey(providerID: String, apiKey: String, kind: AIProviderKind) async throws -> Bool {
        guard await config.current.providers.contains(where: { $0.id == providerID && $0.kind == kind }) else {
            throw AppError.configuration("找不到 Provider：\(providerID)")
        }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try await config.mutateProvider(id: providerID) { p in
            p.apiKey = trimmed.isEmpty ? nil : trimmed
        }
        if trimmed.isEmpty {
            try await config.mutateProduct { product in
                if product.activeProvider(for: kind) == providerID {
                    product.selectModel(nil, for: kind)
                }
            }
        }
        return !trimmed.isEmpty
    }

    /// 校验云端 API Key 并拉取可用模型（不落盘，仅探测）。
    /// 各厂商均为 OpenAI 兼容协议，发现流程对任意能力（llm/asr/tts/…）通用。
    public func fetchRemoteModels(providerID: String, apiKey: String, kind: AIProviderKind = .llm) async throws -> [DiscoveredModel] {
        let configuration = await config.current
        guard var providerConfig = configuration.providers.first(where: { $0.id == providerID && $0.kind == kind }) else {
            throw AppError.configuration("找不到 Provider：\(providerID)")
        }
        providerConfig.apiKey = apiKey
        // 发现流程对任意能力通用（llm / asr / tts …）：同一套 OpenAI 兼容 `/models`，
        // 只是按能力过滤掉不属于这一类模型的条目（云端返回的是混合列表）。
        return try await RemoteCommon.discoverModels(
            config: providerConfig,
            kind: kind,
            client: HTTPClient(useSystemProxy: true)
        )
    }

    /// 记住某云端 Provider 探测到的模型列表（写进 `candidateModels`）。
    ///
    /// 探测本身仍是只读的（`fetchRemoteModels` 不写配置），但把结果留下来能让用户
    /// **重开设置时选择器直接可用**——否则「验证并获取模型」每次都要重点一遍。
    public func rememberRemoteModels(_ models: [DiscoveredModel], providerID: String, kind: AIProviderKind) async {
        let ids = models.map(\.id)
        guard !ids.isEmpty else { return }
        guard await config.current.providers.contains(where: { $0.id == providerID && $0.kind == kind }) else { return }
        try? await config.mutateProvider(id: providerID) { p in
            p.candidateModels = ids
        }
    }

    /// 拉取供应商自报的音色清单（`voice_list_path`，如 Edge TTS 代理的 `/voices`），
    /// 并把「音色 id → 友好名」写进配置（原子局部更新），UI 据此显示晓晓 / 云希这类名字。
    ///
    /// - 若配置里还没有静态音色清单，把探测结果补进去（选择器从此直接可用）。
    /// - 探测失败原样抛错：调用方（设置页）把错误显示给用户即可。
    @discardableResult
    public func discoverRemoteVoices(providerID: String, kind: AIProviderKind = .tts) async throws -> [RemoteVoiceCatalog.Voice] {
        let configuration = await config.current
        guard var providerConfig = configuration.providers.first(where: { $0.id == providerID && $0.kind == kind }) else {
            throw AppError.configuration("找不到 Provider：\(providerID)")
        }
        let voices = try await RemoteCommon.discoverVoices(config: providerConfig, client: HTTPClient(useSystemProxy: true))
        guard !voices.isEmpty else { return [] }
        let names = Dictionary(uniqueKeysWithValues: voices.map { ($0.id, $0.name) })
        let ids = voices.map(\.id)
        try? await config.mutateProvider(id: providerID) { p in
            p.voiceNames = names
            if (p.voices ?? []).isEmpty { p.voices = ids }
        }
        return voices
    }

    /// 配置里已存的音色友好名（id → 名字；没有则原样返回 id）。
    public func voiceLabel(providerID: String, voice: String, kind: AIProviderKind = .tts) async -> String {
        let configuration = await config.current
        guard let provider = configuration.providers.first(where: { $0.id == providerID && $0.kind == kind }) else {
            return voice
        }
        return provider.voiceLabel(for: voice) ?? voice
    }

    /// 某供应商是否**免密钥**（UI 据此隐藏 Key 输入框、放行无 Key 的接入）。
    public func isKeyless(providerID: String, kind: AIProviderKind) async -> Bool {
        let configuration = await config.current
        return configuration.providers.first { $0.id == providerID && $0.kind == kind }?.requiresAPIKey == false
    }

    /// 保存云端 Provider 的 API Key / 模型 / 推理强度，并把该能力切换到这个 Provider。
    ///
    /// **只写配置，不做重装配**（重装配见 `applyRemoteProvider`）。拆成两步是为了让
    /// 「配置到底写对没有」可以脱离 Provider 装配单独验证——历史上这里丢过 Key。
    public func persistRemoteProvider(providerID: String, apiKey: String, model: String,
                                      reasoningEffort: String? = nil, kind: AIProviderKind = .llm) async throws {
        guard await config.current.providers.contains(where: { $0.id == providerID && $0.kind == kind }) else {
            throw AppError.configuration("找不到 Provider：\(providerID)")
        }
        // ⚠️ API Key **以输入框内容为唯一真相**：输入框为空 = 用户没有配置 Key，
        // 这里就把已保存的 Key 一并清掉（连同产品层的选择）。
        //
        // 历史行为是「输入框为空则沿用配置里已保存的 Key」，于是界面上明明没填 Key，
        // 应用却仍拿旧 Key 去调用云端——用户明确禁止这种情况（2026-09-13 反馈）。
        // 记住一个 Key 的唯一形式是**把它填进输入框**，不是替用户保管。
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        // 全部走**原子局部更新**：每步都基于 actor 内的最新值，字段之间不会互相覆盖。
        // 顺序也有讲究——先改 enabled（会遍历同类所有 Provider），再写这个 Provider 的
        // Key/模型，最后动产品层。反过来写就会出现「enabled 循环把刚保存的 Key 抹掉」。
        try await config.mutateProviders(kind: kind) { p in
            p.enabled = (p.id == providerID)
        }
        try await config.mutateProvider(id: providerID) { p in
            p.apiKey = trimmedKey.isEmpty ? nil : trimmedKey
            p.model = trimmedModel.isEmpty ? nil : trimmedModel
            p.reasoningEffort = reasoningEffort
            // 用过的模型并入候选集：下次打开设置时选择器要能直接列出它，
            // 不必再点一次「验证并获取模型」才能切换（产品要求见需求 ①）。
            if !trimmedModel.isEmpty, !p.candidateModels.contains(trimmedModel) {
                p.candidateModels.insert(trimmedModel, at: 0)
            }
        }
        try await config.mutateProduct { product in
            product.activateProvider(providerID, for: kind)
            product.selectModel(trimmedModel.isEmpty ? nil : trimmedModel, for: kind)
        }
    }

    /// 保存云端 Provider 的 API Key / 模型 / 推理强度，并激活 + 重装配（任意能力通用）。
    public func applyRemoteProvider(providerID: String, apiKey: String, model: String,
                                    reasoningEffort: String? = nil, kind: AIProviderKind = .llm) async throws {
        try await persistRemoteProvider(
            providerID: providerID, apiKey: apiKey, model: model,
            reasoningEffort: reasoningEffort, kind: kind
        )
        await rebootstrap(kind: kind)
    }

    /// 按能力重装配（本地模型切换 / 云端激活后调用）。
    public func rebootstrap(kind: AIProviderKind) async {
        switch kind {
        case .llm:
            try? await bootstrapLLM()
        case .asr, .tts:
            _ = await bootstrapVoice()
        default:
            break // vad / embedding / pronunciation V1 尚无真实 runtime
        }
    }

    // MARK: - 模型启动 / 关闭（设置页）

    /// 某能力当前是否处于「启动」状态。
    ///
    /// 语义是**用户意图**：应用打开时所有模型默认为启动态（不会被持久化成关闭）。
    /// 用户显式关闭与资源管理挂起都算「没在运行」，但恢复路径不同（见 `suspendedKinds`）。
    public func isModelRunning(_ kind: AIProviderKind) -> Bool {
        !stoppedKinds.contains(kind) && !suspendedKinds.contains(kind)
    }

    /// 全部能力的启停快照（UI 展示用）。
    public func modelRunStates() -> [AIProviderKind: Bool] {
        var result: [AIProviderKind: Bool] = [:]
        for kind in AIProviderKind.allCases { result[kind] = isModelRunning(kind) }
        return result
    }

    /// 打开 / 关闭一个能力的模型。
    ///
    /// - 本地模型（实现了 `ModelServiceControlling`）：真的把后台服务拉起来 / 停掉。
    /// - 云端 / 内置模拟：只做应用层面的开关（外部服务无法被本应用终止）。
    ///
    /// - Returns: 面向用户的一句话说明（告诉用户刚才到底发生了什么）。
    @discardableResult
    public func setModelRunning(_ kind: AIProviderKind, running: Bool) async throws -> String {
        let configuration = await config.current
        let providerConfig = configuration.resolvedProvider(for: kind)
        let providerName = providerConfig?.userFacingName
        let model = configuration.resolvedModel(for: kind)
        let who = ModelDiagnostics.label(providerName: providerName, model: model)

        if running {
            stoppedKinds.remove(kind)
            suspendedKinds.remove(kind)
            if let controller = await serviceController(for: kind) {
                try await controller.startModelService()
                await rebootstrap(kind: kind)
                return "\(who) 已启动：后台服务已拉起。"
            }
            await rebootstrap(kind: kind)
            return "\(who) 已启动（应用层面）：本地无需启动服务。"
        }

        stoppedKinds.insert(kind)
        if let controller = await serviceController(for: kind) {
            do {
                try await controller.stopModelService()
                return "\(who) 已关闭：后台服务已下线，不再占用资源。"
            } catch {
                // 关闭失败也保持「关闭」状态（应用层面照样不再调用它），但把原因告诉用户。
                throw AppError.unknown(ModelDiagnostics.describe(providerName: providerName, model: model, error: error))
            }
        }
        return "\(who) 已关闭（应用层面）：不会再被调用。"
    }

    /// 该能力背后可真实启停的服务控制器；不支持时返回 nil。
    private func serviceController(for kind: AIProviderKind) async -> (any ModelServiceControlling)? {
        switch kind {
        case .llm: llmProvider as? any ModelServiceControlling
        case .asr: await asr.current as? any ModelServiceControlling
        case .tts: await tts.current as? any ModelServiceControlling
        default: nil
        }
    }

    // MARK: - 资源管理（第 27 步：ModelLifecycleManager 的落点）

    /// 资源管理自动挂起一个能力（区别于用户关闭：下次被使用时自动恢复）。
    ///
    /// 本地模型真的把后台服务停掉（复用「关闭」的服务控制链路，如 Ollama `keep_alive:0`）；
    /// 云端 / mock 只做应用层面挂起。返回面向用户的一句话说明。
    @discardableResult
    public func suspendModel(_ kind: AIProviderKind) async throws -> String {
        guard !stoppedKinds.contains(kind) else { return "\(await modelLabel(for: kind)) 已被用户关闭，无需挂起。" }
        guard !suspendedKinds.contains(kind) else { return "\(await modelLabel(for: kind)) 已处于挂起状态。" }

        suspendedKinds.insert(kind)
        if let controller = await serviceController(for: kind) {
            do {
                try await controller.stopModelService()
                return "\(await modelLabel(for: kind)) 已自动挂起：空闲释放资源，需要时会自动恢复。"
            } catch {
                // 停服务失败就退回启动态，避免「服务还在跑却显示挂起」的假状态。
                suspendedKinds.remove(kind)
                throw AppError.unknown("\(await modelLabel(for: kind)) 自动挂起失败：\(error.localizedDescription)")
            }
        }
        return "\(await modelLabel(for: kind)) 已自动挂起（应用层面）：不会再被调用。"
    }

    /// 若该能力被资源管理挂起，则自动恢复（拉起服务 + 重装配）。返回是否真的执行了恢复。
    ///
    /// 用户显式关闭的能力**不会**在这里被拉起（那是明确意图，交给用户自己点「启动」）。
    @discardableResult
    public func resumeIfSuspended(_ kind: AIProviderKind) async throws -> Bool {
        guard suspendedKinds.contains(kind) else { return false }
        _ = try await setModelRunning(kind, running: true)
        return true
    }

    /// 资源管理视角下各能力的快照（供 `ResourcePolicy` 决策）。
    public func resourceStates() async -> [ResourcePolicy.ModelState] {
        var states: [ResourcePolicy.ModelState] = []
        for kind in AIProviderKind.allCases {
            // 云端 Provider 挂不挂是外部服务的事，本应用无从「释放内存」；
            // 没有真实服务控制器的（云端 / mock / 未装配）一律视为不可挂起。
            let unloadable = await serviceController(for: kind) != nil
            let idle: Double?
            switch kind {
            case .llm: idle = await llm.idleSeconds
            case .asr: idle = await asr.idleSeconds
            case .tts: idle = await tts.idleSeconds
            default: idle = nil
            }
            states.append(.init(
                kind: kind,
                isUnloadable: unloadable,
                isUserStopped: stoppedKinds.contains(kind),
                isSuspended: suspendedKinds.contains(kind),
                idleSeconds: idle
            ))
        }
        return states
    }

    /// 执行一次资源巡检：读内存压力 → 策略决策 → 逐个挂起。返回下次巡检间隔（秒）。
    ///
    /// 由 `ModelLifecycleManager` 周期调用；测试可注入假监控直接驱动。
    @discardableResult
    public func runResourceTick(monitor: any MemoryPressureMonitoring) async -> Double {
        let configuration = await config.current
        let policy = configuration.resourcePolicy
        let idleTimeouts: [AIProviderKind: Double] = {
            var timeouts: [AIProviderKind: Double] = [
                .llm: policy.llmIdleUnloadMinutes * 60,
                .asr: policy.asrIdleUnloadMinutes * 60,
            ]
            if let ttsMinutes = policy.ttsIdleUnloadMinutes {
                timeouts[.tts] = ttsMinutes * 60
            }
            return timeouts
        }()
        let budget = ResourcePolicy.MemoryBudget(minAvailableBytes: policy.minAvailableMemoryMB * 1_048_576)
        let available = monitor.availableMemoryBytes().map(Double.init)
        let states = await resourceStates()
        let decisions = ResourcePolicy.suspendDecisions(
            states: states,
            idleTimeouts: idleTimeouts,
            activeWindowSeconds: policy.activeWindowMinutes * 60,
            budget: budget,
            availableMemoryBytes: available
        )
        for kind in decisions {
            do {
                let message = try await suspendModel(kind)
                AppLog.info("资源管理：\(message)", category: "lifecycle")
            } catch {
                AppLog.warning("资源管理挂起 \(kind.displayName) 失败：\(error.localizedDescription)", category: "lifecycle")
            }
        }
        return policy.tickSeconds
    }

    /// 生效 LLM 的「哪个模型」描述（如 `本地模型 · qwen3:8b`），错误提示统一用它。
    public func llmLabel() async -> String {
        let configuration = await config.current
        let provider = configuration.resolvedProvider(for: .llm)
        return ModelDiagnostics.label(
            providerName: provider?.userFacingName,
            model: configuration.resolvedModel(for: .llm)
        )
    }

    /// 某能力的「哪个模型」描述（设置页与提示共用）。
    public func modelLabel(for kind: AIProviderKind) async -> String {
        let configuration = await config.current
        let provider = configuration.resolvedProvider(for: kind)
        return ModelDiagnostics.label(
            providerName: provider?.userFacingName,
            model: configuration.resolvedModel(for: kind)
        )
    }

    /// 把配置里的启停命令补齐：老配置文件（本轮新增字段之前写的）里没有这两项，
    /// 用内置默认配置里同 id 的值兜底，保证「启动 / 关闭」按钮一装上就能用。
    public static func fillServiceCommands(_ config: ProviderConfig) -> ProviderConfig {
        guard config.serviceStartCommand == nil || config.serviceStopCommand == nil,
              let defaults = try? DefaultConfiguration.load(),
              let fallback = defaults.providers.first(where: { $0.id == config.id })
        else { return config }
        var result = config
        if result.serviceStartCommand == nil { result.serviceStartCommand = fallback.serviceStartCommand }
        if result.serviceStopCommand == nil { result.serviceStopCommand = fallback.serviceStopCommand }
        return result
    }

    /// 设置某能力当前使用的模型（本地检测选择 / 手动填写共用），并重装配。
    public func setCapabilityModel(_ kind: AIProviderKind, model: String) async throws {
        guard let provider = await config.current.resolvedProvider(for: kind) else {
            throw AppError.configuration("没有可用的 \(kind.displayName) Provider")
        }
        // 原子更新：只改这个 Provider 的 model 与产品层的选中模型，
        // 不碰同一条记录上的 apiKey / endpoint（旧写法用过期快照整体写回，会连带覆盖）。
        try await config.mutateProvider(id: provider.id) { p in
            p.model = model
            // 手动填写的模型也要并入候选清单：云端调用的「模型白名单」以候选清单为准
            // （见 `RemoteCallPolicy.allowedModelSet`），不并进去就会被自己的闸门拦下。
            if p.isRemote, !p.candidateModels.contains(model) {
                p.candidateModels.insert(model, at: 0)
            }
        }
        try await config.mutateProduct { $0.selectModel(model, for: kind) }
        await rebootstrap(kind: kind)
    }

    /// 修掉「本地模型名被写进云端供应商」的历史坏配置。
    ///
    /// 实测过的状态：`remote.siliconflow-asr` 的 model 变成了本地的 `ggml-small.en`，
    /// 界面于是显示成「SiliconFlow 语音识别 · ggml-small.en 已就绪」——本地被关掉、
    /// 外部接口却开着，而且这个模型名在云端**不可能**存在（要么 404，要么被路由到别的模型）。
    ///
    /// 判定依据是「这个名字确实是本机 `~/AI_Models` 里的模型」：这种串线只可能来自
    /// 旧版本「选本地模型 → 写进当前生效的云端 Provider」那条路径。
    ///
    /// 处理方式（三件事一起做，缺一不可）：
    /// 1. **清掉该 Provider 的 model** —— 这个名字在云端不存在，留着只会显示错误；
    /// 2. **把这个云端接口关掉（`enabled = false`）** —— 用户反馈的原话是
    ///    「切换本地模型后，没有关闭外部模型接口」：它上面写着本地模型名本来就调不通，
    ///    却因为 `enabled = true` 一直占着生效位、害得本地 Provider 用不上；
    ///    并让产品层不再指向它；
    /// 3. **把该能力对应的本地 Provider 打开** —— 「切本地」当初只做了一半
    ///    （名字写进云端、本地没启用），这里补完，避免落到「云端关了、本地也没开」的真空。
    ///
    /// 例外：如果这个名字出现在该 Provider **自己探测到的候选清单**里，说明它可能是用户
    /// 正当地从云端列表里选的（本地恰好装了同名模型，如公开可下载的 Qwen3-TTS 系列），
    /// 这种情况一律不动——不能为了修坏数据而误伤一份能用的云端配置。
    ///
    /// - Parameter localModelNames: 本机某能力已安装的模型名（可注入，便于脱机测试）。
    /// - Returns: 被修掉的能力（供 UI 提示）。
    @discardableResult
    public func healCrossProviderModels(
        localModelNames: (@Sendable (AIProviderKind) -> Set<String>)? = nil
    ) async -> [AIProviderKind] {
        let names: @Sendable (AIProviderKind) -> Set<String> = localModelNames ?? { kind in
            Set(LocalModelScanner.scan(kind: kind).map(\.name))
        }
        let configuration = await config.current
        var healed: [AIProviderKind] = []
        for provider in configuration.providers where provider.isRemote {
            let model = (provider.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, names(provider.kind).contains(model) else { continue }
            // 例外：这家供应商**自己广告过**这个名字（探测进了候选清单）→ 它可能是
            // 用户正当地从云端列表里选的（本地恰好装了同名模型，如 Qwen3-TTS 系列）。
            // 这种情况不动它，免得误伤一个能用的云端配置。
            guard !provider.candidateModels.contains(model) else { continue }
            try? await config.mutateProvider(id: provider.id) { p in
                p.model = nil
                p.enabled = false   // 「外部模型接口」就此关闭，不再占着生效位
            }
            // 「切本地」这个动作在旧版本里只做了一半：本地模型名写进了云端，本地却没启用。
            // 这里把它补完——找到该能力下**名字对得上的**本地 Provider 打开，
            // 否则用户会落到「云端被关了、本地也没开」的真空状态。
            let localCandidates = configuration.providers.filter {
                $0.kind == provider.kind && !$0.isRemote && $0.runtime != .mock
            }
            if let local = localCandidates.first(where: { ($0.model ?? "") == model }) ?? localCandidates.first {
                try? await config.mutateProvider(id: local.id) { p in
                    p.enabled = true
                    if (p.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        p.model = model   // 它本来就是本机的模型名，落到本地 Provider 上正好
                    }
                }
            }
            try? await config.mutateProduct { product in
                if product.selectedModel(for: provider.kind) == model {
                    product.selectModel(nil, for: provider.kind)
                }
                if product.activeProvider(for: provider.kind) == provider.id {
                    product.activateProvider(nil, for: provider.kind)
                }
            }
            if !healed.contains(provider.kind) { healed.append(provider.kind) }
            AppLog.warning(
                "云端 Provider \(provider.id) 的模型名「\(model)」是本地模型，已清除并关闭该接口（请重新选择云端模型或改用本地模型）",
                category: "configuration"
            )
        }
        return healed
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
    /// 返回前统一注入「关卡 → 情景」绑定（绑定表来自资源文件，不落库）。
    public func loadProgress() async -> LearnerProgress {
        var progress: LearnerProgress
        if let learning, let saved = try? await learning.loadProgress() {
            progress = saved
        } else {
            progress = .seed()
            try? await learning?.saveProgress(progress)
        }
        progress.applyScenarioBindings(LevelBindingCatalog.bundled())
        return progress
    }

    public func saveProgress(_ progress: LearnerProgress) async {
        guard let learning else { return }
        try? await learning.saveProgress(progress)
    }

    // MARK: - 学习进度快照（第 25 步 Dashboard）

    /// 汇总一份学习进度快照（今日 / 时长 / 纠错 / 词汇 / 发音 / 目标 + 六类趋势）。
    /// 星星与每日目标由产品层传入 —— 本服务只负责「记录折算」这一件事。
    public func progressSnapshot(
        days: Int = ProgressAggregator.defaultDays,
        totalStars: Int = 0,
        goalMinutes: Int = ProgressAggregator.defaultGoalMinutes
    ) async -> ProgressSnapshot {
        await progress.snapshot(days: days, totalStars: totalStars, goalMinutes: goalMinutes)
    }

    // MARK: - 会话持久化（ChatService 使用）

    /// 首次发消息时登记会话（已存在则不动，避免把 message_count 归零）。
    public func persistSession(_ session: ChatSession) async {
        guard let learning else { return }
        try? await learning.createSessionIfAbsent(session)
    }

    /// 把会话标记为「在练某个情景」（进入情景时调用，重启后可接着练）。
    /// 传 `nil` 表示退出情景（回到普通练习）。
    public func attachScenario(_ scenarioID: String?, to sessionID: UUID, mode: PracticeMode) async {
        guard let learning else { return }
        try? await learning.setSessionScenario(
            id: sessionID, scenarioID: scenarioID, mode: mode, startedAt: Date()
        )
    }

    /// 某会话进行的情景 id（nil = 普通练习）。
    public func sessionScenarioID(_ sessionID: UUID) async -> String? {
        guard let learning else { return nil }
        return (try? await learning.sessionScenarioID(id: sessionID)) ?? nil
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

    // MARK: - 练习复盘（学习记忆）

    /// 会话时长（秒）：会话首条消息 → 现在。流水为空时为 0。
    public func sessionDuration(sessionID: UUID) async -> TimeInterval {
        guard let summary = await sessionSummary(id: sessionID) else { return 0 }
        return max(Date().timeIntervalSince(summary.startedAt), 0)
    }

    /// 生成一次练习复盘并落库（模型不可用时自动退化为规则总结）。
    public func makeSessionReview(
        sessionID: UUID,
        messages: [ChatMessage],
        corrections: [GrammarCorrection],
        duration: TimeInterval,
        proficiency: String = "beginner"
    ) async -> SessionReview {
        let configuration = await config.current
        let provider = configuration.resolvedProvider(for: .llm)
        let options = SessionReviewService.ReviewOptions(
            model: await currentLLMModel(),
            temperature: provider?.temperature,
            // 复盘是短 JSON：推理模型会吞掉预算，给足上限（配置优先）。
            maxTokens: provider?.maxTokens,
            learningLanguage: configuration.product.learningLanguage,
            nativeLanguage: configuration.product.nativeLanguage,
            proficiency: proficiency
        )
        return await reviewer.makeReview(
            sessionID: sessionID,
            messages: messages,
            corrections: corrections,
            duration: duration,
            options: options
        )
    }

    /// 某会话已有的复盘（未生成则 nil）。
    public func sessionReview(sessionID: UUID) async -> SessionReview? {
        await reviewer.review(sessionID: sessionID)
    }

    /// 最近的复盘列表（学习记录页展示）。
    public func recentReviews(limit: Int = 10) async -> [SessionReview] {
        await reviewer.recentReviews(limit: limit)
    }

    // MARK: - 词汇本（第 24 步 Vocabulary）

    /// 从复盘 new_words 导入生词（按 word 去重）。返回新词数。
    @discardableResult
    public func importVocabularyFromReviews() async -> Int {
        await vocabulary.importFromReviews()
    }

    /// 给生词补「详细中文释义 + 例句 + 重点单词」（按需：点按钮才调用）。
    /// 详细释义比旧版长，token 上限放宽到 768。
    public func defineVocabulary(_ entry: VocabularyEntry) async throws -> VocabularyEntry {
        guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
        try await ensureLLMReady()
        let provider = await config.current.resolvedProvider(for: .llm)
        let options = VocabularyDefineOptions(
            model: await currentLLMModel(),
            maxTokens: min(provider?.maxTokens ?? 768, 768)
        )
        let configuration = await config.current
        return try await vocabulary.define(
            entry,
            learningLanguage: configuration.product.learningLanguage,
            nativeLanguage: configuration.product.nativeLanguage,
            options: options
        )
    }

    /// 补齐已落库卡片里缺失的「词性 / 中文」（历史数据：模型当年只回了英文）。
    /// 后台静默调用：模型没在跑 / 补不到就返回 nil，不打扰用户。
    public func completeVocabularyTerms(_ entry: VocabularyEntry) async -> VocabularyEntry? {
        guard isModelRunning(.llm) else { return nil }
        try? await ensureLLMReady()
        let provider = await config.current.resolvedProvider(for: .llm)
        let options = VocabularyDefineOptions(
            model: await currentLLMModel(),
            maxTokens: min(provider?.maxTokens ?? 256, 256)
        )
        let configuration = await config.current
        return await vocabulary.completeTerms(
            of: entry,
            learningLanguage: configuration.product.learningLanguage,
            nativeLanguage: configuration.product.nativeLanguage,
            options: options
        )
    }

    /// 抽一组每日推荐词（3 简单 / 5 中等 / 2 困难 / 2 词组，雅思标准；本地选词，不调模型）。
    public func dailyWordRecommendation(excluding: Set<String> = []) async -> [DailyWord] {
        await vocabulary.dailyRecommendation(excluding: excluding)
    }

    /// 每日推荐所用词库的全部词（设置页统计 / 每日推荐选词）。
    public func dailyWordBank() async -> [DailyWord] {
        await vocabulary.wordBank()
    }

    /// 词库的词性 / 中文速查（词汇本添加框联想浮层）。
    public func dailyWordBankEntries() async -> [WordBankEntry] {
        await vocabulary.wordBankEntries()
    }

    /// 给每日推荐的词补「音标 / 词性 / 中文义项 / 解释 / 例句及翻译 / 近反义 / 重点单词」
    /// （按需 LLM，不落库；与词汇本同一套字段）。
    public func defineDailyWord(_ word: String) async throws -> VocabularyDefinition {
        guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
        try await ensureLLMReady()
        let provider = await config.current.resolvedProvider(for: .llm)
        let options = VocabularyDefineOptions(
            model: await currentLLMModel(),
            maxTokens: min(provider?.maxTokens ?? 768, 768)
        )
        let configuration = await config.current
        return try await vocabulary.defineDaily(
            word,
            learningLanguage: configuration.product.learningLanguage,
            nativeLanguage: configuration.product.nativeLanguage,
            options: options
        )
    }

    // MARK: - 情景对话（Role Play，第 21 步）

    /// 全部内置场景（数据驱动，来自 `Resources/Scenarios/*.json`）。
    /// 资源缺失时返回空数组，由 UI 给出可操作提示（不崩、不静默、不内置兜底场景）。
    public func availableScenarios() -> [Scenario] {
        if let scenarioCache { return scenarioCache }
        let loaded = ScenarioCatalog.bundled()
        scenarioCache = loaded
        return loaded
    }

    /// 按 id 取场景（不存在返回 nil）。
    public func scenario(id: String) -> Scenario? {
        availableScenarios().first { $0.id == id }
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

    // MARK: - 云端调用审计（费用护栏留痕）

    /// 本次运行的对外调用汇总：计费 / 探测 / 拦截次数、涉及模型、异常扇出预警。
    /// 用户拿它跟服务商账单对账——「应用到底调了什么」不再是个黑盒。
    public func remoteCallSummary() async -> RemoteCallSummary {
        await RemoteCallAudit.shared.summary()
    }

    /// 最近若干条对外调用记录（新的在前，只含元数据）。
    public func recentRemoteCalls(limit: Int = 20) async -> [RemoteCallRecord] {
        await RemoteCallAudit.shared.recent(limit: limit)
    }

    /// 清空内存记录（磁盘留痕保留，便于事后对账）。
    public func resetRemoteCalls() async {
        await RemoteCallAudit.shared.reset()
    }

    /// 审计文件位置（用户可直接打开核对）。
    public nonisolated static func remoteCallLogURL() -> URL {
        RemoteCallAudit.logURL()
    }

    // MARK: - Provider 工厂（唯一允许 new 出 Adapter 的地方）

    private static func makeASRProvider(_ config: ProviderConfig) -> any ASRProvider {
        switch config.runtime {
        case .externalLocalRuntime:
            WhisperASRAdapter(providerID: config.id)
        case .remoteAPI:
            RemoteASRAdapter(providerID: config.id)
        default:
            MockASRProvider()
        }
    }

    private static func makeTTSProvider(_ config: ProviderConfig) -> any TTSProvider {
        switch config.runtime {
        case .externalLocalRuntime:
            Qwen3TTSAdapter(providerID: config.id)
        case .remoteAPI:
            RemoteTTSAdapter(providerID: config.id)
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
