import AIDomain
import AIInterfaces
import AIServices
import AppCore
import Foundation
import Observation
import SwiftUI

/// 一个能力（ASR/TTS/VAD/Embedding/Pronunciation）当前模型情况的 UI 快照。
public struct CapabilityModelInfo: Sendable, Equatable {
    public let kind: AIProviderKind
    public let healthOK: Bool
    public let healthText: String
    /// 当前选中的模型名（可能来自 runtime 自报或配置）。
    public let currentModel: String?
    /// 来源描述（如「本地 · /Users/…/ggml-small.en.bin」或「DeepSeek 提供的云端模型」）。
    public let sourceDescription: String
    /// ~/AI_Models 下自动检测到的本地模型。
    public let localModels: [LocalModel]
}

/// UI 唯一状态源。**只依赖 Application Services，不碰 Provider / HTTP / SQL。**
@MainActor
@Observable
public final class AppState {

    public let services: CoachServices
    public let chat: ChatService

    public var themeMode: ThemeMode = .day
    public var systemIsDark: Bool = false
    /// 侧边栏展开/收起（供主界面参与宽度分配）。
    public var isSidebarExpanded = true
    /// 真实进度：来自学习数据库；首次启动为种子关卡。
    public var progress: LearnerProgress = .seed()

    public private(set) var availableModels: [DiscoveredModel] = []
    public private(set) var health: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    public private(set) var isBooting = true
    public private(set) var bootMessage: String?
    public var modelDraft: String = ""
    public var showingSettings = false
    // MARK: 模型 Provider（本地 + 云端并存）
    /// 当前生效的 LLM Provider（决定实际调用本地还是云端）。
    public private(set) var activeProvider: ProviderConfig?
    /// 设置页当前选中的 Provider 标签（可编辑未生效的 Provider）。
    public var selectedProviderID: String = "ollama.llm"
    /// 云端 API Key 草稿（按 provider id 存，避免切换标签互相覆盖）。
    public var apiKeyDrafts: [String: String] = [:]
    /// 云端探测到的模型列表（按 provider id 缓存）。
    public private(set) var remoteModels: [String: [DiscoveredModel]] = [:]
    /// 云端推理强度草稿（low / medium / high；nil = 标准）。
    public var reasoningEffortDraft: String?
    public private(set) var isFetchingRemoteModels = false
    /// 云端配置操作结果（成功提示或错误）。
    public var remoteMessage: String?
    /// 上下文窗口（token），nil = 未知。
    public private(set) var contextLimit: Int?
    /// 生效模型的推理强度（low / medium / high；nil = 标准）。
    public private(set) var activeReasoningEffort: String?
    /// 今日全局 token 用量（侧边栏黑板 / 督促气泡判定）。
    public private(set) var todayTokens: Int = 0
    // MARK: 语音（第 17/18 步）
    /// 是否正在录音。
    public private(set) var isRecording = false
    /// 是否正在识别。
    public private(set) var isTranscribing = false
    /// 是否正在朗读教师回复。
    public private(set) var isSpeaking = false
    /// 朗读相位：准备中（已点中、正在合成首句）/ 朗读中（已有声音）。
    public private(set) var speechPhase: SpeechPhase = .idle
    /// 正在准备的朗读原文：让对应消息的按钮立刻显示「准备中」。
    public private(set) var speakingText: String?
    /// 教师回复完成后自动朗读（设置里可关）。
    public var autoSpeak = false
    /// 当前教师音色（runtime 自报的候选 + 配置值兜底）。
    public private(set) var availableVoices: [String] = ["Serena", "Vivian", "Ryan", "Aiden", "Eric"]
    /// 本地语音 runtime 自报描述（如「Qwen3-TTS 0.6B · mps」），nil = 未知。
    public private(set) var ttsRuntimeInfo: String?
    /// 最近语音错误（nil = 正常）。
    public private(set) var voiceError: String?
    /// 语音服务健康状态。
    public private(set) var asrHealth: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    public private(set) var ttsHealth: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    // MARK: 模型管理中心（本地检测 ~/AI_Models + 外部模型统一入口）
    /// 每个能力的模型信息（当前模型/来源/本地检测列表）。
    public private(set) var capabilityInfos: [AIProviderKind: CapabilityModelInfo] = [:]
    /// 外部模型 API Key 草稿（providerID -> key）。
    public var externalKeyDrafts: [String: String] = [:]
    /// 外部模型探测结果（providerID -> models）。
    public private(set) var externalModels: [String: [DiscoveredModel]] = [:]
    /// 每个能力当前展开的外部 Provider 标签。
    public var externalSelectedProvider: [String: String] = [:]
    /// 外部 Provider 候选缓存（kind -> options，设置页打开时拉一次）。
    public var externalProviderCache: [String: [(id: String, name: String)]] = [:]
    public private(set) var isFetchingExternal = false
    /// 外部模型操作结果消息（providerID -> message）。
    public var externalMessages: [String: String] = [:]
    /// 手动填写模型名草稿（kind -> name）。
    public var customModelDrafts: [String: String] = [:]
    /// 中栏切换：学习记录页（false = 练习对话）。
    public var showingRecords = false
    /// 情景选择浮层开关（应用内 overlay，随日夜主题）。
    public var showingScenarios = false
    /// 内置情景场景（数据来自资源文件；空 = 资源缺失，UI 给可操作提示）。
    public private(set) var scenarios: [Scenario] = []
    /// 是否已尝试加载过场景（用于区分「加载中」与「确实为空」）。
    public private(set) var didLoadScenarios = false
    /// 学习记录数据（进入页面时加载）。
    public private(set) var records: [SessionSummary] = []
    public private(set) var mistakes: [GrammarCorrection] = []
    /// 练习复盘：最新一份（本次会话或最近一次）。nil = 还没生成过。
    public private(set) var latestReview: SessionReview?
    /// 历史复盘（学习记录页可回看）。
    public private(set) var reviews: [SessionReview] = []
    /// 是否正在生成复盘（按钮 loading）。
    public private(set) var isGeneratingReview = false
    /// 数据目录缓存快照（设置页「缓存管理」卡片）。
    public private(set) var cacheSnapshot: CacheSnapshot = .empty
    /// 上一次清理释放的字节数（展示用，0 = 无）。
    public private(set) var cacheFreedBytes: Int64 = 0
    /// 情景结算奖励提示（nil = 不显示）。UI 展示数秒后自动消失。
    public private(set) var lastReward: ScenarioReward?
    // MARK: 模型启停（设置页「启动 / 关闭」）
    /// 各能力模型是否处于启动态。**应用打开时全部为启动**（不持久化关闭状态）。
    public private(set) var modelRunStates: [AIProviderKind: Bool] = [:]
    /// 正在切换启停的能力（按钮 loading）。
    public private(set) var modelSwitching: Set<AIProviderKind> = []
    /// 启停结果弹框（应用顶部向下弹入，数秒后向上收起）。nil = 不显示。
    public private(set) var modelToast: ModelToast?
    /// 输入框的预设学员提问（数据来自资源文件；为空则退回普通占位文案）。
    public private(set) var starterQuestions: [String] = []
    /// 翻译失败提示（对话区展示，可关闭）。
    public var translationNotice: String? { chat.translationError }

    // MARK: - 跟读（第 22 步 Shadowing）

    /// 是否停在跟读页（占中间栏，与学习记录页同级）。
    public var showingShadowing = false
    /// 跟读素材（进页面时按需加载；资源缺失则保持空并由 UI 提示）。
    public private(set) var shadowingDrills: [ShadowingDrill] = []
    /// 当前练到第几句（在 `shadowingDrills` 中的下标）。
    public private(set) var shadowingIndex = 0
    /// 最近一次评测结果（nil = 这一句还没评过）。
    public private(set) var shadowingComparison: ShadowingComparison?
    /// 最近一次发音评测（第 23 步；nil = 没录到音频 / 还没评）。
    public private(set) var shadowingPronunciation: PronunciationReport?
    /// 跟读汇总（次数 / 最佳 / 平均 / 最近）。
    public private(set) var shadowingStats: ShadowingStats = .empty
    /// 正在跟读录音。
    public private(set) var isShadowingRecording = false
    /// 跟读链路上的忙碌态（播放示范 / 识别中 / 回放中）。
    public private(set) var isShadowingBusy = false
    /// 跟读提示（可关闭，nil = 正常）。
    public private(set) var shadowingNotice: String?
    // MARK: 语音流式输入
    /// 录音过程中实时识别出的文本（nil = 未在录音）。UI 把它写进输入框。
    public private(set) var voiceTranscript: String?

