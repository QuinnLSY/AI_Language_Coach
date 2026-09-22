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
    /// 入学定级（进阶 ⑤）：题库读入 + 出卷。判分与定级是纯函数，不在这里。
    public let placement: PlacementService
    /// 今日跟读句子的落盘缓存（每天一份，按日期 + 学习语言作废）。
    private let shadowingDailyStore: ShadowingDailyStore
    /// 发音评测（Pronunciation，第 23 步）：从录音量语速 / 停顿 / 音高 / 音量起伏。
    public let pronunciation: PronunciationService
    /// 词汇本（Vocabulary，第 24 步）：生词导入 / 复习 / 按需释义。
    public let vocabulary: VocabularyService
    /// 词典（新功能）：词典库（内置三本 + 导入）、模糊匹配、按词查完整条目。
    public let dictionary: DictionaryService
    /// 学习进度（Dashboard，第 25 步）：会话 / 纠错 / 跟读 / 词汇按天汇总。
    public let progress: ProgressService
    /// 写作批改（#230）：题目走内置题库，批改一次请求出全部分数 / 批改 / 改写。
    public let writing: WritingService
    /// 每日短文阅读（#231）：一次请求出文章 + 题目 + 答案 + 解析；判分在本地零请求。
    public let reading: ReadingService
    /// 语义索引（Embedding，第 15 步）：把历史学习记忆按「与当前话题的相关度」取回来。
    /// 默认配置下装配的是 mock（不具语义），此时 `supportsSemanticRanking == false`，
    /// 记忆退回结构化路径 —— 不引入任何额外开销。
    public let embedding: EmbeddingManager

    /// 学习数据库。打开失败时为 nil（功能降级为不持久化，不影响对话）。
    public private(set) var learning: LearningDatabase?
    /// 学习库被**隔离重建**时给用户看的说明（nil = 一切正常）。
    ///
    /// 沉默重建是发布级事故：用户会以为旧记录还在。这里必须如实说出来。
    /// 本轮启动应用备份恢复的说明（nil = 没有待恢复内容）。
    public private(set) var pendingRestoreNote: String?
    /// 本轮启动学习库的恢复说明（坏库隔离重建时给出）。
    public private(set) var databaseRecoveryNote: String?
    /// 数据备份开关第 30 步）：导出 / 清单都在项目空间 `.workbuddy/backups/`。
    private let backup: DataBackup
    /// 克隆音色档案（第 24 步）：独立持久化，与 config.json 分开存放（见 `VoiceProfileStore`）。
    private let voiceProfileStore: VoiceProfileStore
    /// 聊天附件仓库（图片 / 视频 / 文件）：文件本体与 config.json 分开存放。
    private let attachmentStore: AttachmentStore
    /// 上传材料的落盘仓库（材料 → 情景 + 跟读句 + 生词表，#208）。
    private let materialStore: MaterialStore
    private let config: ConfigStore
    private var llmProvider: (any LLMProvider)?
    /// 场景目录缓存（资源文件，进程内读一次即可）。
    private var scenarioCache: [Scenario]?
    /// 考卷目录缓存（同上）。
    private var examCache: [ExamBlueprint]?
    /// 进行中的 LLM 装配任务：并发调用只装配一次（见 `ensureLLMReady`）。
    private var llmReadyTask: Task<Void, Error>?
    /// 被用户显式「关闭」的模型能力。**仅进程内有效**：应用打开时全部为启动态。
    private var stoppedKinds: Set<AIProviderKind> = []
    /// 被资源管理**自动挂起**的能力（第 27 步）：与用户关闭语义不同——
    /// 挂起是省内存的临时状态，下次被使用时自动恢复（`resumeIfSuspended`）；
    /// 用户关闭是明确意图，绝不自动拉起。两者都让 `isModelRunning` 变 false。
    private var suspendedKinds: Set<AIProviderKind> = []
    /// 语义索引是否已尝试装配过（每进程只试一次，避免 runtime 没起时每轮重试）。
    private var embeddingBootstrapAttempted = false

    public init(
        config: ConfigStore = .shared,
        llm: LLMManager = LLMManager(),
        databasePath: String? = nil,
        voiceProfileStore: VoiceProfileStore = .shared,
        attachmentStore: AttachmentStore = .shared,
        dictionaryStore: DictionaryBookStore = .shared,
        shadowingDailyStore: ShadowingDailyStore = .shared,
        materialStore: MaterialStore = MaterialStore()
    ) {
        self.config = config
        self.llm = llm
        self.voiceProfileStore = voiceProfileStore
        self.attachmentStore = attachmentStore
        self.asr = ASRManager()
        self.tts = TTSManager()
        self.embedding = EmbeddingManager()
        self.voice = VoiceService(asr: self.asr, tts: self.tts)
        let path = databasePath ?? LearningDatabase.defaultURL().path
        // 备份恢复（#209）：待恢复内容必须在**打开学习库之前**应用——
        // 活连接底下换库文件轻则损坏、重则连当前库一起搭进去。
        let restoreDataDirectory = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
        self.pendingRestoreNote = DataBackup.applyPendingRestoreIfNeeded(dataDirectory: restoreDataDirectory)
        if let note = self.pendingRestoreNote {
            AppLog.info("备份恢复：\(note)", category: "database")
        }
        // 坏库不等于「不能用」：先把可疑文件隔离保住证据，再重建空库继续服务，
        // 并通过 `databaseRecoveryNote` 把这件事如实告诉用户（沉默降级比崩溃更糟）。
        let opened = Self.openLearningDatabase(at: path)
        let database = opened.database
        self.learning = database
        self.databaseRecoveryNote = opened.note
        self.reviewer = SessionReviewService(llm: self.llm, learning: database)
        self.spellingCorrector = SpellingCorrectionService(llm: self.llm)
        self.translator = TranslationService(llm: self.llm)
        // 发音评测（第 23 步）：首版纯声学 + 文本对齐，不依赖任何发音模型；
        // 将来接入音素模型时，把 provider 从工厂装进 PronunciationService 即可。
        self.pronunciation = PronunciationService()
        self.shadowing = ShadowingService(voice: self.voice, pronunciation: self.pronunciation, learning: database)
        self.shadowingDailyStore = shadowingDailyStore
        // 入学定级（进阶 ⑤）：题库随包发布，出卷 / 判分全在本地（零请求）。
        self.placement = PlacementService()
        self.materialStore = materialStore
        self.vocabulary = VocabularyService(llm: self.llm, learning: database)
        self.dictionary = DictionaryService(llm: self.llm, store: dictionaryStore)
        self.progress = ProgressService(learning: database)
        self.writing = WritingService(llm: self.llm)
        self.reading = ReadingService(llm: self.llm)
        self.backup = DataBackup()
        if self.learning == nil {
            AppLog.warning("学习数据库不可用（已尝试隔离重建）: \(path)", category: "database")
        }
    }

    /// 打开学习库；坏库先隔离再重建，并返回要给用户看的说明。
    private static func openLearningDatabase(at path: String) -> (database: LearningDatabase?, note: String?) {
        do {
            let result = try DataResilience.openLearningDatabase(path: path)
            let note = result.recovered ? Self.recoveryNote(path: path) : nil
            return (result.database, note)
        } catch {
            AppLog.error("学习数据库隔离重建失败: \(path) — \(error.localizedDescription)", category: "database")
            return (nil, Self.unavailableNote(path: path))
        }
    }

    private static func recoveryNote(path: String) -> String {
        """
        学习数据库损坏，已自动隔离并重建。

        损坏的文件保留在 corrupt 目录里（\(DataResilience.quarantineDirectory(base: URL(fileURLWithPath: path).deletingLastPathComponent()).lastPathComponent)/），没有被删除；
        这段时间之外的历史记录需要从那里找回，新的学习记录会正常保存。
        """
    }

    private static func unavailableNote(path: String) -> String {
        "学习数据库无法打开，本轮的进度与复盘不会保存：\(URL(fileURLWithPath: path).lastPathComponent)"
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

    /// 装配发音评测的**声学通道**（第 23 步：音素级打分）。
    ///
    /// 两条通道的分工见 `PronunciationService`：
    /// 配置了云端发音评测（如 Azure）就用实测，否则自动回落规则推断。
    /// **不需要 Key 也能用**，所以这里从不抛错——没有云端配置不是错误，只是走另一条路。
    ///
    /// - Returns: 声学通道的健康状态；未配置时返回 `configurationInvalid`（说明走推断）。
    @discardableResult
    public func bootstrapPronunciation() async -> ProviderHealth {
        let configuration = await config.current
        guard let raw = Self.preferredProvider(.pronunciation, in: configuration),
              raw.runtime == .remoteAPI else {
            await pronunciation.attachAcousticProvider(nil)
            return .configurationInvalid(reason: "未配置云端发音评测，使用规则推断")
        }
        var providerConfig = raw
        if let model = configuration.resolvedModel(for: .pronunciation) {
            providerConfig.model = model
        }
        let provider = RemotePronunciationAdapter(providerID: providerConfig.id)
        do {
            try await provider.initialize(config: providerConfig)
        } catch {
            // 配置不完整（缺端点 / 缺 Key / 没选语言）：卸掉声学通道，回到规则推断，
            // 但把原因如实带回去给 UI，别让用户以为「配了云端却在用推断」是无声发生的。
            await pronunciation.attachAcousticProvider(nil)
            return .configurationInvalid(reason: error.localizedDescription)
        }
        let health = await provider.healthCheck()
        if health.isUsable {
            await pronunciation.attachAcousticProvider(provider)
        } else {
            await pronunciation.attachAcousticProvider(nil)
        }
        return health
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

    /// 音色能否启用 / 为什么不能（第 24 步）：把产品口径（显式授权 / 本地文件 / 供应商能力）
    /// 落到一处，UI 与测试都只认它。返回空数组 = 可以启用。
    public func voiceAccessViolations(for profile: VoiceProfile) async -> [VoiceAccessPolicy.Violation] {
        let supportsCloning = await ttsSupportsVoiceCloning()
        return VoiceAccessPolicy.violations(for: profile, providerSupportsCloning: supportsCloning)
    }

    /// 当前音色的可见提示（克隆音色必须让用户看得见；nil = 内置音色，无需提示）。
    public func voiceActiveIndicator(for profile: VoiceProfile) -> String? {
        VoiceAccessPolicy.activeIndicator(for: profile)
    }

    // MARK: - 克隆音色（第 24 步）

    /// 当前 TTS 供应商是否支持音色克隆。
    ///
    /// **实现为权威**：答案一律来自「真正会去做这次合成的那个实现」的 `capabilities()`，
    /// 配置自报**不能**单独把结论变成「支持」。
    ///
    /// 早先这里是「配置声明为真就直接算真」（`config.supportsVoiceCapability`）——不看实现。
    /// 后果是配置里写一句 `capabilities: ["voiceCloning"]` 就能让界面显示
    /// 「当前供应商支持克隆」，用户建完音色、点启用才发现合成直接报错（false capability）。
    /// 现在配置只作**闸门**：适配器算出的能力是 `配置声明 ∩ 实现天花板`
    /// （见 `ProviderCapabilities.effectiveVoiceCapabilities`），云端适配器结构上拒收
    /// 参考音频，所以怎么声明都不会变成「支持」。
    ///
    /// 尚未装配时按同一个工厂造一个、喂同一份配置再问 ——
    /// 既不拿「还没装配」当「不支持」，也不让判定依赖装配时机。
    public func ttsSupportsVoiceCloning() async -> Bool {
        guard let provider = await config.current.resolvedProvider(for: .tts) else { return false }
        if let live = await tts.current {
            return live.capabilities().voiceCloning
        }
        let adapter = Self.makeTTSProvider(provider)
        try? await adapter.initialize(config: provider)
        return adapter.capabilities().voiceCloning
    }

    /// 全部音色档案。
    public func voiceProfiles() async -> [VoiceProfile] { await voiceProfileStore.all }

    /// 发音评测这一次到底是「实测」还是「推断」——配置体检那一行用。
    ///
    /// 报告里也带 `phonemeSource`（那是一次评测的结果），这里说的是**通道现在挂没挂上**：
    /// 用户问「为什么我的音素分看着像估的」，答案在通道这一层。
    public func pronunciationChannelSummary() async -> String {
        await pronunciation.hasAcousticChannel
            ? "声学通道已挂载 · 音素评分走实测"
            : "没有声学通道 · 音素评分走规则推断（如需实测请在上方接入云端发音评测）"
    }

    /// 音色档案文件的位置（设置页「数据存放位置」展示 + 「在 Finder 中打开」用）。
    ///
    /// 音色档案是**用户资产**（参考音频 + 授权留痕），与 `config.json` 分开放，
    /// 所以位置要单独告诉用户，别让他以为「配置在哪它就在哪」。
    public func voiceProfilesLocation() async -> URL { await voiceProfileStore.storageLocation }

    /// 当前启用的**克隆**音色档案（nil = 用内置音色）。
    public func activeClonedVoice() async -> VoiceProfile? {
        guard let id = await config.current.product.activeVoiceProfileID else { return nil }
        return await voiceProfileStore.profile(id: id)
    }

    /// 朗读时实际要传给 TTS runtime 的音色选择（克隆音色真正生效的唯一落点）。
    ///
    /// 返回的是**通用音色标识 + 参考音频**：给 runtime 的是「这是谁的音色 + 参考音频在哪」，
    /// 至于它内部怎么用（缓存音色 / 每次现场克隆）属于 runtime 的实现。
    /// 应用侧因此不出现任何厂商专属调用手段 —— 这正是 Phase 24 的红线。
    ///
    /// ⚠️ 只给一个档案 id 是**不够**的：那是应用本地生成的 UUID，任何 provider 都无法
    /// 据此还原音色，那样「已启用克隆音色」就只是个看起来生效的开关。
    public func effectiveSpeechVoiceSelection() async -> SpeechVoiceSelection {
        let configuration = await config.current
        guard let id = configuration.product.activeVoiceProfileID,
              let profile = await voiceProfileStore.profile(id: id),
              // 只有克隆音色才带参考音频；内置音色即使误登在档案里也不该走克隆链路。
              profile.isCloned,
              let reference = profile.referenceAudioPath,
              !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .builtin(configuration.product.teacherVoice)
        }
        return SpeechVoiceSelection(
            voice: profile.id,
            referenceAudioPath: reference,
            referenceText: profile.referenceText
        )
    }

    /// 朗读用的音色标识（内置音色名，或克隆音色档案 id）。
    ///
    /// 只有需要「名字」的场景（诊断、日志、UI 文案）才用它；**真正朗读请走
    /// `effectiveSpeechVoiceSelection()`** —— 单给名字会丢掉克隆所需的参考音频。
    public func effectiveSpeechVoice() async -> String {
        await effectiveSpeechVoiceSelection().voice
    }

    /// 保存（新增 / 覆盖）一份音色档案。这里**只存不校验**：
    /// 校验发生在启用时（`activateVoiceProfile`），因为「能不能用」取决于当时的供应商能力。
    public func saveVoiceProfile(_ profile: VoiceProfile) async throws {
        try await voiceProfileStore.upsert(profile)
    }

    // MARK: - 聊天附件（第 3 项需求：图片 / 视频 / 文件）

    /// 把用户选中的文件复制进附件目录并登记。**体积护栏在这里把关**：
    /// 超限时抛可读错误，而不是让用户等到「发一句话卡了五分钟」才发现。
    public func importAttachment(from url: URL) async throws -> ChatAttachment {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if let reason = AttachmentPolicy.rejectionReason(fileName: name, byteCount: size) {
            throw AppError.configuration(reason)
        }
        return try await attachmentStore.importFile(at: url)
    }

    /// 附件在本机的位置（nil = 文件已被清理，UI 显示「不可用」）。
    public func attachmentURL(for attachment: ChatAttachment) async -> URL? {
        await attachmentStore.fileURL(for: attachment)
    }

    /// 读取附件内容（多模态请求内联图片时用）。
    public func attachmentData(for attachment: ChatAttachment) async -> Data? {
        await attachmentStore.data(for: attachment)
    }

    /// 删除附件本体（移除待发附件 / 清理时调用）。
    public func removeAttachment(_ attachment: ChatAttachment) async {
        _ = await attachmentStore.remove(attachment)
    }

    /// 附件目录（设置页「在 Finder 中打开」用）。
    public var attachmentDirectory: URL {
        get async { await attachmentStore.storageDirectory }
    }

    /// 把用户选中的参考音频**复制**进应用数据目录，返回新路径。
    ///
    /// 为什么必须复制而不是记下原路径：
    /// 原文件可能被移动 / 删除 / 在云端盘上被驱逐，那时克隆音色会莫名其妙地失效却查不出原因；
    /// 而且「引用任意外部路径」本身就是「拿别人的音频做克隆」的入口，
    /// 复制进应用自己的目录后，来源与生命周期都可控（删档案时可一并清理）。
    public func importVoiceReference(from sourceURL: URL) throws -> String {
        let manager = FileManager.default
        let directory = AppPaths.userDataDirectory().appendingPathComponent("voices", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: sourceURL, to: destination)
        return destination.path
    }

    /// 删除音色档案；若它正是当前启用的那个，一并停用 ——
    /// 否则配置里会留下一个指向不存在档案的 id，表现为「朗读时音色突然变回内置」却查不出原因。
    public func deleteVoiceProfile(id: String) async throws {
        _ = try await voiceProfileStore.remove(id: id)
        if await config.current.product.activeVoiceProfileID == id {
            try await config.mutateProduct { $0.activeVoiceProfileID = nil }
        }
    }

    /// 启用克隆音色。**违反合规口径就直接抛错**并带上可读原因，
    /// 绝不「先启用再说」—— `VoiceAccessPolicy` 是不可绕过的硬闸门。
    public func activateVoiceProfile(id: String) async throws {
        guard let profile = await voiceProfileStore.profile(id: id) else {
            throw AppError.configuration("找不到这个音色档案。")
        }
        let violations = await voiceAccessViolations(for: profile)
        guard violations.isEmpty else {
            throw AppError.configuration(violations.map(\.userMessage).joined(separator: " "))
        }
        try await config.mutateProduct { $0.activeVoiceProfileID = id }
    }

    /// 停用克隆音色（回到内置音色）。
    public func deactivateClonedVoice() async throws {
        try await config.mutateProduct { $0.activeVoiceProfileID = nil }
    }

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

    // MARK: - 考试模式（雅思口语 / 面试问答）

    /// 内置考卷（只读资源文件，进程内读一次即可）。
    public func examBlueprints() async -> [ExamBlueprint] {
        if let examCache { return examCache }
        let loaded = ExamCatalog.bundled()
        examCache = loaded
        return loaded
    }

    /// 考后示范答案：**一次请求**写完所有目标题目。
    ///
    /// 与翻译 / 复盘同一套口径：模型没起来就直接返回空字典（调用方据此说明
    /// 「这次没拿到」，而不是把空字符串当成示范答案显示出去）；
    /// 返回的内容只认 `[[SAMPLE]]` 标记行，解析规则是纯函数（`ExamSampleAnswerRule.parse`）。
    ///
    /// - Returns: 题号 → 示范答案。空字典 = 没拿到（不可用 / 回空 / 一行都没解析出来）。
    public func examSampleAnswers(
        examTitle: String,
        targets: [ExamSampleTarget],
        learningLanguage: String,
        nativeLanguage: String
    ) async -> [Int: String] {
        guard !targets.isEmpty, isModelRunning(.llm) else { return [:] }
        do { try await ensureLLMReady() } catch { return [:] }
        let configuration = await config.current
        let provider = configuration.resolvedProvider(for: .llm)
        let request = LLMRequest(
            messages: [
                LLMMessage(
                    role: .system,
                    content: PromptBuilder.examSampleAnswerPrompt(
                        examTitle: examTitle,
                        targets: targets,
                        learningLanguage: learningLanguage,
                        nativeLanguage: nativeLanguage
                    )
                ),
                LLMMessage(role: .user, content: "Write the model answers now."),
            ],
            model: configuration.resolvedModel(for: .llm),
            // 示范答案要一点文采，给 0.4：比翻译（0）松，比聊天（默认）紧，
            // 免得同一题两次跑出两套完全不同的句式结构。
            temperature: 0.4,
            maxTokens: provider?.maxTokens,
            streaming: false
        )
        guard let response = try? await llm.generate(request) else { return [:] }
        return ExamSampleAnswerRule.parse(response.text)
    }

    /// 跨会话学习记忆（第 15 步）：把库里的纠错 / 词汇 / 跟读发音收敛成老师可用的背景。
    ///
    /// 只读本地库、**不发起任何模型请求**（除非给了 `query` 且装配了真实语义索引）。
    /// 排序 / 折算口径都在 `MemoryRetriever` 的纯函数里，这里只负责把原始事实取出来。
    ///
    /// - Parameter query: 学员当前这句话。给了它、且语义索引可用时，记忆会按**相关度**
    ///   重排并丢掉明显不相关的条目；否则保持结构化结果（默认 mock 即走这条路）。
    public func learningMemory(
        query: String? = nil,
        correctionLimit: Int = 200,
        pronunciationLimit: Int = 100,
        sessionLimit: Int = 500
    ) async -> LearningMemory {
        guard let learning else { return .empty }
        let corrections = (try? await learning.correctionRecords(since: .distantPast, limit: correctionLimit)) ?? []
        let vocabulary = (try? await learning.allVocabulary()) ?? []
        let attempts = (try? await learning.recentShadowingAttempts(limit: pronunciationLimit)) ?? []
        let sessions = (try? await learning.recentSessions(limit: sessionLimit)) ?? []
        let memory = MemoryRetriever.brief(
            corrections: corrections,
            vocabulary: vocabulary,
            reports: attempts.compactMap(\.pronunciation),
            sessionCount: sessions.count,
            sessionFacts: sessionFacts(sessions)
        )
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !memory.isEmpty else {
            return memory
        }
        await ensureEmbeddingReady()
        // mock 的向量没有语义，按它排序等于乱排 —— 只认真实 runtime。
        guard await embedding.supportsSemanticRanking else { return memory }
        return await semanticallyRanked(memory, query: query) ?? memory
    }

    /// 清除学习记忆（**不可逆**）：删掉喂给老师的纠错 / 复盘 / 跟读 / 复习流水。
    ///
    /// 库不可用时**报错而不是返回 0** —— 说「删掉了 0 条」会让人以为真的清干净了。
    @discardableResult
    public func clearLearningMemory() async throws -> MemoryClearance {
        guard let learning else { throw AppError.database("学习库尚未就绪") }
        return try await learning.clearLearningMemory()
    }

    /// 把会话记录折成记忆检索要的事实：纠错条数取会话自带的纠错，话题取情景标题。
    ///
    /// **没绑情景的普通练习不编话题** —— 拿模式名或时间拼一个，等于让老师「以为」
    /// 学员在练某个话题，那是编造不是记忆。
    private func sessionFacts(_ sessions: [SessionSummary]) -> [MemorySessionFact] {
        sessions.map { session in
            let topic = session.scenarioID.flatMap { scenario(id: $0)?.title }
            return MemorySessionFact(
                startedAt: session.startedAt,
                topic: topic,
                correctionCount: session.corrections.count,
                messageCount: session.messageCount
            )
        }
    }

    /// 按与 `query` 的语义相似度重排记忆。任何失败都返回 nil（调用方保留结构化结果）——
    /// 语义索引是增强，绝不能因为它挂了就让老师失忆。
    private func semanticallyRanked(_ memory: LearningMemory, query: String) async -> LearningMemory? {
        let errors = memory.recurringErrors
        let words = memory.focusWords
        var texts = [query]
        texts.append(contentsOf: errors.map { "\($0.original) -> \($0.corrected)" })
        texts.append(contentsOf: words)
        guard texts.count > 1 else { return memory }
        do {
            let vectors = try await embedding.embed(texts)
            guard vectors.count == texts.count, let queryVector = vectors.first else { return nil }
            var relevance: [String: Double] = [:]
            for (index, error) in errors.enumerated() {
                relevance[error.id] = SemanticRanking.cosineSimilarity(queryVector, vectors[index + 1])
            }
            let wordOffset = 1 + errors.count
            for (index, word) in words.enumerated() {
                relevance[word] = SemanticRanking.cosineSimilarity(queryVector, vectors[wordOffset + index])
            }
            return MemoryRetriever.reranked(memory, relevance: relevance)
        } catch {
            return nil
        }
    }

    /// 按需装配语义索引（幂等）。
    ///
    /// 每个进程只尝试一次：runtime 没起时不做「每轮重试」的网络风暴；
    /// 装配失败就是「没有语义索引」，结构化记忆照常工作，不打扰用户。
    /// - Parameter force: 重装配（配置被外部改动后「重新载入」会用到）。
    ///   不加这个开关的话，第一次装配失败会被记成「本进程已试过」，
    ///   用户把模型装好、点「重新载入配置」时反而永远接不上。
    public func ensureEmbeddingReady(force: Bool = false) async {
        guard force || !embeddingBootstrapAttempted else { return }
        embeddingBootstrapAttempted = true
        guard !(await embedding.isUsable) else { return }
        let configuration = await config.current
        guard let providerConfig = configuration.resolvedProvider(for: .embedding),
              let provider = Self.makeEmbeddingProvider(providerConfig) else { return }
        do {
            try await provider.initialize(config: providerConfig)
            try await provider.load()
            await embedding.register(provider)
            AppLog.info(
                "语义记忆检索已接通：\(providerConfig.id)（\(await embedding.dimensions) 维）",
                category: "memory"
            )
        } catch {
            // ⚠️ 只警告、不弹给用户：语义索引是增强，缺席时结构化记忆照常工作。
            // 常见情形（Ollama 没开 / 没装嵌入模型）都是「用户没要求这项功能」，
            // 拿它去打扰用户，等于用警告换惊吓。
            AppLog.warning("语义索引装配失败（记忆退回结构化路径）: \(error.localizedDescription)", category: "memory")
        }
    }

    /// 语义记忆检索是否**真的接通**（诊断 / 设置页用）。
    ///
    /// 判据是「装配到了真实 runtime 的嵌入 Provider」：mock 也能给向量，
    /// 但那是字符桶计数、没有语义，按它排序会把相关历史随机丢掉（见 `EmbeddingManager`）。
    public var isSemanticMemoryEnabled: Bool {
        get async { await embedding.supportsSemanticRanking }
    }

    private static func makeEmbeddingProvider(_ config: ProviderConfig) -> (any EmbeddingProvider)? {
        switch config.runtime {
        case .ollama:
            OllamaEmbeddingAdapter(providerID: config.id, dimensions: config.dimensions ?? 768)
        case .mock:
            MockEmbeddingProvider()
        case .remoteAPI:
            // 云端嵌入：同样经过计费闸门（RemoteCommon.beginBillableCall），
            // 与本地 Ollama 复用同一套「记忆索引」发现 / 健康逻辑。
            RemoteEmbeddingAdapter(providerID: config.id, dimensions: config.dimensions ?? 0)
        default:
            // 其余 runtime（MLX / llama.cpp …）V1 未实现嵌入适配器。
            // **不注册**，而不是拿 mock 冒充 —— 语义索引缺席，记忆退回结构化。
            nil
        }
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
        try await config.mutate { configuration in
            // 用注册表的语义做这次写入（同类只留一个 enabled + 产品层指向与模型对齐）。
            // 注册表是**纯函数**：它只给出变换，落盘仍只走 ConfigStore 这一条路，
            // 因此不会长出「配置 vs 注册表」两份互相漂移的真相。
            _ = ModelRegistry.enable(&configuration, providerID: providerID)
        }
        await rebootstrap(kind: kind)
    }

    // MARK: - 模型注册表（Phase 3）

    /// 全部可选 Provider 的配置视图（只读投影：可用性 / 是否生效都在这里问）。
    public func modelConfigs(kind: AIProviderKind? = nil) async -> [ModelConfig] {
        ModelRegistry.listAvailable(await config.current, kind: kind)
    }

    /// 某能力当前**生效**的那一个。
    public func defaultModelConfig(for kind: AIProviderKind) async -> ModelConfig? {
        ModelRegistry.getDefault(await config.current, for: kind)
    }

    /// 该能力应当由谁去探活。
    ///
    /// 注册表只回答「该探谁」——真探活在 `llmHealth()` / `asrHealth()` / `ttsHealth()`
    /// （要发网络请求、要看 runtime 进程），**不在纯逻辑层假装探过**。
    public func healthTarget(for kind: AIProviderKind) async -> HealthTarget? {
        ModelRegistry.healthTarget(await config.current, for: kind)
    }

    /// 配置一致性体检：找出会让「生效 Provider 解析不出来」的问题。
    public func registryInconsistencies(for kind: AIProviderKind) async -> [String] {
        ModelRegistry.inconsistencies(await config.current, kind: kind)
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
        // 落盘前统一做粘贴清洗：控制台复制出来的引号 / 「Bearer 」前缀 / 换行
        // 会让每一次调用都被服务端判为「Invalid token」，而用户看不出哪里不对。
        let trimmed = CredentialText.normalizedKey(apiKey)
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
        providerConfig.apiKey = CredentialText.normalizedKey(apiKey)
        // 发现流程对任意能力通用（llm / asr / tts …）：同一套 OpenAI 兼容 `/models`，
        // 只是按能力过滤掉不属于这一类模型的条目（云端返回的是混合列表）。
        return try await RemoteCommon.discoverModels(
            config: providerConfig,
            kind: kind,
            client: HTTPClient(useSystemProxy: true)
        )
    }

    /// 验证云端**发音评测**的 Key / 端点是否真的可用。
    ///
    /// 与模型列表探测的区别：发音评估没有只读端点，唯一的验证方式是**发一段音频**。
    /// 这里用 1 秒静音——它足够让服务端把「认证 / 端点 / 音频格式」三件事验完
    /// （静音通常回 `NoMatch`，那恰好证明上面三件事都通过），而费用可以忽略。
    ///
    /// ⚠️ 这是**计费调用**，所以只在用户点「验证」时发生，不做后台静默探测。
    ///
    /// - Returns: 面向用户的一句话结论。
    @discardableResult
    public func verifyRemotePronunciation(
        providerID: String, apiKey: String, model: String?
    ) async throws -> String {
        let configuration = await config.current
        guard var providerConfig = configuration.providers.first(where: {
            $0.id == providerID && $0.kind == .pronunciation
        }) else {
            throw AppError.configuration("找不到发音评测 Provider：\(providerID)")
        }
        providerConfig.apiKey = CredentialText.normalizedKey(apiKey)
        if let model, !model.isEmpty { providerConfig.model = model }
        guard let locale = providerConfig.model, !locale.isEmpty else {
            throw AIProviderError.invalidConfiguration("未选择评测语言（如 en-US）")
        }
        let adapter = RemotePronunciationAdapter(providerID: providerID)
        try await adapter.initialize(config: providerConfig)
        let status = try await adapter.probe()
        let host = providerConfig.endpoint.flatMap { RemoteEndpoint.base($0) }.map { RemoteCommon.host(of: $0) } ?? "?"
        return "认证通过（\(host) · \(locale)）。探测返回 \(status)——静音的预期结果，说明端点与密钥都可用。"
    }

    /// 记住某云端 Provider 探测到的模型列表（写进 `candidateModels`）。
    ///
    /// 探测本身仍是只读的（`fetchRemoteModels` 不写配置），但把结果留下来能让用户
    /// **重开设置时选择器直接可用**——否则「验证并获取模型」每次都要重点一遍。
    public func rememberRemoteModels(_ models: [DiscoveredModel], providerID: String, kind: AIProviderKind) async {
        let ids = models.map(\.id)
        guard !ids.isEmpty else { return }
        guard await config.current.providers.contains(where: { $0.id == providerID && $0.kind == kind }) else { return }
        // 写不进去不影响探测结果本身（模型列表已经拿到了），但**不能静默**：
        // 「下次开设置还要重点一次」这种症状，靠这条 debug 才能定位到是落盘失败。
        do {
            try await config.mutateProvider(id: providerID) { p in
                p.candidateModels = ids
            }
        } catch {
            AppLog.debug("候选模型清单落盘失败（\(providerID)/\(kind.rawValue)）：\(error)", category: "config")
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
        guard let providerConfig = configuration.providers.first(where: { $0.id == providerID && $0.kind == kind }) else {
            throw AppError.configuration("找不到 Provider：\(providerID)")
        }
        let voices = try await RemoteCommon.discoverVoices(config: providerConfig, client: HTTPClient(useSystemProxy: true))
        guard !voices.isEmpty else { return [] }
        let names = Dictionary(uniqueKeysWithValues: voices.map { ($0.id, $0.name) })
        let ids = voices.map(\.id)
        // 同上：音色名字写不进去只是「选择器下次还得重新问」，不该吞成无声失败。
        do {
            try await config.mutateProvider(id: providerID) { p in
                p.voiceNames = names
                if (p.voices ?? []).isEmpty { p.voices = ids }
            }
        } catch {
            AppLog.debug("音色清单落盘失败（\(providerID)/\(kind.rawValue)）：\(error)", category: "config")
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
        let trimmedKey = CredentialText.normalizedKey(apiKey)
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
        case .pronunciation:
            // 音素评测换了供应商 / 填了 Key，声学通道要跟着换（否则还在用旧端点）。
            _ = await bootstrapPronunciation()
        case .embedding:
            // 语义索引的装配是「一次一条路」，重装配要显式放行（见 ensureEmbeddingReady）。
            await ensureEmbeddingReady(force: true)
        default:
            break // vad 尚无真实 runtime
        }
    }

    /// **全部**能力重装配。用于「用户在外面手改了 config.json / 把备份配置拷回来」之后：
    /// 只把配置读回内存是不够的 —— 真正干活的是已经装配好的 provider，
    /// 不重装配就会出现「设置页按新配置显示、实际还在打旧端点」这种最难查的错位。
    public func rebootstrapAll() async {
        for kind in AIProviderKind.allCases {
            await rebootstrap(kind: kind)
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
            // 记住点击前的状态：启动失败必须回滚，否则界面会显示「已启动」骗人。
            let wasRunning = isModelRunning(kind)
            stoppedKinds.remove(kind)
            suspendedKinds.remove(kind)
            do {
                // 同时拉起同一能力下的兄弟本地服务（如 Edge-TTS 本地代理），让「启动」按钮
                // 真正覆盖所有本地后端，而不只是当前生效的那个 Provider。
                await self.syncSiblingLocalServices(kind: kind, running: true)
                if let controller = await serviceController(for: kind) {
                    try await controller.startModelService()
                    await rebootstrap(kind: kind)
                    return "\(who) 已启动：后台服务已拉起。"
                }
                await rebootstrap(kind: kind)
                // ⚠️ 应用层面的「启动」不能无条件报成功（2026-09-14 反馈：Key 已失效，
                // 弹窗却写「已启动」）。没有后台服务可拉的能力，启动的实质是
                // 「确认这条链路现在真的可用」——所以这里做一次真实健康探测，
                // 不通就按失败处理（红色弹窗 + 原因），而不是提前弹绿。
                if let health = await currentHealth(for: kind) {
                    guard health.isUsable else {
                        throw Self.startFailure(health)
                    }
                    // 发音评测没有只读探测端点，配置级检查不能冒充「连接已校验」——
                    // 弹窗说的话必须与真实发生过的事一致（2026-09-14 的同一条教训）。
                    if kind == .pronunciation {
                        return "\(who) 已启用（应用层面）：配置完整，真正的联网校验会在第一次跟读时进行。"
                    }
                    return "\(who) 已启动（应用层面）：连接校验通过。"
                }
                return "\(who) 已启动（应用层面）。"
            } catch {
                if !wasRunning { stoppedKinds.insert(kind) }
                throw error
            }
        }

        stoppedKinds.insert(kind)
        // 同时停掉同一能力下的兄弟本地服务（如 Edge-TTS 本地代理）。
        await self.syncSiblingLocalServices(kind: kind, running: false)
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

    /// Edge-TTS 本地代理在配置里的 Provider id（跑在本机 127.0.0.1:8856 的轻量服务）。
    private static let edgeTTSProxyProviderID = "remote.kina-tts"

    /// 把同一能力下「兄弟本地服务」一并启停。
    ///
    /// 场景：TTS 能力下可能并存多个本地服务（Qwen3 本地 TTS 于 8855、Edge-TTS 本地代理于 8856）。
    /// 点 TTS 的「启动 / 关闭」应当同时拉起 / 停掉所有这些本地后端，而不只是当前生效的那一个——
    /// 否则选了 Edge 音色、却只在按钮上看到 Qwen3 被控制，代理永远起不来。
    ///
    /// 默认生效 Provider 若本身由 `ModelServiceControlling` 控制器处理（本地主模型），会被跳过以免重复拉起。
    /// 兄弟服务失败不影响主链路：例如 Qwen3 起来即可朗读，代理失败不阻断。
    private func syncSiblingLocalServices(kind: AIProviderKind, running: Bool) async {
        let configuration = await config.current
        guard let resolvedID = configuration.resolvedProvider(for: kind)?.id else { return }
        let hasController = await serviceController(for: kind) != nil
        for provider in configuration.providers where provider.kind == kind && provider.enabled {
            let hasCommands = !(provider.serviceStartCommand ?? "").isEmpty
                && !(provider.serviceStopCommand ?? "").isEmpty
            guard hasCommands else { continue }
            // 已由主控制器处理的那个（本地主 Provider）跳过，避免重复拉起
            if provider.id == resolvedID, hasController { continue }
            do {
                if running {
                    try await LocalServiceControl.start(config: provider)
                } else {
                    try await LocalServiceControl.stop(config: provider)
                }
            } catch {
                // 兄弟服务失败不影响主链路
            }
        }
    }

    /// 应用启动时默认拉起 Edge-TTS 本地代理（remote.kina-tts）：它是免费微软音色（如
    /// en-GB-SoniaNeural）的来源，如今跑在本机 127.0.0.1:8856。只处理这一个轻量代理，
    /// 不动 Qwen3 等重型本地模型（后者仍由设置页「启动」按钮按需拉起，避免拖慢开屏）。
    ///
    /// 最佳努力、不阻断启动；代理已运行时跳过（脚本幂等，端口被占用直接退出）。
    public func ensureEdgeTTSProxyOnLaunch() async {
        let configuration = await config.current
        guard let provider = configuration.providers.first(where: {
            $0.id == Self.edgeTTSProxyProviderID && $0.kind == .tts && $0.enabled
        }) else { return }
        guard let command = provider.serviceStartCommand, !command.isEmpty else { return }
        // 端口已被占用（代理在跑）就直接跳过，避免重复拉起
        if let endpoint = provider.endpoint,
           await LocalServiceRunner.waitUntilReachable(endpoint: endpoint, timeout: 1.5, interval: 0.3) {
            return
        }
        do {
            try await LocalServiceControl.start(config: provider, reachTimeout: 12)
        } catch {
            // 启动失败不阻断应用：用户在设置里点「启动」可重试并看到真实错误。
        }
    }

    /// **当前选中的本机语音识别服务**随应用一起起来。
    ///
    /// 用户挑了本机 whisper 做语音识别，进应用后麦克风就该能用 —— 否则每一次冷启动
    /// 都要先去设置里点一次「启动」，而这一步连着力都看不出来（模型只是在后台载入）。
    ///
    /// 与 Edge-TTS 代理同一套打法：最佳努力、不阻断开屏；服务已经在跑就直接跳过
    /// （whisper 载入几百 MB 权重要十几秒，重复拉一次很贵）。
    ///
    /// - Returns: 是否真的执行了启动（调用方据此决定要不要刷新界面状态）。
    @discardableResult
    public func ensureLocalASROnLaunch() async -> Bool {
        let configuration = await config.current
        guard let provider = configuration.resolvedProvider(for: .asr), provider.enabled else { return false }
        // ⚠️ 命令要从**补齐后的**配置里取：存量用户的配置文件是加这个字段之前写下的，
        // 合并时整条 provider 替换会把内置默认的命令吞掉（`ConfigStore.merge`）——
        // 不补的话，本机语音识别永远只能靠用户手动点「启动」。
        let launchable = Self.fillServiceCommands(provider)
        guard let command = launchable.serviceStartCommand, !command.isEmpty else { return false }
        guard let endpoint = launchable.endpoint, !endpoint.isEmpty else { return false }
        // 端口已经通了（服务在跑）就跳过。
        if await LocalServiceRunner.waitUntilReachable(endpoint: endpoint, timeout: 1.5, interval: 0.3) {
            return false
        }
        do {
            try await LocalServiceControl.start(config: launchable, reachTimeout: 25)
            return true
        } catch {
            // 启动失败不阻断应用：用户在设置里点「启动」能看到真实原因。
            return false
        }
    }

    /// 该能力当前生效 Provider 的真实健康状态；尚无真实 runtime 的能力返回 nil。
    ///
    /// 「启动」按钮对云端 / 无后台服务的能力必须用**真实探测**说话——
    /// 弹窗与实际连通性脱节就是 2026-09-14 反馈的第四组问题。
    private func currentHealth(for kind: AIProviderKind) async -> ProviderHealth? {
        switch kind {
        case .llm: await llmHealth()
        case .asr: await asrHealth()
        case .tts: await ttsHealth()
        case .pronunciation: await pronunciationHealth()
        default: nil
        }
    }

    /// 发音评测的健康状态。
    ///
    /// 配置齐全就当可用，但**不宣称「连接校验通过」**：发音评测没有只读探测端点，
    /// 真要验证连通性就得发一段音频（= 花钱）。所以这里只验配置，真实连通性在
    /// 第一次跟读时才揭晓——`setModelRunning` 的文案也必须与此一致。
    private func pronunciationHealth() async -> ProviderHealth {
        let health = await bootstrapPronunciation()
        return health
    }

    /// 健康状态 → 抛给「启动」弹窗的错误。
    ///
    /// 用 `AIProviderError` 而不是 `AppError`：失败弹窗走 `ModelDiagnostics.describe`，
    /// 它对 `AIProviderError` 会产出「谁 · 配置有误：<服务端原话>」这类完整句子；
    /// 传 `AppError` 会多包一层「配置错误：」前缀。注意这里传的是**未加前缀的原始原因**
    /// （`userFacingDescription` 自带「配置有误：」，再传就重复了）。
    private static func startFailure(_ health: ProviderHealth) -> AIProviderError {
        switch health {
        case .connected:
            return .invalidConfiguration("未知原因")
        case .configurationInvalid(let reason):
            return .invalidConfiguration(reason)
        case .runtimeUnavailable(let reason):
            return .runtimeUnavailable(reason)
        case .modelUnavailable(let model):
            return .modelUnavailable(model)
        case .requestFailed(let reason):
            return .connectionFailed(reason)
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
            do {
                try await config.mutateProvider(id: provider.id) { p in
                    p.model = nil
                    p.enabled = false   // 「外部模型接口」就此关闭，不再占着生效位
                }
            } catch {
                AppLog.debug("本地模型自愈：关闭云端 \(provider.id) 失败：\(error)", category: "config")
            }
            // 「切本地」这个动作在旧版本里只做了一半：本地模型名写进了云端，本地却没启用。
            // 这里把它补完——找到该能力下**名字对得上的**本地 Provider 打开，
            // 否则用户会落到「云端被关了、本地也没开」的真空状态。
            let localCandidates = configuration.providers.filter {
                $0.kind == provider.kind && !$0.isRemote && $0.runtime != .mock
            }
            if let local = localCandidates.first(where: { ($0.model ?? "") == model }) ?? localCandidates.first {
                do {
                    try await config.mutateProvider(id: local.id) { p in
                        p.enabled = true
                        if (p.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            p.model = model   // 它本来就是本机的模型名，落到本地 Provider 上正好
                        }
                    }
                } catch {
                    AppLog.debug("本地模型自愈：启用本地 \(local.id) 失败：\(error)", category: "config")
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

    /// 记忆索引（embedding）的本地 / 云端模型发现，与 `availableLLMModels` 同构。
    ///
    /// 不依赖 Manager 的懒加载注册（首次聊天才注册），而是直接从配置构造适配器：
    /// 这样设置页打开时就能列出本机 Ollama 的嵌入模型或云端的可选模型，
    /// 与「AI 大脑」卡片的本地检测逻辑完全一致。
    public func availableEmbeddingModels() async -> [DiscoveredModel] {
        let configuration = await config.current
        guard let providerConfig = configuration.resolvedProvider(for: .embedding),
              let provider = Self.makeEmbeddingProvider(providerConfig) else { return [] }
        do {
            try await provider.initialize(config: providerConfig)
            if let discovered = try? await provider.discoverModels() {
                return discovered
            }
        } catch {
            AppLog.warning("记忆索引模型发现失败（退回候选清单）: \(error.localizedDescription)", category: "memory")
        }
        let candidates = providerConfig.candidateModels
        return candidates.map { DiscoveredModel(id: $0, name: $0) }
    }

    /// 记忆索引的健康状态（设置页状态点用）。
    ///
    /// 同样从配置直接构造适配器探查，不依赖懒加载注册，
    /// 否则设置页打开时还没聊过天就会显示「未注册」。
    public func embeddingHealth() async -> ProviderHealth {
        let configuration = await config.current
        guard let providerConfig = configuration.resolvedProvider(for: .embedding),
              let provider = Self.makeEmbeddingProvider(providerConfig) else {
            return .configurationInvalid(reason: "未配置记忆索引")
        }
        do {
            try await provider.initialize(config: providerConfig)
            return await provider.healthCheck()
        } catch {
            return .configurationInvalid(reason: error.localizedDescription)
        }
    }

    /// 当前生效的 LLM 能不能**真的读图**。
    ///
    /// 谁在用：对话区带了图片附件时提醒用户「老师看不到这张图，只会知道文件名」。
    /// 这条能力声明以前只有产出方没有消费方（`ProviderCapabilities.vision` 与配置里的
    /// `vision` 并列存在，没人读能力面那一份），于是「不读图的模型收到图」是**静默降级**的。
    public func llmSupportsVision() async -> Bool {
        await llm.current?.capabilities().vision ?? false
    }

    /// 当前生效的语音识别引擎**给不给词级时间戳**。
    ///
    /// 谁会用到：设置页「运行环境」的配置体检行。`ProviderCapabilities.wordTimestamp`
    /// 这条声明以前只有产出方（`WhisperASRAdapter` 声明 true）没有消费方 ——
    /// 于是没人知道 `ASRResult.words` 到底会不会被填上，也没人盯着它别退化成空数组。
    /// 这里把它读出来如实展示：**声明的能力必须有人看**，否则就是个装饰。
    public func asrWordTimestampSupport() async -> Bool {
        await asr.current?.capabilities().wordTimestamp ?? false
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

    /// 近一年的练习分布（年度记录卡）。与 `progressSnapshot` 同层：这里只做取数编排。
    public func annualRecap(
        now: Date = Date(),
        goalMinutes: Int = ProgressAggregator.defaultGoalMinutes
    ) async -> AnnualRecap {
        await progress.annualRecap(now: now, goalMinutes: goalMinutes)
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

    /// 历史纠错**原始记录**（时间新 → 旧）。语法分析判重与教学决策都用它。
    ///
    /// 与 `recentCorrections` 的区别：带上时间戳与原句上下文，
    /// 「同一个错犯了几次」要按记录算，不能先丢时间信息再回头猜。
    public func recentCorrectionRecords(limit: Int = 100) async -> [CorrectionRecord] {
        guard let learning else { return [] }
        return (try? await learning.correctionRecords(since: .distantPast, limit: limit)) ?? []
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

    /// 某会话最近一次复盘覆盖到的消息数（判断「有没有新内容需要复盘」）。
    public func reviewedMessageCount(sessionID: UUID) async -> Int {
        guard let learning else { return 0 }
        return (try? await learning.reviewedMessageCount(sessionID: sessionID)) ?? 0
    }

    /// 删掉某会话的**练习流水**（消息 + 纠错），保留会话行与复盘。
    ///
    /// ⚠️ 调用方必须先拿到复盘并确认可用（`PracticeReviewPolicy.canPurgeSource`）：
    /// 复盘失败还把流水删了，这一局的对话就永远看不到了。
    @discardableResult
    public func purgePracticeMessages(sessionID: UUID) async -> Int {
        guard let learning else { return 0 }
        return (try? await learning.purgeSessionMessages(sessionID: sessionID)) ?? 0
    }

    // MARK: - 情景主线任务进度（需求 3 / 5）

    public func questProgress(scenarioID: String) async -> ScenarioQuestRecord? {
        guard let learning else { return nil }
        return try? await learning.questProgress(scenarioID: scenarioID)
    }

    /// 全部情景的主线任务进度，按情景 id 索引（大树与情景卡片一次取完）。
    public func allQuestProgress() async -> [String: ScenarioQuestRecord] {
        guard let learning else { return [:] }
        let records = (try? await learning.allQuestProgress()) ?? []
        return Dictionary(uniqueKeysWithValues: records.map { ($0.scenarioID, $0) })
    }

    public func saveQuestProgress(_ record: ScenarioQuestRecord) async {
        guard let learning else { return }
        try? await learning.saveQuestProgress(record)
    }

    /// 清掉某情景的主线任务进度（重练这一关时调用）。
    public func clearQuestProgress(scenarioID: String) async {
        guard let learning else { return }
        try? await learning.clearQuestProgress(scenarioID: scenarioID)
    }

    /// 某情景最近一次复盘（「任务前情提要」的原料）。
    public func latestScenarioReview(scenarioID: String) async -> SessionReview? {
        guard let learning else { return nil }
        return try? await learning.latestReview(scenarioID: scenarioID)
    }

    /// 合成「任务前情提要」（纯本地读库，**不发起任何模型请求**）。
    public func scenarioBriefing(for scenario: Scenario) async -> ScenarioBriefing {
        let record = await questProgress(scenarioID: scenario.id)
        let review = await latestScenarioReview(scenarioID: scenario.id)
        return ScenarioBriefingBuilder.build(
            scenario: scenario,
            questDone: record?.doneStepSet ?? [],
            review: review
        )
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

    // MARK: - 每周小结 / 月环比（#228）

    /// 「本周小结」卡的数字（取数与折算都在 `ProgressService` / `ProgressAggregator`）。
    public func weeklyInsight() async -> WeeklyInsight? {
        await progress.weeklyInsight()
    }

    // MARK: - 写作批改（#230）

    /// 批改一篇写作。与释义同一条门：模型在跑 + 就绪后一次请求出全部结果。
    /// 任何失败返回 nil（UI 给提示，不抛错）。
    public func reviewWriting(topic: WritingTopic, essay: String) async -> WritingReview? {
        guard isModelRunning(.llm) else { return nil }
        try? await ensureLLMReady()
        let configuration = await config.current
        return await writing.review(
            topic: topic,
            essay: essay,
            learningLanguage: configuration.product.learningLanguage,
            nativeLanguage: configuration.product.nativeLanguage,
            model: await currentLLMModel()
        )
    }

    /// 出今天的短文阅读（`level` 传 CEFR 档位名，如 "B1"；unknown 传空串由服务兜底）。
    /// 任何失败返回 nil（UI 给可操作的提示）。判分不在模型侧 —— 生成时答案已随文下发。
    public func generateReading(level: String) async -> ReadingPassage? {
        guard isModelRunning(.llm) else { return nil }
        try? await ensureLLMReady()
        let configuration = await config.current
        return await reading.generate(
            theme: ReadingThemeLibrary.theme(for: Date()),
            level: level,
            learningLanguage: configuration.product.learningLanguage,
            nativeLanguage: configuration.product.nativeLanguage,
            model: await currentLLMModel()
        )
    }

    // MARK: - 写作 / 阅读记录持久化（#233）

    /// 交卷批改成功后落一行写作记录（学习记录页的「写作练习」卡与每周小结都吃它）。
    public func recordWritingSubmission(topic: WritingTopic, essay: String, review: WritingReview) async {
        guard let learning else { return }
        let words = ShadowingScorer.words(essay).count
        try? await learning.appendWritingEntry(
            title: topic.title,
            score: review.score.map(Double.init),
            wordCount: words,
            createdAt: Date()
        )
    }

    /// 某一天已生成的短文（旧 → 新；重启后回看的唯一来源）。
    public func todaysReadings(dayKey: Int) async -> [StoredReading] {
        guard let learning else { return [] }
        return (try? await learning.readings(dayKey: dayKey)) ?? []
    }

    /// 落一篇短文（生成成功 / 作答变化都整体覆盖写）。
    public func saveReading(_ entry: StoredReading) async {
        guard let learning else { return }
        try? await learning.saveReading(entry)
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

    /// 抽一组每日推荐词（3 简单 / 5 中等 / 2 困难 / 2 词组；本地选词，不调模型）。
    ///
    /// **词源来自词典库**：按用户选定的优先级顺序取词（没勾选任何词典时 =
    /// 全部可见词典按名字排，见 `DictionaryLibrary.sourceBookIDs`）。
    /// 词典库被清空（一本书都没有）时才退回随包词库 —— 单本入口的意义就在这里。
    ///
    /// - Parameter seed: 给了就**按天恒定**（`DailySeed.seed(dayKey:language:)`）：
    ///   同一天多次打开看到同一批词，跨天才换。不给就是真随机 —— 「换一批」走这一条。
    public func dailyWordRecommendation(excluding: Set<String> = [], seed: UInt64? = nil) async -> [DailyWord] {
        let pools = await dictionary.recommendationPools()
        if pools.contains(where: { !$0.isEmpty }) {
            return await vocabulary.dailyRecommendation(fromSources: pools, excluding: excluding, seed: seed)
        }
        return await vocabulary.dailyRecommendation(excluding: excluding, seed: seed)
    }

    /// 每日推荐所用词库的全部词（设置页统计「已学 x / y 词」）。
    ///
    /// 口径跟着**词典库**走：推荐词是从可见词典里抽的，统计的分母就必须是同一批词，
    /// 否则会出现「总共 145 词、已学 200 词」这种自相矛盾的数字。
    ///
    /// ⚠️ 合并后**必须按词去重**：每本书各自一份池子，`say`/`go` 这类词几本书里都有，
    /// 直接相加会把同一个词算好几遍 —— 分母虚高、和「词库共 N 词」也对不上。
    /// （选词侧 `DailyWordPicker` 本来就会去重，这里对齐的是统计口径。）
    public func dailyWordBank() async -> [DailyWord] {
        let pools = await dictionary.recommendationPools()
        let merged = pools.flatMap { $0 }
        guard !merged.isEmpty else { return await vocabulary.wordBank() }
        var seen = Set<String>()
        return merged.filter { seen.insert($0.word.lowercased()).inserted }
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

    // MARK: - 词典（词典库 + 查词）

    /// 词典库里可见的书（内置去掉用户删掉的 + 用户导入的），已按优先级排好序。
    public func dictionaryBooks() async -> [DictionaryBook] {
        await dictionary.books()
    }

    /// 被用户删掉、**还能恢复**的内置词典。
    public func restorableDictionaryBooks() async -> [DictionaryBook] {
        let state = await dictionary.library()
        return state.restorableBuiltIns(builtIns: await dictionary.builtInBooksSnapshot())
    }

    /// 模糊匹配（最多 10 条）。
    public func dictionarySearch(_ query: String) async -> [DictionaryWord] {
        await dictionary.search(query)
    }

    /// 词库速查（**不起模型、不花钱**）：只查内置 / 导入词典里有没有这个词。
    ///
    /// 划词气泡的第一站：鼠标扫过一个词时先问它，命中就直接出音标与中文，
    /// 不必为一句话里的每个常见词都花一次模型调用。
    public func dictionaryKnownWord(_ query: String) async -> DictionaryWord? {
        await dictionary.knownWord(query)
    }

    /// 划到的是变体时，用它的本体去词库速查（`subtitles` → `subtitle`）。
    ///
    /// 与 `dictionaryKnownWord` 一样零成本、零延迟 —— 划词主路径上先走这两条，
    /// 命中就完全不用起模型。
    public func dictionaryBaseFormWord(of query: String) async -> (candidate: WordForm.Candidate, word: DictionaryWord)? {
        await dictionary.baseFormWord(of: query)
    }

    /// 查一个词的完整条目（按需 LLM；命中进程内缓存则不发请求）。
    public func dictionaryLookUp(
        _ word: String,
        ignoringCache: Bool = false,
        baseFormHints: [String] = []
    ) async throws -> DictionaryDetail {
        guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
        try await ensureLLMReady()
        let provider = await config.current.resolvedProvider(for: .llm)
        let options = DictionaryLookupOptions(
            model: await currentLLMModel(),
            // 词典条目含搭配 / 例句 / 派生词，比词汇本释义长：上限给到 1024。
            maxTokens: min(provider?.maxTokens ?? 1024, 1024)
        )
        let configuration = await config.current
        return try await dictionary.lookUp(
            word,
            learningLanguage: configuration.product.learningLanguage,
            nativeLanguage: configuration.product.nativeLanguage,
            options: options,
            baseFormHints: baseFormHints,
            ignoringCache: ignoringCache
        )
    }

    /// 某本词典在「每日推荐词源」里的名次（没被选作词源 → nil）。
    public func dictionaryRank(of id: String) async -> Int? {
        await dictionary.rank(of: id)
    }

    /// 每本词典的名次表（书封面上的优先级框显示用）。
    public func dictionarySourceRanks() async -> [String: Int] {
        await dictionary.sourceRanks()
    }

    /// 空查询页的「试试这些词」（从可见词典里间隔取，不随机）。
    public func dictionarySampleWords(limit: Int = 6) async -> [DictionaryWord] {
        await dictionary.sampleWords(limit: limit)
    }

    /// 「试试这些词」的**轮换词池**（随机抽，每次都不一样）。
    ///
    /// 页面上那一排胶囊每 10 秒换一批，换的时候不该再去查一次库 —— 一次取一批放内存里慢慢用。
    public func dictionarySamplePool(limit: Int = 48) async -> [DictionaryWord] {
        await dictionary.randomSampleWords(limit: limit)
    }

    /// 已缓存的查词结果（切页 / 回退时先占位，不闪空白）。
    public func dictionaryCached(_ word: String) async -> DictionaryDetail? {
        await dictionary.cached(word)
    }

    /// 删掉一本词典（内置只隐藏可恢复；导入的连文件一起删）。
    @discardableResult
    public func removeDictionaryBook(id: String) async throws -> DictionaryBook? {
        try await dictionary.removeBook(id: id)
    }

    /// 恢复一本内置词典。
    public func restoreDictionaryBook(id: String) async throws {
        try await dictionary.restoreBook(id: id)
    }

    /// 一键恢复全部内置词典。
    public func restoreBuiltInDictionaries() async throws {
        try await dictionary.restoreBuiltIns()
    }

    /// 勾选 / 取消「作为每日推荐词源」（取消后名次自动补位）。
    @discardableResult
    public func toggleDictionarySource(id: String) async throws -> Bool {
        try await dictionary.toggleSource(id: id)
    }

    /// 导入一本词典（JSON，只有 word 必填）。
    @discardableResult
    public func importDictionary(from url: URL, name: String? = nil) async throws -> DictionaryBook {
        try await dictionary.importBook(from: url, name: name)
    }

    /// 可见词典的词条总数（页头统计 / 设置页分母）。
    public func dictionaryWordCount() async -> Int {
        await dictionary.totalWordCount()
    }

    /// **去重后**的词库规模（跨词典同名词只算一个）。UI 上「词库共 N 词」都用它。
    public func dictionaryUniqueWordCount() async -> Int {
        await dictionary.uniqueWordCount()
    }

    // MARK: - 今日跟读（每天按情景现生成 20 句）

    /// 今日缓存的跟读句子（日期或学习语言不匹配 → nil）。
    public func shadowingCachedDrills(day: String?) async -> [ShadowingDrill]? {
        let key = day ?? ShadowingDailyRule.dayKey()
        let language = await config.current.product.learningLanguage
        return await shadowingDailyStore.drills(day: key, language: language)
    }

    /// 今日跟读 20 句：**当天缓存优先**，没有才按当天轮到的情景生成并落盘。
    ///
    /// 为什么缓存优先是本方法的第一条分支，而不是「每次都重新生成」：
    /// 用户练到第 7 句去泡了杯茶，回来句子全换掉，等于这一轮练习作废。
    /// 同一天必须拿到同一批句子（`ShadowingDailyRule.dayKey` 保证「同一天同一个键」）。
    ///
    /// 生成失败一律抛错，由 UI 决定「先用内置素材顶着」——
    /// 本方法不内置兜底句子（跟读素材写死在代码里，正是这一轮要拆掉的东西）。
    public func shadowingDailyDrills(day: String? = nil) async throws -> [ShadowingDrill] {
        let key = day ?? ShadowingDailyRule.dayKey()
        let configuration = await config.current
        let language = configuration.product.learningLanguage
        let native = configuration.product.nativeLanguage

        if let cached = await shadowingDailyStore.drills(day: key, language: language) {
            return cached
        }
        guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
        try await ensureLLMReady()

        let total = ShadowingDailyRule.dailySentenceCount
        let picked = ShadowingDailyRule.rotatedScenarios(from: availableScenarios())
        // 情景取不够（资源缺失）时退一步：一个情景都不给，模型就无从「按情景」写 —— 这时
        // 不猜、不编，直接报错让 UI 用内置素材。
        guard !picked.isEmpty else {
            throw AppError.unknown("没有可用的情景素材（Resources/Scenarios/*.json）")
        }
        let perScenario = max(total / picked.count, 1)
        let list = picked.map { scenario in
            (
                name: scenario.titleZh.isEmpty ? scenario.title : scenario.titleZh,
                objective: scenario.objective,
                level: scenario.level,
                difficulty: scenario.difficulty
            )
        }
        let prompt = PromptBuilder.shadowingDailyPrompt(
            learningLanguage: language,
            nativeLanguage: native,
            scenarioList: list,
            perScenario: perScenario,
            total: perScenario * picked.count
        )
        let provider = await config.current.resolvedProvider(for: .llm)
        let request = LLMRequest(
            messages: [LLMMessage(role: .system, content: prompt)],
            model: await currentLLMModel(),
            // 每天要的是一批**不一样的**句子：温度必须给足，否则同一份情景清单
            // 会得到高度雷同的句子（换了日期却像没换）。
            temperature: 0.9,
            // 20 句 × 3 个字段，按 1024 会被截断在中途。
            maxTokens: min(provider?.maxTokens ?? 2048, 2048),
            streaming: false,
            reasoningEffort: LLMRequest.noThinkingEffort
        )
        let response = try await llm.generate(request)
        let drills = ShadowingDailyRule.parse(response.text, limit: total)
        guard drills.count >= total / 2 else {
            // 只解析出零星几句：不落盘（下次还会重试），也不假装这就是今天的素材。
            throw AppError.unknown("模型只给出了 \(drills.count) 句跟读素材")
        }
        await shadowingDailyStore.save(day: key, language: language, drills: drills)
        return drills
    }

    /// 清掉今日跟读缓存（用户点「重新生成」）。
    public func clearShadowingDailyCache() async {
        await shadowingDailyStore.clear()
    }

    // MARK: - 上传材料自动出题（材料 → 情景 + 跟读句 + 生词表，#208）

    /// 全部已生成的材料（按生成时间倒序）。材料是个位数规模，每次读盘即可，
    /// 不做进程内缓存 —— 缓存失效点少一个是一个。
    public func availableMaterials() async -> [MaterialKit] {
        await materialStore.all()
    }

    /// 删除一份材料（情景卡、跟读句、生词表一起消失；词汇本里已加入的词**不**回收）。
    public func deleteMaterial(id: String) async {
        await materialStore.delete(id: id)
    }

    /// 把一份材料拆成整套练习：**一次请求**同时产出情景 + 生词表 + 跟读句。
    ///
    /// 「一次操作 = 一个模型请求」的落点：拆解是一次性的整体动作，拆成三次请求
    /// 只会让用户等三趟、多花三份钱。生成成功即落盘；同 id 重复生成 = 覆盖更新。
    public func generateMaterialKit(from raw: String) async throws -> MaterialKit {
        if let issue = MaterialKitRule.inputIssue(for: raw) {
            switch issue {
            case .empty:
                throw AppError.unknown("材料是空的，先粘贴或导入一篇文字再生成。")
            case .tooShort(let actual):
                throw AppError.unknown("材料太短（只有 \(actual) 字，至少需要 \(MaterialKitRule.minimumLength) 字），撑不起一套练习。")
            }
        }
        guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
        try await ensureLLMReady()

        let configuration = await config.current
        let material = MaterialKitRule.sanitized(raw)
        let prompt = PromptBuilder.materialKitPrompt(
            material: material,
            learningLanguage: configuration.product.learningLanguage,
            nativeLanguage: configuration.product.nativeLanguage
        )
        let provider = await config.current.resolvedProvider(for: .llm)
        let request = LLMRequest(
            messages: [LLMMessage(role: .system, content: prompt)],
            model: await currentLLMModel(),
            // 拆解要忠实于材料：低温、关思考（确定性短任务必关思考）。
            temperature: 0.3,
            maxTokens: min(provider?.maxTokens ?? 2048, 2048),
            streaming: false,
            reasoningEffort: LLMRequest.noThinkingEffort
        )
        let response = try await llm.generate(request)
        guard let kit = MaterialKitRule.parse(response.text, text: material) else {
            // 解析失败不落盘：宁可让用户重试，也不能存一份缺胳膊少腿的材料。
            throw AppError.unknown("没能从材料里拆出完整的练习（缺标题 / 情景 / 跟读句），请重试一次。")
        }
        try await materialStore.save(kit)

        // 生词表自动进词汇本（已有同词则跳过，`add` 内部去重）。
        for word in kit.words {
            _ = await vocabulary.add(word: word.word, meaning: word.meaning, source: .material)
        }
        return kit
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

    /// 「关卡 → 情景」绑定表（来自 `Resources/Levels/level_bindings.json`，不落库）。
    ///
    /// 课程阶梯要靠它把关卡挂到 CEFR 档上：关卡自己不知道属于哪一档，
    /// 是「它绑的那个情景的 level」决定的。资源缺失时返回空表（不瞎猜）。
    public func levelBindings() -> [String: String] {
        LevelBindingCatalog.bundled()
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

    // MARK: - 隐私（设置页「隐私与安全」）

    /// 隐私状况：当前有没有数据外发、发往哪里，以及本地数据都存在哪。
    ///
    /// 每次都**实时从配置推导**——用户切回本地模型后，这里必须立刻变回「纯本地」，
    /// 不能停留在上一次的快照上（否则等于谎报）。
    public func privacyReport() async -> PrivacyReport {
        let configuration = await config.current
        // 附件与音色档案这两份「用户资产」的落点由本服务给出：它们各自有唯一出口
        // （`AttachmentStore.storageDirectory` / `VoiceProfileStore.storageLocation`），
        // 在别处重拼一次路径就多一份会漂移的真相。
        return PrivacyReport(
            disclosure: PrivacyPolicy.disclosure(for: configuration),
            locations: PrivacyDataLocator.locations(
                attachmentDirectory: await attachmentDirectory,
                voiceProfilesFile: await voiceProfilesLocation()
            ),
            dataDirectory: PrivacyDataLocator.dataDirectory()
        )
    }

    // MARK: - 数据备份（第 30 步：Release checklist / Data）

    /// 导出一份完整备份（学习库 + 配置 + 调用留痕），返回压缩包位置。
    @discardableResult
    public func exportBackup() async throws -> BackupRecord {
        BackupRecord(try await backup.export())
    }

    /// 已有备份，新的在前。
    public func backups() async -> [BackupRecord] {
        await backup.snapshots().map(BackupRecord.init)
    }

    /// 备份放在哪儿（UI 直达用）。
    public var backupDirectory: URL {
        get async { await backup.directory }
    }

    /// 学习库出过什么状况（nil = 一切正常）。界面要把它显示出来。
    public var recoveryNote: String? { databaseRecoveryNote }

    /// 校验一份备份（导入确认框用）：坏包在这里就被拦下，给出明确原因。
    public func inspectBackup(at path: String) async throws -> DataBackup.ImportPlan {
        try await backup.inspectBackup(at: URL(fileURLWithPath: path))
    }

    /// 安排恢复：校验 → 当前数据自动留底 → 新文件落暂存（重启时才真正替换）。
    @discardableResult
    public func stageRestore(at path: String) async throws -> DataBackup.ImportPlan {
        try await backup.stageRestore(at: URL(fileURLWithPath: path))
    }

    /// 本轮启动应用的备份恢复说明（nil = 没有）。
    public var restoreNote: String? { pendingRestoreNote }

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
