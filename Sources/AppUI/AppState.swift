import AIDomain
import AIInterfaces
import AIServices
import AppCore
import AppKit
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
    /// 当前生效 Provider 是否为云端 API（设置页用来区分「本地 / 云端」）。
    public let isRemote: Bool
    /// 当前生效 Provider 的展示名（如「本地模型」「OpenAI 语音识别」）。
    public let providerName: String?
    /// 当前生效 Provider 的 id（设置页用它给「正在使用的那家」点绿点——
    /// 有 Key 草稿 ≠ 在用：用户切走后草稿还在，绿点却不该亮，2026-09-13 反馈）。
    public let providerID: String?
    /// ~/AI_Models 下自动检测到的本地模型。
    public let localModels: [LocalModel]

    public init(
        kind: AIProviderKind,
        healthOK: Bool,
        healthText: String,
        currentModel: String?,
        sourceDescription: String,
        isRemote: Bool,
        providerName: String?,
        providerID: String? = nil,
        localModels: [LocalModel]
    ) {
        self.kind = kind
        self.healthOK = healthOK
        self.healthText = healthText
        self.currentModel = currentModel
        self.sourceDescription = sourceDescription
        self.isRemote = isRemote
        self.providerName = providerName
        self.providerID = providerID
        self.localModels = localModels
    }
}

/// 配置体检的一行：某个能力「该由谁生效」以及**为什么生不生效**。
///
/// 数据来自 `ModelRegistry` 的读侧投影（`modelConfigs` / `defaultModelConfig` /
/// `registryInconsistencies`）—— 这三条以前没有任何界面在读，等于「配置体检」这个能力
/// 只存在于代码里。设置页的「配置体检」区块就是它们的消费方。
public struct RegistryCheckRow: Sendable, Equatable, Identifiable {
    public let kind: AIProviderKind
    /// 当前生效的那个 Provider（nil = 解析不出来，见 `issues`）。
    public let effective: ModelConfig?
    /// 该能力配置里的 Provider 总数 / 启用数（用来区分「一个都没配」和「配了但没启用」）。
    public let providerCount: Int
    public let enabledCount: Int
    /// 一致性问题（空 = 这一项健康）。
    public let issues: [String]
    /// 该能力此刻的健康文案（有就展示：配置没问题 ≠ 服务真的通）。
    public let healthDescription: String?

    public var id: String { kind.rawValue }
    public var isHealthy: Bool { issues.isEmpty && effective != nil }

    public init(
        kind: AIProviderKind,
        effective: ModelConfig?,
        providerCount: Int,
        enabledCount: Int,
        issues: [String],
        healthDescription: String? = nil
    ) {
        self.kind = kind
        self.effective = effective
        self.providerCount = providerCount
        self.enabledCount = enabledCount
        self.issues = issues
        self.healthDescription = healthDescription
    }
}