    // MARK: - 词汇本（第 24 步 Vocabulary）

    /// 是否停在词汇本页（占中间栏）。
    public var showingVocabulary = false
    /// 词汇表（进页面时加载；新 → 旧）。
    public private(set) var vocabularyEntries: [VocabularyEntry] = []
    /// 词汇统计（总数 / 待复习 / 已掌握 / 已释义）。
    public private(set) var vocabularyStats: VocabularyStats = .empty
    /// 正在补释义的词（按钮 loading）。
    public private(set) var isDefiningVocabulary: Set<UUID> = []
    /// 添加生词草稿（输入框绑定）。
    public var vocabularyDraft = ""
    /// 词汇本提示（可关闭；nil = 正常）。
    public private(set) var vocabularyNotice: String?
    /// 释义被手动收起的词条（「查释义」按钮与收起开关是同一个按钮；
    /// 已有释义默认展开，收起后点「看释义」再展开，不重新请求模型）。
    public private(set) var collapsedVocabularyDefinitions: Set<UUID> = []
    /// 每日推荐（本次启动随机抽的 12 个：3 简单 / 5 中等 / 2 困难 / 2 词组；不落库）。
    public private(set) var dailyWords: [DailyWord] = []
    /// 每日推荐词的释义缓存（按需 LLM，word → 释义；与词汇本共用同一结构）。
    public private(set) var dailyDefinitions: [String: VocabularyDefinition] = [:]
    /// 正在补释义的每日推荐词（按钮 loading）。
    public private(set) var isDefiningDaily: Set<String> = []
    /// 已展开释义的每日推荐词（点「查释义」展开，再点收起）。
    public private(set) var expandedDailyWords: Set<String> = []
    /// 本次展示中已计入「认识」的推荐词（再点一次是撤销 → 计数 -1）。
    /// 每次换一批/重启后清空 —— 单词每出现一次最多计一次，防误点连击。
    public private(set) var dailyAcknowledged: Set<String> = []
    /// 「认识」累计计数（跨启动持久化）。满 3 次的词不再进入每日推荐。
    private var dailyRecognitions: [String: Int] = [:]
    /// 本次启动是否已抽过每日推荐（每次启动只抽一次，刷新按钮才重新抽）。
    private var dailyWordsLoaded = false
    /// 本地词库缓存（添加框联想 / 总词数统计共用；只在需要时载入一次）。
    private var vocabularyBankEntries: [WordBankEntry] = []
    private var vocabularyBankLoaded = false
    /// 添加框联想候选池（词库 + 本机已有释义）。
    public private(set) var vocabularySuggestions: [VocabularySuggestion] = []
    /// 当前输入命中的联想（悬浮框展示；空 = 不展示，不挤压下方内容）。
    public private(set) var vocabularyMatches: [VocabularySuggestion] = []
    /// 上次重置每日推荐学习进度的时间（没重置过为 nil）。
    public private(set) var dailyProgressResetAt: Date?
    /// 重置那一刻已学完（累计认识满 3 次）的词数。
    public private(set) var dailyProgressResetLearned = 0
    /// 词库总词数（设置页展示「上次已学 x / y 词」）。
    public private(set) var dailyBankTotal = 0

    /// 「认识」计数的持久化键（UserDefaults：轻量 [word: count]，不值得为此建表）。
    private static let dailyRecognitionStorageKey = "vocabulary.dailyRecognitions"
    /// 上次重置时间的持久化键。
    private static let dailyResetAtKey = "vocabulary.dailyProgressResetAt"
    /// 上次重置时已学词数的持久化键。
    private static let dailyResetLearnedKey = "vocabulary.dailyProgressResetLearned"
    /// 累计认识满此次数 → 不再推荐。
    public static let dailyRecognitionRetireCount = 3

    /// 产品配置缓存（Sendable，可在 MainActor 直接修改后整体回写）。
    private var product: ProductConfig = ProductConfig()
    /// 结算提示的自动收起任务。
    private var rewardDismissTask: Task<Void, Never>?
    /// 启停弹框的自动收起任务。
    private var toastDismissTask: Task<Void, Never>?

    /// 注入外部装配好的服务（**测试专用**：真实 `CoachServices` 会去启停本机模型服务，
    /// 单测必须换掉它，否则会误杀用户正在运行的 TTS/ASR 进程）。
    init(services: CoachServices) {
        self.services = services
        self.chat = ChatService(services: services)
        // 应用打开时，所有模型默认为「启动」。
        var states: [AIProviderKind: Bool] = [:]
        for kind in AIProviderKind.allCases { states[kind] = true }
        self.modelRunStates = states
        // 每日推荐「认识」计数（手写 init 不给默认值漏赋值报错，必须显式加载）。
        self.dailyRecognitions = Self.loadDailyRecognitions()
        // 上次重置进度的时间与已学词数（同样手写加载）。
        let resetStamp = UserDefaults.standard.double(forKey: Self.dailyResetAtKey)
        self.dailyProgressResetAt = resetStamp > 0
            ? Date(timeIntervalSince1970: resetStamp)
            : nil
        self.dailyProgressResetLearned = UserDefaults.standard.integer(forKey: Self.dailyResetLearnedKey)
    }

    public convenience init() { self.init(services: CoachServices()) }

    /// 某能力模型当前是否启动（默认启动）。
    public func isModelRunning(_ kind: AIProviderKind) -> Bool {
        modelRunStates[kind] ?? true
    }

    public var theme: ForestTheme {
        ForestThemeResolver.resolve(mode: themeMode, systemIsDark: systemIsDark)
    }

    // 供设置页读取的产品字段
    public var productPracticeMode: PracticeMode { product.practiceMode }
    public var learningLanguage: String { product.learningLanguage }
    public var nativeLanguage: String { product.nativeLanguage }
    public var teacherVoice: String { product.teacherVoice }
    public var teacherBubblesEnabled: Bool { product.teacherBubbles }
    public var animalBubblesEnabled: Bool { product.animalBubbles }
    public var animalActivityEnabled: Bool { product.animalActivity }
    /// 活动频率（0...1）。
    public var animalActivityFrequency: Double { product.animalActivityFrequency }
    /// 音色切换自动试听开关。
    public var voicePreviewEnabled: Bool { product.voicePreview }
    /// 教师朗读语速（倍速，1 = 正常）。
    public var speechRate: Double { product.speechRate }
    /// 实际生效的活动开关：配置开 && 非夜晚（夜晚自动安静）。
    public var animalActivityEffective: Bool { product.animalActivity && !theme.isNight }

    /// 设置页「小动物自由活动」开关的显示值（纯函数，便于单测）：
    /// 夜晚一律显示为未勾选（小动物都睡了），**但不动用户白天保存的配置**，切回白天即恢复。
    nonisolated public static func animalActivityToggleValue(enabled: Bool, isNight: Bool) -> Bool {
        isNight ? false : enabled
    }

    /// 老师形象（侧边栏底部 + 聊天区 AI 头像）。
    public var teacherAnimalKind: AnimalKind {
        AnimalKind(rawValue: product.teacherAnimal) ?? .panda
    }
    /// 小学员形象（聊天区学员位 + 右侧爬树形象）。
    public var studentAnimalKind: AnimalKind {
        AnimalKind(rawValue: product.studentAnimal) ?? .bear
    }

    public var currentModelName: String? {
        if let resolved = availableModels.first(where: { $0.id == modelDraft })?.name { return resolved }
        return modelDraft.isEmpty ? nil : modelDraft
    }

    /// 状态栏用：生效 Provider 的展示名（如「本地模型」「DeepSeek」）。
    public var activeProviderName: String { activeProvider?.userFacingName ?? "未配置" }
    /// 生效 Provider 是否为云端 API。
    public var isActiveProviderRemote: Bool { activeProvider?.runtime == .remoteAPI }

    /// 设置页 Provider 标签列表（id + 展示名），来自配置文件。
    public func llmProviderOptions() async -> [(id: String, name: String, isRemote: Bool)] {
        let configuration = await services.configuration
        return configuration.providers
            .filter { $0.kind == .llm }
            .map { ($0.id, $0.userFacingName, $0.runtime == .remoteAPI) }
    }

    // MARK: - 启动

    public func start() async {
        let configuration = await services.configuration
        product = configuration.product
        themeMode = configuration.product.themeMode
        autoSpeak = configuration.product.autoSpeak
        chat.profile.learningLanguage = configuration.product.learningLanguage
        chat.profile.nativeLanguage = configuration.product.nativeLanguage
        progress = await services.loadProgress()

        isBooting = true
        do {
            try await services.bootstrapLLM()
            bootMessage = nil
        } catch {
            bootMessage = error.localizedDescription
        }
        // 恢复上次会话的聊天内容（无历史则保持空白）
        await chat.restoreLastSessionIfNeeded()
        await bootstrapVoice()
        await refreshStatus()
        refreshTodayTokens()
        modelRunStates = await services.modelRunStates()
        starterQuestions = await services.starterQuestions()
        isBooting = false
        // 所有服务就绪后由**老师先开口**：学员看到老师说话，就知道现在开口一定有人回。
        // （以前是学员先发第一句，常常撞上还没装配完的 Provider，那句话就没了。）
        chat.greetIfNeeded()
    }

    // MARK: - 气泡翻译

    /// 取某条消息的译文（再点一次收起）。走按需翻译 + 有界缓存，不进对话历史。
    public func translateMessage(_ id: UUID) async {
        await chat.translate(messageID: id)
    }

    /// 关闭翻译失败提示。
    public func clearTranslationNotice() { chat.clearTranslationError() }

    // MARK: - 模型启停（设置页「启动 / 关闭」）

    /// 启动 / 关闭某能力的模型。
    ///
    /// - 本地模型：真的把后台服务拉起 / 停掉（Ollama 载入或卸载模型；语音服务执行配置里的启停命令）。
    /// - 云端 / 内置模型：只做应用层面的开关（外部服务无法被本应用终止）。
    ///
    /// 结果只走顶部弹框（绿=成功 / 红=失败并说明原因），不再塞在设置页卡片里。
    public func setModelRunning(_ kind: AIProviderKind, running: Bool) async {
        guard !modelSwitching.contains(kind) else { return }
        modelSwitching.insert(kind)
        defer { modelSwitching.remove(kind) }
        let label = await services.modelLabel(for: kind)
        do {
            let message = try await services.setModelRunning(kind, running: running)
            showModelToast(message, isSuccess: true)
        } catch {
            let reason = ModelDiagnostics.describe(label: label, error: error)
            showModelToast("\(running ? "启动" : "关闭")失败 · \(reason)", isSuccess: false)
        }
        modelRunStates = await services.modelRunStates()
        await refreshStatus()
        if kind == .asr || kind == .tts { await bootstrapVoice() }
        await refreshCapabilityInfos()
    }