/// 跟读的粒度（#232）。
public enum ShadowingMode: String, Sendable, CaseIterable, Identifiable {
    /// 一句一练：听一句 → 跟读一句 → 看这一句的逐词反馈。
    case sentence
    /// 整段跟读：听一整段 → 一口气跟读 → 把整段回填到每一句，逐句给分。
    case passage

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sentence: "一句一练"
        case .passage: "整段跟读"
        }
    }

    /// 顶栏切换按钮的图标。
    public var symbol: String {
        switch self {
        case .sentence: "text.alignleft"
        case .passage: "text.bubble"
        }
    }

    public var help: String {
        switch self {
        case .sentence: "一句一句地跟，逐词反馈看得最细"
        case .passage: "一口气读完一整段，练的是连贯与停顿"
        }
    }
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
    /// 服务装配中（**只覆盖本地装配**：配置 / 语音 / 健康探测）。
    ///
    /// ⚠️ 它**不再**覆盖老师的开场白：开场白是一次真实模型调用（本机冷加载实测 30～60s），
    /// 以前 `isBooting` 一直盖到它结束，于是开屏半分钟里界面既不能看也不能用。
    /// 现在开场白挪到后台（见 `openInBackground()`），首屏由本地数据秒开。
    public private(set) var isBooting = true
    /// 开场白 / 续做仍在**后台**生成（首屏已经能练，只是老师还没开口）。
    public private(set) var isPreparingOpening = false
    /// 老师已经开口，但人不在对话页 —— 左栏「练习」给个提示点，回到对话页即清。
    public private(set) var teacherOpenerPending = false
    public private(set) var bootMessage: String?
    public var modelDraft: String = ""
    public var showingSettings = false
    /// 当前有没有整块面板 / 页面盖在聊天区之上（面板一开，划词气泡就该立刻收掉）。
    public var isContentCovered: Bool {
        showingSettings || showingRecords || showingScenarios
            || showingMaterialUpload || showingVocabulary
            || showingDictionary || showingProgress || showingWriting || showingReading
    }
    // MARK: 模型 Provider（本地 + 云端并存）
    /// 当前生效的 LLM Provider（决定实际调用本地还是云端）。
    public private(set) var activeProvider: ProviderConfig?
    /// 设置页当前选中的 Provider 标签（可编辑未生效的 Provider）。
    public var selectedProviderID: String = "ollama.llm"
    /// 云端 API Key 草稿（按 provider id 存，避免切换标签互相覆盖）。
    public var apiKeyDrafts: [String: String] = [:]
    /// 云端推理强度草稿（low / medium / high；nil = 标准）。
    public var reasoningEffortDraft: String?
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
    public private(set) var speechPhase: SpeechPhase = .idle {
        didSet { lookupBubble.refreshSpeaking() }
    }
    /// 正在准备的朗读原文：让对应消息的按钮立刻显示「准备中」。
    public private(set) var speakingText: String? {
        didSet { lookupBubble.refreshSpeaking() }
    }
    /// 教师回复完成后自动朗读（设置里可关）。
    public var autoSpeak = false
    /// 当前教师音色（runtime 自报的候选 + 配置值兜底）。
    public private(set) var availableVoices: [String] = ["Serena", "Vivian", "Ryan", "Aiden", "Eric"]
    /// 本地语音 runtime 自报描述（如「Qwen3-TTS 0.6B · mps」），nil = 未知。
    public private(set) var ttsRuntimeInfo: String?
    /// 当前朗读投递方式：云端整段合成、本地分句流水线（随语音装配刷新）。
    public private(set) var speechDelivery: SpeechDelivery = .segmented
    /// 最近语音错误（nil = 正常）。
    public private(set) var voiceError: String?

    // MARK: - 克隆音色（第 24 步）

    /// 全部音色档案（内置 + 克隆）。
    public private(set) var voiceProfiles: [VoiceProfile] = []
    /// 当前 TTS 供应商是否支持音色克隆（不支持时 UI 直接说明，而不是让用户配完才发现不行）。
    public private(set) var voiceCloningSupported = false
    /// 克隆音色操作的结果提示（成功 / 失败，可关闭）。
    public private(set) var voiceProfileNotice: String?
    /// 正在试听 / 启用的克隆音色 id（按钮转圈用）。
    public private(set) var busyVoiceProfileID: String?

    /// 当前启用的克隆音色（nil = 内置音色）。
    public var activeClonedVoice: VoiceProfile? {
        guard let id = product.activeVoiceProfileID else { return nil }
        return voiceProfiles.first { $0.id == id }
    }

    /// 「正在使用克隆音色」的可见提示（内置音色返回 nil）。
    ///
    /// 需求原文就是「clear indication when a cloned/custom voice is active」——
    /// 用户任何时候都该知道自己在听的是不是克隆音色。
    public var activeVoiceIndicator: String? {
        activeClonedVoice.flatMap { VoiceAccessPolicy.activeIndicator(for: $0) }
    }
    /// 拼写纠正当前的执行口径（设置页展示）。
    ///
    /// 拼写纠正在「说完一句话」之后**自动**发生，用户看不到——所以必须把口径写出来：
    /// 云端语言模型下一律跳过，避免一次语音输入多出一笔看不见的 token 账单。
    public private(set) var spellingNote: String = ""
    /// 历史坏配置的修复提示（「本地模型名被写进云端供应商」被就地清掉时出现）。
    public private(set) var modelHealNotice: String?
    /// 坏配置修复只在本次运行做一次（幂等，修完配置里就没有坏值了）。
    private var didHealCrossProviderModels = false
    /// 语音服务健康状态。
    public private(set) var asrHealth: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    public private(set) var ttsHealth: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    /// 发音评测声学通道状态。`configurationInvalid` 不代表坏了——没有云端发音评测时
    /// 评测走规则推断，这一项只是用来如实说明「这次是实测还是推断」。
    public private(set) var pronunciationHealth: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    // MARK: 模型管理中心（本地检测 ~/AI_Models + 外部模型统一入口）
    /// 每个能力的模型信息（当前模型/来源/本地检测列表）。
    public private(set) var capabilityInfos: [AIProviderKind: CapabilityModelInfo] = [:]
    /// 各能力**当前生效**的 Provider id / 模型名（覆盖**全部**能力，含 `llm`）。
    ///
    /// ⚠️ 不能拿 `capabilityInfos` 代替：它只覆盖 asr / tts / vad / embedding / pronunciation
    /// 五项，「AI 大脑」不在其中。外部模型面板曾经按它判断「谁是当前生效的供应商」，
    /// 于是 llm 这条路上永远查不到 —— 表现为绿点不亮、面板不定位当前供应商、
    /// 选好的模型跳回默认（2026-09-14 反馈的第三组问题）。
    /// 这里存的是**生效结果**（`resolvedProvider` / `resolvedModel`），不是草稿、不是意图。
    public private(set) var activeProviderIDs: [AIProviderKind: String] = [:]
    public private(set) var activeModels: [AIProviderKind: String] = [:]
    /// 外部模型 API Key 草稿（providerID -> key）。
    ///
    /// **输入框就是唯一真相**：绿点、指纹、能不能启用云端、调用时用哪把 Key，
    /// 全部只看这里有没有内容。配置里存着的旧 Key 不会被隐式沿用
    /// （用户明确要求：空框 = 不配置）。
    public var externalKeyDrafts: [String: String] = [:]
    /// 已保存密钥的指纹（providerID -> `••••末4位`）。
    ///
    /// 只用来回答一个问题：「应用现在拿的是哪一把 Key」。
    /// 换 Key 后如果指纹没变，说明改的不是当前生效的那一条 Provider——省下反复试错。
    public private(set) var externalKeyFingerprints: [String: String] = [:]
    /// 本次运行里被用户**主动清空**输入框的供应商。
    ///
    /// 用户清空输入框 = 明确表示「这个供应商不配置」。重开设置时不得再从配置里把旧 Key
    /// 回填回来——否则「空框」总是被旧密钥复活，用户永远清不掉它。
    private var clearedKeyDrafts: Set<String> = []
    /// 外部模型探测结果（providerID -> models）。
    public private(set) var externalModels: [String: [DiscoveredModel]] = [:]
    /// 每个能力当前展开的外部 Provider 标签。
    public var externalSelectedProvider: [String: String] = [:]
    /// 外部 Provider 候选缓存（kind -> options，设置页打开时拉一次）。
    public var externalProviderCache: [String: [(id: String, name: String)]] = [:]
    /// 免密钥供应商集合（配置 `api_key_required = false`）：设置页对它们隐藏 Key 输入框。
    public private(set) var keylessProviders: Set<String> = []
    public private(set) var isFetchingExternal = false
    /// 外部模型操作结果消息（providerID -> message）。
    public var externalMessages: [String: String] = [:]
    /// 最近一次**认证通过**的 Key（providerID -> 清洗后的 Key）。
    ///
    /// 「确认配置」必须建立在真实认证之上：只有刚才用同一把 Key 验证成功过才免二次探测，
    /// 否则应用前先打一次真实验证——失败就整路失败，卡片维持原样（2026-09-14 反馈）。
    public private(set) var externalVerifiedKeys: [String: String] = [:]
    /// 手动填写模型名草稿（kind -> name）。
    public var customModelDrafts: [String: String] = [:]
    // MARK: 云端调用审计（费用护栏留痕）
    /// 本次运行的对外调用汇总（计费 / 探测 / 拦截 + 涉及模型 + 异常扇出预警）。
    ///
    /// 存在的意义只有一个：让「应用到底调了哪几个模型」变成可核对的事实，
    /// 而不是等账单出来才发现不对。云端调用一条都不例外地记在这里。
    public private(set) var remoteCallSummary: RemoteCallSummary = RemoteCallSummary()
    /// 最近若干条对外调用记录（新的在前，只含元数据，不含任何请求正文）。
    public private(set) var remoteCallRecords: [RemoteCallRecord] = []
    /// 中栏切换：学习记录页（false = 练习对话）。
    public var showingRecords = false
    // MARK: 写作练习（#230）
    /// 中栏切换：写作页。
    public var showingWriting = false
    /// 今天的写作题（`WritingTopicPicker` 恒定一天一题；进页时取一次）。
    public private(set) var writingTopic: WritingTopic?
    /// 写作草稿。
    public var writingDraft = ""
    /// 最近一次批改结果（nil = 还没交过 / 批改失败）。
    public private(set) var writingReview: WritingReview?
    /// 正在批改（按钮 loading）。
    public private(set) var isWritingReviewing = false
    /// 写作页的提示消息（词数不足 / 批改失败 / 已加入词汇本）。
    public var writingNotice = ""

    // MARK: 阅读理解（#231 / #233）
    /// 中栏切换：阅读页。
    public var showingReading = false
    /// 今天已生成的短文（旧 → 新，含作答进度；**落学习库，重启不丢**）。
    ///
    /// 每天生成一次后固定展示：进页先取库里的，不再自动重新出题；
    /// 只有「换一篇」才追加一篇。回看靠 `readingEntryIndex` 切换。
    public private(set) var readingEntries: [StoredReading] = []
    /// 当前展示第几篇（`readingEntries` 下标）。
    public private(set) var readingEntryIndex: Int = 0
    /// 正在生成短文（首篇或「换一篇」）。
    public private(set) var isReadingLoading = false
    /// 已交卷（交卷后锁定选项、标对错、展开解析）——指**当前展示**的这篇。
    public private(set) var isReadingReviewed = false
    /// 每题的选择：题目下标 → 选项下标（当前展示的这篇）。
    public private(set) var readingChoices: [Int: Int] = [:]
    /// 展开解析卡的题目下标（交卷后自动全展开，可手动收起）。
    public var expandedReadingQuestions: Set<Int> = []
    /// 阅读页的提示消息（生成失败等）。
    public var readingNotice = ""

    /// 当前展示的短文。
    public var readingPassage: ReadingPassage? {
        readingEntries.indices.contains(readingEntryIndex)
            ? readingEntries[readingEntryIndex].passage
            : nil
    }
    /// 学习记录页要定位到的卡片（「前往学习记录巩固」这类跨页跳转用）。
    ///
    /// 页面消费后自行清空 —— 下次进来不该还自动跳一次：跳转是**这一次点击**的意图，
    /// 不是这一页的默认行为。
    public var recordsFocus: RecordsFocus?
    /// 情景选择浮层开关（应用内 overlay，随日夜主题）。
    public var showingScenarios = false
    /// 内置情景场景（数据来自资源文件；空 = 资源缺失，UI 给可操作提示）。
    public private(set) var scenarios: [Scenario] = []
    /// 是否已尝试加载过场景（用于区分「加载中」与「确实为空」）。
    public private(set) var didLoadScenarios = false
    // MARK: 上传材料自动出题（#208）
    /// 已生成的材料（材料 → 情景 + 跟读句 + 生词表），按生成时间倒序。
    public private(set) var materialKits: [MaterialKit] = []
    /// 「上传材料」浮层开关。
    public var showingMaterialUpload = false
    /// 材料输入草稿（粘贴或导入的文字）。
    public var materialDraft = ""
    /// 是否正在生成（按钮 loading；一次生成 = 一次模型请求）。
    public private(set) var isGeneratingMaterial = false
    /// 生成结果回执（成功 / 失败都给，UI 展示后由 `dismissMaterialResult` 清掉）。
    public var materialResult: String?
    /// 最近一次生成成功的材料（浮层里展示「拆出了什么」）。
    public private(set) var lastGeneratedKit: MaterialKit?
    /// 学习记录数据（进入页面时加载）。
    public private(set) var records: [SessionSummary] = []
    public private(set) var mistakes: [GrammarCorrection] = []
    /// 练习复盘：最新一份（本次会话或最近一次）。nil = 还没生成过。
    public private(set) var latestReview: SessionReview?
    /// 历史复盘（学习记录页可回看）。
    public private(set) var reviews: [SessionReview] = []
    /// 会话 id → 复盘（记录页展开某条练习记录时用；`loadRecords` 一次取够）。
    ///
    /// ⚠️ 不复用 `reviews` 的 10 条上限：记录页列了 20 条练习，
    /// 用 10 条去索引会出现「第 11 条明明有复盘却显示没有」。
    public private(set) var reviewIndex: [UUID: SessionReview] = [:]
    /// 跨会话学习记忆（第 15 步）：老师记住了什么，学员也该看得见。
    public private(set) var learningMemory: LearningMemory = .empty
    /// 清除记忆后的结果/失败提示（清除不可逆，做完必须给回执）。
    public var learningMemoryNotice: String?
    /// 是否正在生成复盘（按钮 loading）。
    public private(set) var isGeneratingReview = false
    /// 数据目录缓存快照（设置页「缓存管理」卡片）。
    public private(set) var cacheSnapshot: CacheSnapshot = .empty
    /// 上一次清理释放的字节数（展示用，0 = 无）。
    public private(set) var cacheFreedBytes: Int64 = 0
    /// 隐私状况（设置页「隐私与安全」卡片）：有无外发、发往哪里、本地数据在哪。
    public private(set) var privacyReport: PrivacyReport = .empty
    /// 配置文件（`config.json`）的绝对路径。设置页「运行环境」展示 + 在 Finder 中打开。
    public private(set) var configLocationPath = ""
    /// 内置默认配置载入失败的原因（nil = 正常）。
    ///
    /// ⚠️ 载入失败时应用会以「零 provider」启动，界面上就是「一个模型都没有」。
    /// 以前这件事完全无声，用户只能靠猜；现在把它摆到设置页最上面。
    public private(set) var configLoadFailure: String?
    /// 「重新载入配置」的结果回执（nil = 不显示）。
    public private(set) var configReloadNotice: String?
    /// 配置体检：每个能力「该由谁生效、生不生效得了」。
    public private(set) var registryCheckRows: [RegistryCheckRow] = []
    /// 记忆索引的健康态（比「装配过没有」更进一步：能看出服务后来是不是关了）。
    public private(set) var embeddingHealth: ProviderHealth = .configurationInvalid(reason: "尚未检查")
    /// 关卡 → 情景 绑定（来自资源文件；随情景一起加载）。
    private var levelBindings: [String: String] = [:]

    /// 已导出的备份（设置页「存储与缓存」卡片），新的在前。
    public private(set) var backupSnapshots: [BackupRecord] = []
    /// 备份导出中的标记（按钮 loading）。
    public private(set) var isExportingBackup = false
    /// 最近一次导出失败的原因（nil = 没失败过）。
    public private(set) var backupError: String?
    /// 学习库被隔离重建时的说明（nil = 一切正常）——**必须让用户看见**。
    public private(set) var databaseRecoveryNote: String?
    /// 备份导入：已通过校验、等用户确认的恢复计划（nil = 没在导入流程中）。
    public private(set) var backupImportPlan: BackupImportPlan?
    /// 备份导入：选中的压缩包路径（确认后交给 stageRestore）。
    private var backupImportPath: String?
    /// 备份导入：确认后「已安排恢复，重启生效」的回执（nil = 不显示）。
    public private(set) var backupImportNotice: String?
    /// 启动时应用的备份恢复说明（nil = 本次启动没有恢复动作）。
    public private(set) var restoreNote: String?
    /// 情景结算奖励提示（nil = 不显示）。UI 展示数秒后自动消失。
    public private(set) var lastReward: ScenarioReward?
    /// 最近一次情景练习的 CEFR 覆盖度判定（nil = 不显示）。
    ///
    /// 与 `lastReward` **分开**：奖励说的是「拿了几颗星」（参与度），
    /// 这里说的是「这一关的目标句真的说到了几句」（内容覆盖），
    /// 两者可能不一致 —— 比如说满轮次但全是短句，星星拿满、目标句一句没说。
    /// 混成一条提示就会逼着其中一件事说谎。
    public private(set) var lastAssessment: CurriculumAssessment?
    /// 产生 `lastAssessment` 的是哪个情景 —— 判定卡上要写清这是哪一关的判定，
    /// 而这时情景通常已经结束了（`activeScenario` 已清空），只能自己记一份。
    public private(set) var lastAssessedScenarioID: String?

    // MARK: 主线任务 / 前情提要（需求 3–6）
    /// 各情景的主线任务进度（情景卡片、大树节点一次读库后缓存）。
    public private(set) var questRecords: [String: ScenarioQuestRecord] = [:]
    /// 当前任务的前情提要（情景模式下的引导卡片）。
    public private(set) var briefing: ScenarioBriefing?
    /// 展开的情景卡片 id（点击卡片展开主线任务与教学重点，再点收起）。
    /// **展开不等于进练习**：进练习要点卡片里的「开始任务」（需求 3）。
    public var expandedScenarioID: String?
    /// 上一段练习自动复盘的结果提示（nil = 不显示）。
    public var practiceNotice: String?

    /// 关闭「自动复盘」回执提示。
    public func dismissPracticeNotice() { practiceNotice = nil }

    // MARK: 考试模式（雅思口语 / 面试问答）

    /// 内置考卷（资源文件；空 = 资源缺失，面板给可操作提示）。
    public private(set) var examBlueprints: [ExamBlueprint] = []
    /// 是否已尝试加载过考卷（区分「加载中」与「确实为空」）。
    public private(set) var didLoadExamBlueprints = false
    /// 进行中的考试（nil = 没在考）。纯值类型，可单测。
    public private(set) var examRunner: ExamRunner?
    /// 考后报告（非 nil = 结算卡可见）。
    public private(set) var examReport: ExamReport?
    /// 示范答案（题号 → 回答），考后一次请求拿回来。
    public private(set) var examSampleAnswers: [Int: String] = [:]
    /// 示范答案没拿到时的说明（nil = 正常）。
    public private(set) var examSampleNotice: String?
    /// 正在写示范答案（卡片上转圈）。
    public private(set) var isGeneratingExamSamples = false
    /// 本次该给哪几问写示范答案（结算卡据此显示题面 + 转圈，重试也用它 ——
    /// 重算会随作答变化而漂，同一份报告不该长出不同的示范题）。
    public private(set) var examSampleTargets: [ExamSampleTarget] = []
    private var examSampleTask: Task<Void, Never>?

    /// 是否正在考试（界面据此切到考场态）。
    public var isExamActive: Bool { examRunner != nil }

    /// 考场条的数据快照（视图只读它，不自己算时间）。
    ///
    /// ⚠️ 考完（或提前交卷）之后返回 nil：那时该看的是结算卡，
    /// 一条「第 7/7 问 · 等待考官提问…」还挂着只会让人以为考试没结束。
    public var examBarModel: ExamBarModel? {
        guard let runner = examRunner, !runner.isFinished else { return nil }
        return ExamBarModel(
            title: runner.blueprint.title,
            stageTitle: runner.currentStage?.title ?? runner.blueprint.title,
            instructions: runner.currentStage?.instructions ?? "",
            questionNumber: runner.questionNumber,
            totalQuestions: runner.totalQuestions,
            minimumWords: runner.currentStage?.minimumWords ?? 0,
            limitSeconds: runner.questionLimitSeconds,
            deadline: runner.questionDeadline,
            // 题号 + 起表时刻 = 这一问的唯一键：`.task(id:)` 靠它换一次计时任务，
            // 少了起表时刻，下一问的倒计时会接着上一问的计时跑。
            questionKey: "\(runner.questionNumber)-\(runner.questionDeadline?.timeIntervalSince1970 ?? 0)"
        )
    }
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

    // MARK: 聊天附件（第 3 项需求：图片 / 视频 / 文件）

    /// 已选好、还没发出去的附件（输入框上方那一行胶囊）。
    ///
    /// 放在「待发」区而不是「选了就发」：学员常常一次选两三张图再配一句话，
    /// 中途还想删掉其中一张 —— 选完即发会逼他重来一遍。
    public private(set) var pendingAttachments: [ChatAttachment] = []
    /// 附件相关的提示（超限 / 导入失败，可关闭）。
    public private(set) var attachmentNotice: String?
    /// 正在导入附件（选大文件时给个转圈）。
    public private(set) var isImportingAttachments = false
    /// 最近一次「保存附件」的结果提示（成功/失败都说一声，静默失败最容易被当成已保存）。
    public private(set) var attachmentSaveNotice: String?
    /// 当前生效的 LLM 能不能**真的读图**（false = 图片只会以文件名告诉老师）。
    ///
    /// 来源是 `ProviderCapabilities.vision`（适配器按配置声明自报）。
    /// 以前这个能力位只有产出方没有消费方，于是「不读图的模型收到图」是静默降级的。
    public private(set) var llmSupportsVision = true
    /// 「已保存」回执的自动收起计划（`dismissReward` 同款做法）。
    private var attachmentSaveNoticeTask: Task<Void, Never>?

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
    /// **正在放声音**（示范 / 回放）。
    ///
    /// 与 `isShadowingBusy` 分开：忙碌态还覆盖「识别 + 评分」那段窗口，
    /// 那里给「停止」按钮是错的（停的是声音，不是评分）。按钮据此在
    /// 「听示范」与「停止」之间切换。
    public private(set) var isShadowingPlaying = false
    /// 跟读提示（可关闭，nil = 正常）。
    public private(set) var shadowingNotice: String?

    /// 正在生成今天的 20 句（页面上转圈，避免用户以为「卡住了」）。
    public private(set) var isShadowingLoading = false
    /// 页面上这批句子是不是**今天现生成**的（false = 内置素材兜底）。
    /// 页头据此如实说明来源 —— 用户有权知道自己在练的是哪种素材。
    public private(set) var shadowingIsDailyGenerated = false

    // MARK: 段落级跟读（#232）

    /// 跟读粒度：一句一练 / 整段跟读。
    public private(set) var shadowingMode: ShadowingMode = .sentence
    /// 当前练到第几段（在 `shadowingPassages` 中的下标）。
    public private(set) var shadowingPassageIndex = 0
    /// 最近一次段落评测结果（nil = 这一段还没评过）。
    public private(set) var shadowingPassageResult: ShadowingPassageResult?
    /// 最近一次段落发音评测（整段音频量出来的）。
    public private(set) var shadowingPassagePronunciation: PronunciationReport?
    // MARK: 语音流式输入
    /// 录音过程中实时识别出的文本（nil = 未在录音）。UI 把它写进输入框。
    public private(set) var voiceTranscript: String?

    // MARK: - 词汇本（第 24 步 Vocabulary）

    /// 是否停在词汇本页（占中间栏）。
    public var showingVocabulary = false
    /// 词汇表（进页面时加载；新 → 旧）。
    public private(set) var vocabularyEntries: [VocabularyEntry] = []
    /// 词汇本收录的**去重**单词数（按词忽略大小写；`reloadVocabulary` 是唯一失效点）。
    /// 设置页词汇本卡片的「单词数」用它——收录 / 删除词条后卡片数字要跟着走。
    public private(set) var vocabularyUniqueWordCount = 0
    /// 词汇统计（总数 / 待复习 / 已掌握 / 已释义）。
    public private(set) var vocabularyStats: VocabularyStats = .empty
    /// 正在补释义的词（按钮 loading）。
    public private(set) var isDefiningVocabulary: Set<UUID> = []
    /// 词汇本提示（可关闭；nil = 正常）。
    public private(set) var vocabularyNotice: String?
    /// 释义被手动收起的词条（「查释义」按钮与收起开关是同一个按钮；
    /// 已有释义默认展开，收起后点「看释义」再展开，不重新请求模型）。
    public private(set) var collapsedVocabularyDefinitions: Set<UUID> = []
    /// 已经尝试过「词性 / 中文补全」的词条（每个词一次，失败不反复重试）。
    private var termsHealAttempted: Set<UUID> = []
    /// 每日推荐（**按天恒定**的 12 个：3 简单 / 5 中等 / 2 困难 / 2 词组；不落库）。
    /// 同一天、同一学习语言必定是同一批（种子见 `DailySeed`）；只有「换一批」才重抽。
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
    /// 本地词库是否已载入（只为设置页「已学 x / y 词」的分母 `dailyBankTotal` 载入一次）。
    private var vocabularyBankLoaded = false

    // MARK: - 词典（新功能：词典库 + 查单词）
    //
    // 两个页面共用中间栏（顶栏一个按钮来回切）。**查词会话不因为切走而丢**：
    // 用户口径明确「切回查单词页要继续展示之前那个词的展示页，跳转历史也还在」。

    /// 词典页的两种模式。
    public enum DictionaryMode: String, Sendable, Equatable {
        /// 查单词（默认）。
        case search
        /// 词典库（书架）。
        case library

        /// 顶栏那个切换按钮的文案：**写着「要去的地方」**。
        public var switchTitle: String {
            switch self {
            case .search: "进入词典库"
            case .library: "去查单词"
            }
        }

        public var switchIcon: String {
            switch self {
            case .search: "books.vertical"
            case .library: "magnifyingglass"
            }
        }

        public func toggled() -> DictionaryMode { self == .search ? .library : .search }
    }

    /// 是否停在词典页（占中间栏）。
    public var showingDictionary = false
    /// 当前模式：查单词 / 词典库。
    public var dictionaryMode: DictionaryMode = .search
    /// 词典库里可见的书（已按优先级排序）。
    public private(set) var dictionaryBooks: [DictionaryBook] = []
    /// 被删掉、**还能恢复**的内置词典。
    public private(set) var restorableDictionaries: [DictionaryBook] = []
    /// 可见词典的词条总数（各书相加；**不去重**，只用于分账展示）。
    public private(set) var dictionaryWordCount = 0
    /// **去重后**的词库规模（跨词典同名词只算一个）。
    /// ⚠️ 设置页卡片 / 词典页页头显示的「词库共 N 词」都用这个，不是上面那个相加值：
    /// 三本内置词典相加 12,625，按词去重后只有 7,404 —— 两个数同时在界面上出现必然被当成 bug。
    public private(set) var dictionaryUniqueWordCount = 0
    /// 每本书在「每日推荐词源」里的名次（bookID → 名次；没勾选的不在表里）。
    public private(set) var dictionarySourceRanks: [String: Int] = [:]
    /// 空查询页上的「试试这些词」（从可见词典间隔取，不随机）。
    public private(set) var dictionarySampleWords: [String] = []
    /// 那一排胶囊的**轮换词池**（随机抽一批，够页面换十几轮）。
    ///
    /// 与 `dictionarySampleWords` 分开：那个是「一页之内不许自己变」的固定样例，
    /// 这个专门给「每 10 秒换一批」用 —— 换的时候从内存里取，不再查库。
    public private(set) var dictionarySamplePool: [String] = []
    /// 搜索输入框内容。**搜索后不清空**（用户口径：搜索时输入框中内容不清除）。
    public var dictionaryQuery = ""
    /// 模糊匹配结果（最多 10 条，每项带单词 / 音标 / 翻译）。
    public private(set) var dictionaryMatches: [DictionaryWord] = []
    /// **已经被「查询」消费掉的那个词**：输入框里是它时不再弹匹配浮层。
    ///
    /// ⚠️ 光比「请求发出前后 `dictionaryQuery` 有没有变」是不够的：用户敲完
    /// `aban` 直接回车，输入框里的字**一个字都没改**，那次联想请求回来时凭
    /// 「文本没变」判定有效，于是刚收起的浮层又冒出来 —— 用户看到的就是
    /// 「点了查询/回车，匹配列表还在」。所以必须记一笔：这个词已经被查过了。
    private var consumedDictionaryQuery: String?
    /// 联想浮层**是否正处在「用户在输入框里找词」那一段**里。
    ///
    /// ⚠️ 浮层的生死不能只看「`dictionaryMatches` 里有没有内容」：在途的联想回来时
    /// 会把列表填上，浮层就会在用户**已经查到词之后**自己冒出来 —— 09-16 用户那张
    /// 截图正是如此（输入框与展示页都是 `snatch`，浮层还挂着一条 `snatch`）。
    /// 所以另设一个开关：**打字 / 点回输入框 = 开**，**查到词（提交 / 选中 / 跳转 /
    /// 回退）或清空 = 关**；在途结果回来时若开关已经关上，一律丢弃。
    private var isDictionaryMatchListArmed = false
    /// 查词跳转历史（当前页 / 上一页 / 最初那个词）。
    public private(set) var dictionaryLookup = DictionaryLookupSession.empty
    /// 正在查的词（nil = 没在查；用来在详情位上转圈而不是闪空白）。
    public private(set) var dictionaryLoadingWord: String?
    /// 正在跑的那次查词请求的句柄 —— 用户清空输入时要**真把它取消掉**。
    ///
    /// 用户口径：在输入框里取消了输入，就该同步终止正在查的进程，
    /// 否则请求照样跑完、照样占着模型额度，还会把卡片顶上屏。
    private var dictionaryLookupTask: Task<DictionaryDetail, Error>?
    /// 查词请求的轮次号：晚到的旧请求不许把新请求的状态清掉。
    private var dictionaryLookupGeneration = 0
    /// 词典页提示（可关闭；nil = 正常）。
    public private(set) var dictionaryNotice: String?
    /// 正在从磁盘导入词典。
    public private(set) var isImportingDictionary = false
    /// 词典库里处在「确认删除」状态的书（点删除第一次只是变红，再点才真删）。
    public private(set) var dictionaryPendingDelete: String?

    // MARK: - 词汇复习闭环（P1-3 复习会话）

    /// 正在进行的一轮复习（nil = 不在复习模式，页面照常显示词表）。
    /// 队列与结算口径全在 `AIDomain.VocabularyReviewSession`（纯函数），这里只持有它。
    public private(set) var vocabularyReview: VocabularyReviewSession?
    /// 当前这张卡是否已翻面（看过释义）。
    public private(set) var vocabularyReviewRevealed = false
    /// 当前这张卡的朗读评测报告（nil = 这次还没读 / 没拿到录音）。
    /// ⚠️ 只作为**证据**展示，绝不替学员点「认识 / 忘了」。
    public private(set) var vocabularyReviewReport: PronunciationReport?
    /// 当前这张卡朗读时系统听成了什么（用来如实说明「它听到了别的词」）。
    public private(set) var vocabularyReviewRecognized: String?
    /// 正在录这张卡的朗读。
    public private(set) var isVocabularyReviewRecording = false
    /// 朗读评测进行中（录音已结束，正在跑 ASR / 音素）。
    public private(set) var isVocabularyReviewBusy = false
    /// 复习模式里的一次性提示（读失败 / 没听清等）。
    public private(set) var vocabularyReviewNotice: String?
    /// 上次重置每日推荐学习进度的时间（没重置过为 nil）。
    public private(set) var dailyProgressResetAt: Date?
    /// 重置那一刻已学完（累计认识满 3 次）的词数。
    public private(set) var dailyProgressResetLearned = 0
    /// 词库总词数（设置页展示「上次已学 x / y 词」）。
    public private(set) var dailyBankTotal = 0

    // MARK: - 学习进度（第 25 步 Dashboard）

    /// 是否停在学习进度页（占中间栏，与其他页互斥）。
    public var showingProgress = false
    /// 学习进度快照（进页面时汇总一次）。**UI 只读它，不自己统计**。
    public private(set) var progressSnapshot: ProgressSnapshot = .empty()
    /// 近一年的练习分布（年度记录卡）。与 `progressSnapshot` 一样是只读缓存。
    ///
    /// 初值是**一整张全空的网格**而不是空数组：年度卡一进页面就有正确的尺寸，
    /// 数据到了只是把格子染上色，Layout 不会跳一下。
    public private(set) var annualRecap: AnnualRecap = .empty()
    /// 正在汇总进度（首次进入时的 loading 态）。
    public private(set) var isLoadingProgress = false
    /// 统计窗口天数（7 / 14 / 30 天，UI 可切换）。
    public var progressWindowDays = ProgressAggregator.defaultDays

    /// 今日任务推荐（PRD §7.1）。由 `DailyPlanner` 纯函数从快照排出来，UI 只读它。
    ///
    /// 快照还没汇总时排出来是空计划 —— 页面会显示「今天没有安排」，
    /// 而不是编一份看着热闹但不基于任何记录的假清单。
    public var dailyPlan: DailyPlan {
        DailyPlanner.plan(snapshot: progressSnapshot, mode: product.dailyGoalMode)
    }

    // MARK: 今日作业（老师黑板）

    /// 黑板是否展开。**不持久化**：每次启动都是收起的，展开与否是「这一次」的事。
    public var isBlackboardExpanded = false

    /// 今日完成的庆祝信号：每次 +1 让右侧森林的小动物跳一次（**一天只放一次**）。
    public private(set) var celebrationTick = 0
    /// 正在放庆祝（黑板上盖章 + 烟花，几秒后自动收，不留常驻动画）。
    public private(set) var isCelebratingToday = false
    /// 点黑板上的小图标 → 切到「学习进度」并滚到今日任务卡（每次 +1 触发一次滚动）。
    public private(set) var progressFocusTick = 0
    /// 「切过去之后还要滚到今日任务卡」这个意图**还没被学习进度页消费**。
    /// 与 tick 并行存在：tick 管「已经在这一页时再点一次」，它管「页面是刚被切出来的」。
    private var progressFocusPending = false

    private static let todayCelebratedDayKey = "today.celebratedDayKey"
    private static let todayBoardAutoExpandedDayKey = "today.boardAutoExpandedDayKey"
    /// 上次庆祝过的 `dayKey`（**持久化**：同一天重开应用不再重复放烟花）。
    private var celebratedDayKey: String {
        get { UserDefaults.standard.string(forKey: Self.todayCelebratedDayKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.todayCelebratedDayKey) }
    }
    /// 上次「开屏自动展开黑板」的 `dayKey`（**持久化**：一天最多自动展开一次）。
    private var boardAutoExpandedDayKey: String {
        get { UserDefaults.standard.string(forKey: Self.todayBoardAutoExpandedDayKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.todayBoardAutoExpandedDayKey) }
    }
    /// 汇总节流：一轮对话就全量汇总一次没必要（本地聚合也有代价）。
    private var lastTodayPanelRefreshAt: Date = .distantPast
    /// 后台开场任务（学员一开口就让它让位，见 `learnerEngagedThisLaunch`）。
    private var openingTask: Task<Void, Never>?
    /// 学员在本轮启动里已经开口 —— 后台开场**不许再动会话**（不能把人家刚说的话清掉）。
    private var learnerEngagedThisLaunch = false
    /// 本轮启动里黑板已经自动展开过（收起后不许再自己弹开）。
    private var didAutoExpandBoardThisLaunch = false

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
    /// 课程覆盖度判定卡的自动收起任务（与奖励条各管各的）。
    private var assessmentDismissTask: Task<Void, Never>?
    /// 启停弹框的自动收起任务。
    private var toastDismissTask: Task<Void, Never>?
    /// 资源管理巡检器（第 27 步）：start() 里创建并启动，随应用生命周期常驻。
    private var lifecycle: ModelLifecycleManager?
    /// 本地定时练习提醒（#226）：start() 里静默同步配置；开关/时刻改动时重新排。
    /// ⚠️ 必须常驻持有 —— 通知 delegate 是弱引用，实例被释放点通知就没响应了。
    private let reminders = PracticeReminderService()
    /// 提醒授权是否被系统拒绝（设置页如实展示一句指引）。
    public private(set) var reminderAuthorizationDenied = false
    /// 情景结算卡还挂着时今日庆祝先不放（防堆叠）；卡收起后的那次刷新补放。
    private var rewardCelebrationPending = false
    /// 节流跳过后的**收尾补刷**：完成最后一项任务的那一轮若被 15s 节流吞掉，
    /// 最多 15s 后补一次 —— 庆祝仪式不许因为节流而缺席。
    private var trailingRefreshTask: Task<Void, Never>?

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
        // 学员每说完一句 → 实时保存主线任务进度（需求 5：练习内容先实时保存）。
        // ⚠️ 用捕获列表避免循环引用：`chat` 被 `self` 持有，闭包再强持有 `self` 就是环。
        chat.onLearnerTurn = { [weak self] in
            await self?.persistLiveQuestProgress()
            // 今日卷轴跟着走：练一句就看得见进度动一格（内部有 15s 节流）。
            await self?.refreshTodayPanel()
        }
        // 老师每说完一轮（成功 / 失败 / 被取消都算）→ 考试模式据此起表计时、补记纠错。
        chat.onTeacherTurnEnd = { [weak self] message, corrections in
            self?.handleTeacherTurnEnd(message, corrections: corrections)
        }
    }

    public convenience init() { self.init(services: CoachServices()) }

    /// 某能力模型当前是否启动（默认启动）——**这是界面快照，不是真源**。
    ///
    /// ⚠️ 后台资源巡检挂起模型后不会立刻回写这份快照。任何「据此决定要不要拉起服务」的
    /// **动作判断**都必须问 `services.isModelRunning`（真源）；拿快照判断会跳过自动恢复，
    /// 请求打到已停的服务上（2026-09-19 语音识别「设置里开着、一用就连接失败」即此）。
    public func isModelRunning(_ kind: AIProviderKind) -> Bool {
        modelRunStates[kind] ?? true
    }

    /// 把「启动 / 关闭」快照与服务层真源对齐（廉价：只读内存集合，不联网）。
    ///
    /// 资源巡检的挂起、以及使用处的自动恢复都会改变真源，做完要调一次，界面才不说谎。
    public func syncModelRunStates() async {
        modelRunStates = await services.modelRunStates()
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

    /// 老师人格档位（教学风格）。认不出的值落回 `.standard`，同 `teacherAnimalKind` 的约定。
    public var teacherPersona: TeacherPersona {
        TeacherPersona(rawValue: product.teacherPersona) ?? .standard
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
        // 用户上次在设置页选的日志级别要**在最早一刻**生效，否则启动早期按默认口径收/漏日志。
        LogOptions.applyPersistedLevel()
        let configuration = await services.configuration
        product = configuration.product
        themeMode = configuration.product.themeMode
        autoSpeak = configuration.product.autoSpeak
        chat.profile.learningLanguage = configuration.product.learningLanguage
        chat.profile.nativeLanguage = configuration.product.nativeLanguage
        progress = await services.loadProgress()
        // 备份恢复（#209）：本轮启动若应用了待恢复内容，说明要让用户看见。
        restoreNote = await services.restoreNote

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
        // 应用启动即拉起本机语音：Edge-TTS 代理（免费微软音色）+ **当前选中的本机语音识别**。
        // 两者都用「的服务/port 流程」，不阻断开屏；拉起后重新装配语音，让真实健康状态即时可见。
        Task { [weak self] in
            await self?.services.ensureEdgeTTSProxyOnLaunch()
            guard await self?.services.ensureLocalASROnLaunch() == true else {
                await self?.bootstrapVoice()
                return
            }
            // 起来了：设置页的「运行中」标记与 ASR 健康态跟着刷新一次。
            self?.modelRunStates = (await self?.services.modelRunStates()) ?? [:]
            await self?.refreshStatus()
            await self?.bootstrapVoice()
        }
        // 发音评测的声学通道（云端发音评估）：没配置也不报错，评测自动走规则推断。
        pronunciationHealth = await services.bootstrapPronunciation()
        await refreshStatus()
        refreshTodayTokens()
        modelRunStates = await services.modelRunStates()
        starterQuestions = await services.starterQuestions()
        // 资源管理巡检（第 27 步）：按配置周期检查内存压力 / 空闲时长并自动挂起省内存；
        // 被挂起的模型在下次被使用时会自动恢复（ChatService / 语音入口已接线）。
        if lifecycle == nil {
            // 巡检会真的挂起模型（停掉本地服务），而界面读的是自己那份快照缓存 ——
            // 让它在每次巡检后对齐真源，设置页才不会继续说「运行中」
            // （2026-09-19 语音识别「设置里开着、一用就连接失败」的另一半原因）。
            let manager = ModelLifecycleManager(services: services) { [weak self] in
                await self?.syncModelRunStates()
            }
            lifecycle = manager
            await manager.start()
        }
        // 定时练习提醒（#226）：点通知进「今天」。
        // ⚠️ 配置同步放在下面 `refreshTodayPanel` 之后 —— 首次排通知的文案里
        // 要用**真实的**连续天数（seed 快照里是 0）。
        reminders.onOpenToday = { [weak self] in
            // 点通知进「今天」：激活窗口 + 展开今日黑板 + 强刷一次（回零点/新一天也对）。
            // ⚠️ 全部状态操作收进 @MainActor（AppState 的属性是主线程隔离的）。
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                guard let self else { return }
                self.isBlackboardExpanded = true
                await self.refreshTodayPanel(force: true)
            }
        }
        isBooting = false
        // 情景素材与关卡绑定：启动时就要有 —— 「继续上次的情景任务」要靠它找到那一个情景。
        await loadScenarios()
        await refreshQuestRecords()
        // 首屏「今日卷轴」的数据（本地聚合）：打开应用第一眼就该看到今天要做什么，
        // 一条模型调用都不等。
        await refreshTodayPanel(force: true)
        // 定时练习提醒（#226）：启动静默同步（已授权才排通知；未授权不弹框 ——
        // 弹框只在用户主动打开开关时发生）。
        await syncPracticeReminder(requestIfNeeded: false)
        // 老师先开口（需求 6：上次是情景就续做、是随口练就接着聊、第一次才给一般招呼）。
        //
        // ⚠️ 挪到**后台**跑：它是一次真实模型调用（本机冷加载实测 30～60s）。
        // 以前 `start()` 一直 `await` 到这里才返回，于是
        //   ① 主界面 `.task` 里排在后面的启动钩子（--theme / --open-* / --send）全被堵住；
        //   ② 这半分钟里对话区只有一张等待卡 —— 每天开一次就劝退一次。
        // 现在首屏由本地数据秒开，开场白生成完自己滑进对话区。
        openingTask?.cancel()
        openingTask = Task { [weak self] in await self?.openInBackground() }
    }

    /// 后台开场：老师先开口 / 续做上一段（需求 6）。
    ///
    /// ⚠️ 三条让位规则（学员一旦开口，这段会话就归他）：
    /// 1. 开场还没跑完学员就开口 → 整段放弃，绝不撤他的会话
    ///    （背景里那次「复盘上一段」会把人家刚说的话一起清掉）；
    /// 2. `resumeOrOpenPractice` 的破坏性分支（隐藏历史 → 复盘 → 清空）会**再查一次**；
    /// 3. 人在别的板块 → 只在左栏标一个提示点，不抢画面。
    private func openInBackground() async {
        isPreparingOpening = true
        defer { isPreparingOpening = false }
        guard !learnerEngagedThisLaunch else { return }
        await resumeOrOpenPractice()
        guard !learnerEngagedThisLaunch else { return }
        // 老师开口了但人不在对话页 → 左栏提示（回到对话页即清）。
        if !chat.visibleMessages.isEmpty, activeSection != .practice {
            teacherOpenerPending = true
        }
    }

    // MARK: - 今日作业（老师黑板）

    /// 黑板上点某一项 → 直接去做（与「学习进度」页同一个去处，同一套口径）。
    public func openTodayTask(_ kind: DailyTask.Kind) async {
        switch kind {
        case .conversation: await openPractice()
        case .shadowing: await openShadowing()
        case .review: await openVocabulary()
        }
    }

    /// 黑板上的小图标 → 切到「学习进度」页并滚到今日任务卡。
    ///
    /// 板上放不下详情（宽度只有侧栏那么宽），所以要留一条「去哪儿看完整版」的路。
    ///
    /// ⚠️ 除了 `progressFocusTick`（**已经在这一页**时再点一次也要能滚）之外，还要落一个
    /// **一次性的意图标记**：页面是从别的页切过来的新实例，`onChange` 只对「变化」生效，
    /// 而 tick 在它出现之前就已经加过了 —— 光靠 tick 会「指令收到了，页面不动」。
    public func openTodayTasksInProgress() {
        applySection(.progress)
        progressFocusPending = true
        progressFocusTick += 1
    }

    /// 消费一次「滚到今日任务卡」的意图。
    ///
    /// 与 `recordsFocus` 同一套道理：跳转是**这一次点击**的意图，不是这一页的默认行为 ——
    /// 页面读一次就该清掉，下次从侧栏正常进来不许自动跳。
    public func consumeProgressFocus() -> Bool {
        guard progressFocusPending else { return false }
        progressFocusPending = false
        return true
    }

    /// 汇总今日作业需要的进度，并判定「今日全部完成」的庆祝。
    ///
    /// - Parameter force: true = 跳过节流（启动 / 手动刷新走这条）。
    ///
    /// ⚠️ 不跑年度汇总：开屏那一下只查窗口内的记录，全年 53×7 的那张热力图
    /// 留给真正打开进度页的人（见 `reloadProgress(includeAnnual:)`）。
    public func refreshTodayPanel(force: Bool = false) async {
        let now = Date()
        guard force || now.timeIntervalSince(lastTodayPanelRefreshAt) > 15 else {
            // 被节流吞掉的那一轮不许就此蒸发：收尾补刷一次（最多 15s），
            // 否则「做完最后一项」的那一刻可能永远等不到庆祝。
            scheduleTrailingRefresh()
            return
        }
        trailingRefreshTask?.cancel()
        trailingRefreshTask = nil
        lastTodayPanelRefreshAt = now
        await reloadProgress(includeAnnual: false)

        let key = ShadowingDailyRule.dayKey()
        if TodayPanel.shouldCelebrate(
            plan: dailyPlan,
            celebratedDayKey: celebratedDayKey,
            dayKey: key
        ) {
            if lastReward != nil {
                // 情景结算卡（+N 星 / 点亮关卡）还挂在最上层：先不放庆祝，
                // **也不盖章** —— 卡收起后的那次刷新会补放（dayKey 还没写，判定仍成立）。
                rewardCelebrationPending = true
            } else {
                celebrateToday(dayKey: key)
            }
        }

        // 开屏自动展开一次黑板：今天还没做完 → 打开就知道要交什么作业。
        // ⚠️ 只在本次启动里做一次，且 `dayKey` 落盘保证一天最多一次 ——
        // 用户手动收起之后不许再自己弹开（那是抢界面）。
        guard !didAutoExpandBoardThisLaunch,
              TodayPanel.shouldAutoExpand(
                plan: dailyPlan,
                autoExpandedDayKey: boardAutoExpandedDayKey,
                dayKey: key
              ) else { return }
        didAutoExpandBoardThisLaunch = true
        boardAutoExpandedDayKey = key
        Task { [weak self] in
            // 等主界面那一帧稳住再展开，否则动画会和开屏的布局一起抖。
            try? await Task.sleep(for: .seconds(0.6))
            self?.isBlackboardExpanded = true
        }
    }

    /// 今日完成的收尾仪式（#227）：盖章（幂等）+ 大树小动物欢跳 + 黑板烟花几秒。
    private func celebrateToday(dayKey: String) {
        // 一天只放一次（`dayKey` 落盘）：练完那一刻放，之后反复汇总都不再放。
        celebratedDayKey = dayKey
        rewardCelebrationPending = false
        celebrationTick += 1
        isCelebratingToday = true
        // 烟花放几秒就撤 —— 开屏第一眼不该有东西一直在动。
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.isCelebratingToday = false
        }
    }

    /// 节流跳过后的收尾补刷（防抖：同一时刻只挂一个）。
    private func scheduleTrailingRefresh() {
        guard trailingRefreshTask == nil else { return }
        trailingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.trailingRefreshTask = nil
            await self?.refreshTodayPanel(force: true)
        }
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
        // 朗读投递方式随 Provider 变化：云端整段、本地分句（设置页会说明当前用的是哪种）。
        speechDelivery = await services.voice.deliveryMode()
        await refreshVoiceProfiles()
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
        // 语音识别模型不在运行 → 资源管理挂起的自动恢复；用户关闭的才提示怎么打开。
        // ⚠️ 状态一律问**服务层真源**（`services.isModelRunning`），绝不用 `isModelRunning`
        // 那份界面快照：巡检挂起后它不会立刻刷新，会让这里误判「还在跑」而跳过自动恢复，
        // 请求打到已停的 whisper 上（2026-09-19 连接失败的根因）。
        // `resumeIfSuspended` 对「没被挂起」是廉价空操作；用户显式关闭的不会被自动拉起。
        _ = (try? await services.resumeIfSuspended(.asr)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.asr) else {
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
        // 教师语音模型不在运行 → 资源管理挂起的自动恢复；用户关闭的才明确提示。
        // ⚠️ 同 ASR：判断用服务层真源，不用会过期的界面快照（见 `isModelRunning` 的说明）。
        _ = (try? await services.resumeIfSuspended(.tts)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.tts) else {
            voiceError = "\(await services.modelLabel(for: .tts)) 已关闭，请在设置里点绿色的「启动」后再朗读。"
            return
        }
        isSpeaking = true
        // 音色取值统一走 `effectiveSpeechVoiceSelection()`：启用克隆音色时它带档案 id **和参考音频**，
        // 否则是内置音色名。UI 不自己判断该用哪个 —— 那会让两处口径漂移。
        await services.voice.speak(text, voice: await services.effectiveSpeechVoiceSelection(),
                                   language: "English", rate: Float(product.speechRate))
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
        // 选内置音色 = 停用克隆音色。否则 `effectiveSpeechVoice()` 仍会返回克隆档案 id，
        // 用户看到的表现是「换了个音色，老师却还用克隆的声音说话」。
        if product.activeVoiceProfileID != nil {
            try? await services.deactivateClonedVoice()
            await reloadProduct()
            await refreshVoiceProfiles()
        }
        product.teacherVoice = voice
        await persistProduct()
        if product.voicePreview {
            await services.voice.speak("Nice to meet you!", voice: voice, language: "English",
                                       rate: Float(product.speechRate))
            voiceError = await services.voice.lastError
        }
    }

    // MARK: - 克隆音色（第 24 步）

    /// 刷新音色档案，以及「当前供应商是否支持克隆」。
    public func refreshVoiceProfiles() async {
        voiceProfiles = await services.voiceProfiles()
        voiceCloningSupported = await services.ttsSupportsVoiceCloning()
    }

    /// 新建一份克隆音色档案：把选中的本地参考音频**复制**进应用目录，并记下授权说明。
    ///
    /// 只存不启用 —— 启用要单独走 `activateClonedVoice`（那里做合规校验）。
    /// 这样「先填好、以后再开」不会被合规闸门拦住，而「真的要用」时一道都少不了。
    @discardableResult
    public func createClonedVoice(
        name: String,
        referenceURL: URL,
        consentStatement: String,
        referenceText: String? = nil
    ) async -> VoiceProfile? {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let statement = consentStatement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            voiceProfileNotice = "请先给这个音色起个名字。"
            return nil
        }
        guard !statement.isEmpty else {
            voiceProfileNotice = VoiceAccessPolicy.Violation.emptyConsent.userMessage
            return nil
        }
        do {
            let path = try await services.importVoiceReference(from: referenceURL)
            let profile = VoiceProfile(
                id: "cloned." + UUID().uuidString.prefix(8).lowercased(),
                displayName: displayName,
                kind: .cloned,
                referenceAudioPath: path,
                referenceText: referenceText?.trimmingCharacters(in: .whitespacesAndNewlines),
                consent: VoiceConsent(statement: statement)
            )
            try await services.saveVoiceProfile(profile)
            await refreshVoiceProfiles()
            voiceProfileNotice = "已保存音色「\(profile.displayName)」，启用后老师就用它说话。"
            return profile
        } catch {
            voiceProfileNotice = "保存音色失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 启用克隆音色。违规时给出**可读原因**（缺授权 / 参考音频不是本地文件 / 供应商不支持），
    /// 不静默失败，也不「先启用再说」。
    public func activateClonedVoice(id: String) async {
        busyVoiceProfileID = id
        defer { busyVoiceProfileID = nil }
        do {
            try await services.activateVoiceProfile(id: id)
            await reloadProduct()
            await refreshVoiceProfiles()
            voiceProfileNotice = activeVoiceIndicator
        } catch {
            voiceProfileNotice = error.localizedDescription
        }
    }

    /// 停用克隆音色，回到内置音色。
    public func deactivateClonedVoice() async {
        do {
            try await services.deactivateClonedVoice()
            await reloadProduct()
            await refreshVoiceProfiles()
            voiceProfileNotice = "已切回内置音色「\(product.teacherVoice)」。"
        } catch {
            voiceProfileNotice = error.localizedDescription
        }
    }

    /// 删除音色档案（若正被使用会一并停用）。
    public func deleteClonedVoice(id: String) async {
        do {
            try await services.deleteVoiceProfile(id: id)
            await reloadProduct()
            await refreshVoiceProfiles()
            voiceProfileNotice = "已删除这个音色档案。"
        } catch {
            voiceProfileNotice = error.localizedDescription
        }
    }

    public func clearVoiceProfileNotice() { voiceProfileNotice = nil }

    // MARK: - 聊天附件（第 3 项需求）

    /// 把用户选中的文件导入待发区。
    ///
    /// 逐个导入、逐个报错：一批里有一个超大文件时，其余的文件照样要能加上 ——
    /// 不能因为第 3 个失败就把前 2 个一起丢掉。
    public func addAttachments(from urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImportingAttachments = true
        defer { isImportingAttachments = false }
        var failures: [String] = []
        var added = 0
        for url in urls {
            guard AttachmentPolicy.remainingSlots(current: pendingAttachments.count) > 0 else {
                failures.append("一条消息最多带 \(AttachmentPolicy.maxPerMessage) 个附件。")
                break
            }
            do {
                let attachment = try await services.importAttachment(from: url)
                pendingAttachments.append(attachment)
                added += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if failures.isEmpty {
            attachmentNotice = nil
        } else {
            attachmentNotice = failures.joined(separator: "\n")
        }
        _ = added
    }

    /// 移除一个待发附件（文件本体一并清理 —— 用户明确删掉了它，留着只是垃圾）。
    public func removePendingAttachment(_ id: UUID) async {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = pendingAttachments.remove(at: index)
        await services.removeAttachment(attachment)
    }

    /// 清空待发附件（发送后调用；**不删文件**，消息里还要用它）。
    public func clearPendingAttachments() {
        pendingAttachments.removeAll()
        attachmentNotice = nil
    }

    public func clearAttachmentNotice() { attachmentNotice = nil }

    /// 收起「已保存」回执，并撤销自动收起的计划。
    public func clearAttachmentSaveNotice() {
        attachmentSaveNoticeTask?.cancel()
        attachmentSaveNoticeTask = nil
        attachmentSaveNotice = nil
    }

    /// 保存回执展示几秒后自己收起。
    ///
    /// 与「导入失败」提示的区别：失败提示要用户读完再走（必须手动关），
    /// 成功回执只是一句「刚才那下成了」，赖着不走会变成噪音。
    private func scheduleAttachmentSaveNoticeDismissal() {
        attachmentSaveNoticeTask?.cancel()
        guard attachmentSaveNotice != nil else {
            attachmentSaveNoticeTask = nil
            return
        }
        attachmentSaveNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.attachmentSaveNotice = nil
            self?.attachmentSaveNoticeTask = nil
        }
    }

    /// 附件在本机的位置（渲染用；不做存在性检查 —— 文件可能在运行期间被清理，
    /// 那正是「文件已不可用」应当被看到的时候）。
    public func attachmentLocation(for attachment: ChatAttachment) -> URL {
        chat.attachmentLocation(for: attachment)
    }

    /// 下载附件：「另存为」到用户选的位置。结果如实说出来。
    @discardableResult
    public func downloadAttachment(_ attachment: ChatAttachment) -> Bool {
        let url = attachmentLocation(for: attachment)
        let saved = AttachmentExporter.save(attachment: attachment, from: url)
        attachmentSaveNotice = saved ? "已保存「\(attachment.fileName)」。" : nil
        scheduleAttachmentSaveNoticeDismissal()
        return saved
    }

    /// 发送一条消息（**带上待发附件**，随后清空待发区）。
    ///
    /// 收成一个方法而不是让 View 自己「先读 pending 再 send 再 clear」：
    /// 那三步任何一步忘掉，都会表现为「带图发出去、下一句又把同一张图重发一遍」。
    @discardableResult
    public func sendChat(_ text: String) -> Bool {
        let attachments = pendingAttachments
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        guard llmStoppedNotice == nil else { return false }
        // 考试模式：这一句是**作答**。先记进考卷（含实际用时）并推进到下一问，
        // 老师这一轮拿到的题号才是对的那一题（顺序颠倒会一直问同一问）。
        if examRunner != nil, !trimmed.isEmpty {
            submitExamAnswer(trimmed)
        }
        pendingAttachments.removeAll()
        attachmentNotice = nil
        // 学员开口了：这一轮会话归他 —— 后台那句开场白不许再动会话（见 `openInBackground`）。
        learnerEngagedThisLaunch = true
        // 抢在老师前面说话：那句还在后台生成的开场白立刻让位。
        // ⚠️ `ChatService.send` 只在 `isGreeting` 时主动撤招呼，而后台开场期间
        // `isGenerating` 也可能是 true —— 不主动撤，这句话会被 `guard !isGenerating`
        // **静默丢掉**，表现为「我打了一句，屏幕上什么都没有」。
        if isPreparingOpening, chat.isGenerating { chat.cancel() }
        // 附件随消息落库：`chat.send` 内部会把整条消息（含附件）写进数据库。
        chat.send(trimmed, attachments: attachments)
        return true
    }

    public func refreshStatus() async {
        health = await services.llmHealth()
        // 当前模型读不读图：带图说话时要不要提醒「老师看不到这张图」。
        llmSupportsVision = await services.llmSupportsVision()
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
        // 「AI 大脑」当前生效的 Provider / 模型也要进快照：外部模型面板与模型卡片都读它。
        // （`refreshCapabilityInfos` 覆盖另外五项能力，这里补 llm。）
        if let provider = activeProvider {
            activeProviderIDs[.llm] = provider.id
        } else {
            activeProviderIDs[.llm] = nil
        }
        if !modelDraft.isEmpty { activeModels[.llm] = modelDraft }
        // 关键：同步本地 product 缓存。否则切换 Provider 后，任何一次 persistProduct
        // 都会用旧缓存回写配置，把 activeProviders/apiKey 决策抹掉（重启回到 qwen3 的根源）。
        product = await services.configuration.product
    }

    // MARK: - 模型管理中心（本地检测 + 外部模型）

    /// 刷新各能力的模型信息快照（设置页打开 / 检测按钮时调用）。
    public func refreshCapabilityInfos() async {
        // 顺手修掉「本地模型名被写进云端供应商」的历史坏配置（只做一次，幂等）。
        // 这种模型名在云端不可能成立，留着只会让界面显示错误、调用必然失败。
        if !didHealCrossProviderModels {
            didHealCrossProviderModels = true
            let healed = await services.healCrossProviderModels()
            if !healed.isEmpty {
                modelHealNotice = "已修好 \(healed.map(\.displayName).joined(separator: "、")) 的配置：清掉云端上错写的本地模型名、关闭了那个外部接口，并切回本地模型"
                    + "（云端没有这个模型，留着只会一直调用失败）。如需改用云端，请在这些能力的「外部模型」里重新验证并选择模型。"
                // ⚠️ 配置换了 Provider，必须重新装配 + 重取健康状态。
                // 否则界面会拿**上一个 Provider 的旧体检结果**去描述新的 Provider——
                // 实测就是刚切回本地，卡片却写着「配置有误：API Key 无效或已过期」。
                if healed.contains(where: { $0 == .asr || $0 == .tts }) {
                    await bootstrapVoice()
                }
                for kind in healed where kind != .asr && kind != .tts {
                    await services.rebootstrap(kind: kind)
                }
            }
        }
        let configuration = await services.configuration
        // ⚠️ 顺手把本地 product 缓存对齐服务端。
        //
        // 这里必须同步：任何写配置的路径（切云端、选模型、启停）结束后都会调本方法，
        // 若缓存留着旧的 activeProviders / selectedModels，之后任何一次 persistProduct
        // （改主题、改语速、点动画开关…）都会用旧缓存**整体回写**，把刚生效的
        // 「已启用云端模型」抹回未配置——实测症状就是卡片显示已启用、实际仍是未配置。
        product = configuration.product
        var result: [AIProviderKind: CapabilityModelInfo] = [:]
        for kind in [AIProviderKind.asr, .tts, .vad, .embedding, .pronunciation] {
            let provider = configuration.resolvedProvider(for: kind)
            // 记忆索引的「本地模型」与「AI 大脑」一致：优先从 runtime 实际发现
            // （本机 Ollama 的嵌入模型 / 云端可选模型），不再是只读 ~/AI_Models 目录。
            let localModels: [LocalModel]
            if kind == .embedding {
                // 记忆索引与 ASR 同构：`~/AI_Models/embedding/` 目录里部署的模型
                // 照常扫描出来（带真实路径，可显示「本地 · 路径」）；
                // 再并入 runtime 实际发现的模型（本机 Ollama 的嵌入模型）。
                // 目录结果在前；Ollama 结果按名字去重后补在后面，
                // 路径用 `ollama://` 合成值——`LocalModel.id` 是 path，空串会撞 id。
                var merged = LocalModelScanner.scan(kind: kind)
                let discovered = await services.availableEmbeddingModels()
                let onDisk = Set(merged.map(\.name))
                for model in discovered where !onDisk.contains(model.name) {
                    merged.append(LocalModel(name: model.name, path: "ollama://\(model.id)"))
                }
                localModels = merged
            } else {
                localModels = LocalModelScanner.scan(kind: kind)
            }

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
            case .embedding:
                // ⚠️ 别再按「内置模拟」报：默认配置里这条是**真的本地索引**（Ollama + 嵌入模型），
                // 说成模拟会让用户以为这一栏永远关着。这里真的问一次接通没有 ——
                // 每个进程只装配一次，失败就如实说「退回结构化」。
                await services.ensureEmbeddingReady()
                healthOK = await services.isSemanticMemoryEnabled
                if healthOK {
                    // 装配成功 ≠ 现在还能用：Ollama 可能是开屏时在跑、之后被关掉了。
                    // 只报「已接通」会让用户以为检索在走语义，实际早就退回结构化顺序了。
                    embeddingHealth = await services.embeddingHealth()
                    healthText = embeddingHealth.isUsable
                        ? "已接通 · 按与当前话题的相关度取回记忆"
                        : "已启用，但服务当前不可用（\(embeddingHealth.userFacingDescription)）· 暂时按结构化顺序取回"
                } else {
                    healthText = "未接通 · 记忆按结构化顺序取回（不影响练习）"
                }
            default:
                // VAD / Pronunciation V1 尚无独立 runtime，如配置了本地 Provider 才有意义
                healthOK = false
                healthText = provider?.runtime == .externalLocalRuntime ? "等待接入" : "内置模拟"
            }

            let current = product.selectedModel(for: kind) ?? provider?.model
            let source: String
            switch provider?.runtime {
            case .remoteAPI:
                // 没选定模型时要说清「现在不会调用任何云端模型」——这是费用护栏的对外口径，
                // 不能让用户以为自己选好了、实际却在打账号里某个没选的模型。
                source = current == nil
                    ? "\(provider?.userFacingName ?? "云端") · 尚未选择模型（不会发起任何调用）"
                    : "\(provider?.userFacingName ?? "云端") 提供的云端模型"
            case .externalLocalRuntime, .ollama:
                if let current, let path = LocalModelScanner.path(of: current, kind: kind) {
                    source = "本地 · \(path)"
                } else if let endpoint = provider?.endpoint {
                    source = "本地服务 · \(endpoint)"
                } else {
                    source = "本地模型"
                }
            default:
                // ⚠️ 只有 runtime 真的是 mock 才叫「内置模拟」。本地嵌入（Ollama）也是非云端
                // runtime，却是一条真链路，写成模拟等于把已接通的功能说成没接。
                if provider?.runtime == .mock {
                    source = "内置模拟（无需配置）"
                } else if let endpoint = provider?.endpoint, !endpoint.isEmpty {
                    source = "本地服务 · \(endpoint)"
                } else {
                    source = provider == nil ? "未配置" : "内置模拟（无需配置）"
                }
            }

            result[kind] = CapabilityModelInfo(
                kind: kind,
                healthOK: healthOK,
                healthText: healthText,
                currentModel: current,
                sourceDescription: source,
                isRemote: provider?.isRemote ?? false,
                providerName: provider?.userFacingName,
                providerID: provider?.id,
                localModels: localModels
            )
        }
        capabilityInfos = result
        // 「各能力当前生效的 Provider / 模型」快照：**覆盖全部能力**（含 llm，
        // 它不在 `capabilityInfos` 里但同样需要）。外部模型面板的预选、绿点、
        // 模型回填与模型卡片的展示都读它，因此必须是「配置里生效的结果」而不是草稿。
        var activeIDs: [AIProviderKind: String] = [:]
        var activeModelNames: [AIProviderKind: String] = [:]
        for kind in AIProviderKind.allCases {
            if let provider = configuration.resolvedProvider(for: kind) {
                activeIDs[kind] = provider.id
            }
            if let model = configuration.resolvedModel(for: kind), !model.isEmpty {
                activeModelNames[kind] = model
            }
        }
        activeProviderIDs = activeIDs
        activeModels = activeModelNames
        spellingNote = await services.spellingCorrectionNote()
        // 顺带刷新云端调用审计：设置页的「对外调用记录」卡片要和模型信息同时是最新的。
        await refreshRemoteCalls()
        // 供应商一变，外发口径就变了：这里顺手重算，避免隐私卡片停留在旧结论上
        //（用户刚切回本地模型，卡片却还写着「正在使用云端服务」是不可接受的）。
        await refreshPrivacy()
    }

    // MARK: - 云端调用审计（费用护栏留痕）

    /// 刷新对外调用审计（打开设置 / 每次模型信息刷新时调用）。
    public func refreshRemoteCalls() async {
        remoteCallSummary = await services.remoteCallSummary()
        remoteCallRecords = await services.recentRemoteCalls(limit: 12)
    }

    /// 清空本次运行的审计记录（磁盘上的留痕保留，便于事后与账单对账）。
    public func clearRemoteCalls() async {
        await services.resetRemoteCalls()
        await refreshRemoteCalls()
    }

    /// 审计文件的绝对路径（用户可直接打开核对）。
    public var remoteCallLogPath: String { CoachServices.remoteCallLogURL().path }

    /// 选择本地检测到的模型（~/AI_Models）：**先把该能力切回本地 Provider**，再设模型。
    ///
    /// 修的就是「切换本地模型后没有关闭外部模型接口、且显示错误」这件事：
    /// 旧实现只调 `setCapabilityModel`，而它写的是「当前生效的 Provider」——
    /// 云端正生效时，就把本地模型名（如 `ggml-small.en`）写进了**云端**供应商，
    /// 云端既没被关掉，界面还显示成「SiliconFlow 语音识别 · ggml-small.en」。
    public func selectLocalModel(_ kind: AIProviderKind, name: String) async {
        do {
            let configuration = await services.configuration
            guard let local = Self.localProvider(for: kind, in: configuration) else {
                throw AppError.configuration("该能力没有可用的本地 Provider，无法切换到本地模型。")
            }
            // ① 真正切到本地：同类其它 Provider 一律停用，云端接口就此关闭。
            try await services.setCapabilityProvider(kind, providerID: local.id)
            // ② 再把模型写到这个本地 Provider 上。
            try await services.setCapabilityModel(kind, model: name)
            bootMessage = nil
        } catch {
            bootMessage = error.localizedDescription
        }
        await refreshCapabilityInfos()
    }

    /// 某能力的本地 Provider（非云端那一个）。
    ///
    /// 真实本地 runtime（Ollama / 外部本地服务）优先于 mock：
    /// 记忆索引同时有 `ollama.embedding` 与 `mock.embedding` 时，本地模型选择器
    /// 应当切到 Ollama，而不是把模型名写进 mock（mock 会忽略 model 字段）。
    nonisolated static func localProvider(
        for kind: AIProviderKind,
        in configuration: AppConfiguration
    ) -> ProviderConfig? {
        let locals = configuration.providers.filter { $0.kind == kind && !$0.isRemote }
        if let real = locals.first(where: { $0.runtime != .mock }) { return real }
        return locals.first
    }

    /// 手动填写模型名并应用。
    ///
    /// 名字能在本地扫描结果里找到 → 按「切到本地」处理（顺带关掉云端接口）；
    /// 否则视为给**当前生效的那家**供应商指定模型（本地 / 云端都合法），
    /// 由云端闸门的「模型必须属于该供应商」兜住串线。
    public func applyCustomModel(_ kind: AIProviderKind, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if LocalModelScanner.path(of: trimmed, kind: kind) != nil {
            await selectLocalModel(kind, name: trimmed)
        } else {
            do {
                try await services.setCapabilityModel(kind, model: trimmed)
                bootMessage = nil
            } catch {
                bootMessage = error.localizedDescription
            }
            await refreshCapabilityInfos()
        }
        customModelDrafts[kind.rawValue] = ""
    }

    /// 打开设置页时，按**已保存的配置**回填外部模型草稿。
    ///
    /// 修掉三个「每次都要重来一遍」的痛点（用户实测反馈）：
    /// 1. **API Key 不回填** → 明明存过，界面上却是空框，用户以为丢了、要重新输；
    /// 2. **模型列表只活在「本次点过验证」的内存里** → 重开设置选择器就空了，无法直接切换；
    /// 3. **选中标签默认落在候选第一家** → 而不是用户上次真正在用的那一家。
    ///
    /// 只补**空**的位置：用户当下正在输入的内容不会被配置覆盖。
    public func prefillExternalDrafts() async {
        let configuration = await services.configuration
        for provider in configuration.providers where provider.isRemote {
            let saved = (provider.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Key 草稿按**卡片归属**分开填：语言模型走「云端 Provider」区块（apiKeyDrafts），
            // 其余能力走各自卡片里的「外部模型」区块（externalKeyDrafts）。
            // 两个字典都填会出事：用户在能力卡里清空输入框后，另一个字典里的旧值会把 Key「复活」，
            // 于是又回到「框里空着，应用却还在用旧密钥」——那正是这次要杜绝的行为。
            if !clearedKeyDrafts.contains(provider.id) {
                if provider.kind == .llm {
                    if (apiKeyDrafts[provider.id] ?? "").isEmpty { apiKeyDrafts[provider.id] = saved }
                } else if (externalKeyDrafts[provider.id] ?? "").isEmpty {
                    externalKeyDrafts[provider.id] = saved
                }
            }
            // 指纹只在**输入框里确实有 Key** 时才显示：框是空的就不该出现「当前使用的密钥」，
            // 那会让用户以为应用还在用旧密钥（实测反馈，截图里就是这个状态）。
            externalKeyFingerprints[provider.id] = hasKeyDraft(provider.id) ? provider.keyFingerprint : nil
            // 候选模型 + 该 Provider 当前模型 + 该能力产品层选中的模型：
            // 三者合并去重，保证选择器既能列出历史候选，也能显示「现在用的是哪个」。
            // ⚠️ 语音供应商优先用**音色清单**（friendly 名）：它们的「模型」就是音色，
            // 且静态清单随配置分发——打开设置就能选，不必先点一次「接入音色列表」。
            var models: [DiscoveredModel]
            if provider.kind == .tts, let voices = provider.voices, !voices.isEmpty {
                models = voices.map { voice in
                    DiscoveredModel(id: voice, name: provider.voiceLabel(for: voice) ?? voice)
                }
                if let model = provider.model, !model.isEmpty, !voices.contains(model) {
                    models.insert(DiscoveredModel(id: model, name: model), at: 0)
                }
            } else {
                // 候选模型的来源分两档，**不能混为一谈**：
                //   ① Provider 自己在配置里声明的 model / candidate_models —— 属于它，带上；
                //   ② 产品层当前选中的模型 —— 只有**这家就是这个能力的生效 Provider** 时才带上。
                //
                // ②这个限定是必须的：`product.selectedModel(for:)` 是**按能力**存的全局值，
                // 不看 Provider。无脑并进来，用户打开 DeepSeek 面板就会看到本地 Ollama 的
                // qwen3:8b 被列成「DeepSeek 可用模型」，页脚还写着「共 1 个可用模型」——
                // 既误导选择，也可能真的选中它去发一个必然失败的请求。
                var ids = provider.candidateModels
                if let own = provider.model, !own.isEmpty, !ids.contains(own) {
                    ids.insert(own, at: 0)
                }
                let isActiveForKind = configuration.resolvedProvider(for: provider.kind)?.id == provider.id
                if isActiveForKind,
                   let selected = configuration.product.selectedModel(for: provider.kind),
                   !selected.isEmpty,
                   !ids.contains(selected) {
                    ids.insert(selected, at: 0)
                }
                models = ids.map { DiscoveredModel(id: $0, name: $0) }
            }
            guard !models.isEmpty else { continue }
            if (externalModels[provider.id] ?? []).isEmpty { externalModels[provider.id] = models }
        }
        // 选中标签：优先落在该能力**当前生效**的云端 Provider 上（本地生效则维持原样）。
        for kind in AIProviderKind.allCases {
            guard let active = configuration.resolvedProvider(for: kind), active.isRemote else { continue }
            externalSelectedProvider[kind.rawValue] = active.id
        }
    }

    // MARK: - API Key 输入框（唯一真相）

    /// 输入框里当前的 Key（两个区块的草稿；同一 Provider 只会出现在其中一处）。
    public func keyDraft(for providerID: String) -> String {
        for draft in [externalKeyDrafts[providerID], apiKeyDrafts[providerID]] {
            guard let draft, !draft.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            return draft
        }
        return ""
    }

    /// 输入框里**现在有没有** Key。绿点、指纹、能否启用云端、调用用哪把 Key，全看它。
    public func hasKeyDraft(_ providerID: String) -> Bool {
        !keyDraft(for: providerID).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 用户在输入框里的改动。清空 = 明确表示「这个供应商不配置」。
    public func setKeyDraft(_ value: String, providerID: String, kind: AIProviderKind) {
        if kind == .llm {
            apiKeyDrafts[providerID] = value
        } else {
            externalKeyDrafts[providerID] = value
        }
        if value.trimmingCharacters(in: .whitespaces).isEmpty {
            clearedKeyDrafts.insert(providerID)
        } else {
            clearedKeyDrafts.remove(providerID)
        }
        // 框空了就别再显示「当前使用的密钥」——否则用户以为应用还在用旧 Key。
        if !hasKeyDraft(providerID) { externalKeyFingerprints[providerID] = nil }
        // ⚠️ 输入框内容一变，「已验证」记录立即作废：否则「验证 A → 改成 B → 确认配置」
        // 会拿 A 的认证记录放行 B（认证闸门的漏洞，2026-09-14 反馈系列修复）。
        if CredentialText.normalizedKey(value) != externalVerifiedKeys[providerID] {
            externalVerifiedKeys[providerID] = nil
        }
    }

    /// 把输入框内容落进配置：**空 = 清除已保存的密钥**。返回是否留下可用的 Key。
    @discardableResult
    private func syncKeyDraft(_ providerID: String, kind: AIProviderKind) async -> Bool {
        let draft = keyDraft(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = (try? await services.setRemoteProviderKey(providerID: providerID, apiKey: draft, kind: kind)) ?? false
        if !ok {
            externalKeyFingerprints[providerID] = nil
        }
        return ok
    }

    /// 某云端 Provider 配置里已保存的推理强度（外部模型面板打开时预选它，
    /// 否则用户每次进来都要重新选一遍，实际感受是「上次明明设过」）。
    public func storedReasoningEffort(providerID: String) async -> String? {
        let configuration = await services.configuration
        return configuration.providers.first { $0.id == providerID }?.reasoningEffort
    }

    /// 某能力配置里的外部 Provider 候选（id + 展示名）。
    public func remoteProviderOptions(for kind: AIProviderKind) async -> [(id: String, name: String)] {
        let configuration = await services.configuration
        return configuration.providers
            .filter { $0.kind == kind && $0.runtime == .remoteAPI }
            .map { ($0.id, $0.userFacingName) }
    }

    /// 外部模型：校验 API Key 并拉取模型列表（不落盘）。
    ///
    /// 免密钥供应商（`api_key_required = false`，如自建 Edge TTS 代理）不需要 Key：
    /// TTS 且配置了 `voice_list_path` 的拉**音色目录**（友好名一并落盘），否则按普通模型列表处理。
    public func fetchExternalModels(kind: AIProviderKind, providerID: String) async {
        let keyless = await services.isKeyless(providerID: providerID, kind: kind)
        if !keyless {
            let apiKey = await resolvedExternalAPIKey(providerID: providerID)
            guard !apiKey.isEmpty else {
                // 输入框为空 = 用户没有配置这个供应商。这里顺手把配置里的旧 Key 清掉，
                // 不让它继续留在「已配置」状态里（用户明确要求：空框不再被识别成旧密钥）。
                await syncKeyDraft(providerID, kind: kind)
                externalMessages[providerID] = "请先填写 API Key。输入框为空时应用不会使用任何已保存的旧密钥，该供应商的密钥已清除。"
                return
            }
        }
        isFetchingExternal = true
        externalMessages[providerID] = nil
        do {
            if kind == .tts, keyless {
                let voices = try await services.discoverRemoteVoices(providerID: providerID, kind: kind)
                // 音色进模型选择器：name 显示友好名（晓晓…），tag 是真音色 id。
                externalModels[providerID] = voices.map {
                    DiscoveredModel(id: $0.id, name: $0.name, isEmbeddingOnly: false, contextLength: nil)
                }
                externalMessages[providerID] = "接入成功，获取到 \(voices.count) 个音色。选好音色后会自动启用。"
            } else if kind == .pronunciation {
                // 发音评测没有「模型列表」可拉：它的 `model` 是**评测语言**（en-US…）。
                // 所以这里做两件事：把可选语言列出来，再用 1 秒静音真探一次认证。
                let apiKey = await resolvedExternalAPIKey(providerID: providerID)
                let configuration = await services.configuration
                let provider = configuration.providers.first { $0.id == providerID && $0.kind == kind }
                let locales = provider?.candidateModels ?? []
                externalModels[providerID] = locales.map {
                    DiscoveredModel(id: $0, name: $0, isEmbeddingOnly: false, contextLength: nil)
                }
                let locale = provider?.model ?? locales.first
                let conclusion = try await services.verifyRemotePronunciation(
                    providerID: providerID, apiKey: apiKey, model: locale
                )
                externalMessages[providerID] = "\(conclusion)选好评测语言后点右下角「确认配置」才会启用。"
                externalVerifiedKeys[providerID] = CredentialText.normalizedKey(apiKey)
            } else {
                let apiKey = await resolvedExternalAPIKey(providerID: providerID)
                let models = try await services.fetchRemoteModels(providerID: providerID, apiKey: apiKey, kind: kind)
                externalModels[providerID] = models.filter { !$0.isEmbeddingOnly }
                externalMessages[providerID] = "验证成功，获取到 \(models.count) 个模型。选好模型后点右下角「确认配置」才会启用。"
                // 这把 Key 刚刚真实通过认证：记下来，「确认配置」用它免二次探测（费用护栏）。
                externalVerifiedKeys[providerID] = CredentialText.normalizedKey(apiKey)
                // 把探测结果留下来：重开设置时选择器直接可用，不必再点一次验证。
                await services.rememberRemoteModels(models, providerID: providerID, kind: kind)
            }
        } catch {
            // 认证/探测失败：清掉「已验证」记录，保证「确认配置」会重新走真实认证。
            externalVerifiedKeys[providerID] = nil
            externalMessages[providerID] = error.localizedDescription
        }
        isFetchingExternal = false
    }

    /// 外部模型：保存 Key/模型并激活该 Provider。
    ///
    /// **Key 以输入框为准**：先把它落进配置（空 = 清除），再要求 Key 存在才允许启用。
    /// 这样不会出现「框里空着却被启用、并在背后用旧 Key 调用云端」的状态。
    /// 免密钥供应商不在此列：没有 Key 可要求，直接启用。
    ///
    /// ⚠️ **认证是硬闸门**（2026-09-14 反馈）：除非刚才用同一把 Key 真实验证成功过，
    /// 否则启用前先打一次真实请求——认证不过就整路失败：不落盘激活、不改模型卡片、
    /// 也不写任何成功文案。失败的配置必须「维持之前的模型调用」。
    public func applyExternalModel(
        _ kind: AIProviderKind,
        providerID: String,
        model: String,
        reasoningEffort: String? = nil
    ) async {
        let keyless = await services.isKeyless(providerID: providerID, kind: kind)
        if !keyless {
            let hasKey = await syncKeyDraft(providerID, kind: kind)
            guard hasKey else {
                externalMessages[providerID] = "请先填写 API Key。输入框为空时应用不会使用任何已保存的旧密钥，该供应商的密钥已清除。"
                await refreshCapabilityInfos()
                return
            }
        }
        let apiKey = await resolvedExternalAPIKey(providerID: providerID)
        do {
            try await validateExternalKeyIfNeeded(
                kind: kind, providerID: providerID, apiKey: apiKey, keyless: keyless, model: model
            )
            try await services.applyRemoteProvider(
                providerID: providerID, apiKey: apiKey, model: model,
                reasoningEffort: reasoningEffort, kind: kind
            )
            externalMessages[providerID] = "已启用 \(model)"
            if !keyless {
                externalKeyFingerprints[providerID] = await remoteKeyFingerprint(providerID: providerID)
            }
            if kind == .asr || kind == .tts { await bootstrapVoice() }
            if kind == .pronunciation {
                // 发音评测的应用 = 装配声学通道。装不上就回落规则推断（仍然可用），
                // 但状态要如实更新，别让设置页显示一个并不存在的「已生效云端评测」。
                pronunciationHealth = await services.bootstrapPronunciation()
            }
            // ⚠️ 面板是「配置入口」，卡片是「结果展示」，两者必须同时前进。
            //
            // 应用成功只更新 `externalMessages` 是不够的：卡片读的是
            // `activeProvider` / `modelDraft` / `activeReasoningEffort`，而它们由
            // `refreshStatus()` 填充 —— 不刷新就会出现「面板里明明已启用，关掉弹窗后
            // 卡片还停在旧模型 / 未接入」（2026-09-14 反馈的第三组问题）。
            selectedProviderID = providerID
            externalSelectedProvider[kind.rawValue] = providerID
            if kind == .llm {
                // 顺手清掉卡片上可能残留的上一次报错，再换成这次的结论。
                await refreshStatus()
                // ⚠️ 成功文案必须与真实健康状态一致（2026-09-14 反馈：右上角「配置有误」
                // 左下角却写「已启用云端模型」）。这里不再写死成功，而是**读真实健康状态**：
                // 体检通过才说「已启用」，否则原样呈现失败原因，两处口径永远同源。
                remoteMessage = health.isUsable
                    ? "已启用云端模型 \(model)"
                    : health.userFacingDescription
            }
        } catch {
            // 失败：什么都不改（配置激活被跳过、卡片保持原 Provider），只把原因留在面板里。
            externalMessages[providerID] = error.localizedDescription
        }
        await refreshCapabilityInfos()
    }

    /// 「确认配置」前的认证闸门：同一把 Key 刚验证成功过才免二次探测。
    ///
    /// 验证失败会抛错（含服务端原话），调用方据此整路失败、不落盘激活。
    private func validateExternalKeyIfNeeded(
        kind: AIProviderKind, providerID: String, apiKey: String, keyless: Bool, model: String? = nil
    ) async throws {
        guard !keyless else { return }
        let normalized = CredentialText.normalizedKey(apiKey)
        if externalVerifiedKeys[providerID] == normalized { return }
        // 发音评测没有 `/models` 可查，硬打它只会 404 并被翻译成「模型不存在」——
        // 走它自己的验证方式：发 1 秒静音探测认证与端点。
        if kind == .pronunciation {
            _ = try await services.verifyRemotePronunciation(
                providerID: providerID, apiKey: apiKey, model: model
            )
            externalVerifiedKeys[providerID] = normalized
            return
        }
        _ = try await services.fetchRemoteModels(providerID: providerID, apiKey: apiKey, kind: kind)
        externalVerifiedKeys[providerID] = normalized
    }

    /// 解析要使用的 Key：**只认输入框**。
    ///
    /// 历史实现会在输入框为空时回退到配置里已保存的 Key，于是出现「框里空着、
    /// 应用却仍拿旧 Key 去调用云端」——用户明确禁止（2026-09-13 反馈）。
    private func resolvedExternalAPIKey(providerID: String) async -> String {
        keyDraft(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 配置里这把 Key 的指纹（保存成功后刷新展示）。
    private func remoteKeyFingerprint(providerID: String) async -> String? {
        let configuration = await services.configuration
        return configuration.providers.first { $0.id == providerID }?.keyFingerprint
    }

    // MARK: - 模型 Provider（本地 / 云端切换）

    /// API Key 解析：**只认输入框**（见 `keyDraft`）。
    private func resolvedAPIKey(for providerID: String) async -> String {
        keyDraft(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 设置页：切换选中的 Provider 标签（仅改 UI，不生效）。
    public func selectProviderTab(_ id: String) {
        selectedProviderID = id
        remoteMessage = nil
        reasoningEffortDraft = id == activeProvider?.id ? activeProvider?.reasoningEffort : reasoningEffortDraft
    }

    /// 设置页：激活某个 Provider（本地或云端）。
    ///
    /// 先把输入框里的 Key 落进配置（空 = 清除该供应商的密钥），再切换。
    /// 于是「框里没填 Key」就不可能启用云端——不会出现「已启用却用着旧 Key」的状态。
    public func activateProvider(_ id: String) async {
        do {
            await syncKeyDraft(id, kind: .llm)
            try await services.switchLLMProvider(id)
            bootMessage = nil
            remoteMessage = nil
        } catch {
            remoteMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    /// 设置页：保存云端配置（API Key + 模型 + 推理强度）并激活。
    ///
    /// Key 以输入框为准（空 = 清除），所以「保存」这个动作同时也承担「不再记住这把 Key」。
    /// ⚠️ 与外部模型面板同一条认证闸门：同一把 Key 刚验证成功过才免二次探测，
    /// 否则先真实验证——不过就整路失败，卡片维持原样（2026-09-14 反馈）。
    public func applyRemoteProvider(model: String) async {
        let hasKey = await syncKeyDraft(selectedProviderID, kind: .llm)
        guard hasKey else {
            remoteMessage = "请先填写 API Key。输入框为空时应用不会使用任何已保存的旧密钥，该供应商的密钥已清除。"
            await refreshStatus()
            return
        }
        let apiKey = await resolvedAPIKey(for: selectedProviderID)
        do {
            try await validateExternalKeyIfNeeded(
                kind: .llm, providerID: selectedProviderID, apiKey: apiKey, keyless: false
            )
            try await services.applyRemoteProvider(
                providerID: selectedProviderID,
                apiKey: apiKey,
                model: model,
                reasoningEffort: reasoningEffortDraft,
                kind: .llm
            )
            bootMessage = nil
            externalKeyFingerprints[selectedProviderID] = await remoteKeyFingerprint(providerID: selectedProviderID)
            await refreshStatus()
            // 成功文案与真实健康状态同源（与外部模型面板一致，见 `applyExternalModel`）。
            remoteMessage = health.isUsable
                ? "已启用云端模型 \(model)"
                : health.userFacingDescription
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

    /// 老师人格档位（教学风格）。
    ///
    /// 只写配置，**不推给引擎**：`ChatService` 每轮生成前都会从配置里重读档位
    /// （见 `generate()` 里的 `syncPreference`）。两处各推一次就是两个写入口，
    /// 而它们迟早会不一致。
    public func setTeacherPersona(_ persona: TeacherPersona) async {
        product.teacherPersona = persona.rawValue
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

    // MARK: - 页面切换（侧栏 / 快捷键 / 菜单共用唯一入口）

    /// 当前显示的是哪一页。
    ///
    /// **唯一取数点**：侧栏高亮与快捷键都读它，别再各自去拼 `!a && !b && !c`——
    /// 漏一项的表现是「两个条目同时高亮」，那是真的发生过。
    ///
    /// ⚠️ 设置页**不在**这个枚举里：它是浮在内容之上的浮层，
    /// 打开设置不该把底下那一页关掉（否则关掉设置会掉回练习，用户会觉得页面丢了）。
    public var activeSection: AppSection {
        if showingRecords { return .records }
        if showingShadowing { return .shadowing }
        if showingWriting { return .writing }
        if showingReading { return .reading }
        if showingVocabulary { return .vocabulary }
        if showingProgress { return .progress }
        if showingDictionary { return .dictionary }
        if showingScenarios { return .scenarios }
        return .practice
    }

    /// 把「当前页」切到 `section`：**七个页面标记一次写齐**。
    ///
    /// 所有 `open*()` 都走这里，别再各自手写一串 `showingXxx = false` ——
    /// `openScenarios()` 当初就漏了 `showingRecords`，于是「学习记录」和「情景对话」会同时高亮。
    /// 只碰页面标记，**绝不碰 `showingSettings`**（理由见 `activeSection`）。
    private func applySection(_ section: AppSection) {
        showingRecords = section == .records
        showingShadowing = section == .shadowing
        showingWriting = section == .writing
        showingReading = section == .reading
        showingVocabulary = section == .vocabulary
        showingProgress = section == .progress
        showingDictionary = section == .dictionary
        showingScenarios = section == .scenarios
        // 离开词典页（或任何页面切换）就撤掉「再点一次真删」的待确认态：
        // 那个状态是**一次点击的余温**，让它跨页面活下来，用户下一次进词典库
        // 随手一点删除就是不可逆的真删。
        if section != .dictionary { dictionaryPendingDelete = nil }
    }

    /// 统一的页面跳转入口：侧栏条目、`Cmd+数字`、菜单都调它。
    ///
    /// 保留 `open*()` 上那些「顺带加载数据」的动作（进度汇总、记录加载、词汇导入…），
    /// 所以这里是转发而不是直接 `applySection`——少了那一步，页面会打开但内容是空的。
    public func go(to section: AppSection) async {
        switch section {
        case .practice: await openPractice()
        case .shadowing: await openShadowing()
        case .writing: await openWriting()
        case .reading: await openReading()
        case .dictionary: await openDictionary()
        case .vocabulary: await openVocabulary()
        case .scenarios: await openScenarios()
        case .progress: await openProgress()
        case .records: await openRecords()
        }
    }

    // MARK: - 学习记录

    public func openRecords(focus: RecordsFocus? = nil) async {
        // 跳转目标先记下来、由学习记录页消费掉：视图是 `if/else` 切出来的，
        // 每次进来都是新建的实例，没法靠视图自己的状态接住这个意图。
        recordsFocus = focus
        applySection(.records)
        await loadRecords()
    }

    public func openPractice() async {
        applySection(.practice)
        // 回到对话页 = 已经看到老师开口了，左栏那个提示点该收了。
        teacherOpenerPending = false
        // 卷轴上的进度可能是刚才练出来的（本地聚合，有节流）。
        await refreshTodayPanel()
    }

    // MARK: - 学习进度（Dashboard，第 25 步）

    /// 进入学习进度页并汇总一次。星星与每日目标是产品层输入，记录折算在服务层。
    public func openProgress() async {
        applySection(.progress)
        await reloadProgress()
    }

    /// 重新汇总学习进度（切窗口 / 手动刷新 / 刚练完回来都走这里）。
    ///
    /// - Parameter includeAnnual: 是否顺带汇总**全年**记录卡。开屏的今日卷轴传 false ——
    ///   那张 53×7 热力图要回看一整年，不该挂在「打开应用第一眼」的关键路径上。
    public func reloadProgress(includeAnnual: Bool = true) async {
        // 重入保护：页面出现与卡片刷新可能同时触发，重复跑一遍全库汇总没有意义。
        guard !isLoadingProgress else { return }
        isLoadingProgress = true
        defer { isLoadingProgress = false }
        // 年度记录要回看一整年，取数量级远大于窗口 —— 两件事**并行**做，
        // 串起来会让进度页每次都等两遍查询。
        //
        // ⚠️ goalMinutes 用 `effectiveGoalMinutes`：保底档下判定口径就是 5 分钟
        // （目标环、goalReached 与黑板计划的量对得上 —— 达标判定与实际记录一致）。
        // 每周小结 / 月环比（#228）同样并行：它要看 63 天，不该串在窗口快照后面。
        async let insight = services.weeklyInsight()
        let snapshot: ProgressSnapshot
        if includeAnnual {
            async let recap = services.annualRecap(goalMinutes: effectiveGoalMinutes)
            snapshot = await services.progressSnapshot(
                days: progressWindowDays,
                totalStars: progress.totalStars,
                goalMinutes: effectiveGoalMinutes
            )
            annualRecap = await recap
        } else {
            snapshot = await services.progressSnapshot(
                days: progressWindowDays,
                totalStars: progress.totalStars,
                goalMinutes: effectiveGoalMinutes
            )
        }
        progressSnapshot = snapshot
        weeklyInsight = await insight
    }

    /// 「本周小结 / 月环比」（#228）。与快照一起刷新；nil = 数据还不够 / 数据库不可用。
    public private(set) var weeklyInsight: WeeklyInsight?

    /// 能力定位（#229）：由进度快照 + 词汇量折出来的**估计值**，与课程进度无关。
    ///
    /// 词汇量优先用去重口径（设置页同一个数）；词汇页还没进过时退回快照的全量统计。
    public var placementEstimate: PlacementEstimate {
        let vocabularyCount = max(vocabularyUniqueWordCount, progressSnapshot.vocabulary.total)
        return PlacementEstimator.estimate(
            skills: progressSnapshot.skills,
            totalMessages: progressSnapshot.totalMessages,
            activeDays: progressSnapshot.activeDays,
            vocabularyCount: vocabularyCount,
            masteredCount: progressSnapshot.vocabulary.mastered
        )
    }

    /// 切换统计窗口（7 / 14 / 30 天）。
    public func setProgressWindow(_ days: Int) async {
        progressWindowDays = min(max(days, 7), 90)
        await reloadProgress()
    }

    /// 每日目标（分钟）——写产品配置（持久化）。
    public func setDailyGoalMinutes(_ minutes: Int) async {
        product.dailyGoalMinutes = min(max(minutes, 5), 180)
        await persistProduct()
        await reloadProgress()
    }

    /// 当前每日目标（分钟）。
    public var dailyGoalMinutes: Int { product.dailyGoalMinutes }

    /// 当前目标档位（保底 5 分钟 / 进阶）。
    public var dailyGoalMode: DailyGoalMode { product.dailyGoalMode }

    /// 切换目标档位（持久化）。
    public func setDailyGoalMode(_ mode: DailyGoalMode) async {
        guard mode != product.dailyGoalMode else { return }
        product.dailyGoalMode = mode
        await persistProduct()
        await reloadProgress()
    }

    /// 判定「今天目标达成」的时长口径（分钟）：
    /// 保底档固定 5（与保底计划的量对得上），进阶档用设置的目标值。
    private var effectiveGoalMinutes: Int {
        product.dailyGoalMode == .baseline
            ? DailyGoalMode.baselineMinutes
            : product.dailyGoalMinutes
    }

    // MARK: 定时练习提醒（#226）

    /// 当前提醒开关 / 时刻（设置页读取）。
    public var practiceReminderEnabled: Bool { product.practiceReminderEnabled }
    public var practiceReminderHour: Int { product.practiceReminderHour }
    public var practiceReminderMinute: Int { product.practiceReminderMinute }

    /// 开关练习提醒（用户主动动作 → 允许弹系统授权框）。
    public func setPracticeReminderEnabled(_ enabled: Bool) async {
        product.practiceReminderEnabled = enabled
        await persistProduct()
        await syncPracticeReminder(requestIfNeeded: true)
    }

    /// 改提醒时刻（持久化 + 重排；已授权的话立即生效）。
    public func setPracticeReminderTime(hour: Int, minute: Int) async {
        product.practiceReminderHour = min(max(hour, 0), 23)
        product.practiceReminderMinute = min(max(minute, 0), 59)
        await persistProduct()
        await syncPracticeReminder(requestIfNeeded: false)
    }

    /// 把提醒配置同步给系统通知中心，并回写授权状态供设置页展示。
    private func syncPracticeReminder(requestIfNeeded: Bool) async {
        let copy = TodayPanel.practiceReminderCopy(streakDays: progressSnapshot.streakDays)
        reminderAuthorizationDenied = await reminders.sync(
            enabled: product.practiceReminderEnabled,
            requestIfNeeded: requestIfNeeded,
            hour: product.practiceReminderHour,
            minute: product.practiceReminderMinute,
            title: copy.title,
            body: copy.body
        )
    }

    // MARK: - 写作练习（#230）

    /// 进入写作页：取今天的题（同一天恒定，与每日推荐同口径）。
    public func openWriting() async {
        applySection(.writing)
        if writingTopic == nil || writingTopic?.dayKey != WritingTopicPicker.dayKey(for: Date()) {
            writingTopic = WritingTopicPicker.topic(for: Date())
        }
    }

    /// 草稿词数（与跟读同一把分词尺）。
    public var writingWordCount: Int { ShadowingScorer.words(writingDraft).count }

    /// 交给老师批改：**一次写作 = 一次模型请求**（闸门在服务装配层）。
    public func submitWriting() async {
        guard !isWritingReviewing, let topic = writingTopic else { return }
        let essay = writingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ShadowingScorer.words(essay).count >= 30 else {
            writingNotice = "再多写几句再交 —— 至少 30 词（目标 80–120 词）。"
            return
        }
        isWritingReviewing = true
        writingNotice = ""
        defer { isWritingReviewing = false }
        guard let review = await services.reviewWriting(topic: topic, essay: essay) else {
            writingNotice = "批改没成功：老师现在联系不上（模型没启动或请求失败）。把模型跑起来后再交一次。"
            return
        }
        writingReview = review
        // 交卷即落一行写作记录（学习记录页 / 每周小结的「写作练习」口径）。
        await services.recordWritingSubmission(topic: topic, essay: essay, review: review)
    }

    /// 收掉当前批改卡（改稿重写时用）。
    public func dismissWritingReview() {
        writingReview = nil
        writingNotice = ""
    }

    /// 把批改里值得记的词收进词汇本（已存在时不重复加）。
    public func addWritingWord(_ item: WritingWord) async {
        guard await services.vocabulary.add(word: item.word) != nil else {
            writingNotice = "「\(item.word)」没能加入词汇本。"
            return
        }
        writingNotice = "已把「\(item.word)」收进词汇本。"
        await reloadVocabulary()
    }

    // MARK: - 阅读理解（#231）

    /// 进入阅读页：**今天生成过就直接回看库里那批**（一天一次生成，重启也不重出题）；
    /// 今天一篇都没有才出第一份。
    public func openReading() async {
        applySection(.reading)
        let dayKey = WritingTopicPicker.dayKey(for: Date())
        // 内存里已是今天这批（页内来回切换不重查库）。
        if !readingEntries.isEmpty, readingEntries.first?.passage.dayKey == dayKey { return }
        let stored = await services.todaysReadings(dayKey: dayKey)
        if !stored.isEmpty {
            readingEntries = stored
            showReadingEntry(at: stored.count - 1)
            return
        }
        await loadReading()
    }

    /// 出一篇短文：**一次阅读 = 一次模型请求**（首篇自动出；之后只由「换一篇」触发）。
    /// 难度档位取自能力定位（#229）的估计值 —— 还在观察中就按 A2-B1 出。
    public func loadReading() async {
        guard !isReadingLoading else { return }
        isReadingLoading = true
        readingNotice = ""
        defer { isReadingLoading = false }
        let level = placementEstimate.level?.rawValue.uppercased() ?? ""
        guard let passage = await services.generateReading(level: level) else {
            readingNotice = "短文没取到：老师现在联系不上（模型没启动或请求失败）。把模型跑起来后再试一次。"
            return
        }
        let entry = StoredReading(passage: passage, createdAt: Date())
        readingEntries.append(entry)
        showReadingEntry(at: readingEntries.count - 1)
        await services.saveReading(entry)
    }

    /// 切到今天的第 `index` 篇（编号按钮；作答进度随篇恢复）。
    public func selectReadingEntry(at index: Int) {
        guard readingEntries.indices.contains(index), index != readingEntryIndex else { return }
        showReadingEntry(at: index)
    }

    /// 把「当前展示」的三件套（篇 / 选择 / 交卷态）指到某一篇。
    private func showReadingEntry(at index: Int) {
        guard readingEntries.indices.contains(index) else { return }
        readingEntryIndex = index
        let entry = readingEntries[index]
        readingChoices = entry.choices
        isReadingReviewed = entry.isReviewed
        expandedReadingQuestions = entry.isReviewed ? Set(0..<entry.passage.questions.count) : []
        readingNotice = ""
    }

    /// 选一道题的选项（交卷后锁定；每一步选择都落库，中途退出也不丢）。
    public func chooseReadingOption(question: Int, option: Int) {
        guard !isReadingReviewed, readingEntries.indices.contains(readingEntryIndex) else { return }
        readingChoices[question] = option
        readingEntries[readingEntryIndex].choices = readingChoices
        let entry = readingEntries[readingEntryIndex]
        Task { await services.saveReading(entry) }
    }

    /// 是否每题都答了（交卷按钮的可用条件）。
    public var readingAllAnswered: Bool {
        guard let passage = readingPassage else { return false }
        return (0..<passage.questions.count).allSatisfy { readingChoices[$0] != nil }
    }

    /// 交卷：**判分纯本地零请求**（答案生成时已随文下发）——标对错、全展开解析、落库。
    public func submitReading() async {
        guard readingEntries.indices.contains(readingEntryIndex),
              !isReadingReviewed, readingAllAnswered else { return }
        isReadingReviewed = true
        // 全部展开：答对的看讲解，答错的看错因复盘 —— 需求要求对错都要溯源原文。
        let passage = readingEntries[readingEntryIndex].passage
        expandedReadingQuestions = Set(0..<passage.questions.count)
        let correct = ReadingGrader.correctCount(passage, choices: readingChoices)
        readingNotice = "交卷完成：答对 \(correct) / \(passage.questions.count)。"
        readingEntries[readingEntryIndex].isReviewed = true
        readingEntries[readingEntryIndex].choices = readingChoices
        let entry = readingEntries[readingEntryIndex]
        await services.saveReading(entry)
        await refreshTodayPanel(force: true)
    }

    /// 收起 / 展开一道题的解析卡。
    public func toggleReadingQuestion(_ index: Int) {
        if expandedReadingQuestions.contains(index) {
            expandedReadingQuestions.remove(index)
        } else {
            expandedReadingQuestions.insert(index)
        }
    }

    // MARK: - 词汇本（Vocabulary，第 24 步）

    /// 进入词汇本页：加载词表 + 从复盘导入新词。
    public func openVocabulary() async {
        applySection(.vocabulary)
        let imported = await services.importVocabularyFromReviews()
        if imported > 0 {
            vocabularyNotice = "从最近复盘导入了 \(imported) 个新词，点「查释义」配上中文解释。"
        }
        await reloadVocabulary()
        await loadVocabularyBankIfNeeded()
        await healVocabularyTermsIfNeeded()
    }

    /// 进页面时把**历史落库**里缺「词性 / 中文」的词条补一遍（后台，每次启动每个词只试一次）。
    ///
    /// 早先版本模型只把重点单词写成英文（实测 `precipitation, rainfall, drizzle, drought`），
    /// 老数据不会自己变好 —— 这里定向问一次模型补上并覆盖落库，之后的启动就直接是好的。
    /// 模型没在跑 / 补不到就静默跳过，不打扰用户。
    private func healVocabularyTermsIfNeeded() async {
        for entry in vocabularyEntries where !collapsedVocabularyDefinitions.contains(entry.id) {
            guard !termsHealAttempted.contains(entry.id) else { continue }
            let definition = VocabularyDefinitionRule.decodeStored(entry.meaning)
            guard !definition.termsNeedingCompletion.isEmpty else { continue }
            await healVocabularyTerms(id: entry.id)
        }
    }

    /// 重新读库 + 汇总统计。
    public func reloadVocabulary() async {
        let loaded = await services.vocabulary.entries()
        vocabularyEntries = loaded
        // 收录单词数按「词」去重（忽略大小写）——同词多条记录（不同释义版本）只算一个。
        // 设置页词汇本卡片的数字从这里取，收录 / 删除后跟着更新。
        vocabularyUniqueWordCount = Set(loaded.map { $0.word.lowercased() }).count
        vocabularyStats = VocabularyStats.from(loaded)
        // 复习卡上那张是队列里的**值拷贝**：词表一刷新就把新的那份资料带回卡上。
        // 不做这一步，「复习途中查到的释义」只在词表里生效，翻面还是「还没有释义」；
        // 放在这里（而不是查释义那个函数里）是因为改释义的路不止一条
        // （查释义 / 重新释义 / 补全词性与中文），凡是改了词表都该同步。
        if let current = vocabularyReview?.current,
           let fresh = loaded.first(where: { $0.id == current.id }) {
            vocabularyReview?.updateCurrent(fresh)
        }
    }

    /// 给一个词补「详细中文释义 + 例句 + 重点单词」（按需 LLM）。失败原因走页面提示条。
    public func defineVocabulary(id: UUID) async {
        if let message = await requestVocabularyDefinition(id: id).message {
            vocabularyNotice = message
        }
    }

    /// 复习途中**就地**查释义：与词表里的「查释义」是同一条链路（同一次模型调用、
    /// 同样落库、同样刷新词表），差别只在提示走复习卡自己的通道。
    ///
    /// 为什么要就地查：用户实测反馈「没有释义的词只能回词表点查释义，打断复习的连续性」。
    /// 查到的释义既落到词表（`reloadVocabulary` 会把它带回这一张卡上），也不离开这一轮。
    public func defineVocabularyReviewWord() async {
        guard let entry = vocabularyReview?.current else { return }
        vocabularyReviewNotice = nil
        if let message = await requestVocabularyDefinition(id: entry.id).message {
            vocabularyReviewNotice = message
            return
        }
        // 模型偶尔回一段空的：如实说一句，而不是留用户对着「还没有释义」发呆。
        if vocabularyReview?.current?.meaning.isEmpty ?? true {
            vocabularyReviewNotice = "模型这次没给出「\(entry.word)」的解释，可以再点一次试试。"
        }
    }

    /// 查释义的共用实现（词表与复习卡都走这里）。
    ///
    /// 成功时 `entry` 是落库后的词条；失败时 `message` 是**一句给用户看的原因** ——
    /// 调用方只决定这句话往哪条提示走（页面提示条 / 复习卡的提示条）。
    private func requestVocabularyDefinition(
        id: UUID
    ) async -> (entry: VocabularyEntry?, message: String?) {
        guard let entry = vocabularyEntries.first(where: { $0.id == id }) else {
            return (nil, "这个词已经不在词表里了。")
        }
        // 「模型没开」要说清是模型没开，别把 notInitialized 翻译成「查失败」。
        guard isModelRunning(.llm) else {
            return (nil, "\(await services.modelLabel(for: .llm)) 已关闭，请在设置里点绿色的「启动」后再查释义。")
        }
        isDefiningVocabulary.insert(id)
        defer { isDefiningVocabulary.remove(id) }
        do {
            _ = try await services.defineVocabulary(entry)
            collapsedVocabularyDefinitions.remove(id)
            await reloadVocabulary()
            guard let updated = vocabularyEntries.first(where: { $0.id == id }) else {
                return (nil, "「\(entry.word)」的释义没能读回来。")
            }
            return (updated, nil)
        } catch {
            return (nil, "「\(entry.word)」释义失败：\(error.localizedDescription)")
        }
    }

    /// 查释义按钮（与收起开关集成）：没释义 → 请求模型；有释义 → 展开 / 收起切换。
    public func toggleVocabularyDefinition(id: UUID) async {
        guard let entry = vocabularyEntries.first(where: { $0.id == id }) else { return }
        if entry.meaning.isEmpty {
            await defineVocabulary(id: id)
        } else if collapsedVocabularyDefinitions.contains(id) {
            collapsedVocabularyDefinitions.remove(id)
            // 展开时顺手补一次「词性 / 中文」：早年落库的释义里重点单词只有英文。
            await healVocabularyTerms(id: id)
        } else {
            collapsedVocabularyDefinitions.insert(id)
        }
    }

    /// 已落库释义的词条补全：近义词 / 反义词 / 重点单词缺词性或中文时，
    /// 定向请求一次模型补上并覆盖落库（每个词只试一次，失败静默）。
    private func healVocabularyTerms(id: UUID) async {
        guard !termsHealAttempted.contains(id) else { return }
        // 模型没开就等下次进页面再试（不标记，否则本次启动内不再补）。
        guard isModelRunning(.llm) else { return }
        termsHealAttempted.insert(id)
        guard let entry = vocabularyEntries.first(where: { $0.id == id }) else { return }
        guard let updated = await services.completeVocabularyTerms(entry) else { return }
        if let index = vocabularyEntries.firstIndex(where: { $0.id == id }) {
            vocabularyEntries[index] = updated
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

    // MARK: - 词汇复习闭环（P1-3 复习会话）
    //
    // 队列、判分推进、结算全部在 `AIDomain.VocabularyReviewSession`（纯函数）；
    // 这里只做三件事：开一轮、把学员的动作转成服务调用、把结果摆到界面上。
    //
    // ⚠️ **朗读分不参与等级**。音素评测回答的是「你刚才读得准不准」，
    // 而认识 / 忘了回答的是「你还记不记得这个词」—— 拿发音分替学员点等级，
    // 是两件事混成一件（读错一个音就被判「忘了」）。所以朗读只把证据摆出来。

    /// 开一轮复习：把**真的到期**的词排成队列（最多 `VocabularyReviewSession.maxCards` 个）。
    ///
    /// 没有到期的词就如实说一声，不硬开一个空会话 —— 空会话只会让人看到一条「0/0」的进度条。
    public func startVocabularyReview() async {
        let session = VocabularyReviewSession(entries: vocabularyEntries)
        guard !session.queue.isEmpty else {
            vocabularyNotice = "今天没有到期的词。过几天再来，或者去每日推荐里挑几个加进复习列表。"
            return
        }
        await stopSpeaking()
        vocabularyReview = session
        vocabularyReviewRevealed = false
        vocabularyReviewReport = nil
        vocabularyReviewRecognized = nil
        vocabularyReviewNotice = nil
        isVocabularyReviewRecording = false
        isVocabularyReviewBusy = false
    }

    /// 翻面看释义（正面只给词，先自己想一遍）。
    public func revealVocabularyReviewCard() {
        vocabularyReviewRevealed = true
    }

    /// 判分并推到下一张。
    ///
    /// 朗读结果（如果有）随判分记进结算 —— 但等级用的是学员自己按的那个。
    public func gradeVocabularyReviewCard(remembered: Bool) async {
        guard let entry = vocabularyReview?.current else { return }
        if isVocabularyReviewRecording { await cancelVocabularyReviewRecording() }
        _ = await services.vocabulary.grade(id: entry.id, remembered: remembered)
        vocabularyReview?.grade(
            remembered: remembered,
            pronunciationScore: vocabularyReviewReport?.overall,
            phonemeSource: vocabularyReviewReport?.phonemeSource
        )
        vocabularyReviewRevealed = false
        vocabularyReviewReport = nil
        vocabularyReviewRecognized = nil
        vocabularyReviewNotice = nil
        await reloadVocabulary()
        // ⚠️ 黑板要跟着复习实时走：每判一张就刷新今日作业（force 跳过 15s 节流）。
        // 之前只刷词表不刷进度快照，黑板一直显示「0/8 个词」，要点开学习进度才同步（2026-09-19）。
        await refreshTodayPanel(force: true)
    }

    /// 收起这一轮（提前退出 / 结算卡上的「完成」都走这里）。
    public func finishVocabularyReview() async {
        if isVocabularyReviewRecording { await cancelVocabularyReviewRecording() }
        await services.shadowing.stopAudio()
        vocabularyReview = nil
        vocabularyReviewRevealed = false
        vocabularyReviewReport = nil
        vocabularyReviewRecognized = nil
        vocabularyReviewNotice = nil
        isVocabularyReviewRecording = false
        isVocabularyReviewBusy = false
        await reloadVocabulary()
        await refreshTodayPanel(force: true)
    }

    /// 点一下开始读，再点一下停止并评分。
    public func toggleVocabularyReviewRecording() async {
        if isVocabularyReviewRecording {
            await finishVocabularyReviewRecording()
        } else {
            await startVocabularyReviewRecording()
        }
    }

    /// 开始读当前这个词（录音期间 VoiceService 会把识别结果流式推给输入框）。
    public func startVocabularyReviewRecording() async {
        guard vocabularyReview?.current != nil else { return }
        // ⚠️ 真源而非界面快照（见 `isModelRunning` 的说明）：巡检挂起后快照会过期。
        _ = (try? await services.resumeIfSuspended(.asr)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.asr) else {
            vocabularyReviewNotice = "\(await services.modelLabel(for: .asr)) 已关闭，请在设置里点绿色的「启动」后再读。"
            return
        }
        vocabularyReviewNotice = nil
        vocabularyReviewReport = nil
        vocabularyReviewRecognized = nil
        // 录音前先停掉朗读，别把喇叭里的老师声音也录进去。
        await stopSpeaking()
        await services.shadowing.stopAudio()
        await services.shadowing.startRecording(language: ShadowingService.practiceLanguage)
        isVocabularyReviewRecording = await services.voice.isRecording
        if !isVocabularyReviewRecording {
            vocabularyReviewNotice = await services.shadowing.lastError() ?? "麦克风没能打开，检查一下系统权限。"
        }
    }

    /// 停止录音 → **原始**识别（不做拼写纠正）→ 音素评测（跟读同一套双通道）。
    public func finishVocabularyReviewRecording() async {
        guard let entry = vocabularyReview?.current else { return }
        isVocabularyReviewRecording = false
        isVocabularyReviewBusy = true
        let recognized = await services.shadowing.finishRecording(language: ShadowingService.practiceLanguage)
        voiceTranscript = nil
        guard let recognized, !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isVocabularyReviewBusy = false
            vocabularyReviewNotice = await services.shadowing.lastError() ?? "没有听清，凑近麦克风再说一次。"
            return
        }
        vocabularyReviewRecognized = recognized
        vocabularyReviewReport = await services.shadowing.evaluateSpeech(reference: entry.word, recognized: recognized)
        if vocabularyReviewReport == nil {
            // 没拿到音频就不给分数：宁可少一项，也不拿 0 分冒充「读得很差」。
            vocabularyReviewNotice = "这次没拿到录音，所以没算分（发音是通过录音量出来的，识别文本替代不了）。"
        }
        isVocabularyReviewBusy = false
    }

    /// 放弃这次录音。
    public func cancelVocabularyReviewRecording() async {
        isVocabularyReviewRecording = false
        await services.shadowing.cancelRecording()
    }

    /// 听我的：回放刚才读的那遍。
    public func replayVocabularyReviewRecording() async {
        guard await services.shadowing.hasRecording else {
            vocabularyReviewNotice = "还没有录音，先点「读一遍」。"
            return
        }
        vocabularyReviewNotice = nil
        isVocabularyReviewBusy = true
        do {
            try await services.shadowing.replayRecording(rate: Float(product.speechRate))
        } catch {
            vocabularyReviewNotice = "回放失败：\(error.localizedDescription)"
        }
        isVocabularyReviewBusy = false
    }

    /// 朗读当前这个词（听示范）。
    public func speakVocabularyReviewWord() async {
        guard let entry = vocabularyReview?.current else { return }
        if stateSpeakingThis(entry.word) {
            await stopSpeaking()
        } else {
            await speak(entry.word)
        }
    }

    /// 正在朗读的文本是不是这一条（避免两处各写一遍比较逻辑）。
    private func stateSpeakingThis(_ text: String) -> Bool {
        speakingText == text && speechPhase != .idle
    }

    public func dismissVocabularyReviewNotice() {
        vocabularyReviewNotice = nil
    }

    // MARK: - 词汇本 · 词库总词数

    /// 载入「每日推荐词库总词数」（一次）：设置页「已学 x / y 词」的分母。
    ///
    /// ⚠️ 这个分母必须用**词典库**那份（`dailyWordBank()`，已按词去重）：
    ///   推荐词本来就是从可见词典里抽的。早先误用随包词库，会得到
    ///   「词库共 7,404 词」旁边写着「已学 0 / 145 词」这种自相矛盾。
    public func loadVocabularyBankIfNeeded() async {
        guard !vocabularyBankLoaded else { return }
        vocabularyBankLoaded = true
        dailyBankTotal = await services.dailyWordBank().count
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
        dailyWords = await services.dailyWordRecommendation(excluding: retiredDailyWords, seed: dailyWordsSeed)
        vocabularyNotice = "每日推荐学习进度已重置：认识记录清零，词库重新从简单档开始推荐。"
    }

    /// 抽 12 个推荐词（3 简单 / 5 中等 / 2 困难 / 2 词组，雅思标准）。
    /// 只在第一次进词汇本页时抽，之后进页面保持同一组；已认熟的词不再出现。
    ///
    /// ⚠️ **按天恒定**：种子由「日期 + 学习语言」派生，所以同一天关掉再打开看到的还是
    /// 这一批（原先是每次启动真随机，一天里换好几拨，「今天要学的词」这件事立不住）。
    public func loadDailyWordsIfNeeded() async {
        guard !dailyWordsLoaded else { return }
        dailyWordsLoaded = true
        dailyWords = await services.dailyWordRecommendation(excluding: retiredDailyWords, seed: dailyWordsSeed)
    }

    /// 每日推荐「按天恒定」的种子：同一天、同一学习语言 → 同一批词。
    private var dailyWordsSeed: UInt64 {
        DailySeed.seed(
            dayKey: ShadowingDailyRule.dayKey(),
            language: chat.profile.learningLanguage
        )
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

    // MARK: - 词典（词典库 + 查单词）

    /// 进入词典页。默认停在「查单词」（用户口径），**但不动已有会话**：
    /// 之前查过的词、跳转历史、输入框内容照旧留着。
    public func openDictionary() async {
        applySection(.dictionary)
        await reloadDictionaryLibrary()
    }

    /// 重新读词典库（删 / 恢复 / 改优先级 / 导入之后都走一遍）。
    public func reloadDictionaryLibrary() async {
        dictionaryBooks = await services.dictionaryBooks()
        restorableDictionaries = await services.restorableDictionaryBooks()
        dictionaryWordCount = await services.dictionaryWordCount()
        dictionaryUniqueWordCount = await services.dictionaryUniqueWordCount()
        dictionarySourceRanks = await services.dictionarySourceRanks()
        dictionarySampleWords = await services.dictionarySampleWords().map(\.word)
        dictionarySamplePool = await services.dictionarySamplePool().map(\.word)
    }

    /// 顶栏按钮：查单词 ←→ 词典库。两边状态各自保留，不用重载 ——
    /// 切走再切回来，查词会话（当前词 / 上一页 / 最初那个词）与输入框都还在。
    public func toggleDictionaryMode() async {
        dictionaryMode = dictionaryMode.toggled()
        dictionaryNotice = nil
        dictionaryPendingDelete = nil
        if dictionaryMode == .library {
            await reloadDictionaryLibrary()
        }
    }

    // MARK: 查单词

    /// 输入变化 → 刷新模糊匹配（空输入 = 收起浮层）。
    public func dictionaryQueryChanged() async {
        let query = dictionaryQuery
        // 用户把输入清空 = 这次查询他不要了：**正在跑的请求要真取消**。
        // 不取消的话，它跑完照样把卡片顶上屏 —— 而用户明明已经取消（实测报障）。
        // ⚠️ 这一步必须放在下面那个 `return` 之前：清空后 `dictionaryQuery` 与
        //    `consumedDictionaryQuery` 都是空串，会走「已消费」那条提前返回的短路。
        if normalizedDictionaryQuery(query).isEmpty {
            cancelDictionaryLookup()
        }
        // 这个词已经被查询 / 刚被程序性同步进输入框：收起浮层，也不再联想。
        // 用户下次改动输入框（哪怕只多打一个字母）就会走出这个分支，重新联想。
        if normalizedDictionaryQuery(query) == consumedDictionaryQuery {
            isDictionaryMatchListArmed = false
            dictionaryMatches = []
            return
        }
        // 用户在输入框里动了一下 = 他又在找词了，浮层这一段可以出现。
        isDictionaryMatchListArmed = true
        let matches = await services.dictionarySearch(query)
        // 期间用户可能又敲了、或者中途按了查询：落后一轮的结果一律丢弃，
        // 免得闪现旧匹配 / 把刚收起的浮层又顶出来。
        guard isDictionaryMatchListArmed,
              normalizedDictionaryQuery(dictionaryQuery) != consumedDictionaryQuery,
              query == dictionaryQuery
        else { return }
        dictionaryMatches = matches
    }

    /// 匹配 / 消费判定都走同一把尺：首尾空白不算区别。
    private func normalizedDictionaryQuery(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 收起匹配浮层（点「查询」/ 选中一条 / 清空之后）。
    public func dismissDictionaryMatches() {
        consumedDictionaryQuery = normalizedDictionaryQuery(dictionaryQuery)
        isDictionaryMatchListArmed = false
        dictionaryMatches = []
    }

    /// 用户**点回输入框**：把「已消费」这笔撤掉，重新联想一次。
    ///
    /// 用户口径：「查到之后自动隐藏，鼠标再次点击输入框时才浮现」—— 后半个动作
    /// 就靠这条。视图那边挂的是 `simultaneousGesture`（不抢输入框自己的那次点击）。
    public func rearmDictionaryMatches() async {
        consumedDictionaryQuery = nil
        await dictionaryQueryChanged()
    }

    /// 展示页出现哪个词，输入框里就是哪个词（用户口径：**任何情况下都同步**）。
    ///
    /// ⚠️ 同步的同时必须把这一笔记成「已消费」：否则这次**程序性**赋值会触发
    /// 视图上的 `.onChange`，凭空弹回一层联想浮层 —— 看着就像「跳转之后浮层
    /// 自己冒出来」（正是 09-16 那张截图里的样子）。
    private func syncDictionaryQueryToDisplayedWord() {
        guard let word = dictionaryLookup.currentWord else { return }
        let clean = normalizedDictionaryQuery(word)
        consumedDictionaryQuery = clean
        isDictionaryMatchListArmed = false
        dictionaryMatches = []
        if dictionaryQuery != clean { dictionaryQuery = clean }
    }

    /// 点「查询」按钮或回车：查输入框里的词。
    /// **不清空输入框**（用户口径）—— 查完还能就着它改一两个字母再查。
    public func submitDictionaryQuery() async {
        let word = normalizedDictionaryQuery(dictionaryQuery)
        guard !word.isEmpty else { return }
        // 先记「消费掉」再清列表：浮层收起，也不会被在途的联想请求重新顶出来。
        consumedDictionaryQuery = word
        dictionaryMatches = []
        await lookUpDictionaryWord(word, pushing: false)
    }

    /// 点中一条匹配项：**直接查那一条**（不是把输入框改掉再等用户点查询）。
    public func selectDictionaryMatch(_ match: DictionaryWord) async {
        // 顺序要紧：`dictionaryQuery` 一改会触发一次新的联想（onChange），
        // 得先把「这个词已消费」记下，那次联想才会自己收起来。
        consumedDictionaryQuery = match.word
        dictionaryQuery = match.word
        dictionaryMatches = []
        await lookUpDictionaryWord(match.word, pushing: false)
    }

    /// 点详情里可跳转的词（派生词 / 近义词 / 反义词）→ 压栈查它。
    public func openDictionaryRelated(_ word: String) async {
        await lookUpDictionaryWord(word, pushing: true)
    }

    /// 查一个词并展示。
    ///
    /// - `pushing == false`：这是「重新查一个词」，历史从它重新开始；
    /// - `pushing == true`：这是「从当前条目点进去的词」，压栈 → 左上角出现「返回上一页」。
    ///
    /// 历史**先动、请求后发**：页面立刻切到目标词（转圈），而不是让用户盯着上一页发呆。
    public func lookUpDictionaryWord(_ word: String, pushing: Bool, ignoringCache: Bool = false) async {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        dictionaryNotice = nil

        if pushing {
            dictionaryLookup.push(clean)
        } else {
            dictionaryLookup.begin(clean)
        }
        // 展示页换了词 → 输入框跟着换（跳转来的词也一样），顺带收起浮层。
        syncDictionaryQueryToDisplayedWord()

        // 已经查过（进程内缓存 / 本次会话缓存）：立刻展示，不再发请求。
        if !ignoringCache {
            if let cached = await services.dictionaryCached(clean) {
                dictionaryLookup.cache(cached)
                return
            }
            if dictionaryLookup.detail(for: clean) != nil { return }
        }

        dictionaryLoadingWord = clean
        dictionaryLookupGeneration += 1
        let generation = dictionaryLookupGeneration
        // ⚠️ 包成 `Task` 是为了**留一个能取消的句柄**：`cancelDictionaryLookup()` 拿它 cancel，
        //    底层那次 HTTP 请求会跟着被中断（不再白跑一趟、也不再烧额度）。
        let task = Task { try await services.dictionaryLookUp(clean, ignoringCache: ignoringCache) }
        dictionaryLookupTask = task
        defer {
            // 只有「还是我这一轮」才清：晚到的旧请求不许踩掉新请求的状态。
            if dictionaryLookupGeneration == generation {
                dictionaryLoadingWord = nil
                dictionaryLookupTask = nil
            }
        }
        do {
            let detail = try await task.value
            dictionaryLookup.cache(detail)
        } catch is CancellationError {
            // 用户自己取消的（清空输入 / 换了查询词）：静默收场 ——
            // 不留错误提示，也不把结果顶上屏。
        } catch {
            dictionaryNotice = Self.dictionaryFailureMessage(error, word: clean)
        }
    }

    /// 取消正在跑的那次查词（用户清空输入 = 这次查询他不要了）。
    ///
    /// 三件事一起做，缺一不可：
    /// ① 取消请求（真的中断，不是只把结果丢掉）；
    /// ② 收掉「正在查…」的转圈 —— 请求不会再回来了，不收就永远转着；
    /// ③ 把**还没拿到结果的当前页**撤掉（撤回上一页 / 回到空态）——
    ///    已经查到的词不动，缓存也留着。
    public func cancelDictionaryLookup() {
        guard dictionaryLookupTask != nil || dictionaryLoadingWord != nil else { return }
        dictionaryLookupTask?.cancel()
        dictionaryLookupTask = nil
        dictionaryLoadingWord = nil
        dictionaryLookupGeneration += 1
        dictionaryLookup.discardPendingCurrent()
    }

    /// 忽略缓存重查当前这个词（模型这次给的条目不好用时用）。
    public func relookUpDictionaryWord() async {
        guard let word = dictionaryLookup.currentWord else { return }
        await lookUpDictionaryWord(word, pushing: false, ignoringCache: true)
    }

    /// 回到上一页（左上角左箭头）。
    public func goBackDictionary() async {
        guard dictionaryLookup.canGoBack else { return }
        dictionaryLookup.goBack()
        dictionaryNotice = nil
        // 换页也是「展示页换了词」，输入框一样要跟上。
        syncDictionaryQueryToDisplayedWord()
        await ensureCurrentDictionaryDetail()
    }

    /// 一键回到最初查的那个词（多层跳转时才有这个按钮）。
    public func returnToDictionaryOrigin() async {
        guard dictionaryLookup.canReturnToOrigin else { return }
        dictionaryLookup.returnToOrigin()
        dictionaryNotice = nil
        syncDictionaryQueryToDisplayedWord()
        await ensureCurrentDictionaryDetail()
    }

    /// 当前页的详情缺失（上次查失败 / 缓存被清）时补一次请求。
    private func ensureCurrentDictionaryDetail() async {
        guard let word = dictionaryLookup.currentWord,
              dictionaryLookup.detail(for: word) == nil
        else { return }
        dictionaryLoadingWord = word
        defer { dictionaryLoadingWord = nil }
        do {
            let detail = try await services.dictionaryLookUp(word)
            dictionaryLookup.cache(detail)
        } catch {
            dictionaryNotice = Self.dictionaryFailureMessage(error, word: word)
        }
    }

    /// 查词页右上角「添加复习」：把当前词加进词汇本复习列表。
    public func addDictionaryWordToReview() async {
        guard let word = dictionaryLookup.currentWord else { return }
        if vocabularyEntries.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
            dictionaryNotice = "「\(word)」已经在词汇本里了。"
            return
        }
        guard await services.vocabulary.add(word: word) != nil else {
            dictionaryNotice = "「\(word)」没能加入复习列表（为空或没有学习数据库）。"
            return
        }
        await reloadVocabulary()
    }

    /// 当前词是否已在词汇本里（右上按钮据此显示「已在词表」）。
    public func dictionaryWordIsInVocabulary(_ word: String) -> Bool {
        vocabularyEntries.contains { $0.word.caseInsensitiveCompare(word) == .orderedSame }
    }

    // MARK: 词典库

    /// 点删除：第一次只是进入「确认」态（删除不可逆，导入的书连文件一起删）。
    public func requestRemoveDictionary(id: String) {
        dictionaryPendingDelete = dictionaryPendingDelete == id ? nil : id
        dictionaryNotice = nil
    }

    public func cancelRemoveDictionary() {
        dictionaryPendingDelete = nil
    }

    /// 再点一次 → 真删。
    public func confirmRemoveDictionary(id: String) async {
        dictionaryPendingDelete = nil
        do {
            let removed = try await services.removeDictionaryBook(id: id)
            await reloadDictionaryLibrary()
            await refreshDailyWordsAfterDictionaryChange()
            if let removed {
                dictionaryNotice = removed.isBuiltIn
                    ? "已把「\(removed.name)」从书架取下。内置词典不会丢，随时能在下面点回来。"
                    : "已删除导入的词典「\(removed.name)」，文件也一并删掉了。"
            }
        } catch {
            dictionaryNotice = error.localizedDescription
        }
    }

    /// 恢复一本被删的内置词典。
    public func restoreDictionary(id: String) async {
        do {
            try await services.restoreDictionaryBook(id: id)
            await reloadDictionaryLibrary()
            await refreshDailyWordsAfterDictionaryChange()
            dictionaryNotice = "「\(dictionaryBooks.first { $0.id == id }?.name ?? "词典")」已放回书架。"
        } catch {
            dictionaryNotice = error.localizedDescription
        }
    }

    /// 一键恢复全部内置词典。
    public func restoreBuiltInDictionaries() async {
        do {
            try await services.restoreBuiltInDictionaries()
            await reloadDictionaryLibrary()
            await refreshDailyWordsAfterDictionaryChange()
            dictionaryNotice = "内置词典已全部放回书架。"
        } catch {
            dictionaryNotice = error.localizedDescription
        }
    }

    /// 勾选 / 取消「作为每日推荐词源」。取消后名次自动补位，不留空洞。
    public func toggleDictionarySource(id: String) async {
        do {
            let on = try await services.toggleDictionarySource(id: id)
            await reloadDictionaryLibrary()
            await refreshDailyWordsAfterDictionaryChange()
            guard let book = dictionaryBooks.first(where: { $0.id == id }) else { return }
            if on, let rank = await services.dictionaryRank(of: id) {
                dictionaryNotice = "「\(book.name)」现在是每日推荐的词源，优先级 \(rank)。"
            } else {
                dictionaryNotice = "「\(book.name)」不再作为每日推荐的词源。一本都没选时，全部词典都参与推荐。"
            }
        } catch {
            dictionaryNotice = error.localizedDescription
        }
    }

    /// 导入一本词典（JSON；只有 word 必填，见词典库页的格式气泡）。
    public func importDictionary(from url: URL) async {
        isImportingDictionary = true
        defer { isImportingDictionary = false }
        do {
            let book = try await services.importDictionary(from: url)
            await reloadDictionaryLibrary()
            await refreshDailyWordsAfterDictionaryChange()
            dictionaryNotice = "已导入「\(book.name)」，共 \(book.entryCount) 词。"
        } catch {
            dictionaryNotice = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 词源变了（删 / 恢复 / 改优先级）：每日推荐重新抽一批，否则本页推荐还是旧词典的词。
    private func refreshDailyWordsAfterDictionaryChange() async {
        guard dailyWordsLoaded || !dailyWords.isEmpty else { return }
        await refreshDailyWords()
    }

    public func dismissDictionaryNotice() {
        dictionaryNotice = nil
    }

    /// 查词失败时给一句**能照着做**的话：模型没起 ≠ 这个词查不到。
    private static func dictionaryFailureMessage(_ error: Error, word: String) -> String {
        if let providerError = error as? AIProviderError, providerError == .notInitialized {
            return "AI 大脑还没启动，先在设置里点绿色的「启动」，再来查「\(word)」。"
        }
        return "「\(word)」没查到：\(error.localizedDescription)"
    }

    // MARK: - 划词翻译（悬停 / 拖选 → 气泡卡）

    /// 划词上下文：**三个页面共用这一份**（查词 / 跟读 / 练习）。
    ///
    /// 三处各写一套绑定的话，「朗读走哪条链路」「点了查单词跳到哪」这些口径迟早漂移，
    /// 而症状只会是「同一件事在 A 页好用、在 B 页不一样」。
    public var wordLookupContext: WordLookupContext {
        WordLookupContext(
            card: { [self] text in wordLookupCard(for: text) },
            onProbe: { [self] text in Task { await probeWordLookup(text) } },
            onDismiss: { [self] in clearWordLookupCard() },
            onSpeak: { [self] text in Task { await speak(text) } },
            onStopSpeak: { [self] in Task { await stopSpeaking() } },
            isSpeaking: { [self] text in speakingText == text && speechPhase != .idle },
            onOpenDictionary: { [self] text in Task { await openDictionaryForLookupWord(text) } },
            onAddToReview: { [self] text in Task { await addLookupWordToReview(text) } },
            onRetryLookup: { [self] text in Task { await retryWordLookup(text) } }
        )
    }

    /// 划词气泡的浮层宿主：整份 App 一份，注入环境后由各页面的句子共用。
    ///
    /// 气泡为什么不住在句子里：句子都在滚动容器（聊天区还带渐隐 `mask`）里，
    /// 句内 overlay 会被裁掉、也会被后面的兄弟视图盖住。交给这一层就没有遮挡问题。
    public let lookupBubble = WordLookupBubblePresenter()

    /// 当前划词气泡的内容（nil = 没有气泡）。
    ///
    /// 内容是**异步**来的（本地词库几乎瞬时，问模型要几秒），探测的那一刻通常还没有，
    /// 所以任何一次赋值都要把它推给浮层 —— 浮层自己记着这次划的是哪句话。
    public private(set) var wordLookupCard: WordLookupCard? {
        didSet { lookupBubble.updateCard(wordLookupCard) }
    }
    /// 已经问过模型的词：**同一个词一个会话只问一次**。
    /// 鼠标来回扫过同一句话是常态，没有这道闸门就会反复烧 token。
    private var wordLookupAttempted: Set<String> = []
    /// 划词请求的序号：慢的那个回来时若已经不是当前词，直接丢弃（不然会闪回上一个词）。
    private var wordLookupTicket = 0

    /// 气泡要显示的内容（页面按划到的文字来取，不匹配 → nil，气泡自然不出现）。
    public func wordLookupCard(for text: String) -> WordLookupCard? {
        guard let card = wordLookupCard else { return nil }
        return card.matches(WordLookupQuery.normalize(text)) ? card : nil
    }

    public func clearWordLookupCard() {
        wordLookupCard = nil
        wordLookupTicket += 1
    }

    /// 查不到时在气泡卡上点 ↻ **直接重查**（2026-09-19 用户口径）：
    /// 「同一个词一个会话只问一次」的省钱闸门在这条路上**显式放行** ——
    /// 用户亲手点的重试就是要再问一次，闸门只挡鼠标扫过的误触。
    public func retryWordLookup(_ raw: String) async {
        let text = WordLookupQuery.normalize(raw)
        wordLookupAttempted.remove(WordLookupQuery.key(text))
        // ⚠️ 必须先清卡：`probeWordLookup` 开头有「当前卡已匹配就早退」的闸门，
        // 不清的话失败卡还挂着、重试会被它自己挡回去。
        wordLookupCard = nil
        await probeWordLookup(text)
    }

    /// 划到一段文字（悬停一个词 / 拖选一段）→ 取内容。
    ///
    /// 取数顺序，每一步都是为了「不白花一次模型调用」：
    /// 1. **本地词库**（ECDICT 编出来的三本词典就在进程里）→ 零延迟、零成本；
    /// 2. 本地没有 → 多词走**翻译**、单词走**查词**（查词结果进词典进程内缓存，
    ///    用户接着点右上角「查单词」进那一页时直接命中，不重复问模型）；
    /// 3. 同一个单词同一个会话只问一次 —— 划来划去不重复花钱。
    public func probeWordLookup(_ raw: String) async {
        let text = WordLookupQuery.normalize(raw)
        let key = WordLookupQuery.key(text)
        guard !key.isEmpty else {
            clearWordLookupCard()
            return
        }
        // 同一个词已经出过结果 / 正在查：不重来（鼠标在同一句上微动会反复触发）。
        if let current = wordLookupCard, current.matches(text) { return }

        wordLookupTicket += 1
        let ticket = wordLookupTicket
        let isPhrase = WordLookupQuery.isPhrase(text)

        // ① 本地词库
        if let hit = await services.dictionaryKnownWord(text) {
            guard ticket == wordLookupTicket else { return }
            wordLookupCard = WordLookupCard(
                text: hit.word,
                phonetic: hit.phonetic,
                pos: hit.pos,
                translation: hit.translation,
                isPhrase: isPhrase,
                notice: hit.translation.isEmpty ? "词库里这个词没有中文释义" : nil
            )
            return
        }

        // ② 变体（复数 / -ing / -ed…）：本地词库里查**本体**。
        //
        // 用户口径：「单词一旦变为复数或 -ing、-ed 等变体就一直显示查不到 —— 应该查出
        // 单词的本体，同时解释当前变体相对本体的含义，每一个单词都要能够查到」。
        // 这一步同样零成本：只在本地库里找原形，命中就直接出条目，连模型都不用起。
        if !isPhrase, let base = await services.dictionaryBaseFormWord(of: text) {
            guard ticket == wordLookupTicket else { return }
            wordLookupCard = WordLookupCard(
                text: text,
                phonetic: base.word.phonetic,
                pos: base.word.pos,
                translation: base.word.translation,
                isPhrase: false,
                notice: base.word.translation.isEmpty ? "词库里这个词没有中文释义" : nil,
                lemma: base.word.word,
                formLabel: base.candidate.label
            )
            return
        }

        // ③ 模型没起：如实说一句，并指向「查单词」那条路（内置词典仍可用）。
        guard isModelRunning(.llm) else {
            guard ticket == wordLookupTicket else { return }
            wordLookupCard = WordLookupCard(
                text: text,
                isPhrase: isPhrase,
                notice: "词库里没有「\(text)」。启动 \(await services.modelLabel(for: .llm)) 后这里可以直接查。"
            )
            return
        }

        if !isPhrase, wordLookupAttempted.contains(key) {
            guard ticket == wordLookupTicket else { return }
            wordLookupCard = WordLookupCard(
                text: text,
                notice: "「\(text)」这次没查到，点右上角的 ↻ 再查一次，或用放大镜去词典里翻。"
            )
            return
        }

        wordLookupCard = WordLookupCard(text: text, isLoading: true, isPhrase: isPhrase)
        do {
            if isPhrase {
                let translated = try await services.translate(text, targetLanguage: nativeLanguage)
                guard ticket == wordLookupTicket else { return }
                wordLookupCard = WordLookupCard(
                    text: text, translation: translated, isPhrase: true, isFromModel: true
                )
            } else {
                wordLookupAttempted.insert(key)
                // 变体：把本地推出的候选原形当**提示**带给模型（模型可以否掉）。
                // 这一步是「subtitles / listening 查不到」的正解 —— 之前只把变体本身
                // 丢给模型，它会用一句话解释「这是 subtitle 的复数」，格式就崩了。
                let hints = WordForm.candidates(of: text).prefix(3).map(\.lemma)
                let detail = try await services.dictionaryLookUp(text, baseFormHints: Array(hints))
                guard ticket == wordLookupTicket else { return }
                wordLookupCard = Self.wordLookupCard(from: detail, text: text)
            }
        } catch {
            guard ticket == wordLookupTicket else { return }
            wordLookupCard = WordLookupCard(
                text: text,
                isPhrase: isPhrase,
                notice: "没查到「\(text)」：\(Self.dictionaryFailureMessage(error, word: text))"
            )
        }
    }

    /// 把查词结果压成气泡要的那几行（音标 + 词性 + 中文义项）。
    ///
    /// ⚠️ `text` 是用户**划到的那个写法**，而 `detail.word` 是模型给出的**本体**：
    /// 两者不同时，气泡上多一行「= 本体 · 什么形式」，这就是用户要的
    /// 「解释当前变体相对本体的含义」。形态名称由本地规则倒推（拿不到就不显示）。
    private static func wordLookupCard(from detail: DictionaryDetail, text: String) -> WordLookupCard {
        let phonetic = detail.phoneticUS.isEmpty ? detail.phoneticUK : detail.phoneticUS
        let first = detail.senses.first
        let lines = detail.senses.prefix(3).map { sense -> String in
            sense.pos.isEmpty ? sense.text : "\(sense.pos) \(sense.text)"
        }
        let translation = first == nil
            ? ""
            : lines.joined(separator: "\n")
        // 本体优先看 `form:` 那行给的（模型自己判的），没有再退回条目里的 `word:`
        // （`dictionaryLookUp` 传了 fallback，所以 `word` 正常就等于用户查的那个写法）。
        let declared = detail.baseForm.isEmpty ? detail.word : detail.baseForm
        let lemma = declared.trimmingCharacters(in: .whitespaces)
        let isSameWord = lemma.isEmpty || lemma.caseInsensitiveCompare(text) == .orderedSame
        return WordLookupCard(
            text: text,
            phonetic: phonetic,
            // 词性只在**首条义项**上显示一次：气泡只有巴掌大，每条都带词性会挤成一片。
            pos: first?.pos ?? "",
            translation: translation,
            isPhrase: false,
            isFromModel: true,
            lemma: isSameWord ? "" : lemma,
            formLabel: isSameWord ? "" : (WordForm.label(surface: text, lemma: lemma) ?? ""),
            formNote: detail.formNote
        )
    }

    /// 气泡右上角「查单词」：切到词典页并把这个词查出来（命中划词时的缓存则不发请求）。
    public func openDictionaryForLookupWord(_ raw: String) async {
        // 变体先还原成本体再进词典页：`subtitles` 直接搜是搜不到 `subtitle` 这一条的，
        // 用户在气泡上看到的就是本体的释义，进词典却空手而归会显得前后矛盾。
        let normalized = WordLookupQuery.normalize(raw)
        let word = wordLookupCard?.matches(normalized) == true
            ? (wordLookupCard?.lookupWord ?? normalized)
            : normalized
        guard !word.isEmpty else { return }
        clearWordLookupCard()
        await openDictionary()
        dictionaryQuery = word
        await lookUpDictionaryWord(word, pushing: false)
    }

    /// 气泡右上角「添加复习」：加进词汇本，并在气泡里给一句反馈。
    public func addLookupWordToReview(_ raw: String) async {
        let normalized = WordLookupQuery.normalize(raw)
        // 变体收**本体**：单词本里该出现的是 `subtitle`，不是只在一个句子里见过的 `subtitles`。
        let word = wordLookupCard?.matches(normalized) == true
            ? (wordLookupCard?.lookupWord ?? normalized)
            : normalized
        guard !word.isEmpty else { return }
        let existed = vocabularyEntries.contains { $0.word.caseInsensitiveCompare(word) == .orderedSame }
        guard await services.vocabulary.add(word: word) != nil else {
            wordLookupCard?.notice = "「\(word)」没能加入复习列表（为空或没有学习数据库）。"
            return
        }
        await reloadVocabulary()
        wordLookupCard?.notice = existed ? "「\(word)」已经在复习列表里了" : "已把「\(word)」加入复习"
    }

    // MARK: - 跟读（Shadowing，第 22 步）

    /// 进入跟读页：加载素材 + 刷新统计。
    public func openShadowing() async {
        applySection(.shadowing)
        await loadShadowing()
    }

    /// 当前要跟读的句子（素材为空时 nil）。
    public var currentShadowingDrill: ShadowingDrill? {
        guard shadowingDrills.indices.contains(shadowingIndex) else { return nil }
        return shadowingDrills[shadowingIndex]
    }

    // MARK: 段落（#232）

    /// 段落划分**从句子实时推导**，不另存一份 —— 存一份就多一个「换了一批句子但段落没跟着换」的失效点。
    public var shadowingPassages: [ShadowingPassage] {
        ShadowingPassageRule.passages(from: shadowingDrills)
    }

    /// 当前要跟读的段落（素材为空时 nil）。
    public var currentShadowingPassage: ShadowingPassage? {
        let passages = shadowingPassages
        guard passages.indices.contains(shadowingPassageIndex) else { return passages.first }
        return passages[shadowingPassageIndex]
    }

    /// 切换跟读粒度。切换时清掉上一次的结果 —— 旧粒度的结果留在新粒度下是指错对象。
    public func setShadowingMode(_ mode: ShadowingMode) {
        guard mode != shadowingMode else { return }
        shadowingMode = mode
        shadowingComparison = nil
        shadowingPronunciation = nil
        shadowingPassageResult = nil
        shadowingPassagePronunciation = nil
        shadowingNotice = nil
    }

    /// 换到下一段（段落模式下）。
    public func nextShadowingPassage() {
        let passages = shadowingPassages
        guard !passages.isEmpty else { return }
        shadowingPassageIndex = (shadowingPassageIndex + 1) % passages.count
        shadowingPassageResult = nil
        shadowingPassagePronunciation = nil
        shadowingNotice = nil
    }

    /// 加载今日素材（当天缓存 → 现生成）与跟读汇总。
    ///
    /// 两步走：**先让内置素材立刻上屏**（用户不会对着空页面等模型），
    /// 拿到今天生成的 20 句之后整批换掉。生成失败就把内置素材留在页面上，
    /// 并如实说明「今天的没生成出来」—— 而不是让页面变空。
    public func loadShadowing() async {
        if shadowingDrills.isEmpty { await loadTodayShadowingDrills() }
        await refreshShadowingStats()
    }

    /// 取今日跟读素材。`regenerate == true` 时忽略当天缓存重新生成（页面上有按钮）。
    public func loadTodayShadowingDrills(regenerate: Bool = false) async {
        if regenerate { await services.clearShadowingDailyCache() }

        // ① 今天已经生成过：直接用它（同一天内必须稳定，否则练到一半句子全换）。
        if !regenerate, let cached = await services.shadowingCachedDrills(day: nil), !cached.isEmpty {
            shadowingDrills = cached
            shadowingNotice = nil
            shadowingIsDailyGenerated = true
            resetShadowingProgress()
            return
        }

        // ② 内置素材先顶着。
        let bundled = await services.shadowing.drills()
        if shadowingDrills.isEmpty {
            shadowingDrills = bundled
            shadowingIsDailyGenerated = false
        }

        // ③ 模型没起：不报错弹窗，只留一句提示 —— 内置素材照样能练。
        guard isModelRunning(.llm) else {
            shadowingNotice = bundled.isEmpty
                ? "没有找到跟读素材（Resources/Shadowing/*.json），请检查安装包资源是否完整。"
                : "\(await services.modelLabel(for: .llm)) 已关闭，现在练的是内置素材；启动后回来就能练今天现生成的 20 句。"
            return
        }

        isShadowingLoading = true
        defer { isShadowingLoading = false }
        do {
            let generated = try await services.shadowingDailyDrills(day: nil)
            guard !generated.isEmpty else { return }
            shadowingDrills = generated
            shadowingIsDailyGenerated = true
            shadowingNotice = nil
            resetShadowingProgress()
        } catch {
            shadowingNotice = generatedFailureMessage(error, hasFallback: !bundled.isEmpty)
        }
    }

    /// 换了一批素材：练到第几句、上一句的评测结果都得跟着清 ——
    /// 留着上一批的下标会让「第 7 / 20 句」指向另一句，评测卡也挂在无关的句子上。
    private func resetShadowingProgress() {
        shadowingIndex = 0
        shadowingPassageIndex = 0
        shadowingComparison = nil
        shadowingPronunciation = nil
        shadowingPassageResult = nil
        shadowingPassagePronunciation = nil
        voiceTranscript = nil
    }

    private func generatedFailureMessage(_ error: any Error, hasFallback: Bool) -> String {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return hasFallback
            ? "今天的跟读句子没能生成（\(reason)），先在页面上练内置素材。"
            : "今天的跟读句子没能生成（\(reason)）。"
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

    /// 听示范（老师的声音读这一句 / 这一整段）。再点一次 = 重读。
    public func playShadowingExample() async {
        guard hasShadowingMaterial else { return }
        // ⚠️ 真源而非界面快照（见 `isModelRunning` 的说明）：巡检挂起后快照会过期。
        _ = (try? await services.resumeIfSuspended(.tts)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.tts) else {
            shadowingNotice = "\(await services.modelLabel(for: .tts)) 已关闭，请在设置里点绿色的「启动」后再听示范。"
            return
        }
        shadowingNotice = nil
        isShadowingBusy = true
        // 单独标一个「正在放声音」：`isShadowingBusy` 还覆盖识别 / 评分，
        // 那段窗口里给用户一个「停止」按钮是错的（停的是声音，不是评分）。
        isShadowingPlaying = true
        let selection = await services.effectiveSpeechVoiceSelection()
        let rate = Float(product.speechRate)
        switch shadowingMode {
        case .sentence:
            guard let drill = currentShadowingDrill else {
                isShadowingBusy = false
                isShadowingPlaying = false
                return
            }
            await services.shadowing.playReference(
                drill, selection: selection, language: "English", rate: rate
            )
        case .passage:
            guard let passage = currentShadowingPassage else {
                isShadowingBusy = false
                isShadowingPlaying = false
                return
            }
            await services.shadowing.playPassage(
                passage, selection: selection, language: "English", rate: rate
            )
        }
        shadowingNotice = await services.shadowing.lastError()
        isShadowingBusy = false
        isShadowingPlaying = false
    }

    /// 当前粒度下有没有可跟读的东西（一句 / 一段）。
    ///
    /// 抽出来的原因：录音、评分、听示范三处都要判，各写一份就会出现
    /// 「段落模式下因为没有 `currentShadowingDrill` 而按不动开始跟读」。
    public var hasShadowingMaterial: Bool {
        switch shadowingMode {
        case .sentence: currentShadowingDrill != nil
        case .passage: currentShadowingPassage != nil
        }
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
        guard hasShadowingMaterial else { return }
        // ⚠️ 真源而非界面快照（见 `isModelRunning` 的说明）：这就是用户报「设置里开着、
        // 一跟读就连接失败」的那一处——快照说还在跑，于是跳过了自动恢复。
        _ = (try? await services.resumeIfSuspended(.asr)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.asr) else {
            shadowingNotice = "\(await services.modelLabel(for: .asr)) 已关闭，请在设置里点绿色的「启动」后再跟读。"
            return
        }
        shadowingNotice = nil
        shadowingComparison = nil
        shadowingPronunciation = nil
        shadowingPassageResult = nil
        shadowingPassagePronunciation = nil
        voiceTranscript = nil
        // 录音前先停掉示范，避免麦克风把老师的声音也录进去。
        await services.shadowing.stopAudio()
        await services.shadowing.startRecording(language: ShadowingService.practiceLanguage)
        isShadowingRecording = await services.voice.isRecording
        if let error = await services.shadowing.lastError() { shadowingNotice = error }
    }

    /// 停止录音 → **原始**识别（不做拼写纠正）→ 对齐 + 发音评测 → 落库。
    ///
    /// 两种粒度共用入口：段落模式把整段识别文本回填到每一句（见 `ShadowingPassageScorer`）。
    public func finishShadowingRecording() async {
        guard hasShadowingMaterial else { return }
        isShadowingRecording = false
        isShadowingBusy = true
        let recognized = await services.shadowing.finishRecording(language: ShadowingService.practiceLanguage)
        isShadowingBusy = false
        voiceTranscript = nil
        guard let recognized, !recognized.isEmpty else {
            shadowingNotice = await services.shadowing.lastError() ?? "没有听清，凑近麦克风再说一次"
            return
        }
        switch shadowingMode {
        case .sentence:
            guard let drill = currentShadowingDrill else { return }
            let result = await services.shadowing.evaluate(drill: drill, recognized: recognized)
            shadowingComparison = result.comparison
            shadowingPronunciation = result.pronunciation
        case .passage:
            guard let passage = currentShadowingPassage else { return }
            let evaluation = await services.shadowing.evaluatePassage(passage, recognized: recognized)
            shadowingPassageResult = evaluation.result
            shadowingPassagePronunciation = evaluation.pronunciation
        }
        await refreshShadowingStats()
        // 跟读也是今日作业的一项：练完立刻刷新黑板/庆祝判定（force —— 练完的瞬间不许被节流吞掉）。
        // ⚠️ 以前这里不刷，跟读凑齐计划的最后一块时收尾仪式永远缺席（#227）。
        await refreshTodayPanel(force: true)
    }

    /// 听我的：回放刚才录的音，和示范对着听。
    public func replayShadowingRecording() async {
        guard await services.shadowing.hasRecording else {
            shadowingNotice = "还没有录音，先点「开始跟读」说一遍"
            return
        }
        shadowingNotice = nil
        isShadowingBusy = true
        isShadowingPlaying = true
        do {
            try await services.shadowing.replayRecording(rate: Float(product.speechRate))
        } catch {
            shadowingNotice = "回放失败：\(error.localizedDescription)"
        }
        isShadowingBusy = false
        isShadowingPlaying = false
    }

    /// 停掉跟读页面的一切声音（示范 / 回放）。
    ///
    /// 接在「听示范 / 听我的」两颗按钮上：正在放声音时它们变成「停止」。
    /// 这不是可有可无的小按钮 —— 示范音是**整段**朗读，等它读完才能开始跟读，
    /// 长句要等十几秒，用户唯一的选择原本是把音量关掉。
    public func stopShadowingAudio() async {
        await services.shadowing.stopAudio()
        isShadowingBusy = false
        isShadowingPlaying = false
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

    /// 段落模式的预览钩子（与上面单句那个同源）：拿一段文本直接走**同一条**段落评测链路。
    ///
    /// 不录麦克风、不落库。存在的理由和单句预览一样：合成不了真实点击与真实录音时，
    /// 得有一条路能把「整段反馈界面」渲染出来看（离屏回归也走它）。
    func previewShadowingPassageResult(_ recognized: String) async {
        guard let passage = currentShadowingPassage else { return }
        let result = ShadowingPassageScorer.evaluate(passage: passage, recognized: recognized)
        shadowingPassageResult = result
        shadowingPassagePronunciation = await services.pronunciation.report(
            reference: passage.text,
            recognized: recognized,
            samples: Self.demoWaveform(for: passage.text),
            sampleRate: 16_000
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
    ///
    /// 考卷与情景在同一张面板上，所以在这里一起加载 —— 分开加载会出现
    /// 「面板开了、考试那一段是空的」，而那正是资源读取失败时最难分辨的样子。
    public func openScenarios() async {
        await loadScenarios()
        await loadExamBlueprints()
        await loadMaterialKits()
        applySection(.scenarios)
    }

    public func closeScenarios() {
        showingScenarios = false
    }

    /// 加载用户材料（生成 / 删除之后由对应方法刷新，这里只在开面板时取一次）。
    public func loadMaterialKits() async {
        materialKits = await services.availableMaterials()
    }

    // MARK: 上传材料自动出题（#208）

    /// 打开「上传材料」浮层（材料列表顺带刷新）。
    public func openMaterialUpload() async {
        await loadMaterialKits()
        showingMaterialUpload = true
    }

    public func closeMaterialUpload() {
        showingMaterialUpload = false
        materialResult = nil
        lastGeneratedKit = nil
    }

    public func dismissMaterialResult() {
        materialResult = nil
    }

    /// 从文件导入材料正文（只认 txt / md；读不出来如实报错）。
    public func importMaterialFile(at path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        guard ["txt", "md"].contains(ext) else {
            materialResult = "只支持 txt / md 文本文件。"
            return
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8), !content.isEmpty else {
            materialResult = "这个文件读不出文字内容（可能是空文件或编码不支持）。"
            return
        }
        materialDraft = MaterialKitRule.sanitized(content)
        materialResult = nil
    }

    /// 生成材料练习：一次生成 = 一次模型请求；成功后材料卡立即出现在面板「我的材料」分区。
    public func generateMaterialFromDraft() async {
        guard !isGeneratingMaterial else { return }
        materialResult = nil
        lastGeneratedKit = nil
        isGeneratingMaterial = true
        defer { isGeneratingMaterial = false }
        do {
            let kit = try await services.generateMaterialKit(from: materialDraft)
            lastGeneratedKit = kit
            await loadMaterialKits()
            materialResult = "拆好了：「\(kit.scenario?.titleZh ?? kit.title)」＋ \(kit.drills.count) 句跟读 ＋ \(kit.words.count) 个生词（生词已收进词汇本）。"
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            materialResult = reason
        }
    }

    /// 删除一份材料（已加进词汇本的词不回收——那已经是学员的词了）。
    public func deleteMaterialKit(id: String) async {
        await services.deleteMaterial(id: id)
        await loadMaterialKits()
    }

    /// 开始练材料拆出的情景（与内置情景同一条练习链路）。
    public func startMaterialScenario(_ kit: MaterialKit) async {
        guard let scenario = kit.scenario else { return }
        await startScenario(scenario)
    }

    /// 拿材料的跟读句去跟读页练（覆盖当批素材；重新打开跟读页恢复每日 20 句）。
    public func useMaterialDrills(_ kit: MaterialKit) {
        guard !kit.drills.isEmpty else { return }
        shadowingDrills = kit.drills
        shadowingIsDailyGenerated = false
        shadowingNotice = "正在练材料「\(kit.scenario?.titleZh ?? kit.title)」的 \(kit.drills.count) 句。"
        resetShadowingProgress()
        Task { await openShadowing() }
    }

    /// 加载内置场景（只读资源文件；失败时保持空列表，由 UI 提示）。
    public func loadScenarios() async {
        guard !didLoadScenarios else { return }
        scenarios = await services.availableScenarios()
        // 绑定表与情景一起加载：课程阶梯要把关卡挂到档上，缺了它只能显示「未挂关」。
        levelBindings = await services.levelBindings()
        didLoadScenarios = true
    }

    // MARK: - 练习生命周期（需求 3 / 4 / 5 / 6）

    /// 刷新主线任务进度缓存（情景卡片与大树节点用；避免每帧查库）。
    public func refreshQuestRecords() async {
        questRecords = await services.allQuestProgress()
    }

    /// 某情景的主线任务进度（没有记录时给一份「从零开始」的进度，界面不用判空）。
    public func questProgress(for scenario: Scenario) -> QuestProgress {
        ScenarioQuestRule.progress(
            plan: scenario.questPlan,
            utterances: [],
            alreadyDone: questRecords[scenario.id]?.doneStepSet ?? []
        )
    }

    /// 某情景对应的大树关卡（没绑定返回 nil）。
    /// **情景 ↔ 大树联动的唯一取数点**：情景卡片与树节点都走这里，两边不可能各说各的。
    public func boundLevel(for scenario: Scenario) -> TreeLevel? {
        progress.levels.first { $0.scenarioID == scenario.id }
    }

    /// 大树节点上的「情景 + 主线任务进度」说明（需求 2：情景与大树一眼看出关系）。
    ///
    /// 在 `AppState` 算而不是在树里算：树是纯渲染层，让它自己去查情景、跑任务进度，
    /// 就会出现「树上算一遍、情景卡片再算一遍」的两处真相。
    public var treeLevelNotes: [String: TreeLevelNote] {
        var notes: [String: TreeLevelNote] = [:]
        for level in progress.levels {
            guard let scenarioID = level.scenarioID,
                  let scenario = scenario(for: scenarioID)
            else { continue }
            let quest = questProgress(for: scenario)
            notes[level.id] = TreeLevelNote(
                scenarioTitle: scenario.titleZh,
                questSummary: quest.total > 0 ? "主线 \(quest.doneCount)/\(quest.total)" : ""
            )
        }
        return notes
    }

    /// 情景卡片展开/收起（需求 3：点卡片先展开信息，不直接进练习）。
    public func toggleScenarioExpansion(_ scenarioID: String) {
        expandedScenarioID = expandedScenarioID == scenarioID ? nil : scenarioID
    }

    /// 进入某个情景：**先自动复盘上一段练习并清掉流水**，再带着「前情提要」进任务。
    ///
    /// 与以前「点卡片直接开始」的区别（需求 3）：卡片只负责展开信息，
    /// 真正的开始由卡片里的「开始任务」按钮触发；进来以后先讲前情提要，再开始当前任务。
    public func startScenario(_ scenario: Scenario) async {
        applySection(.practice)
        // 换到别的事上 = 这场考试结束了（报告也不再挂着）：考卷状态留着只会
        // 让下一段对话继续按考官口径说话。
        clearExamState()
        chat.endExam()
        if product.practiceMode != .conversation {
            product.practiceMode = .conversation
            await persistProduct()
        }
        // 上一局的判定先收起来：新的一局开始，旧卡片的覆盖率就是错的数据。
        assessmentDismissTask?.cancel()
        assessmentDismissTask = nil
        lastAssessment = nil
        lastAssessedScenarioID = nil
        expandedScenarioID = nil

        // 已经在练同一个情景：直接续做，**不重开** ——
        // 否则「展开卡片看一眼 → 再点开始任务」就会把刚才说的都清掉。
        if chat.scenarioProgress?.scenario.id == scenario.id {
            await prepareBriefing(for: scenario)
            return
        }
        await concludeCurrentPractice()
        chat.beginNewSession()
        await beginScenario(scenario)
    }

    /// 开始（或续做）一个情景任务：备好前情提要，交给老师说第一句。
    public func beginScenario(_ scenario: Scenario) async {
        // 已通关的这一关再进来 = 重练：「主线任务从头走一遍」，
        // 否则进度条一进来就是满的，学员无事可做。
        if let record = await services.questProgress(scenarioID: scenario.id), record.isComplete {
            await services.clearQuestProgress(scenarioID: scenario.id)
        }
        guard let built = await prepareBriefing(for: scenario) else { return }
        chat.startScenario(scenario, briefing: built)
        chat.deliverOpener()
    }

    /// 组装前情提要（本地读库 + 纯函数，不发请求）并同步给对话服务。
    @discardableResult
    private func prepareBriefing(for scenario: Scenario) async -> ScenarioBriefing? {
        var built = await services.scenarioBriefing(for: scenario)
        // 续做时把本局已经说过的话也算进去：界面上的进度条与老师看到的必须是同一份。
        if chat.scenarioProgress?.scenario.id == scenario.id {
            built = built.refreshed(utterances: chat.scenarioLearnerUtterances)
        }
        briefing = built
        chat.applyBriefing(built)
        await refreshQuestRecords()
        return built
    }

    /// 「开启新练习」（需求 4）：先复盘并清掉上一段，再进随口练。
    ///
    /// 与情景对话的区别：随口练**学员主导**，老师少引导、多建议与纠错；
    /// 所以这里不建主线任务、不讲前情提要，只把话头递出去。
    public func startFreeTalk() async {
        applySection(.practice)
        clearExamState()
        chat.endExam()
        assessmentDismissTask?.cancel()
        assessmentDismissTask = nil
        lastAssessment = nil
        lastAssessedScenarioID = nil
        expandedScenarioID = nil

        let previous = await concludeCurrentPractice()
        chat.beginNewSession()
        if product.practiceMode != .freeTalk {
            product.practiceMode = .freeTalk
            await persistProduct()
        }
        briefing = nil
        chat.beginFreeTalk(review: previous ?? latestReview)
        chat.deliverOpener()
    }

    // MARK: - 考试模式（雅思口语 / 面试问答）

    /// 加载内置考卷（只读资源文件；失败时保持空列表，由面板给可操作提示）。
    public func loadExamBlueprints() async {
        guard !didLoadExamBlueprints else { return }
        examBlueprints = await services.examBlueprints()
        didLoadExamBlueprints = true
    }

    /// 开始一场考试。
    ///
    /// 与进入情景同一条口径：新的一段练习开始前，先把上一段复盘掉。
    /// 区别在于**没有前情提要、没有主线任务** —— 考场上老师只按考卷出题。
    public func startExam(_ blueprint: ExamBlueprint) async {
        applySection(.practice)
        // 上一局的判定先收起来：新的一局开始，旧卡片的覆盖率就是错的数据。
        assessmentDismissTask?.cancel()
        assessmentDismissTask = nil
        lastAssessment = nil
        lastAssessedScenarioID = nil
        expandedScenarioID = nil
        clearExamState()
        // 考试不是随口练：模式必须切回来，否则老师会同时收到「你是考官」
        // 与「学员主导，你跟着聊」两套相反的指令。
        if product.practiceMode != .conversation {
            product.practiceMode = .conversation
            await persistProduct()
        }
        await concludeCurrentPractice()
        chat.beginNewSession()

        let runner = ExamRunner(blueprint: blueprint)
        guard let context = runner.turnContext else {
            // 一题都没有的考卷：说清楚，不进考试 —— 进去了只是卡在空白上。
            examRunner = nil
            practiceNotice = "这套考卷里没有题目，换一套试试。"
            return
        }
        examRunner = runner
        chat.beginExam(context)
        chat.deliverOpener()
    }

    /// 学员提交一次作答：先记进考卷（含实际用时）并推进到下一问，再把话交给考官。
    ///
    /// ⚠️ 顺序不可颠倒：老师这一轮拿到的「现在该问哪一句」必须是**推进之后**的那一题。
    /// - Returns: 真的记下了一次作答才返回 true。
    @discardableResult
    public func submitExamAnswer(_ text: String) -> Bool {
        guard var runner = examRunner, !runner.isFinished else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, runner.submit(text: trimmed) != nil else { return false }
        examRunner = runner
        guard !runner.isFinished else {
            // 最后一问答完：立刻结算，不等老师再开口 ——
            // 报告是这一场的结果，老师的收尾寒暄流没流完，不该决定报告出不出现。
            chat.updateExamContext(runner.closingContext)
            settleExam(runner)
            return true
        }
        chat.updateExamContext(runner.turnContext)
        return true
    }

    /// 学员主动跳过当前这一问。
    public func skipExamQuestion() async {
        await skipExamQuestion(reason: nil)
    }

    /// 当前这一问超时（界面倒计时到点）→ 自动跳过，整场继续。
    ///
    /// ⚠️ 这里只认「已经起表且真的到点」：界面重绘、视图重建都会再触发一次
    /// 同一条计时任务，靠 `isTimedOut` 把重复触发挡掉（否则一题能连跳好几问）。
    public func examQuestionTimedOut() async {
        guard let runner = examRunner, runner.isArmed, runner.isTimedOut(now: Date()) else { return }
        await skipExamQuestion(reason: "时间到")
    }

    private func skipExamQuestion(reason: String?) async {
        guard var runner = examRunner, !runner.isFinished else { return }
        runner.skip()
        examRunner = runner
        guard !runner.isFinished else {
            chat.updateExamContext(runner.closingContext)
            settleExam(runner)
            return
        }
        // 没人作答 = 没有话头递给老师：这一问由考卷直接宣布（本地消息，零模型请求）。
        // 起表也在这里做 —— 宣布是同步的，题目从这一刻起就在学员眼前。
        guard let context = runner.turnContext else { return }
        chat.updateExamContext(context)
        chat.announceExamPrompt(context, reason: reason)
        runner.arm()
        examRunner = runner
    }

    /// 学员点「结束考试」（提前交卷）：剩余题目全部跳过，直接结算。
    public func finishExam() async {
        guard var runner = examRunner, !runner.isFinished else { return }
        // 老师可能正在念题：结束考试就该让它停下来 ——
        // 否则下一句会落到已经收场的考场上，留下一句没头没尾的问题。
        chat.cancel()
        runner.finishEarly()
        examRunner = runner
        chat.updateExamContext(nil)
        settleExam(runner)
    }

    /// 关闭结算卡：本轮考试到此为止（报告、示范答案一起收走）。
    public func dismissExamReport() {
        clearExamState()
        chat.endExam()
    }

    /// 用同一套考卷再来一次。
    public func retakeExam() async {
        guard let blueprint = examRunner?.blueprint else { return }
        dismissExamReport()
        await startExam(blueprint)
    }

    /// 重写一次示范答案（上次没拿到时给学员一个重试的出口）。
    public func retryExamSampleAnswers() {
        guard examRunner != nil, !examSampleTargets.isEmpty else { return }
        requestExamSampleAnswers()
    }

    /// 老师一轮结束（`ChatService.onTeacherTurnEnd`）：考试模式下做两件事。
    ///
    /// ⚠️ 这两件事都**只能**发生在这里：起表要知道题目何时真正出现在学员眼前，
    /// 补记纠错要知道老师这一轮标了几处 —— 都在一次生成之后才知道。
    func handleTeacherTurnEnd(_ message: ChatMessage?, corrections: [GrammarCorrection]) {
        guard var runner = examRunner else { return }
        // ① 老师这一轮没产出正文（模型没起来 / 回空）→ 这一问由考卷本地宣布。
        //    题目照出、整场不卡，而且学员仍然有可答的东西。
        if message == nil, !runner.isFinished, let context = runner.turnContext {
            chat.announceExamPrompt(context, reason: "老师这轮没接上")
        }
        // ② 题目此刻才在学员眼前：倒计时从这一刻起表。
        runner.arm()
        // ③ 老师标出的错误条数补记到刚答完的那一问（语法分的依据）。
        //    —— 收场那一轮不算：那时老师被要求不要评价，把它的「零条」记成
        //    「零错误」就是又一次把「没测到」说成「没问题」。没有正文时同理。
        if message != nil,
           chat.examContext?.isClosing != true,
           let number = runner.lastAnsweredQuestionNumber {
            runner.attachErrorCount(corrections.count, toQuestion: number)
        }
        examRunner = runner
    }

    /// 清掉考试的一切痕迹（学员换到别的事上、或关掉结算卡）。
    private func clearExamState() {
        examSampleTask?.cancel()
        examSampleTask = nil
        isGeneratingExamSamples = false
        examSampleTargets = []
        examSampleAnswers = [:]
        examSampleNotice = nil
        examReport = nil
        examRunner = nil
    }

    /// 结算：出报告 + 请老师写示范答案（**一次请求**，写完之前不发第二次）。
    ///
    /// 报告里的分数**不经过模型**（`ExamScoring` 是纯函数），
    /// 所以报告一定出得来；示范答案是附加项，拿不到就如实说没拿到。
    private func settleExam(_ runner: ExamRunner) {
        let report = runner.report(pronunciation: nil)
        examReport = report
        examSampleAnswers = [:]
        examSampleNotice = nil
        examSampleTargets = ExamSampleAnswerRule.items(
            for: ExamSampleAnswerRule.targets(session: runner.session, report: report),
            in: runner.session
        )
        // 每一问都答够了 → 不硬凑一份示范答案，也不发这一次请求。
        requestExamSampleAnswers()
    }

    private func requestExamSampleAnswers() {
        guard let blueprint = examRunner?.blueprint, !examSampleTargets.isEmpty else { return }
        let targets = examSampleTargets
        let language = product.learningLanguage
        let nativeLanguage = product.nativeLanguage
        examSampleTask?.cancel()
        isGeneratingExamSamples = true
        examSampleTask = Task { [weak self] in
            guard let self else { return }
            let answers = await self.services.examSampleAnswers(
                examTitle: blueprint.title,
                targets: targets,
                learningLanguage: language,
                nativeLanguage: nativeLanguage
            )
            guard !Task.isCancelled else { return }
            self.isGeneratingExamSamples = false
            if answers.isEmpty {
                self.examSampleNotice = "示范答案这次没拿到（模型没起来，或返回里没有可用的答案行）。"
            } else {
                self.examSampleAnswers = answers
                self.examSampleNotice = nil
            }
        }
    }

    /// 收尾当前这段练习：**先复盘，再删流水**（需求 5）。
    ///
    /// 顺序不可颠倒 —— 复盘没成功就把流水删了，这一局说过的话就再也找不回来了。
    /// 复盘失败时**绝不删**，只留一句提示，练习内容继续留着。
    ///
    /// - Returns: 这一步得到的复盘（没有可复盘的内容时为 nil）。
    @discardableResult
    public func concludeCurrentPractice() async -> SessionReview? {
        let sessionID = chat.sessionID
        let messages = chat.messages
        guard !messages.isEmpty else { return nil }

        let reviewedCount = await services.reviewedMessageCount(sessionID: sessionID)
        guard PracticeReviewPolicy.shouldAutoReview(
            messageCount: messages.count, lastReviewedMessageCount: reviewedCount
        ) else {
            return await services.sessionReview(sessionID: sessionID)
        }

        let duration = await services.sessionDuration(sessionID: sessionID)
        let corrections = chat.correctionsByMessage.values.flatMap { $0 }
        let review = await services.makeSessionReview(
            sessionID: sessionID, messages: messages, corrections: corrections, duration: duration
        )
        // 复盘里提到的新词立刻进词汇本（需求 5：复盘完词汇本自动更新）。
        await services.importVocabularyFromReviews()

        guard PracticeReviewPolicy.canPurgeSource(review) else {
            practiceNotice = "这次复盘没生成出来，练习内容先给你留着，稍后再试。"
            await loadReviews()
            return review
        }
        let purged = await services.purgePracticeMessages(sessionID: sessionID)
        practiceNotice = purged > 0
            ? "上一段练习已自动复盘，内容已收进学习记录。"
            : nil
        await loadRecords()
        return review
    }

    /// 启动时的「继续上次」（需求 6）：不再自动开新练习。
    ///
    /// 三条路：
    /// 1. 上一段流水还在（没走成复盘）→ 保留对话直接续，只把前情提要补上；
    /// 2. 流水已清（复盘成功）→ 看会话行：情景就续做任务，随口练就接着聊；
    /// 3. 第一次打开 → 老师给一句一般招呼，等学员开口。
    private func resumeOrOpenPractice() async {
        // ① 流水还在：对话本身就是要接着用的东西，先别再动它。
        if !chat.messages.isEmpty {
            if let scenario = chat.scenarioProgress?.scenario {
                // 情景还没走完 —— 这段历史正是要接着练的那一段，揭开（它一恢复就被按住了）。
                chat.revealRestoredHistory()
                await prepareBriefing(for: scenario)
                return
            }
            // ⚠️ 这段对话**不接着用**（要复盘掉、换成新的一段），所以先把它从界面上撤下来再做。
            // 复盘要跑一次模型请求（实测好几秒），中间还夹着一次 `beginNewSession()` 的清空 ——
            // 不撤的话用户看到的就是「先闪一条学员问候，再变成老师的招呼」（实测报障）。
            //
            // ⚠️ 再查一次「学员有没有开口」：这段现在是**后台**跑的（见 `openInBackground`），
            // 从检查到这儿可能已经过去几十秒 —— 这期间学员说的每一句话都必须留下。
            guard !learnerEngagedThisLaunch else {
                chat.revealRestoredHistory()
                return
            }
            chat.hideRestoredHistory()
            await concludeCurrentPractice()
            // ⚠️ **复盘之后再看一次**：那一次模型调用可能跑了几十秒，
            // 这期间学员完全可能已经开口了 —— 这时 `beginNewSession()` 会把他的话一起清掉。
            // 这里到 `beginNewSession()` 之间没有 await，检查与清空是原子的（都在 MainActor）。
            guard !learnerEngagedThisLaunch else {
                chat.revealRestoredHistory()
                return
            }
            chat.beginNewSession()
        }
        // ② 流水已清：靠会话行判断上次在练什么（sessions 行永远留着）。
        guard let latest = await services.latestChatSession()?.session else {
            chat.greetIfNeeded()
            return
        }
        // ⚠️ 先查「那一关的主线任务是不是已经跑完」：跑完的这一关没有「没做完的事」可续，
        // 一律当空闲处理 —— 否则 `beginScenario` 会把已完成的主线清零重来，
        // 学员一启动就看到「主线 0/3」，而右边大树上那一格却写着「已过关」，两处自相矛盾。
        // 想重练是**主动**行为：去情景卡片点「开始任务」，那时才重置。
        let latestQuestComplete: Bool
        if let id = latest.scenarioID, !id.isEmpty {
            latestQuestComplete = await services.questProgress(scenarioID: id)?.isComplete == true
        } else {
            latestQuestComplete = false
        }
        switch PracticeResumeRule.action(
            latestScenarioID: latest.scenarioID,
            latestMode: latest.mode,
            questComplete: latestQuestComplete
        ) {
        case .resumeScenario(let id):
            guard let scenario = scenario(for: id) else {
                chat.greetIfNeeded()
                return
            }
            if product.practiceMode != .conversation {
                product.practiceMode = .conversation
                await persistProduct()
            }
            await beginScenario(scenario)
        case .resumeFreeTalk:
            if product.practiceMode != .freeTalk {
                product.practiceMode = .freeTalk
                await persistProduct()
            }
            chat.beginFreeTalk(review: await services.recentReviews(limit: 1).first)
            chat.deliverOpener()
        case .idle:
            chat.greetIfNeeded()
        }
        // 走到这里说明这段历史**还留在对话里**（续做情景 / 接着聊 / 只是打个招呼）——
        // 它就是学员要接着看的内容，揭开。要换新一段的那条路已经在上面 `clear()` 掉了，
        // 这里会自然跳过（`revealRestoredHistory` 见空流水直接返回）。
        chat.revealRestoredHistory()
    }

    /// 实时把主线任务进度落库（学员每说完一句就调用，见 `ChatService.onLearnerTurn`）。
    ///
    /// ⚠️ **并集语义**：新完成的步骤与库里已有的取并集，只增不减 ——
    /// 上一局推到的第 2 步不会因为这一局没说到而退回去（断点续做的基础）。
    public func persistLiveQuestProgress() async {
        guard let scenario = chat.scenarioProgress?.scenario,
              let live = chat.briefing?.quest,
              live.total > 0
        else { return }
        let previous = await services.questProgress(scenarioID: scenario.id)
        let record = (previous ?? ScenarioQuestRecord(scenarioID: scenario.id)).merging(
            doneStepIDs: live.completedStepIDs,
            complete: live.isComplete,
            sessionID: chat.sessionID
        )
        await services.saveQuestProgress(record)
        briefing = chat.briefing
        await refreshQuestRecords()
    }

    /// 结束当前情景（对话内容保留），并按「主线任务 + 教学重点」判定是否过关。
    public func endScenario() async {
        guard let progress = chat.scenarioProgress else {
            chat.endScenario()
            return
        }
        // **必须在这一步之前取**：`endScenario()` 一执行，就再也分不清哪几句属于这一局。
        let utterances = chat.scenarioLearnerUtterances
        let plan = chat.briefing?.plan
        let alreadyDone = chat.briefing?.persistedStepIDs ?? []
        chat.endScenario()
        await settleScenario(progress, utterances: utterances, plan: plan, alreadyDone: alreadyDone)
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
        // 结算卡盖住了的今日庆祝现在补放（「防堆叠」的另一半：不是不放，是错开放）。
        if rewardCelebrationPending {
            Task { [weak self] in await self?.refreshTodayPanel(force: true) }
        }
    }

    /// 结算一次情景练习（需求 3 的新口径）：
    ///
    /// **通关 = 完成主线任务 + 教学重点达标**，两条都满足才点亮这一关；
    /// 星星只记「开口量」（参与度），不再决定胜负 —— 说满轮次却没说到点子上不算过关。
    ///
    /// 主线任务进度在这里再落一次库（并集），保证「哪怕中途退出也不丢已完成步骤」。
    private func settleScenario(
        _ finished: ScenarioProgress,
        utterances: [String],
        plan: QuestPlan?,
        alreadyDone: Set<String>
    ) async {
        let scenario = finished.scenario
        let assessment = publishAssessment(
            scenario: scenario, utterances: utterances, plan: plan, alreadyDone: alreadyDone
        )
        await persistQuestProgress(scenario: scenario, assessment: assessment)
        briefing = nil

        let passed = assessment?.verdict.didPass ?? false
        let shortfall = assessment.map { Self.shortfallText($0) }

        guard let index = progress.levels.firstIndex(where: { $0.scenarioID == scenario.id }) else {
            // 场景没有绑定关卡：只给一句反馈，不动进度
            lastReward = ScenarioRewardRule.reward(
                scenarioTitle: scenario.titleZh, stars: 0, levelTitle: nil,
                didPass: passed, willCompleteLevel: false, shortfall: shortfall
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
            scenarioTitle: scenario.titleZh, stars: award.gained, levelTitle: level.title,
            didPass: passed, willCompleteLevel: passed, shortfall: shortfall
        )
        if award.total != level.earnedStars {
            progress.levels[index].earnedStars = award.total
        }
        if passed {
            await completeLevel(level.id, earnedStars: award.total)
        } else {
            // 没通关也要在树上留下痕迹：这一关「正在学」。
            if level.state != .locked {
                progress.levels[index].state = .inProgress
            }
            progress.recalculateSummary()
            await services.saveProgress(progress)
        }
        scheduleRewardDismissal()
    }

    /// 把主线任务进度落库（并集，只增不减）。
    private func persistQuestProgress(scenario: Scenario, assessment: CurriculumAssessment?) async {
        guard let assessment, assessment.quest.total > 0 else { return }
        let previous = await services.questProgress(scenarioID: scenario.id)
        let record = (previous ?? ScenarioQuestRecord(scenarioID: scenario.id)).merging(
            doneStepIDs: assessment.quest.completedStepIDs,
            complete: assessment.quest.isComplete,
            sessionID: chat.sessionID
        )
        await services.saveQuestProgress(record)
        await refreshQuestRecords()
    }

    /// 没通关时的一句话原因（取第一条未达标项，直白可核对）。
    private static func shortfallText(_ assessment: CurriculumAssessment) -> String {
        if !assessment.isQuestSatisfied {
            let remaining = assessment.quest.total - assessment.quest.doneCount
            let next = assessment.quest.currentText
            return next.isEmpty
                ? "主线任务还差 \(remaining) 步"
                : "主线任务还差 \(remaining) 步，下一步是「\(next)」"
        }
        if !assessment.isFocusSatisfied {
            let missing = assessment.focus.missingItems.prefix(2).map(\.text).joined(separator: "、")
            return missing.isEmpty ? "教学重点还差一点" : "教学重点还差：\(missing)"
        }
        return "再完整走一遍这一关"
    }

    /// 算一次判定并挂到 `lastAssessment`（既没有主线任务也没有教学重点的场景不产生判定卡 —— 没有可比的目标）。
    @discardableResult
    private func publishAssessment(
        scenario: Scenario,
        utterances: [String],
        plan: QuestPlan? = nil,
        alreadyDone: Set<String> = []
    ) -> CurriculumAssessment? {
        let effectivePlan = plan ?? scenario.questPlan
        let hasTargets = effectivePlan.total > 0
            || !scenario.targetSentences.isEmpty
            || !scenario.targetVocabulary.isEmpty
        guard hasTargets else {
            lastAssessment = nil
            lastAssessedScenarioID = nil
            return nil
        }
        let assessment = CurriculumScorer.assess(
            scenario: scenario, utterances: utterances, questDone: alreadyDone
        )
        lastAssessedScenarioID = scenario.id
        lastAssessment = assessment
        scheduleAssessmentDismissal()
        return assessment
    }

    /// 立刻收起覆盖度判定卡。
    public func dismissAssessment() {
        assessmentDismissTask?.cancel()
        assessmentDismissTask = nil
        lastAssessment = nil
        lastAssessedScenarioID = nil
    }

    /// 判定卡字更多、要读一会儿，所以比奖励条（5 秒）多留一倍时间。
    private func scheduleAssessmentDismissal() {
        assessmentDismissTask?.cancel()
        assessmentDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.lastAssessment = nil }
        }
    }

    /// 课程阶梯（CEFR 分档 + 大树关卡挂档），供进度页展示。
    ///
    /// 纯计算、不落库：素材改档、绑定改表，这里立刻跟着变。
    ///
    /// 自己补一次绑定注入，**不假设 `start()` 已经跑过** ——
    /// `progress` 的初始值是 `.seed()`，那份数据里每一关的 `scenarioID` 都是 nil，
    /// 少了这一步，阶梯会全部显示成「未挂关」。
    /// 绑定表为空时**原样保留**现有绑定（不静默清空）。
    public var curriculumStages: [CurriculumStage] {
        var tree = progress
        if !levelBindings.isEmpty {
            tree.applyScenarioBindings(levelBindings)
        }
        return CurriculumLadder.stages(scenarios: scenarios, levels: tree.levels)
    }

    /// 整条课程阶梯的完成度 0...1。
    public var curriculumProgress: Double {
        CurriculumLadder.overallProgress(curriculumStages)
    }

    private func scheduleRewardDismissal() {
        rewardDismissTask?.cancel()
        rewardDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.lastReward = nil }
            // 自动收起同样要给被盖住的庆祝一个补放机会。
            if self?.rewardCelebrationPending == true {
                await self?.refreshTodayPanel(force: true)
            }
        }
    }

    public func loadRecords() async {
        records = await services.recentSessions(limit: 20)
        mistakes = await services.recentCorrections(limit: 50)
        await loadReviews()
        reviewIndex = Dictionary(
            (await services.recentReviews(limit: 60)).map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        await refreshLearningMemory()
        await refreshQuestRecords()
    }

    /// 某次练习的复盘（记录页展开卡片时用）。没有复盘返回 nil —— 界面据此显示「暂无复盘」。
    public func review(for sessionID: UUID) -> SessionReview? { reviewIndex[sessionID] }

    /// 重算学习记忆（纯本地库读取，不发起任何模型请求）。
    public func refreshLearningMemory() async {
        learningMemory = await services.learningMemory()
    }

    /// 清除学习记忆（**不可逆**）：删掉纠错 / 复盘 / 跟读 / 复习流水，单词本与对话记录保留。
    ///
    /// 清完立刻重算并刷新记录页，避免界面上还留着「已经删掉」的错题。
    public func clearLearningMemory() async {
        do {
            let cleared = try await services.clearLearningMemory()
            await loadRecords()
            learningMemoryNotice = cleared.total == 0
                ? "本来就没有可清除的学习记忆。"
                : "已清除 \(cleared.total) 条学习记忆（纠错 \(cleared.corrections) · 复盘 \(cleared.reviews) · 跟读 \(cleared.shadowing) · 复习流水 \(cleared.vocabularyReviews)）。单词本和对话记录都还在。"
        } catch {
            learningMemoryNotice = "清除失败：\(error.localizedDescription)"
        }
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

    /// 刷新隐私状况（打开设置页时调用；切换供应商时由 `refreshCapabilityInfos` 自动带上）。
    public func refreshPrivacy() async {
        privacyReport = await services.privacyReport()
    }

    // MARK: - 运行环境 / 配置体检（设置页「运行环境」卡片）

    /// 刷新「数据在哪、配置读没读进来」这类环境信息。
    public func refreshRuntimeLocations() async {
        configLocationPath = await services.configStore.storageLocation.path
        configLoadFailure = await services.configStore.loadFailureReason
    }

    /// 配置体检：每个能力「该由谁生效、为什么生不生效」。
    ///
    /// 读的是注册表那三条投影接口（`modelConfigs` / `defaultModelConfig` /
    /// `registryInconsistencies`）—— 它们以前没有任何消费方，
    /// 于是「配置一致性体检」这件事实际从未发生。
    public func refreshRegistryCheck() async {
        var rows: [RegistryCheckRow] = []
        for kind in AIProviderKind.allCases {
            let all = await services.modelConfigs(kind: kind)
            let effective = await services.defaultModelConfig(for: kind)
            let issues = await services.registryInconsistencies(for: kind)
            rows.append(
                RegistryCheckRow(
                    kind: kind,
                    effective: effective,
                    providerCount: all.count,
                    enabledCount: all.filter(\.isEnabled).count,
                    issues: issues,
                    // 体检要回答的不只是「配置对不对」，还有「配好了但真的在走那条路吗」：
                    // LLM 报连接状态，发音评测报「这次是实测还是推断」。
                    healthDescription: await registryHealthNote(for: kind)
                )
            )
        }
        registryCheckRows = rows
    }

    /// 配置体检那一行下面补的一句「实际情况」（没有就不补）。
    private func registryHealthNote(for kind: AIProviderKind) async -> String? {
        switch kind {
        case .llm:
            llmHealthDescription
        case .pronunciation:
            await services.pronunciationChannelSummary()
        case .asr:
            // 词级时间戳是「转写结果里逐词带不带起止秒」的能力位。
            // 它以前只有产出方、没有消费方 —— 于是既没人看它，
            // 也没人发现它哪天退化成不填（`ASRResult.words` 变空数组是静默的）。
            await services.asrWordTimestampSupport()
                ? "转写返回词级时间戳（每个词带起止秒）"
                : "转写只给整段文本，不带词级时间戳"
        default:
            nil
        }
    }

    /// 从磁盘重新载入配置，并把运行时**重接一遍**。
    ///
    /// 为什么需要它：配置是「内置默认 + 用户覆盖」两层合并出来的，用户在外面手改了
    /// `config.json`（或把备份的配置拷回来）之后，旧版本只能重启应用才生效。
    /// 而只把配置读回内存是不够的 —— 真正干活的是已经装配好的 provider，
    /// 不重装配就会出现「设置页按新配置显示、实际还在打旧端点」这种最难查的错位。
    public func reloadConfigurationFromDisk() async {
        await services.configStore.reload()
        await services.rebootstrapAll()
        await reloadProduct()
        await refreshRuntimeLocations()
        await refreshStatus()
        await refreshCapabilityInfos()
        await refreshRegistryCheck()
        await refreshVoiceProfiles()
        await refreshPrivacy()
        if let failure = configLoadFailure {
            configReloadNotice = "重新载入了，但内置默认配置读不出来：\(failure)"
        } else {
            let count = await services.configuration.providers.count
            configReloadNotice = "已按磁盘上的 config.json 重新载入（\(count) 个供应商），运行时已重接。"
        }
    }

    /// 关掉「重新载入配置」的回执。
    public func dismissConfigReloadNotice() {
        configReloadNotice = nil
    }

    /// 清理可再生的缓存（学习记忆与配置始终保留）。
    public func clearCache() async {
        let before = await services.clearCaches()
        let after = await services.cacheSnapshot()
        cacheSnapshot = after
        cacheFreedBytes = max(before.totalBytes - after.totalBytes, 0)
    }

    // MARK: - 数据备份（第 30 步）

    /// 刷新备份清单与学习库健康状况。
    public func refreshBackups() async {
        backupSnapshots = await services.backups()
        databaseRecoveryNote = await services.recoveryNote
    }

    // MARK: - 备份导入（#209：换机迁移 / 误删恢复）

    /// 第一步：校验备份。通过后存下恢复计划等用户确认；坏包在这里就被拦下。
    public func inspectBackup(at path: String) async {
        backupError = nil
        do {
            let plan = try await services.inspectBackup(at: path)
            backupImportPlan = BackupImportPlan(plan)
            backupImportPath = path
        } catch {
            backupError = error.localizedDescription
        }
    }

    /// 第二步（用户确认后）：覆盖前自动留底当前数据，把新文件落进暂存，重启时自动替换。
    public func confirmBackupImport() async {
        guard backupImportPlan != nil else { return }
        backupImportPlan = nil
        do {
            try await services.stageRestore(at: backupImportPath ?? "")
            backupImportNotice = "已安排恢复。重启应用时自动替换，当前数据已先自动备份一份（含「恢复前」标记）。"
            await refreshBackups()
        } catch {
            backupError = error.localizedDescription
        }
    }

    /// 导入确认框取消。
    public func cancelBackupImport() {
        backupImportPlan = nil
        backupImportPath = nil
    }

    /// 关掉「已安排恢复」回执。
    public func dismissBackupImportNotice() {
        backupImportNotice = nil
    }

    /// 导出一份完整备份，成功后刷新清单。失败要把原因显示出来，
    /// 否则用户会以为「备份做好了」——那比没有备份更危险。
    public func exportBackup() async {
        guard !isExportingBackup else { return }
        isExportingBackup = true
        defer { isExportingBackup = false }
        do {
            _ = try await services.exportBackup()
            backupError = nil
            await refreshBackups()
        } catch {
            backupError = error.localizedDescription
        }
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

    /// 配置在 Services 侧被改过之后，把 UI 的缓存对齐。
    ///
    /// `product` 是 UI 缓存：别处（如启用克隆音色）写了配置却不重读，界面就会一直显示旧值。
    private func reloadProduct() async {
        product = await services.configuration.product
    }
}