    /// 顶部弹框：成功为绿、失败为红，展示后自动向上收起。
    /// 失败文案更长，多留一点时间让人读完。
    public func showModelToast(_ message: String, isSuccess: Bool) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            modelToast = ModelToast(message: message, isSuccess: isSuccess)
        }
        let duration: ContinuousClock.Duration = isSuccess ? .seconds(2) : .seconds(4)
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismissModelToast()
        }
    }

    /// 立刻收起启停弹框（点叉 / 自动到时共用）。
    @MainActor
    public func dismissModelToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        withAnimation(.easeOut(duration: 0.24)) { modelToast = nil }
    }

    /// 对话模型跑在哪儿：本地 = local，云端 = cloud（设置页卡片右上角的状态前缀）。
    public var llmLocationLabel: String { isActiveProviderRemote ? "cloud" : "local" }

    /// 模型提供商卡片右上角那一行：`local.llm · qwen3:8b 已就绪`。
    ///
    /// 前缀说明模型跑在本机还是云端（`local` / `cloud`），后缀是健康状态，
    /// 用户一眼知道自己正在跟哪个模型说话。
    public var llmProviderStatusLine: String {
        let head = "\(llmLocationLabel).llm"
        let model = currentModelName
        let who = (model?.isEmpty ?? true) ? head : "\(head) · \(model ?? "")"
        return ModelDiagnostics.describe(label: who, health: health)
    }

    /// 生效 LLM 的「已就绪 / 连接失败」文案（**带上模型名**，用户一眼知道是哪个模型）。
    public var llmHealthDescription: String {
        ModelDiagnostics.describe(
            providerName: activeProvider?.userFacingName,
            model: currentModelName,
            health: health
        )
    }

    /// 对话模型被关闭时的提示（nil = 正常可对话）。对话区常驻展示。
    public var llmStoppedNotice: String? {
        guard !isModelRunning(.llm) else { return nil }
        return ModelDiagnostics.stoppedHint(
            providerName: activeProvider?.userFacingName,
            model: currentModelName
        )
    }

    /// 刷新今日 token 用量（每次回复完成 / 打开侧边栏时调用）。
    public func refreshTodayTokens() {
        todayTokens = DailyTokenCounter.todayTokens()
    }

    // MARK: - 语音（第 17/18 步）

    /// 装配语音能力。**不阻断启动**：runtime 不在线时仅展示状态。
    public func bootstrapVoice() async {
        // 朗读相位回到主线程驱动 UI（分句流水线的「准备中/朗读中」提示）
        await services.voice.setPhaseHandler { [weak self] phase, text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.speechPhase = phase
                self.speakingText = phase == .idle ? nil : text
            }
        }
        // 流式识别：录音期间不断把「当前听到的整句」送回主线程，UI 实时写进输入框。
        await services.voice.setPartialHandler { [weak self] text in
            Task { @MainActor [weak self] in
                self?.voiceTranscript = text
            }
        }
        let health = await services.bootstrapVoice()
        asrHealth = health.asr
        ttsHealth = health.tts
        let voices = await services.availableVoices()
        if !voices.isEmpty {
            availableVoices = voices
            await normalizeVoice(voices)
        }
        ttsRuntimeInfo = await services.voice.ttsRuntimeDescription()
    }

    /// 把配置里的音色对齐到 runtime 自报列表（大小写不敏感），避免选择器空选。
    private func normalizeVoice(_ voices: [String]) async {
        guard !voices.isEmpty else { return }
        if let matched = voices.first(where: { $0.caseInsensitiveCompare(product.teacherVoice) == .orderedSame }) {
            if matched != product.teacherVoice {
                product.teacherVoice = matched
                await persistProduct()
            }
        } else if product.teacherVoice.isEmpty {
            product.teacherVoice = voices[0]
            await persistProduct()
        }
    }

    /// 点击麦克风：开始录音（录音期间流式把识别结果送到 `voiceTranscript`）。
    public func startVoiceInput() async {
        guard !isRecording else { return }
        // 语音识别模型被关闭 → 别装成在录音，直接说清楚怎么打开。
        guard isModelRunning(.asr) else {
            voiceError = "\(await services.modelLabel(for: .asr)) 已关闭，请在设置里点绿色的「启动」后再用语音输入。"
            return
        }
        voiceError = nil
        isSpeaking = false
        voiceTranscript = nil
        await services.voice.stopSpeaking()
        await services.voice.setPartialLanguage("English")
        await services.voice.startRecording()
        let state = await services.voice.isRecording
        isRecording = state
        if let error = await services.voice.lastError { voiceError = error }
    }

    /// 再次点击：停止录音 → 识别 → 纠正拼写 → 填入输入框（由调用方接收文本）。
    ///
    /// **拼写纠正只在这里发生**：手打的文字一个都不改。
    public func finishVoiceInput() async -> String? {
        guard isRecording else { return nil }
        let recognized = await services.voice.stopRecordingAndTranscribe(language: "English")
        isRecording = false
        isTranscribing = await services.voice.isTranscribing
        voiceError = await services.voice.lastError
        voiceTranscript = nil
        guard let recognized, !recognized.isEmpty else { return nil }
        let corrected = await services.correctSpelling(recognized)
        return corrected.isEmpty ? recognized : corrected
    }

    public func cancelVoiceInput() async {
        await services.voice.cancelRecording()
        isRecording = false
        voiceTranscript = nil
    }

    /// 关闭对话区的语音错误提示。
    public func clearVoiceError() {
        voiceError = nil
    }

    /// 朗读教师回复（按设置里的语速播放）。分句流水线：首句先出声。
    ///
    /// 注意：曾经尝试「发消息时并行预热 TTS」，实测**有害**——LLM 与 TTS 共用 MPS，
    /// 预热在 LLM 生成期间会被挤到显存外，实测单次预热耗时可达 185s，还反过来拖慢回复。
    /// 因此朗读只依赖分句流水线 + 服务端自身的启动预热。
    public func speak(_ text: String) async {
        // 教师语音模型被关闭 → 明确提示，而不是静默无声。
        guard isModelRunning(.tts) else {
            voiceError = "\(await services.modelLabel(for: .tts)) 已关闭，请在设置里点绿色的「启动」后再朗读。"
            return
        }
        isSpeaking = true
        await services.voice.speak(text, voice: product.teacherVoice, language: "English",
                                   rate: Float(product.speechRate))
        isSpeaking = await services.voice.isSpeaking
        speechPhase = await services.voice.phase
        voiceError = await services.voice.lastError
    }

    public func stopSpeaking() async {
        await services.voice.stopSpeaking()
        isSpeaking = false
        speechPhase = .idle
        speakingText = nil
    }

    /// 设置页：切换自动朗读。
    public func setAutoSpeak(_ enabled: Bool) async {
        autoSpeak = enabled
        if !enabled { await stopSpeaking() }
    }

    /// 音色切换时自动试听一句短示例（受设置开关控制）。
    public func setVoice(_ voice: String) async {
        product.teacherVoice = voice
        await persistProduct()
        if product.voicePreview {
            await services.voice.speak("Nice to meet you!", voice: voice, language: "English",
                                       rate: Float(product.speechRate))
            voiceError = await services.voice.lastError
        }
    }

    public func refreshStatus() async {
        health = await services.llmHealth()
        let models = await services.availableLLMModels()
        availableModels = models.filter { !$0.isEmbeddingOnly }
        activeProvider = await services.activeLLMProvider()
        if activeProvider == nil { selectedProviderID = "" } else if !isActiveProviderRemote || selectedProviderID.isEmpty {
            selectedProviderID = activeProvider?.id ?? selectedProviderID
        }
        if let current = await services.currentLLMModel() {
            modelDraft = current
        } else {
            modelDraft = availableModels.first?.id ?? ""
        }
        // 上下文窗口：优先取 runtime 发现的当前模型长度，其次配置值。
        let configured = await services.contextWindow()
        contextLimit = availableModels.first(where: { $0.id == modelDraft })?.contextLength ?? configured
        // 生效模型的推理强度（头部胶囊展示用）。
        activeReasoningEffort = await services.activeReasoningEffort()
        // 关键：同步本地 product 缓存。否则切换 Provider 后，任何一次 persistProduct
        // 都会用旧缓存回写配置，把 activeProviders/apiKey 决策抹掉（重启回到 qwen3 的根源）。
        product = await services.configuration.product
    }

    // MARK: - 模型管理中心（本地检测 + 外部模型）

    /// 刷新各能力的模型信息快照（设置页打开 / 检测按钮时调用）。
    public func refreshCapabilityInfos() async {
        let configuration = await services.configuration
        var result: [AIProviderKind: CapabilityModelInfo] = [:]
        for kind in [AIProviderKind.asr, .tts, .vad, .embedding, .pronunciation] {
            let provider = configuration.resolvedProvider(for: kind)
            let localModels = LocalModelScanner.scan(kind: kind)

            let healthOK: Bool
            let healthText: String
            switch kind {
            case .asr:
                healthOK = asrHealth.isUsable
                healthText = ModelDiagnostics.describe(
                    providerName: provider?.userFacingName,
                    model: product.selectedModel(for: kind) ?? provider?.model,
                    health: asrHealth
                )
            case .tts:
                healthOK = ttsHealth.isUsable
                healthText = ModelDiagnostics.describe(
                    providerName: provider?.userFacingName,
                    model: product.selectedModel(for: kind) ?? provider?.model,
                    health: ttsHealth
                )
            default:
                // VAD / Embedding / Pronunciation V1 尚无独立 runtime，如配置了本地 Provider 才有意义
                healthOK = false
                healthText = provider?.runtime == .externalLocalRuntime ? "等待接入" : "内置模拟"
            }

            let current = product.selectedModel(for: kind) ?? provider?.model
            let source: String
            switch provider?.runtime {
            case .remoteAPI:
                source = "\(provider?.userFacingName ?? "云端") 提供的云端模型"
            case .externalLocalRuntime:
                if let current, let path = LocalModelScanner.path(of: current, kind: kind) {
                    source = "本地 · \(path)"
                } else if let endpoint = provider?.endpoint {
                    source = "本地服务 · \(endpoint)"
                } else {
                    source = "本地模型"
                }
            default:
                source = provider == nil ? "未配置" : "内置模拟（无需配置）"
            }

            result[kind] = CapabilityModelInfo(
                kind: kind,
                healthOK: healthOK,
                healthText: healthText,
                currentModel: current,
                sourceDescription: source,
                localModels: localModels
            )
        }
        capabilityInfos = result
    }

    /// 选择本地检测到的模型（~/AI_Models）并重装配。
    public func selectLocalModel(_ kind: AIProviderKind, name: String) async {
        do {
            try await services.setCapabilityModel(kind, model: name)
            bootMessage = nil
        } catch {
            bootMessage = error.localizedDescription
        }
        await refreshCapabilityInfos()
    }

    /// 手动填写模型名并应用。
    public func applyCustomModel(_ kind: AIProviderKind, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await selectLocalModel(kind, name: trimmed)
        customModelDrafts[kind.rawValue] = ""
    }

    /// 某能力配置里的外部 Provider 候选（id + 展示名）。
    public func remoteProviderOptions(for kind: AIProviderKind) async -> [(id: String, name: String)] {
        let configuration = await services.configuration
        return configuration.providers
            .filter { $0.kind == kind && $0.runtime == .remoteAPI }
            .map { ($0.id, $0.userFacingName) }
    }

    /// 外部模型：校验 API Key 并拉取模型列表（不落盘）。
    public func fetchExternalModels(kind: AIProviderKind, providerID: String) async {
        let apiKey = await resolvedExternalAPIKey(providerID: providerID)
        guard !apiKey.isEmpty else {
            externalMessages[providerID] = "请先填写 API Key"
            return
        }
        isFetchingExternal = true
        externalMessages[providerID] = nil
        do {
            let models = try await services.fetchRemoteModels(providerID: providerID, apiKey: apiKey, kind: kind)
            externalModels[providerID] = models.filter { !$0.isEmbeddingOnly }
            externalMessages[providerID] = "验证成功，获取到 \(models.count) 个模型"
        } catch {
            externalMessages[providerID] = error.localizedDescription
        }
        isFetchingExternal = false
    }

    /// 外部模型：保存 Key/模型并激活该 Provider。
    public func applyExternalModel(_ kind: AIProviderKind, providerID: String, model: String) async {
        let apiKey = await resolvedExternalAPIKey(providerID: providerID)
        guard !apiKey.isEmpty else {
            externalMessages[providerID] = "请先填写 API Key"
            return
        }
        do {
            try await services.applyRemoteProvider(providerID: providerID, apiKey: apiKey, model: model, kind: kind)
            externalMessages[providerID] = "已启用 \(model)"
            if kind == .asr || kind == .tts { await bootstrapVoice() }
        } catch {
            externalMessages[providerID] = error.localizedDescription
        }
        await refreshCapabilityInfos()
    }

    private func resolvedExternalAPIKey(providerID: String) async -> String {
        let draft = externalKeyDrafts[providerID] ?? ""
        if !draft.trimmingCharacters(in: .whitespaces).isEmpty { return draft }
        let configuration = await services.configuration
        return configuration.providers.first { $0.id == providerID }?.apiKey ?? ""
    }

    // MARK: - 模型 Provider（本地 / 云端切换）

    /// API Key 解析：草稿优先，为空则回退到已保存的密钥。
    private func resolvedAPIKey(for providerID: String) async -> String {
        let draft = apiKeyDrafts[providerID] ?? ""
        if !draft.trimmingCharacters(in: .whitespaces).isEmpty { return draft }
        let configuration = await services.configuration
        return configuration.providers.first { $0.id == providerID }?.apiKey ?? ""
    }

    /// 设置页：切换选中的 Provider 标签（仅改 UI，不生效）。
    public func selectProviderTab(_ id: String) {
        selectedProviderID = id
        remoteMessage = nil
        reasoningEffortDraft = id == activeProvider?.id ? activeProvider?.reasoningEffort : reasoningEffortDraft
    }

    /// 设置页：激活某个 Provider（本地或云端）。
    public func activateProvider(_ id: String) async {
        do {
            try await services.switchLLMProvider(id)
            bootMessage = nil
            remoteMessage = nil
        } catch {
            remoteMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    /// 设置页：校验云端 API Key 并拉取模型列表（不落盘）。
    public func fetchRemoteModels() async {
        let apiKey = await resolvedAPIKey(for: selectedProviderID)
        guard !apiKey.isEmpty else {
            remoteMessage = "请先填写 API Key"
            return
        }
        isFetchingRemoteModels = true
        remoteMessage = nil
        do {
            let models = try await services.fetchRemoteModels(providerID: selectedProviderID, apiKey: apiKey)
            remoteModels[selectedProviderID] = models.filter { !$0.isEmbeddingOnly }
            remoteMessage = "验证成功，获取到 \(models.count) 个模型"
        } catch {
            remoteMessage = error.localizedDescription
        }
        isFetchingRemoteModels = false
    }

    /// 设置页：保存云端配置（API Key + 模型 + 推理强度）并激活。
    public func applyRemoteProvider(model: String) async {
        let apiKey = await resolvedAPIKey(for: selectedProviderID)
        guard !apiKey.isEmpty else {
            remoteMessage = "请先填写 API Key"
            return
        }
        do {
            try await services.applyRemoteProvider(
                providerID: selectedProviderID,
                apiKey: apiKey,
                model: model,
                reasoningEffort: reasoningEffortDraft,
                kind: .llm
            )
            bootMessage = nil
            remoteMessage = "已启用云端模型 \(model)"
        } catch {
            remoteMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    // MARK: - 主题

    public func setThemeMode(_ mode: ThemeMode) async {
        themeMode = mode
        product.themeMode = mode
        await persistProduct()
    }

    public func toggleDayNight() async {
        await setThemeMode(Self.themeAfterCelestialTap(isNight: theme.isNight))
    }

    /// 右上角太阳 / 月亮被点后的目标主题（纯函数，便于单测）：
    /// 白天（太阳）→ 夜晚；夜晚（月亮）→ 白天。`isNight` 传当前**生效**主题。
    nonisolated public static func themeAfterCelestialTap(isNight: Bool) -> ThemeMode {
        isNight ? .day : .night
    }

    // MARK: - 进度

    /// 通关一个关卡：累加星星、标记完成并解锁下一关，随后持久化。
    public func completeLevel(_ levelID: String, earnedStars: Int) async {
        guard let index = progress.levels.firstIndex(where: { $0.id == levelID }) else { return }
        progress.levels[index].earnedStars = max(progress.levels[index].earnedStars, earnedStars)
        progress.levels[index].state = .completed
        if let next = progress.levels.indices.first(where: { $0 > index && progress.levels[$0].state == .locked }) {
            progress.levels[next].state = .unlocked
        }
        progress.recalculateSummary()
        await services.saveProgress(progress)
    }

    // MARK: - 模型（UI 可填可选，代码零字面量）

    public func applyModel(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await services.switchLLMModel(trimmed)
            modelDraft = trimmed
            bootMessage = nil
        } catch {
            bootMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    // MARK: - 学习设置

    public func setPracticeMode(_ mode: PracticeMode) async {
        product.practiceMode = mode
        await persistProduct()
    }

    public func setLearningLanguage(_ language: String) async {
        product.learningLanguage = language
        chat.profile.learningLanguage = language
        await persistProduct()
    }

    public func setNativeLanguage(_ language: String) async {
        product.nativeLanguage = language
        chat.profile.nativeLanguage = language
        await persistProduct()
    }

    public func setTeacherVoice(_ voice: String) async {
        product.teacherVoice = voice
        await persistProduct()
    }

    // MARK: - 森林伙伴（气泡 / 活动开关，全部持久化）

    public func setTeacherBubbles(_ enabled: Bool) async {
        product.teacherBubbles = enabled
        await persistProduct()
    }

    public func setAnimalBubbles(_ enabled: Bool) async {
        product.animalBubbles = enabled
        await persistProduct()
    }

    public func setAnimalActivity(_ enabled: Bool) async {
        product.animalActivity = enabled
        await persistProduct()
    }

    public func setAnimalActivityFrequency(_ value: Double) async {
        product.animalActivityFrequency = min(max(value, 0), 1)
        await persistProduct()
    }

    public func setVoicePreview(_ enabled: Bool) async {
        product.voicePreview = enabled
        await persistProduct()
    }

    /// 教师朗读语速：落到最接近的可选档位（设置与对话区两处共用同一份配置）。
    public func setSpeechRate(_ value: Double) async {
        let rate = SpeechRate.nearest(to: value)
        guard rate.rawValue != product.speechRate else { return }
        product.speechRate = rate.rawValue
        await persistProduct()
    }

    // MARK: - 伙伴形象

    public func setTeacherAnimal(_ kind: AnimalKind) async {
        product.teacherAnimal = kind.rawValue
        await persistProduct()
    }

    public func setStudentAnimal(_ kind: AnimalKind) async {
        product.studentAnimal = kind.rawValue
        await persistProduct()
    }

    // MARK: - 学习记录

    public func openRecords() async {
        showingShadowing = false
        showingVocabulary = false
        showingRecords = true
        await loadRecords()
    }

    public func openPractice() async {
        showingRecords = false
        showingShadowing = false
        showingVocabulary = false
    }

    // MARK: - 词汇本（Vocabulary，第 24 步）

    /// 进入词汇本页：加载词表 + 从复盘导入新词。
    public func openVocabulary() async {
        showingRecords = false
        showingShadowing = false
        showingScenarios = false
        showingVocabulary = true
        let imported = await services.importVocabularyFromReviews()
        if imported > 0 {
            vocabularyNotice = "从最近复盘导入了 \(imported) 个新词，点「查释义」配上中文解释。"
        }
        await reloadVocabulary()
        await loadVocabularyBankIfNeeded()
    }

    /// 重新读库 + 汇总统计。
    public func reloadVocabulary() async {
        let loaded = await services.vocabulary.entries()
        vocabularyEntries = loaded
        vocabularyStats = VocabularyStats.from(loaded)
        refreshVocabularySuggestions()
    }

    /// 添加一个生词（手动）。已存在时提示，不重复加。
    public func addVocabularyWord() async {
        let word = vocabularyDraft
        vocabularyDraft = ""
        guard await services.vocabulary.add(word: word) != nil else {
            vocabularyNotice = "「\(word)」没能加入词表（为空或没有学习数据库）。"
            return
        }
        await reloadVocabulary()
    }

    /// 给一个词补「详细中文释义 + 例句 + 重点单词」（按需 LLM）。
    public func defineVocabulary(id: UUID) async {
        guard let entry = vocabularyEntries.first(where: { $0.id == id }) else { return }
        isDefiningVocabulary.insert(id)
        defer { isDefiningVocabulary.remove(id) }
        do {
            _ = try await services.defineVocabulary(entry)
            collapsedVocabularyDefinitions.remove(id)
            await reloadVocabulary()
        } catch {
            vocabularyNotice = "「\(entry.word)」释义失败：\(error.localizedDescription)"
        }
    }

    /// 查释义按钮（与收起开关集成）：没释义 → 请求模型；有释义 → 展开 / 收起切换。
    public func toggleVocabularyDefinition(id: UUID) async {
        guard let entry = vocabularyEntries.first(where: { $0.id == id }) else { return }
        if entry.meaning.isEmpty {
            await defineVocabulary(id: id)
        } else if collapsedVocabularyDefinitions.contains(id) {
            collapsedVocabularyDefinitions.remove(id)
        } else {
            collapsedVocabularyDefinitions.insert(id)
        }
    }

    /// 重新释义：旧数据（早先版本只存了整段中文，没有音标 / 词性 / 例句翻译）
    /// 想升级成新格式时用 —— 重新请求模型并覆盖落库。
    public func redefineVocabulary(id: UUID) async {
        await defineVocabulary(id: id)
    }

    /// 复习判分：认识 / 忘了。判分后刷新（到期列表随之变化）。
    public func gradeVocabulary(id: UUID, remembered: Bool) async {
        _ = await services.vocabulary.grade(id: id, remembered: remembered)
        await reloadVocabulary()
    }

    /// 删除一个词。
    public func removeVocabulary(id: UUID) async {
        await services.vocabulary.remove(id: id)
        await reloadVocabulary()
    }

    public func dismissVocabularyNotice() {
        vocabularyNotice = nil
    }

    // MARK: - 词汇本 · 添加框联想

    /// 载入本地词库（一次）：撑起添加框联想候选 + 设置页的总词数统计。
    public func loadVocabularyBankIfNeeded() async {
        guard !vocabularyBankLoaded else { return }
        vocabularyBankLoaded = true
        vocabularyBankEntries = await services.dailyWordBankEntries()
        dailyBankTotal = vocabularyBankEntries.count
        refreshVocabularySuggestions()
    }

    /// 输入框内容变化 → 刷新悬浮联想（空输入 = 收起浮层）。
    public func vocabularyDraftChanged() {
        vocabularyMatches = VocabularySuggester.match(vocabularyDraft, in: vocabularySuggestions)
    }

    /// 收起联想浮层。
    public func dismissVocabularySuggestions() {
        vocabularyMatches = []
    }

    /// 选中一条联想：**只替换输入框内容**，真正入库仍要点「添加」。
    public func applyVocabularySuggestion(_ suggestion: VocabularySuggestion) {
        vocabularyDraft = suggestion.word
        vocabularyMatches = []
    }

    /// 重建联想候选池：词库（自带词性 / 中文）打底，本机已有释义覆盖上去。
    private func refreshVocabularySuggestions() {
        var byWord: [String: VocabularySuggestion] = [:]
        for entry in vocabularyBankEntries {
            byWord[entry.word.lowercased()] = VocabularySuggestion(
                word: entry.word,
                pos: entry.pos,
                translation: entry.translation,
                difficulty: entry.difficulty
            )
        }
        func overlay(_ word: String, _ definition: VocabularyDefinition, inVocabulary: Bool) {
            let key = word.lowercased()
            var suggestion = byWord[key] ?? VocabularySuggestion(word: word)
            suggestion.word = word
            if !definition.pos.isEmpty { suggestion.pos = definition.pos }
            let translation = definition.senses.isEmpty
                ? (definition.legacyText.split(separator: "\n").first.map(String.init) ?? "")
                : definition.senses
            if !translation.isEmpty { suggestion.translation = translation }
            suggestion.isInVocabulary = suggestion.isInVocabulary || inVocabulary
            byWord[key] = suggestion
        }
        for entry in vocabularyEntries {
            overlay(entry.word, VocabularyDefinitionRule.decodeStored(entry.meaning), inVocabulary: true)
        }
        for (word, definition) in dailyDefinitions {
            overlay(word, definition, inVocabulary: false)
        }
        vocabularySuggestions = byWord.values.sorted { $0.word.lowercased() < $1.word.lowercased() }
    }

    // MARK: - 词汇本 · 每日推荐

    /// 读「认识」计数（UserDefaults，轻量 [word: count]）。
    private static func loadDailyRecognitions() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: dailyRecognitionStorageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    private func saveDailyRecognitions() {
        if let data = try? JSONEncoder().encode(dailyRecognitions) {
            UserDefaults.standard.set(data, forKey: Self.dailyRecognitionStorageKey)
        }
    }

    /// 某词累计被点「认识」的次数。
    public func dailyRecognitionCount(word: String) -> Int {
        dailyRecognitions[word.lowercased()] ?? 0
    }

    /// 已认熟（满 3 次）的词集合：抽词时排除。
    private var retiredDailyWords: Set<String> {
        Set(dailyRecognitions.filter { $0.value >= Self.dailyRecognitionRetireCount }.keys)
    }

    /// 已学完（累计认识满 3 次）的词数。
    public var dailyLearnedCount: Int {
        dailyRecognitions.values.filter { $0 >= Self.dailyRecognitionRetireCount }.count
    }

    /// 重置每日推荐学习进度：清空「认识」记录与派生缓存，重新从最低档开始推荐。
    /// 同时记下**重置那一刻**的时间与已学词数（设置页展示「上次已学 x / y 词」）。
    public func resetDailyProgress() async {
        dailyProgressResetAt = Date()
        dailyProgressResetLearned = dailyLearnedCount   // 先记，再清空
        if let stamp = dailyProgressResetAt {
            UserDefaults.standard.set(stamp.timeIntervalSince1970, forKey: Self.dailyResetAtKey)
        }
        UserDefaults.standard.set(dailyProgressResetLearned, forKey: Self.dailyResetLearnedKey)

        dailyRecognitions = [:]
        saveDailyRecognitions()
        dailyAcknowledged = []
        expandedDailyWords = []
        dailyDefinitions = [:]
        dailyWords = await services.dailyWordRecommendation(excluding: retiredDailyWords)
        vocabularyNotice = "每日推荐学习进度已重置：认识记录清零，词库重新从简单档开始推荐。"
    }

    /// 每次启动随机抽 12 个推荐词（3 简单 / 5 中等 / 2 困难 / 2 词组，雅思标准）。
    /// 只在第一次进词汇本页时抽，之后进页面保持同一组；已认熟的词不再出现。
    public func loadDailyWordsIfNeeded() async {
        guard !dailyWordsLoaded else { return }
        dailyWordsLoaded = true
        dailyWords = await services.dailyWordRecommendation(excluding: retiredDailyWords)
    }

    /// 刷新：重新抽 12 个与当前展示的**不同**的词（清空展开态与本次「认识」记录，
    /// 已认熟的词不再出现；释义缓存保留可复用）。
    public func refreshDailyWords() async {
        var excluding = Set(dailyWords.map { $0.word.lowercased() })
        excluding.formUnion(retiredDailyWords)
        let next = await services.dailyWordRecommendation(excluding: excluding)
        // 词库不足时可能抽不满，把排除条件放宽再抽一次。
        dailyWords = next.isEmpty && !dailyWords.isEmpty
            ? await services.dailyWordRecommendation(excluding: retiredDailyWords)
            : next
        expandedDailyWords = []
        dailyAcknowledged = []
    }

    /// 每日推荐词的「查释义」按钮：展开 / 收起切换，首次展开时请求模型。
    public func toggleDailyDefinition(word: String) async {
        if expandedDailyWords.contains(word) {
            expandedDailyWords.remove(word)
            return
        }
        if dailyDefinitions[word] == nil {
            isDefiningDaily.insert(word)
            defer { isDefiningDaily.remove(word) }
            do {
                dailyDefinitions[word] = try await services.defineDailyWord(word)
                refreshVocabularySuggestions()   // 新释义（词性 / 中文）并入联想池
            } catch {
                vocabularyNotice = "「\(word)」释义失败：\(error.localizedDescription)"
                return
            }
        }
        expandedDailyWords.insert(word)
    }

    /// 每日推荐的「认识」按钮（同一按钮切换）：
    /// - 未计入 → 计数 +1，按钮变灰显示「再想想」（再点撤销 → 计数 -1）；
    /// - 每次出现最多计一次，换一批 / 重启后重新可计；
    /// - 累计满 3 次 → 该词从推荐中移除，之后不再推荐。
    public func toggleDailyRecognized(word: String) async {
        let key = word.lowercased()
        if dailyAcknowledged.contains(word) {
            dailyRecognitions[key] = max((dailyRecognitions[key] ?? 1) - 1, 0)
            dailyAcknowledged.remove(word)
        } else {
            dailyRecognitions[key] = (dailyRecognitions[key] ?? 0) + 1
            dailyAcknowledged.insert(word)
        }
        saveDailyRecognitions()
        if (dailyRecognitions[key] ?? 0) >= Self.dailyRecognitionRetireCount {
            dailyWords.removeAll { $0.word.caseInsensitiveCompare(word) == .orderedSame }
            vocabularyNotice = "「\(word)」累计认识 3 次，已从每日推荐中毕业 🎉"
        }
    }

    /// 把推荐词加入复习列表（用户手动；已在词表时只提示）。
    public func addDailyToReview(word: String) async {
        if vocabularyEntries.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
            vocabularyNotice = "「\(word)」已经在词表里了。"
            return
        }
        guard await services.vocabulary.add(word: word) != nil else {
            vocabularyNotice = "「\(word)」没能加入词表（为空或没有学习数据库）。"
            return
        }
        vocabularyNotice = "「\(word)」已加入复习列表。"
        await reloadVocabulary()
    }

    // MARK: - 跟读（Shadowing，第 22 步）

    /// 进入跟读页：加载素材 + 刷新统计。
    public func openShadowing() async {
        showingRecords = false
        showingScenarios = false
        showingVocabulary = false
        showingShadowing = true
        await loadShadowing()
    }

    /// 当前要跟读的句子（素材为空时 nil）。
    public var currentShadowingDrill: ShadowingDrill? {
        guard shadowingDrills.indices.contains(shadowingIndex) else { return nil }
        return shadowingDrills[shadowingIndex]
    }

    /// 加载素材（进程内只读一次）与跟读汇总。
    public func loadShadowing() async {
        if shadowingDrills.isEmpty {
            shadowingDrills = await services.shadowing.drills()
            if shadowingDrills.isEmpty {
                shadowingNotice = "没有找到跟读素材（Resources/Shadowing/*.json），请检查安装包资源是否完整。"
            }
        }
        await refreshShadowingStats()
    }

    public func refreshShadowingStats() async {
        shadowingStats = await services.shadowing.stats()
    }

    /// 换一句（顺序轮换，到底回到第一句）。换句即清掉上一句的结果。
    public func nextShadowingDrill() {
        guard !shadowingDrills.isEmpty else { return }
        shadowingIndex = (shadowingIndex + 1) % shadowingDrills.count
        shadowingComparison = nil
        shadowingPronunciation = nil
        shadowingNotice = nil
        voiceTranscript = nil
    }

    /// 听示范（老师的声音读这一句）。再点一次 = 重读。
    public func playShadowingExample() async {
        guard let drill = currentShadowingDrill else { return }
        guard isModelRunning(.tts) else {
            shadowingNotice = "\(await services.modelLabel(for: .tts)) 已关闭，请在设置里点绿色的「启动」后再听示范。"
            return
        }
        shadowingNotice = nil
        isShadowingBusy = true
        await services.shadowing.playReference(
            drill, voiceName: product.teacherVoice, language: "English",
            rate: Float(product.speechRate)
        )
        shadowingNotice = await services.shadowing.lastError()
        isShadowingBusy = false
    }

    /// 点一下开始跟读，再点一下停止并评分。
    public func toggleShadowingRecording() async {
        if isShadowingRecording {
            await finishShadowingRecording()
        } else {
            await startShadowingRecording()
        }
    }

    public func startShadowingRecording() async {
        guard currentShadowingDrill != nil else { return }
        guard isModelRunning(.asr) else {
            shadowingNotice = "\(await services.modelLabel(for: .asr)) 已关闭，请在设置里点绿色的「启动」后再跟读。"
            return
        }
        shadowingNotice = nil
        shadowingComparison = nil
        shadowingPronunciation = nil
        voiceTranscript = nil
        // 录音前先停掉示范，避免麦克风把老师的声音也录进去。
        await services.shadowing.stopAudio()
        await services.shadowing.startRecording(language: "English")
        isShadowingRecording = await services.voice.isRecording
        if let error = await services.shadowing.lastError() { shadowingNotice = error }
    }

    /// 停止录音 → **原始**识别（不做拼写纠正）→ 逐词对齐 + 发音评测 → 落库。
    public func finishShadowingRecording() async {
        guard let drill = currentShadowingDrill else { return }
        isShadowingRecording = false
        isShadowingBusy = true
        let recognized = await services.shadowing.finishRecording(language: "English")
        isShadowingBusy = false
        voiceTranscript = nil
        guard let recognized, !recognized.isEmpty else {
            shadowingNotice = await services.shadowing.lastError() ?? "没有听清，凑近麦克风再说一次"
            return
        }
        let result = await services.shadowing.evaluate(drill: drill, recognized: recognized)
        shadowingComparison = result.comparison
        shadowingPronunciation = result.pronunciation
        await refreshShadowingStats()
    }

    /// 听我的：回放刚才录的音，和示范对着听。
    public func replayShadowingRecording() async {
        guard await services.shadowing.hasRecording else {
            shadowingNotice = "还没有录音，先点「开始跟读」说一遍"
            return
        }
        shadowingNotice = nil
        isShadowingBusy = true
        do {
            try await services.shadowing.replayRecording(rate: Float(product.speechRate))
        } catch {
            shadowingNotice = "回放失败：\(error.localizedDescription)"
        }
        isShadowingBusy = false
    }

    /// 停掉跟读页面的一切声音（示范 / 回放）。
    public func stopShadowingAudio() async {
        await services.shadowing.stopAudio()
        isShadowingBusy = false
    }

    public func dismissShadowingNotice() { shadowingNotice = nil }

    /// 截图/验证辅助：拿一段文本直接走**同一条评测链路**，预览反馈界面。
    /// 不录麦克风、不落库 —— 只为了在无法合成点击的环境里验证渲染。
    ///
    /// 发音评测（第 23 步）需要原始音频才能量出语速 / 停顿 / 音高；
    /// 这里按参考句的词数合成一段「演示波形」（有起伏、有换气）驱动同一套纯函数，
    /// 让发音卡片也能端到端渲染。真实录音走的完全是同一条链路。
    func previewShadowingResult(_ recognized: String) async {
        guard let drill = currentShadowingDrill else { return }
        let comparison = ShadowingScorer.compare(reference: drill.text, recognized: recognized)
        shadowingComparison = comparison
        shadowingPronunciation = await services.pronunciation.report(
            reference: drill.text,
            recognized: recognized,
            samples: Self.demoWaveform(for: drill.text),
            sampleRate: 16_000,
            comparison: comparison
        )
    }

    /// 合成一段「像人说话」的演示波形：每个参考词一段带包络的浊音（基频句内起伏、
    /// 音量轻重交替），词间小间隙、句中一次换气。**确定性**（不用随机数），
    /// 同一句每次合成结果一致，评测分数因此可复现。
    nonisolated private static func demoWaveform(for text: String, sampleRate: Double = 16_000) -> [Float] {
        let words = ShadowingScorer.words(text)
        guard !words.isEmpty else { return [] }
        var samples: [Float] = Array(repeating: 0, count: Int(0.35 * sampleRate))
        for (index, _) in words.enumerated() {
            // 词长 0.38~0.50 秒（伪随机但确定）→ 折算约每分钟 135 词，落在理想语速带。
            let duration = 0.38 + Double((index * 7) % 5) * 0.03
            let count = Int(duration * sampleRate)
            // 基频 125~179Hz 循环上抬，让音高有起伏可测。
            let f0 = 125.0 + Double(index % 4) * 18.0
            // 轻重交替：重音节奏的代理量才有东西可量。
            let amplitude = index % 2 == 0 ? 0.55 : 0.85
            for position in 0..<count {
                let t = Double(position) / sampleRate
                let envelope = sin(.pi * Double(position) / Double(count))
                let vibrato = 1.0 + 0.03 * sin(2 * .pi * 5 * t)
                samples.append(Float(amplitude * envelope * sin(2 * .pi * f0 * vibrato * t)))
            }
            // 词间小间隙；句子过半处插一次 0.42 秒的换气（触发「停顿」维度）。
            let breathing = index == words.count / 2 && words.count >= 5
            samples.append(contentsOf: Array(repeating: Float(0), count: Int((breathing ? 0.42 : 0.06) * sampleRate)))
        }
        samples.append(contentsOf: Array(repeating: 0, count: Int(0.4 * sampleRate)))
        return samples
    }

    // MARK: - 情景对话（Role Play，第 21 步）

    /// 进行中的情景（nil = 普通练习）。UI 只读。
    public var activeScenario: ScenarioProgress? { chat.scenarioProgress }

    /// 打开情景选择浮层（顺手加载场景列表）。
    public func openScenarios() async {
        await loadScenarios()
        showingScenarios = true
    }

    public func closeScenarios() {
        showingScenarios = false
    }

    /// 加载内置场景（只读资源文件；失败时保持空列表，由 UI 提示）。
    public func loadScenarios() async {
        guard !didLoadScenarios else { return }
        scenarios = await services.availableScenarios()
        didLoadScenarios = true
    }

    /// 进入某个情景：切到情景对话模式、清掉记录页、老师以角色开场。
    public func startScenario(_ scenario: Scenario) async {
        showingRecords = false
        showingScenarios = false
        showingShadowing = false
        showingVocabulary = false
        if product.practiceMode != .conversation {
            product.practiceMode = .conversation
            await persistProduct()
        }
        chat.startScenario(scenario)
    }

    /// 结束当前情景（对话内容保留），并按轮次把星星结算到绑定关卡。
    public func endScenario() async {
        guard let progress = chat.scenarioProgress else {
            chat.endScenario()
            return
        }
        chat.endScenario()
        await settleScenario(progress)
    }

    /// 按 id 取场景（关卡绑定 / 记录页展示用）。场景在启动时已加载。
    public func scenario(for id: String?) -> Scenario? {
        guard let id else { return nil }
        return scenarios.first { $0.id == id }
    }

    /// 情景的母语标题（学习记录页展示用）。
    public func scenarioTitle(for id: String?) -> String? {
        scenario(for: id)?.titleZh
    }

    /// 立刻收起结算提示。
    public func dismissReward() {
        rewardDismissTask?.cancel()
        rewardDismissTask = nil
        lastReward = nil
    }

    /// 结算一次情景练习：答对轮次越多星越多；绑定关卡**累计**加星（封顶到本关需求）、
    /// 达标即通关并解锁下一关。
    private func settleScenario(_ finished: ScenarioProgress) async {
        let scenario = finished.scenario
        guard let index = progress.levels.firstIndex(where: { $0.scenarioID == scenario.id }) else {
            // 场景没有绑定关卡：只给一句反馈，不动进度
            lastReward = ScenarioRewardRule.reward(
                scenarioTitle: scenario.titleZh, stars: 0, levelTitle: nil, willCompleteLevel: false
            )
            scheduleRewardDismissal()
            return
        }
        let level = progress.levels[index]
        // 已通关的关卡重复练习不再重复加星，但照样给个反馈
        guard level.state != .completed else {
            lastReward = ScenarioReward(
                levelTitle: level.title, stars: 0, didCompleteLevel: false,
                message: "「\(scenario.titleZh)」又练了一遍，很稳！"
            )
            scheduleRewardDismissal()
            return
        }

        // 星星是「累计」的：本次按轮次给分，累加后封顶到本关需求（关卡最多就该拿满这么多星）。
        let scored = ScenarioRewardRule.stars(turnsUsed: finished.turnsUsed, maxTurns: scenario.maxTurns)
        let award = ScenarioRewardRule.award(earned: level.earnedStars, scored: scored, required: level.requiredStars)
        lastReward = ScenarioRewardRule.reward(
            scenarioTitle: scenario.titleZh, stars: award.gained,
            levelTitle: level.title, willCompleteLevel: award.didComplete
        )
        if award.gained > 0 {
            progress.levels[index].earnedStars = award.total
            if award.didComplete {
                await completeLevel(level.id, earnedStars: award.total)
            } else {
                progress.levels[index].state = .inProgress
                progress.recalculateSummary()
                await services.saveProgress(progress)
            }
        }
        scheduleRewardDismissal()
    }

    private func scheduleRewardDismissal() {
        rewardDismissTask?.cancel()
        rewardDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.lastReward = nil }
        }
    }

    public func loadRecords() async {
        records = await services.recentSessions(limit: 20)
        mistakes = await services.recentCorrections(limit: 50)
        await loadReviews()
    }

    public func loadReviews() async {
        reviews = await services.recentReviews(limit: 10)
        if let first = reviews.first {
            latestReview = first
        } else {
            latestReview = await services.sessionReview(sessionID: chat.sessionID)
        }
    }

    /// 生成本次练习的复盘总结（本地模型完成，失败时自动给规则版总结）。
    public func generateSessionReview() async {
        guard !isGeneratingReview else { return }
        isGeneratingReview = true
        defer { isGeneratingReview = false }
        let duration = await services.sessionDuration(sessionID: chat.sessionID)
        let corrections = chat.correctionsByMessage.values.flatMap { $0 }
        let review = await services.makeSessionReview(
            sessionID: chat.sessionID,
            messages: chat.messages,
            corrections: corrections,
            duration: duration
        )
        latestReview = review
        reviews = await services.recentReviews(limit: 10)
    }

    // MARK: - 缓存管理

    public func refreshCacheInfo() async {
        cacheSnapshot = await services.cacheSnapshot()
    }

    /// 清理可再生的缓存（学习记忆与配置始终保留）。
    public func clearCache() async {
        let before = await services.clearCaches()
        let after = await services.cacheSnapshot()
        cacheSnapshot = after
        cacheFreedBytes = max(before.totalBytes - after.totalBytes, 0)
    }

    // MARK: - 高级（普通用户不需要）

    public func setLLMEndpoint(_ endpoint: String) async {
        do {
            try await services.setLLMProviderField(endpoint: endpoint)
            bootMessage = nil
        } catch {
            bootMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    public func setLLMTemperature(_ temperature: Double) async {
        do {
            try await services.setLLMProviderField(temperature: temperature)
        } catch {
            bootMessage = error.localizedDescription
        }
    }

    private func persistProduct() async {
        try? await services.updateProduct(product)
    }
}
