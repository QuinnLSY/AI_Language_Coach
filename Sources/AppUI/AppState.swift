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

/// 语义记忆索引此刻的状态（设置页「运行环境」卡的一行）。
///
/// 「已接通 / 未接通」在模型管理中心的嵌入区块已经说过了，这里补的是它没说的两件事：
/// **用的是多少维的索引**，以及**没接通时该去哪儿接通**——后者才是用户真正的下一步动作。
public struct SemanticMemoryStatus: Sendable, Equatable {
    /// 是否接通了真实（非 mock）的嵌入 runtime。
    public let isEnabled: Bool
    /// 向量维度（0 = 没装索引）。
    public let dimensions: Int

    public static let unknown = SemanticMemoryStatus(isEnabled: false, dimensions: 0)

    public init(isEnabled: Bool, dimensions: Int) {
        self.isEnabled = isEnabled
        // 维度不可能为负；给负数说明上游算错了，静默改 0 会让「已接通但 0 维」看起来正常。
        self.dimensions = max(dimensions, 0)
    }

    /// 主行：一眼看出通没通。
    public var headline: String {
        guard isEnabled else { return "未接通 · 记忆按结构化顺序取回" }
        return dimensions > 0 ? "已接通 · \(dimensions) 维语义检索" : "已接通 · 按相关度取回记忆"
    }

    /// 副行：没接通时给「下一步做什么」，而不是只报一个状态。
    ///
    /// ⚠️ 这里不写「请安装」这类指使句，也不夸大后果 —— 记忆检索是增强，
    /// 缺席时练习照常，把它说成故障会让用户以为应用坏了。
    public var detail: String {
        guard isEnabled else {
            return "不影响练习：记不住的旧话题会按时间顺序取回。想接通就在本地 runtime 装一个嵌入模型（如 nomic-embed-text），下次启动自动接上。"
        }
        return dimensions > 0
            ? "当前索引 \(dimensions) 维；换嵌入模型后维度会跟着变。"
            : "索引已装配，但没报维度——换一个嵌入模型可以拿到更准的相关度排序。"
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
    /// 森林舞台：把学习事件（收词 / 练完 / 攒星 / 通关）翻译成树与林间的视觉脉冲。
    /// 事件源是 `services.events` 总线（订阅凭证见 `forestSubscription`）与本类的直发点。
    public let forest = ForestStage()
    /// 森林舞台对服务层总线的订阅凭证（释放即退订）。
    private var forestSubscription: LearningEventBus.Subscription?
    /// 首次进入的欢迎待演标记（批次八 · H）：判据在 `start()` 里定（全新进度 +
    /// 配置没记过欢迎），**消费**在 MainView（地面带在场后）—— 脉冲发早了
    /// `onChange` 收不到第一拍，所以拆成「先记名、视图到场再演」两步。
    public private(set) var pendingForestWelcome = false
    /// 轻音效中心（批次六 · F）：收词「叮」/ 通关小旋律 / 点小动物一声叫。
    /// 开关默认关（`ProductConfig.soundEffects`），启动与设置页切换时同步 `enabled`。
    public let sound = SoundCueCenter()
    /// 音效对服务层总线的订阅凭证（收词 / 通关两类事件 → cue）。
    private var soundSubscription: LearningEventBus.Subscription?

    public var themeMode: ThemeMode = .day
    public var systemIsDark: Bool = false
    /// 应用内动效档位（设置页「动画效果」）。启动时从配置加载并写进
    /// `AppMotionDescriptor.appOverride`（非 View 上下文的动画链路靠它）。
    public var motionMode: MotionMode = .followSystem
    /// 字号档（#416，设置页「字号」）。根视图据此注入排版环境。
    public var typeSize: FontSizeMode = .regular
    /// 界面密度档（#416，设置页「界面密度」）。
    public var interfaceDensity: DensityMode = .regular
    /// 侧边栏展开/收起（供主界面参与宽度分配）。
    public var isSidebarExpanded = true
    /// 真实进度：来自学习数据库；首次启动为种子关卡。
    public var progress: LearnerProgress = .seed()

    public internal(set) var availableModels: [DiscoveredModel] = []
    public internal(set) var health: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    /// 服务装配中（**只覆盖本地装配**：配置 / 语音 / 健康探测）。
    ///
    /// ⚠️ 它**不再**覆盖老师的开场白：开场白是一次真实模型调用（本机冷加载实测 30～60s），
    /// 以前 `isBooting` 一直盖到它结束，于是开屏半分钟里界面既不能看也不能用。
    /// 现在开场白挪到后台（见 `openInBackground()`），首屏由本地数据秒开。
    public internal(set) var isBooting = true
    /// 开场白 / 续做仍在**后台**生成（首屏已经能练，只是老师还没开口）。
    public internal(set) var isPreparingOpening = false
    /// 老师已经开口，但人不在对话页 —— 左栏「练习」给个提示点，回到对话页即清。
    public internal(set) var teacherOpenerPending = false
    public internal(set) var bootMessage: String?
    public var modelDraft: String = ""
    public var showingSettings = false
    /// 帮助中心（#413）：全局可达 —— 除了设置页那张卡，菜单栏「帮助」里也有入口。
    ///
    /// 为什么不能只住在设置页里（2026-10-01）：它第一节写的就是「新用户最常见的一问」，
    /// 恰恰是那批人**最不知道**说明藏在设置页第一张卡里。
    public var showingHelp = false
    /// 当前有没有整块面板 / 页面盖在聊天区之上（面板一开，划词气泡就该立刻收掉）。
    ///
    /// ⚠️ S4-8：与快捷键那边（`isShortcutBlockingOverlayPresented`）**共用同一份清单**。
    /// 原先两边各写一份，各自漏项：这里漏了考试报告与全局搜索（划词气泡压在最外层 → 命中错乱），
    /// 那边漏了几张页面板卡。现在真源只有下面这两个私有清单。
    public var isContentCovered: Bool { coveringPanels || blockingOverlays }

    /// 会盖住聊天区的**页面 / 面板**：切到别的页（跟读 / 听力 / 记录…）或打开一张设置类面板。
    ///
    /// ⚠️ 新增任何 `showingXxx` 页面标记都要加进来 —— 漏一个的表现就是
    /// 「切到那一页了，划词气泡还浮在窗口最上层」。
    /// （可见性是 internal 而非 private：`isShortcutBlockingOverlayPresented` 在另一个文件里读它。）
    var coveringPanels: Bool {
        showingSettings || showingRecords || showingScenarios || showingMaterialUpload
            || showingVocabulary || showingScenarioComposer || showingCourseComposer
            || showingDictionary
            || showingProgress || showingWriting || showingReading
            || showingShadowing || showingListening || showingHelp
    }

    /// 铺满窗口的**遮罩浮层**：临时盖上去，关掉就回到原来那一页。
    ///
    /// 与 `coveringPanels` 分开的理由只有一个：**快捷键切页**时，
    /// 「已经在别的页上」不该被拦（切页键本来就是干这个的），
    /// 而盖着遮罩时按 ⌘3 只会让面板关掉后「我怎么在另一个页面」。
    var blockingOverlays: Bool {
        showingSettings || showingScenarios || showingMaterialUpload || showingScenarioComposer
            || showingCourseComposer
            || showingGlobalSearch || examReport != nil
    }
    // MARK: 模型 Provider（本地 + 云端并存）
    /// 当前生效的 LLM Provider（决定实际调用本地还是云端）。
    public internal(set) var activeProvider: ProviderConfig?
    /// 设置页当前选中的 Provider 标签（可编辑未生效的 Provider）。
    public var selectedProviderID: String = "ollama.llm"
    /// 云端 API Key 草稿（按 provider id 存，避免切换标签互相覆盖）。
    public var apiKeyDrafts: [String: String] = [:]
    /// 云端推理强度草稿（low / medium / high；nil = 标准）。
    public var reasoningEffortDraft: String?
    /// 云端配置操作结果（成功提示或错误）。
    public var remoteMessage: String?
    /// 上下文窗口（token），nil = 未知。
    public internal(set) var contextLimit: Int?
    /// 生效模型的推理强度（low / medium / high；nil = 标准）。
    public internal(set) var activeReasoningEffort: String?
    /// 今日全局 token 用量（侧边栏黑板 / 督促气泡判定）。
    public internal(set) var todayTokens: Int = 0
    // MARK: 语音（第 17/18 步）
    /// 聊天区语音输入的阶段 —— **唯一真相**（2026-09-27 报障修复）。
    ///
    /// ⚠️ 曾经用两个布尔 `isRecording` / `isTranscribing` 各自维护，结果是
    /// 「识别中」这个状态**从没被置上过**：`finishVoiceInput` 在
    /// `stopRecordingAndTranscribe` 返回**之后**才读 `services.voice.isTranscribing`，
    /// 而那个方法内部 `defer` 已经把标志复原了，于是恒读到 false。
    /// 后果分两层：①识别期间界面没有任何「正在识别」的迹象，用户以为刚才那次点击
    /// 没生效，于是再点一次；②此刻录音其实已经停了，第二次点击落进「开始录音」分支
    /// ——麦克风被重新打开、前一段的识别结果被丢掉，用户看到的就是
    /// 「按键没反应 / 想停停不掉 / 想取消取消不了」。改成单一阶段值之后，
    /// 「同一时刻只能是三者之一」由类型保证，`primaryAction` 也逼着每个使用点
    /// 把「识别中点一下该干什么」想清楚（那一格以前是缺的）。
    public internal(set) var voicePhase: VoiceInputPhase = .idle
    /// 本段语音输入的令牌：取消 / 重开时换值，在途的识别回来即作废（不回填输入框）。
    public internal(set) var voiceInputToken = UUID()
    /// 是否正在录音（由 `voicePhase` 派生；跟读 / 词汇复习各自有独立的录音状态）。
    public var isRecording: Bool { voicePhase == .recording }
    /// 是否正在把这段录音送去识别（同上，派生态）。
    public var isTranscribing: Bool { voicePhase == .transcribing }
    /// 是否正在朗读教师回复。
    public internal(set) var isSpeaking = false
    /// 朗读请求的世代令牌（S4-12）。
    ///
    /// 底层 `VoiceService.speak` 早就有自己的 `speakToken`（作废在途合成 + 停声），
    /// 所以「前一条还在队列里念」这件事已经不会发生。这里补的是**界面侧**的同一道闸门：
    /// 收尾那几行是 await 之后回写 `speechPhase` / `voiceError` 的**快照**，
    /// 连点两条「听老师读」时，前一条可能在后一条已经开始之后才跑完 ——
    /// 它会把过期快照盖上去（界面显示「还在念」，其实早停了）。
    var speakRequestToken: UUID?
    /// 朗读相位：准备中（已点中、正在合成首句）/ 朗读中（已有声音）。
    public internal(set) var speechPhase: SpeechPhase = .idle {
        didSet { lookupBubble.refreshSpeaking() }
    }
    /// 正在准备的朗读原文：让对应消息的按钮立刻显示「准备中」。
    public internal(set) var speakingText: String? {
        didSet { lookupBubble.refreshSpeaking() }
    }
    /// 教师回复完成后自动朗读（设置里可关）。
    public var autoSpeak = false
    /// 当前教师音色（runtime 自报的候选 + 配置值兜底）。
    public internal(set) var availableVoices: [String] = ["Serena", "Vivian", "Ryan", "Aiden", "Eric"]
    /// 本地语音 runtime 自报描述（如「Qwen3-TTS 0.6B · mps」），nil = 未知。
    public internal(set) var ttsRuntimeInfo: String?
    /// 当前朗读投递方式：云端整段合成、本地分句流水线（随语音装配刷新）。
    public internal(set) var speechDelivery: SpeechDelivery = .segmented
    /// 最近语音错误（nil = 正常）。
    public internal(set) var voiceError: String?

    // MARK: - 克隆音色（第 24 步）

    /// 全部音色档案（内置 + 克隆）。
    public internal(set) var voiceProfiles: [VoiceProfile] = []
    /// 当前 TTS 供应商是否支持音色克隆（不支持时 UI 直接说明，而不是让用户配完才发现不行）。
    public internal(set) var voiceCloningSupported = false
    /// 当前 TTS 供应商声明的语音能力（克隆 / 风格 / 情感 / 原生音高），随语音装配刷新。
    ///
    /// 与 `voiceCloningSupported` 的关系：后者就是它的 `voiceCloning` 一位 ——
    /// 保留旧名字是因为设置页的克隆卡片一直读它；两者由同一次刷新一起写，不会各说各话。
    public internal(set) var voiceCapabilities = ProviderCapabilities()
    /// 当前供应商给出的朗读语气候选值（风格 / 情感）。**空 = 不支持**，设置页据此不渲染入口：
    /// 宁可没有入口，也不给一个点了没反应的假入口。
    public internal(set) var speechToneOptions: [VoiceCapability: [String]] = [:]
    /// 克隆音色操作的结果提示（成功 / 失败，可关闭）。
    public internal(set) var voiceProfileNotice: String?
    /// 正在试听 / 启用的克隆音色 id（按钮转圈用）。
    public internal(set) var busyVoiceProfileID: String?

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
    public internal(set) var spellingNote: String = ""
    /// 历史坏配置的修复提示（「本地模型名被写进云端供应商」被就地清掉时出现）。
    public internal(set) var modelHealNotice: String?
    /// 坏配置修复只在本次运行做一次（幂等，修完配置里就没有坏值了）。
    var didHealCrossProviderModels = false
    /// 语音服务健康状态。
    public internal(set) var asrHealth: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    public internal(set) var ttsHealth: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    /// 发音评测声学通道状态。`configurationInvalid` 不代表坏了——没有云端发音评测时
    /// 评测走规则推断，这一项只是用来如实说明「这次是实测还是推断」。
    public internal(set) var pronunciationHealth: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    // MARK: 模型管理中心（本地检测 ~/AI_Models + 外部模型统一入口）
    /// 每个能力的模型信息（当前模型/来源/本地检测列表）。
    public internal(set) var capabilityInfos: [AIProviderKind: CapabilityModelInfo] = [:]
    /// 各能力**当前生效**的 Provider id / 模型名（覆盖**全部**能力，含 `llm`）。
    ///
    /// ⚠️ 不能拿 `capabilityInfos` 代替：它只覆盖 asr / tts / vad / embedding / pronunciation
    /// 五项，「AI 大脑」不在其中。外部模型面板曾经按它判断「谁是当前生效的供应商」，
    /// 于是 llm 这条路上永远查不到 —— 表现为绿点不亮、面板不定位当前供应商、
    /// 选好的模型跳回默认（2026-09-14 反馈的第三组问题）。
    /// 这里存的是**生效结果**（`resolvedProvider` / `resolvedModel`），不是草稿、不是意图。
    public internal(set) var activeProviderIDs: [AIProviderKind: String] = [:]
    public internal(set) var activeModels: [AIProviderKind: String] = [:]
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
    public internal(set) var externalKeyFingerprints: [String: String] = [:]
    /// 本次运行里被用户**主动清空**输入框的供应商。
    ///
    /// 用户清空输入框 = 明确表示「这个供应商不配置」。重开设置时不得再从配置里把旧 Key
    /// 回填回来——否则「空框」总是被旧密钥复活，用户永远清不掉它。
    var clearedKeyDrafts: Set<String> = []
    /// 外部模型探测结果（providerID -> models）。
    public internal(set) var externalModels: [String: [DiscoveredModel]] = [:]
    /// 每个能力当前展开的外部 Provider 标签。
    public var externalSelectedProvider: [String: String] = [:]
    /// 外部 Provider 候选缓存（kind -> options，设置页打开时拉一次）。
    public var externalProviderCache: [String: [(id: String, name: String)]] = [:]
    /// 免密钥供应商集合（配置 `api_key_required = false`）：设置页对它们隐藏 Key 输入框。
    public internal(set) var keylessProviders: Set<String> = []
    public internal(set) var isFetchingExternal = false
    /// 外部模型操作结果消息（providerID -> message）。
    public var externalMessages: [String: String] = [:]
    /// 最近一次**认证通过**的 Key（providerID -> 清洗后的 Key）。
    ///
    /// 「确认配置」必须建立在真实认证之上：只有刚才用同一把 Key 验证成功过才免二次探测，
    /// 否则应用前先打一次真实验证——失败就整路失败，卡片维持原样（2026-09-14 反馈）。
    public internal(set) var externalVerifiedKeys: [String: String] = [:]
    /// 手动填写模型名草稿（kind -> name）。
    public var customModelDrafts: [String: String] = [:]
    // MARK: 云端调用审计（费用护栏留痕）
    /// 本次运行的对外调用汇总（计费 / 探测 / 拦截 + 涉及模型 + 异常扇出预警）。
    ///
    /// 存在的意义只有一个：让「应用到底调了哪几个模型」变成可核对的事实，
    /// 而不是等账单出来才发现不对。云端调用一条都不例外地记在这里。
    public internal(set) var remoteCallSummary: RemoteCallSummary = RemoteCallSummary()
    /// 最近若干条对外调用记录（新的在前，只含元数据，不含任何请求正文）。
    public internal(set) var remoteCallRecords: [RemoteCallRecord] = []
    /// 中栏切换：学习记录页（false = 练习对话）。
    public var showingRecords = false
    // MARK: 写作练习（#230）
    /// 中栏切换：写作页。
    public var showingWriting = false
    /// 今天的写作题（`WritingTopicPicker` 恒定一天一题；进页时取一次）。
    public internal(set) var writingTopic: WritingTopic?
    /// 写作草稿。
    public var writingDraft = ""
    /// 最近一次批改结果（nil = 还没交过 / 批改失败）。
    public internal(set) var writingReview: WritingReview?
    /// 交出去批改的那一版正文（S4-10）。
    ///
    /// ⚠️ 改写对比卡必须拿**这一份**跟 `review.rewrite` 比，不能用 `writingDraft`：
    /// 草稿是活的，用户不收卡直接改稿时，diff 会实时跟着变 ——
    /// 他自己刚改的词会被标成「老师改的」，而老师根本没动过那一处。
    public internal(set) var writingSubmittedEssay = ""
    /// 正在批改（按钮 loading）。
    public internal(set) var isWritingReviewing = false
    /// 写作页的提示消息（词数不足 / 批改失败 / 已加入词汇本）。
    public var writingNotice = ""

    // MARK: 阅读理解（#231 / #233）
    /// 中栏切换：阅读页。
    public var showingReading = false
    /// 今天已生成的短文（旧 → 新，含作答进度；**落学习库，重启不丢**）。
    ///
    /// 每天生成一次后固定展示：进页先取库里的，不再自动重新出题；
    /// 只有「换一篇」才追加一篇。回看靠 `readingEntryIndex` 切换。
    public internal(set) var readingEntries: [StoredReading] = []
    /// 当前展示第几篇（`readingEntries` 下标）。
    public internal(set) var readingEntryIndex: Int = 0
    /// 正在生成短文（首篇或「换一篇」）。
    public internal(set) var isReadingLoading = false
    /// 已交卷（交卷后锁定选项、标对错、展开解析）——指**当前展示**的这篇。
    public internal(set) var isReadingReviewed = false
    /// 每题的选择：题目下标 → 选项下标（当前展示的这篇）。
    public internal(set) var readingChoices: [Int: Int] = [:]
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
    public internal(set) var scenarios: [Scenario] = []
    /// 是否已尝试加载过场景（用于区分「加载中」与「确实为空」）。
    public internal(set) var didLoadScenarios = false
    // MARK: 上传材料自动出题（#208）
    /// 已生成的材料（材料 → 情景 + 跟读句 + 生词表），按生成时间倒序。
    public internal(set) var materialKits: [MaterialKit] = []
    /// 「上传材料」浮层开关。
    public var showingMaterialUpload = false
    /// 材料输入草稿（粘贴或导入的文字）。
    public var materialDraft = ""
    /// 是否正在生成（按钮 loading；一次生成 = 一次模型请求）。
    public internal(set) var isGeneratingMaterial = false
    /// 生成结果回执（成功 / 失败都给，UI 展示后由 `dismissMaterialResult` 清掉）。
    public var materialResult: String?
    /// 最近一次生成成功的材料（浮层里展示「拆出了什么」）。
    public internal(set) var lastGeneratedKit: MaterialKit?
    // MARK: 一句话生成情景（⑦）
    /// 已生成的自建情景草稿（按生成时间倒序）。
    ///
    /// ⚠️ 与下面的 `scenarioPromptText` 差一个 s：那个是**输入框里的那句描述**，
    /// 这个是**已经生成好的成品列表**。命名上刻意区分，免得两处状态互相覆盖。
    public internal(set) var customScenarioDrafts: [ScenarioDraft] = []
    /// 「描述场景」浮层开关。
    public var showingScenarioComposer = false
    /// 一句话描述草稿（输入框内容）。
    public var scenarioPromptText = ""
    /// 是否正在生成（按钮 loading；一次生成 = 一次模型请求）。
    public internal(set) var isGeneratingScenario = false
    /// 生成结果回执（成功 / 失败都给，UI 展示后由 `dismissScenarioResult` 清掉）。
    public var scenarioResult: String?
    /// 最近一次生成成功的情景（浮层里展示「生成了什么」）。
    public internal(set) var lastGeneratedScenarioDraft: ScenarioDraft?
    // MARK: AI 自动课程（③）
    /// 已排好的 AI 课程（按排课时间倒序；课内情景已并进 `scenarios`）。
    public internal(set) var courses: [CourseBlueprint] = []
    /// 「排一条课」浮层开关。
    public var showingCourseComposer = false
    /// 自填主题草稿（输入框内容；顿号 / 逗号 / 分号 / 换行都算分隔）。
    ///
    /// ⚠️ 与 `scenarioPromptText` 一样**不落盘**：它是一次性的表单字段，不是学习数据。
    /// 存进配置的话，「上次写的主题」会在几个月后突然参与排课，而用户早忘了那是自己写的。
    public var courseTopicDraft = ""
    /// 是否正在排课（按钮 loading；一次排课 = 一次模型请求）。
    public internal(set) var isGeneratingCourse = false
    /// 是否正在**续**排（与排课是两件事，两个按钮各自 loading）。
    public internal(set) var isContinuingCourse = false
    /// 排课结果回执（成功 / 失败都给，UI 展示后由 `dismissCourseResult` 清掉）。
    public var courseResult: String?
    /// 最近一次排好的课（浮层里展示「排出了什么」）。
    public internal(set) var lastGeneratedCourse: CourseBlueprint?
    /// 学习记录数据（进入页面时加载）。
    public internal(set) var records: [SessionSummary] = []
    public internal(set) var mistakes: [GrammarCorrection] = []
    /// 练习复盘：最新一份（本次会话或最近一次）。nil = 还没生成过。
    public internal(set) var latestReview: SessionReview?
    /// 历史复盘（学习记录页可回看）。
    public internal(set) var reviews: [SessionReview] = []
    /// 会话 id → 复盘（记录页展开某条练习记录时用；`loadRecords` 一次取够）。
    ///
    /// ⚠️ 不复用 `reviews` 的 10 条上限：记录页列了 20 条练习，
    /// 用 10 条去索引会出现「第 11 条明明有复盘却显示没有」。
    public internal(set) var reviewIndex: [UUID: SessionReview] = [:]
    /// 跨会话学习记忆（第 15 步）：老师记住了什么，学员也该看得见。
    public internal(set) var learningMemory: LearningMemory = .empty
    /// 清除记忆后的结果/失败提示（清除不可逆，做完必须给回执）。
    public var learningMemoryNotice: String?
    /// 改错练习：当前这一轮（nil = 没在练）。
    ///
    /// 队列 / 判定 / 结算全在 `AIDomain.ErrorDrillSession`（纯函数），这里只持有它 ——
    /// 与 `vocabularyReview` 同一套路。
    public internal(set) var errorDrill: ErrorDrillSession?
    /// 刚判的那一处（非 nil = 正停在「改对了 / 正确答案是……」这句回执上，
    /// 要用户点「下一处」才清空）。**判分与推进分成两步**是刻意的：
    /// 交完答案立刻跳到下一题，等于没告诉他错在哪。
    public internal(set) var errorDrillLastOutcome: ErrorDrillSession.Outcome?
    /// 这一轮走完后的结算（走完才挂上）。
    public internal(set) var errorDrillSummary: ErrorDrillSession.Summary?
    /// 每处错的**连对次数**（跨轮账本：这轮对一次、下轮再对一次才算攻克）。
    ///
    /// ⚠️ 刻意不给默认值（与 `dailyRecognitions` 同一条纪律）：这是跨启动恢复的
    /// 持久化状态，由手写 `init(services:)` 从 UserDefaults 加载。给了 `= [:]`
    /// 就等于允许「哪天加载那行被删掉、练过的记录全没了」这种静默退化。
    var errorDrillStreaks: [String: Int]
    /// 是否正在生成复盘（按钮 loading）。
    public internal(set) var isGeneratingReview = false
    /// 数据目录缓存快照（设置页「缓存管理」卡片）。
    public internal(set) var cacheSnapshot: CacheSnapshot = .empty
    /// 上一次清理释放的字节数（展示用，0 = 无）。
    public internal(set) var cacheFreedBytes: Int64 = 0
    /// 隐私状况（设置页「隐私与安全」卡片）：有无外发、发往哪里、本地数据在哪。
    public internal(set) var privacyReport: PrivacyReport = .empty
    /// 配置文件（`config.json`）的绝对路径。设置页「运行环境」展示 + 在 Finder 中打开。
    public internal(set) var configLocationPath = ""
    /// 内置默认配置载入失败的原因（nil = 正常）。
    ///
    /// ⚠️ 载入失败时应用会以「零 provider」启动，界面上就是「一个模型都没有」。
    /// 以前这件事完全无声，用户只能靠猜；现在把它摆到设置页最上面。
    public internal(set) var configLoadFailure: String?
    /// 「重新载入配置」的结果回执（nil = 不显示）。
    public internal(set) var configReloadNotice: String?
    /// 配置体检：每个能力「该由谁生效、生不生效得了」。
    public internal(set) var registryCheckRows: [RegistryCheckRow] = []
    /// 记忆索引的健康态（比「装配过没有」更进一步：能看出服务后来是不是关了）。
    public internal(set) var embeddingHealth: ProviderHealth = .configurationInvalid(reason: "尚未检查")
    /// 语义记忆索引「通没通 + 多少维」（设置页「运行环境」卡；刷新见 `refreshSemanticMemory`）。
    public internal(set) var semanticMemoryStatus = SemanticMemoryStatus.unknown
    /// 本地模型测速进行中（按钮 loading，同时挡住重复点击）。
    public internal(set) var isRunningBenchmark = false
    /// 最近一次本地测速的结果（nil = 还没测过 / 这次没采到样本）。
    public internal(set) var benchmarkSnapshot: BenchmarkSnapshot?
    /// 最近一次测速失败的原因（nil = 没失败过）。**必须显示出来**：
    /// 静默失败会让用户以为「测过了、就是这个速度」。
    public internal(set) var benchmarkError: String?
    /// 本机可用内存（设置页「运行环境」；取不到时为空串）。
    public internal(set) var availableMemoryText = ""
    /// 关卡 → 情景 绑定（来自资源文件；随情景一起加载）。
    var levelBindings: [String: String] = [:]

    /// 已导出的备份（设置页「存储与缓存」卡片），新的在前。
    public internal(set) var backupSnapshots: [BackupRecord] = []
    /// 备份导出中的标记（按钮 loading）。
    public internal(set) var isExportingBackup = false
    /// 最近一次导出失败的原因（nil = 没失败过）。
    public internal(set) var backupError: String?
    /// 自动备份（#415）自己没做成时的提示（nil = 一切正常）。
    ///
    /// 与 `backupError` 分开：前者是用户点了「导出备份」的回执，界面当场看得见；
    /// 自动备份在后台跑，失败不出声就等于「一直在备份、其实早停了」。
    public internal(set) var autoBackupNotice: AppNotice?
    /// 学习库被隔离重建时的说明（nil = 一切正常）——**必须让用户看见**。
    public internal(set) var databaseRecoveryNote: String?
    /// 学习记录「存不住」的提示（nil = 一切正常）。**常驻横幅，不自动消失**。
    ///
    /// ⚠️ 为什么必须有这一条：学习库打不开时应用**照常能聊**，「存不住」这件事
    /// 没有任何天然症状 —— 用户练一整天，退出重进才发现历史是空的，还以为自己记错了。
    /// 静默丢数据比崩溃更糟：崩溃有声音，这个没有。
    public internal(set) var persistenceNotice: AppNotice?
    /// 备份导入：已通过校验、等用户确认的恢复计划（nil = 没在导入流程中）。
    public internal(set) var backupImportPlan: BackupImportPlan?
    /// 备份导入：选中的压缩包路径（确认后交给 stageRestore）。
    var backupImportPath: String?
    /// 备份导入：确认后「已安排恢复，重启生效」的回执（nil = 不显示）。
    public internal(set) var backupImportNotice: String?
    /// 启动时应用的备份恢复说明（nil = 本次启动没有恢复动作）。
    public internal(set) var restoreNote: String?
    /// 备份目录总占用（展示用；nil = 还没查过）。
    public internal(set) var backupTotalText: String?
    /// 学习记录导出中（按钮 loading）。
    public internal(set) var isExportingRecords = false
    /// 学习记录导出的回执或失败原因（nil = 没导出过）。
    ///
    /// 为什么必须给回执：NSSavePanel 选完目录后文件落在用户选的地方，
    /// 界面不说「导到哪儿了」，用户就要去 Finder 里翻。
    public internal(set) var recordsExportNotice: String?
    /// 情景结算奖励提示（nil = 不显示）。UI 展示数秒后自动消失。
    public internal(set) var lastReward: ScenarioReward?
    /// 最近一次情景练习的 CEFR 覆盖度判定（nil = 不显示）。
    ///
    /// 与 `lastReward` **分开**：奖励说的是「拿了几颗星」（参与度），
    /// 这里说的是「这一关的目标句真的说到了几句」（内容覆盖），
    /// 两者可能不一致 —— 比如说满轮次但全是短句，星星拿满、目标句一句没说。
    /// 混成一条提示就会逼着其中一件事说谎。
    public internal(set) var lastAssessment: CurriculumAssessment?
    /// 产生 `lastAssessment` 的是哪个情景 —— 判定卡上要写清这是哪一关的判定，
    /// 而这时情景通常已经结束了（`activeScenario` 已清空），只能自己记一份。
    public internal(set) var lastAssessedScenarioID: String?

    // MARK: 主线任务 / 前情提要（需求 3–6）
    /// 各情景的主线任务进度（情景卡片、大树节点一次读库后缓存）。
    public internal(set) var questRecords: [String: ScenarioQuestRecord] = [:]
    /// 当前任务的前情提要（情景模式下的引导卡片）。
    public internal(set) var briefing: ScenarioBriefing?
    /// 展开的情景卡片 id（点击卡片展开主线任务与教学重点，再点收起）。
    /// **展开不等于进练习**：进练习要点卡片里的「开始任务」（需求 3）。
    public var expandedScenarioID: String?
    /// 上一段练习自动复盘的结果提示（nil = 不显示）。
    ///
    /// ⚠️ 是 `AppNotice`（文案 + 动作绑成一个值）而不是裸 `String?`：
    /// 「上一段练习已自动复盘」这条**必须**带一个「去看复盘」，
    /// 文案与动作拆成两个属性就一定会出现「这条只是告知，却挂着上一条留下的跳转」。
    public var practiceNotice: AppNotice?

    /// 关闭「自动复盘」回执提示。
    public func dismissPracticeNotice() { practiceNotice = nil }

    /// 「开启新练习」正在跑（S4-4）。
    ///
    /// 这一段要先自动复盘上一段、再换会话、再让老师开口，中间有好几个 await；
    /// 没有这个闸门时双击 = 复盘两遍 + 会话 id 连跳两级 + 开场白出两条（或被静默吞掉）。
    /// UI 侧据此把按钮置灰，AppState 侧再挡一道（按钮状态可能比状态机慢一帧）。
    public internal(set) var isStartingFreeTalk = false

    // MARK: 考试模式（雅思口语 / 面试问答）

    /// 内置考卷（资源文件；空 = 资源缺失，面板给可操作提示）。
    public internal(set) var examBlueprints: [ExamBlueprint] = []
    /// 是否已尝试加载过考卷（区分「加载中」与「确实为空」）。
    public internal(set) var didLoadExamBlueprints = false
    /// 进行中的考试（nil = 没在考）。纯值类型，可单测。
    public internal(set) var examRunner: ExamRunner?
    /// 考后报告（非 nil = 结算卡可见）。
    public internal(set) var examReport: ExamReport?
    /// 示范答案（题号 → 回答），考后一次请求拿回来。
    public internal(set) var examSampleAnswers: [Int: String] = [:]
    /// 示范答案没拿到时的说明（nil = 正常）。
    public internal(set) var examSampleNotice: String?
    /// 正在写示范答案（卡片上转圈）。
    public internal(set) var isGeneratingExamSamples = false
    /// 本次该给哪几问写示范答案（结算卡据此显示题面 + 转圈，重试也用它 ——
    /// 重算会随作答变化而漂，同一份报告不该长出不同的示范题）。
    public internal(set) var examSampleTargets: [ExamSampleTarget] = []
    var examSampleTask: Task<Void, Never>?

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
    public internal(set) var modelRunStates: [AIProviderKind: Bool] = [:]
    /// 正在切换启停的能力（按钮 loading）。
    public internal(set) var modelSwitching: Set<AIProviderKind> = []
    /// 启停结果弹框（应用顶部向下弹入，数秒后向上收起）。nil = 不显示。
    public internal(set) var modelToast: ModelToast?
    /// 待用户确认的本机服务启停命令（#S2-6）。非 nil 时设置页弹确认框。
    ///
    /// 为什么要有它：配置文件里的 `serviceStartCommand` 会被 `/bin/sh -lc` 执行，
    /// 而配置文件**能被备份包覆盖**。用户点「启动」时若不先看见命令原文就执行，
    /// 等于把「导入备份 → 重启 → 点一下启动 → 任意命令执行」这条链走完了。
    public internal(set) var pendingShellApproval: ShellApprovalRequest?
    /// 输入框的预设学员提问（数据来自资源文件；为空则退回普通占位文案）。
    public internal(set) var starterQuestions: [String] = []
    /// 开屏话题卡（今天聊什么）。**纯派生、不落盘**：每次刷新重算，
    /// 记在字段上的唯一理由是 UI 要订阅它。
    ///
    /// 派生而不是存残骸：依据是「上次练到哪 / 今天有什么词」，这两件事每时每刻都在变，
    /// 存一份必然会出现「情景早就练完了，卡片还在催」。
    public internal(set) var kickoffSuggestions: [KickoffSuggestion] = []

    // MARK: 碎片热身（⑦-B②）

    /// 这一轮热身**能做哪几步**（纯派生：到期词 + 一句跟读 + 一句开口）。
    /// 一步都排不出来时为 nil —— 那时入口整块不画，不留一张点不动的空壳。
    public internal(set) var warmUpPlan: WarmUpPlan? = nil
    /// 正在跑 / 已跑完的那一轮。nil = 没在跑（画入口卡）。
    ///
    /// ⚠️ 结算也住在这里（走完但没关掉）：`finishedAt` 一钉住，结算上的
    /// 「用时」就不再往后长。
    public internal(set) var warmUp: WarmUpProgress? = nil
    /// 热身卡自己的提示（麦克风打不开 / 没听清这类）。文案与动作绑成一个值。
    public internal(set) var warmUpNotice: AppNotice? = nil
    /// 这一步刚读出来的发音分（按「继续」之前先摆出来给人看一眼）。
    public internal(set) var warmUpStepScore: Double? = nil
    /// 这一步听到的原话。
    public internal(set) var warmUpHeardText: String? = nil
    public internal(set) var isWarmUpRecording = false
    /// 识别 / 评分在跑（这段窗口里不许重开麦克风）。
    public internal(set) var isWarmUpBusy = false

    /// 翻译失败提示（对话区展示，可关闭）。
    public var translationNotice: String? { chat.translationError }

    // MARK: 聊天附件（第 3 项需求：图片 / 视频 / 文件）

    /// 已选好、还没发出去的附件（输入框上方那一行胶囊）。
    ///
    /// 放在「待发」区而不是「选了就发」：学员常常一次选两三张图再配一句话，
    /// 中途还想删掉其中一张 —— 选完即发会逼他重来一遍。
    public internal(set) var pendingAttachments: [ChatAttachment] = []
    /// 附件相关的提示（超限 / 导入失败，可关闭）。
    public internal(set) var attachmentNotice: String?
    /// 正在导入附件（选大文件时给个转圈）。
    public internal(set) var isImportingAttachments = false
    /// 最近一次「保存附件」的结果提示（成功/失败都说一声，静默失败最容易被当成已保存）。
    public internal(set) var attachmentSaveNotice: String?
    /// 当前生效的 LLM 能不能**真的读图**（false = 图片只会以文件名告诉老师）。
    ///
    /// 来源是 `ProviderCapabilities.vision`（适配器按配置声明自报）。
    /// 以前这个能力位只有产出方没有消费方，于是「不读图的模型收到图」是静默降级的。
    public internal(set) var llmSupportsVision = true
    /// 「已保存」回执的自动收起计划（`dismissReward` 同款做法）。
    var attachmentSaveNoticeTask: Task<Void, Never>?

    // MARK: - 跟读（第 22 步 Shadowing）

    /// 是否停在跟读页（占中间栏，与学习记录页同级）。
    public var showingShadowing = false
    /// 跟读素材（进页面时按需加载；资源缺失则保持空并由 UI 提示）。
    public internal(set) var shadowingDrills: [ShadowingDrill] = []
    /// 当前练到第几句（在 `shadowingDrills` 中的下标）。
    public internal(set) var shadowingIndex = 0
    /// 最近一次评测结果（nil = 这一句还没评过）。
    public internal(set) var shadowingComparison: ShadowingComparison?
    /// 最近一次发音评测（第 23 步；nil = 没录到音频 / 还没评）。
    public internal(set) var shadowingPronunciation: PronunciationReport?
    /// **每一句的最近一次分析**（键 = `dayKey#drillID`，见 `shadowingAnalysisKey`）。
    ///
    /// 存在的理由：分析结果以前只保留「当前这一句」一份，换句即清 ——
    /// 于是「回头看看上一句刚才读得怎么样」必须**重新读一遍**才有结果。
    /// 现在按句缓存，切页 / 跳句 / 重启回来都还在（重启那条靠 `rehydrateShadowingAnalyses()` 从库里补）。
    ///
    /// ⚠️ 键必须带 `dayKey`：跟读素材**每天换一批**，而生成出来的 id 是
    /// `daily-<主题序>-<句序>` —— 跨天会重号但句子不同，不带 dayKey 就会把
    /// 昨天的「第 0 句」分析挂到今天的第 0 句上。
    public internal(set) var shadowingAnalyses: [String: ShadowingResult] = [:]
    /// 跟读汇总（次数 / 最佳 / 平均 / 最近）。
    public internal(set) var shadowingStats: ShadowingStats = .empty
    /// 「最近几次 vs 之前几次」的发音对比（样本不够时为 nil —— 不下假结论）。
    ///
    /// ⚠️ 它是**查库**算出来的（`recentAttempts`），不是快照的派生，
    /// 所以只能由 `refreshPronunciationComparison()` 写 —— 派生属性里查库是不允许的。
    public internal(set) var pronunciationComparison: PronunciationComparison?
    /// 正在跟读录音。
    public internal(set) var isShadowingRecording = false
    /// 跟读链路上的忙碌态（播放示范 / 识别中 / 回放中）。
    public internal(set) var isShadowingBusy = false
    /// **正在放声音**（示范 / 回放）。
    ///
    /// 与 `isShadowingBusy` 分开：忙碌态还覆盖「识别 + 评分」那段窗口，
    /// 那里给「停止」按钮是错的（停的是声音，不是评分）。按钮据此在
    /// 「听示范」与「停止」之间切换。
    public internal(set) var isShadowingPlaying = false
    /// 跟读提示（可关闭，nil = 正常）。
    public internal(set) var shadowingNotice: String?

    /// 正在生成今天的 20 句（页面上转圈，避免用户以为「卡住了」）。
    public internal(set) var isShadowingLoading = false
    /// 取今日素材的**并发闸门**（S4-6）。
    ///
    /// 与 `isShadowingLoading` 分开：那个是**界面忙碌态**（骨架屏 / 「生成中…」），
    /// 只在真正生成那一段亮；而本闸门从函数入口就亮 ——
    /// 因为取数路径开头有一串 await（读当天缓存 / 读内置素材），
    /// 两次双击各起一个 Task 时它们都会在那串 await **之前**挤进来，
    /// 只看 `isShadowingLoading` 拦不住 → 发两次真实模型请求（多付一份 token）。
    var isGeneratingShadowingDrills = false
    /// 页面上这批句子是不是**今天现生成**的（false = 内置素材兜底）。
    /// 页头据此如实说明来源 —— 用户有权知道自己在练的是哪种素材。
    public internal(set) var shadowingIsDailyGenerated = false

    // MARK: 顽固音素专项（进阶 ③）

    /// 跨次聚合出来的「老发错的音」（按该练的先后排好；空 = 数据还不够下判断）。
    ///
    /// ⚠️ 空有两种含义（样本不足 / 一个都没错），UI 只在**非空**时显示这一块 ——
    /// 没数据时挂一张空卡，等于凭空多一个让人困惑的区块。
    public internal(set) var phonemeWeaknesses: [PhonemeWeakness] = []
    /// 当前这批跟读素材是不是**音素专项**（true = 替换掉了今日 / 内置素材）。
    ///
    /// 与 `shadowingIsDailyGenerated` 是两件事：专项素材既不是今天的、也不是内置的，
    /// 所以页头的来源说明必须另说一句，否则用户会以为「今天的句子怎么变了」。
    public internal(set) var isPhonemeDrill = false
    /// 专项在练哪个音（nil = 不在专项里）。
    public internal(set) var phonemeDrillFocus: String?

    // MARK: 听力（#308 #309：独立成页，三种形式）

    /// 中栏切换：听力页。
    ///
    /// ⚠️ 与 `showingShadowing` 那一族一样由 `applySection` **一次写齐** ——
    /// 别在 `openListening()` 里手写一串复位，漏一个就是两个条目同时高亮。
    public var showingListening = false

    /// 听力页当前练的是哪种形式（精听默写 / 关键词捕捉 / 听句选义）。
    ///
    /// 刻意**不落盘**：它只是「这回想怎么练」的临时选择，不是用户数据。
    /// 落盘就得在 `init(services:)` 里补一行加载，而那一行漏掉编译器一声不响
    /// （同 `listeningLog` 的注释）—— 为这点小便利去挂那个风险不划算。
    public internal(set) var listeningMode: ListeningMode = .dictation

    /// 是否正处在一轮听力里（true = 听力页的正文换成练习卡）。
    ///
    /// 一轮的句子在**开轮时定下**，中途不随素材变动：练到第 5 句时素材被换掉
    /// （跟读页点「换一批」/ 进音素专项），存着的这一轮还能善终 ——
    /// 现算的话第 5 句会突然变成另一句。
    public internal(set) var isListeningDrill = false
    /// 这一轮要练的句子（开轮时定下）。
    public internal(set) var listeningRound: [ShadowingDrill] = []
    /// 轮到第几句。
    public internal(set) var listeningIndex = 0
    /// 学员正在写的那句（精听：整句；关键词：那些词。提交后清空）。
    public var listeningDraft = ""
    /// 刚提交的对照结果（nil = 还没交；非 nil = 停在这一句的回执上）。
    public internal(set) var listeningResult: ListeningAttempt?
    /// 这一轮已交的听写。
    public internal(set) var listeningAttempts: [ListeningAttempt] = []
    /// 这一句已经听了几遍（提交后归零）。**三种形式共用** —— 播放链路是同一条。
    public internal(set) var listeningPlayCount = 0
    /// 慢速播放开关（下一次播放生效）。
    public internal(set) var listeningSlowPlayback = false
    /// 正在放声音。
    public internal(set) var listeningIsPlaying = false
    /// 这一轮的结算（走完才挂上）。
    public internal(set) var listeningSummary: ListeningSummary?
    /// 听力的提示（可关闭）。
    public internal(set) var listeningNotice: String?
    /// 当天账本（句 id → 最佳准确率）。
    ///
    /// ⚠️ 刻意不给默认值（与 `errorDrillStreaks` 同一条纪律）：这是跨启动恢复的
    /// 持久化状态，由手写 `init(services:)` 从 UserDefaults 加载。给了 `= .empty`
    /// 就等于允许「哪天加载那行被删掉、今天写对的句子全没了」这种静默退化。
    var listeningLog: ListeningLog

    // MARK: 听力 · 关键词捕捉（#309）

    /// 学员正在写的那些词（提交后清空）。
    public var listeningKeywordDraft = ""
    /// 刚提交的对照（nil = 还没交）。
    public internal(set) var listeningKeywordResult: KeywordCapture?
    /// 这一轮已提交的关键词对照。
    public internal(set) var listeningKeywordAttempts: [KeywordCapture] = []

    // MARK: 听力 · 听句选义（#309）

    /// 当前这一句的题（nil = 这一句出不了题，或已经答完在等「下一句」）。
    public internal(set) var listeningMeaningQuestion: MeaningQuestion?
    /// 学员选了几（nil = 还没选）。⚠️ 点下去**即判**，所以它同时是「已答」的标记 ——
    /// 不需要再立一个布尔量，两个状态并存迟早会不一致。
    public internal(set) var listeningMeaningSelection: Int?
    /// 这一轮每句的对错（按作答顺序）。
    public internal(set) var listeningMeaningCorrect: [Bool] = []
    /// 这一轮每句答之前听了几遍（与 `listeningMeaningCorrect` 一一对应）。
    public internal(set) var listeningMeaningPlays: [Int] = []
    /// 这一轮答错那些句子的关键词（收进词汇本用）。
    public internal(set) var listeningMeaningMissedWords: [String] = []

    // MARK: 入学定级（进阶 ⑤）

    /// 摸底浮层是否打开。
    public internal(set) var isPlacementShowing = false
    /// 这一轮的卷子（空 = 还没出卷 / 已经收工）。
    public internal(set) var placementPaper: PlacementPaper = .empty
    /// 答到第几题（从 0 数；等于题数时表示答完）。
    public internal(set) var placementIndex = 0
    /// 学员选的答案（题 id → 选项下标）。
    public internal(set) var placementAnswers: [String: Int] = [:]
    /// 这一轮的结果（答完才有）。
    public internal(set) var placementOutcome: PlacementResult?
    /// 正在读题库 / 出卷。
    public internal(set) var isPlacementLoading = false
    /// 定级的提示（题库缺失这类，可关闭）。
    public internal(set) var placementNotice: String?
    /// 上一次定级的结果（跨启动保留）。
    ///
    /// ⚠️ 这是持久化状态，同样由手写 `init(services:)` 加载。它是 Optional，
    /// 天然有 nil 兜底 —— 漏掉加载那行**编译器拦不住**，所以另配了一条测试钉死
    /// 「存过的结果必须读得回来」。
    var placementResult: PlacementResult?

    // MARK: 段落级跟读（#232）

    /// 跟读粒度：一句一练 / 整段跟读。
    public internal(set) var shadowingMode: ShadowingMode = .sentence
    /// 当前练到第几段（在 `shadowingPassages` 中的下标）。
    public internal(set) var shadowingPassageIndex = 0
    /// 最近一次段落评测结果（nil = 这一段还没评过）。
    public internal(set) var shadowingPassageResult: ShadowingPassageResult?
    /// 最近一次段落发音评测（整段音频量出来的）。
    public internal(set) var shadowingPassagePronunciation: PronunciationReport?
    // MARK: 语音流式输入
    /// 录音过程中实时识别出的文本（nil = 未在录音）。UI 把它写进输入框。
    public internal(set) var voiceTranscript: String?

    // MARK: - 词汇本（第 24 步 Vocabulary）

    /// 是否停在词汇本页（占中间栏）。
    public var showingVocabulary = false
    /// 词汇表（进页面时加载；新 → 旧）。
    public internal(set) var vocabularyEntries: [VocabularyEntry] = []
    /// 词汇本收录的**去重**单词数（按词忽略大小写；`reloadVocabulary` 是唯一失效点）。
    /// 设置页词汇本卡片的「单词数」用它——收录 / 删除词条后卡片数字要跟着走。
    public internal(set) var vocabularyUniqueWordCount = 0
    /// 词汇统计（总数 / 待复习 / 已掌握 / 已释义）。
    public internal(set) var vocabularyStats: VocabularyStats = .empty
    /// 正在补释义的词（按钮 loading）。
    public internal(set) var isDefiningVocabulary: Set<UUID> = []
    /// 词汇本提示（可关闭；nil = 正常）。
    public internal(set) var vocabularyNotice: AppNotice?
    /// 释义被手动收起的词条（「查释义」按钮与收起开关是同一个按钮；
    /// 已有释义默认展开，收起后点「看释义」再展开，不重新请求模型）。
    public internal(set) var collapsedVocabularyDefinitions: Set<UUID> = []
    /// 已经尝试过「词性 / 中文补全」的词条（每个词一次，失败不反复重试）。
    var termsHealAttempted: Set<UUID> = []
    /// 每日推荐（**按天恒定**的 12 个：3 简单 / 5 中等 / 2 困难 / 2 词组；不落库）。
    /// 同一天、同一学习语言必定是同一批（种子见 `DailySeed`）；只有「换一批」才重抽。
    public internal(set) var dailyWords: [DailyWord] = []
    /// 每日推荐词的释义缓存（按需 LLM，word → 释义；与词汇本共用同一结构）。
    public internal(set) var dailyDefinitions: [String: VocabularyDefinition] = [:]
    /// 正在补释义的每日推荐词（按钮 loading）。
    public internal(set) var isDefiningDaily: Set<String> = []
    /// 已展开释义的每日推荐词（点「查释义」展开，再点收起）。
    public internal(set) var expandedDailyWords: Set<String> = []
    /// 本次展示中已计入「认识」的推荐词（再点一次是撤销 → 计数 -1）。
    /// 每次换一批/重启后清空 —— 单词每出现一次最多计一次，防误点连击。
    public internal(set) var dailyAcknowledged: Set<String> = []
    /// 「认识」累计计数（跨启动持久化）。满 3 次的词不再进入每日推荐。
    /// ⚠️ **刻意不给默认值**：这是个要跨启动恢复的持久化状态，由手写 `init(services:)`
    /// 从 UserDefaults 加载。写了 `= [:]` 就给了编译器一条退路 —— 哪天加载那行被删掉，
    /// 它一声不响，只有用户会发现「昨天点过的『认识』今天全没了」。
    /// 不给默认值，漏加载就是**编译错误**，跑都跑不起来。
    var dailyRecognitions: [String: Int]
    /// 本次启动是否已抽过每日推荐（每次启动只抽一次，刷新按钮才重新抽）。
    var dailyWordsLoaded = false
    /// 本地词库是否已载入（只为设置页「已学 x / y 词」的分母 `dailyBankTotal` 载入一次）。
    var vocabularyBankLoaded = false

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
    public internal(set) var dictionaryBooks: [DictionaryBook] = []
    /// 被删掉、**还能恢复**的内置词典。
    public internal(set) var restorableDictionaries: [DictionaryBook] = []
    /// 可见词典的词条总数（各书相加；**不去重**，只用于分账展示）。
    public internal(set) var dictionaryWordCount = 0
    /// **去重后**的词库规模（跨词典同名词只算一个）。
    /// ⚠️ 设置页卡片 / 词典页页头显示的「词库共 N 词」都用这个，不是上面那个相加值：
    /// 三本内置词典相加 12,625，按词去重后只有 7,404 —— 两个数同时在界面上出现必然被当成 bug。
    public internal(set) var dictionaryUniqueWordCount = 0
    /// 每本书在「每日推荐词源」里的名次（bookID → 名次；没勾选的不在表里）。
    public internal(set) var dictionarySourceRanks: [String: Int] = [:]
    /// 空查询页上的「试试这些词」（从可见词典间隔取，不随机）。
    public internal(set) var dictionarySampleWords: [String] = []
    /// 那一排胶囊的**轮换词池**（随机抽一批，够页面换十几轮）。
    ///
    /// 与 `dictionarySampleWords` 分开：那个是「一页之内不许自己变」的固定样例，
    /// 这个专门给「每 10 秒换一批」用 —— 换的时候从内存里取，不再查库。
    public internal(set) var dictionarySamplePool: [String] = []
    /// 「最近查过」的词（最新的在最前，最多 `recentDictionaryWordsLimit` 个）。
    ///
    /// ⚠️ 刻意不给默认值（与 `dailyRecognitions` / `shortcutBindings` 同一条纪律）：
    /// 这是跨启动恢复的持久化状态，由手写 `init(services:)` 从 UserDefaults 加载。
    /// 给了 `= []` 就等于允许「哪天加载那行被删掉、最近查过一个都不剩」这种静默退化。
    public internal(set) var recentDictionaryWords: [String]
    /// 搜索输入框内容。**搜索后不清空**（用户口径：搜索时输入框中内容不清除）。
    /// 跨页全局搜索面板（#414）开着没有。
    public var showingGlobalSearch = false
    /// 搜索框里的原文（用户正在敲的那个，不是归一化后的）。
    public var globalSearchQuery = ""
    /// 最近一次搜索的结果（四个来源合并后）。
    public internal(set) var globalSearchHits: [GlobalSearchHit] = []
    /// 搜索进行中（词典要读内置库，不是瞬时的）。
    public internal(set) var isSearchingGlobally = false

    public var dictionaryQuery = ""
    /// 模糊匹配结果（最多 10 条，每项带单词 / 音标 / 翻译）。
    public internal(set) var dictionaryMatches: [DictionaryWord] = []
    /// **已经被「查询」消费掉的那个词**：输入框里是它时不再弹匹配浮层。
    ///
    /// ⚠️ 光比「请求发出前后 `dictionaryQuery` 有没有变」是不够的：用户敲完
    /// `aban` 直接回车，输入框里的字**一个字都没改**，那次联想请求回来时凭
    /// 「文本没变」判定有效，于是刚收起的浮层又冒出来 —— 用户看到的就是
    /// 「点了查询/回车，匹配列表还在」。所以必须记一笔：这个词已经被查过了。
    var consumedDictionaryQuery: String?
    /// 联想浮层**是否正处在「用户在输入框里找词」那一段**里。
    ///
    /// ⚠️ 浮层的生死不能只看「`dictionaryMatches` 里有没有内容」：在途的联想回来时
    /// 会把列表填上，浮层就会在用户**已经查到词之后**自己冒出来 —— 09-16 用户那张
    /// 截图正是如此（输入框与展示页都是 `snatch`，浮层还挂着一条 `snatch`）。
    /// 所以另设一个开关：**打字 / 点回输入框 = 开**，**查到词（提交 / 选中 / 跳转 /
    /// 回退）或清空 = 关**；在途结果回来时若开关已经关上，一律丢弃。
    var isDictionaryMatchListArmed = false
    /// 查词跳转历史（当前页 / 上一页 / 最初那个词）。
    public internal(set) var dictionaryLookup = DictionaryLookupSession.empty
    /// 正在查的词（nil = 没在查；用来在详情位上转圈而不是闪空白）。
    public internal(set) var dictionaryLoadingWord: String?
    /// 正在跑的那次查词请求的句柄 —— 用户清空输入时要**真把它取消掉**。
    ///
    /// 用户口径：在输入框里取消了输入，就该同步终止正在查的进程，
    /// 否则请求照样跑完、照样占着模型额度，还会把卡片顶上屏。
    var dictionaryLookupTask: Task<DictionaryDetail, Error>?
    /// 查词请求的轮次号：晚到的旧请求不许把新请求的状态清掉。
    var dictionaryLookupGeneration = 0
    /// 词典页提示（可关闭；nil = 正常）。失败那几条自带「重试」，见 `AppNotice`。
    public internal(set) var dictionaryNotice: AppNotice?
    /// 正在从磁盘导入词典。
    public internal(set) var isImportingDictionary = false
    /// 词典库里处在「确认删除」状态的书（点删除第一次只是变红，再点才真删）。
    public internal(set) var dictionaryPendingDelete: String?

    // MARK: - 词汇复习闭环（P1-3 复习会话）

    /// 正在进行的一轮复习（nil = 不在复习模式，页面照常显示词表）。
    /// 队列与结算口径全在 `AIDomain.VocabularyReviewSession`（纯函数），这里只持有它。
    public internal(set) var vocabularyReview: VocabularyReviewSession?
    /// 当前这张卡是否已翻面（看过释义）。
    public internal(set) var vocabularyReviewRevealed = false
    /// 当前这张卡的朗读评测报告（nil = 这次还没读 / 没拿到录音）。
    /// ⚠️ 只作为**证据**展示，绝不替学员点「认识 / 忘了」。
    public internal(set) var vocabularyReviewReport: PronunciationReport?
    /// 当前这张卡朗读时系统听成了什么（用来如实说明「它听到了别的词」）。
    public internal(set) var vocabularyReviewRecognized: String?
    /// 正在录这张卡的朗读。
    public internal(set) var isVocabularyReviewRecording = false
    /// 朗读评测进行中（录音已结束，正在跑 ASR / 音素）。
    public internal(set) var isVocabularyReviewBusy = false
    /// 复习模式里的一次性提示（读失败 / 没听清等）。读失败那几条自带「重试」。
    public internal(set) var vocabularyReviewNotice: AppNotice?
    /// 上次重置每日推荐学习进度的时间（没重置过为 nil）。
    public internal(set) var dailyProgressResetAt: Date?
    /// 重置那一刻已学完（累计认识满 3 次）的词数。
    /// ⚠️ 同上：不给默认值，让「漏加载」变成编译错误而不是静默归零。
    public internal(set) var dailyProgressResetLearned: Int
    /// 词库总词数（设置页展示「上次已学 x / y 词」）。
    public internal(set) var dailyBankTotal = 0

    // MARK: - 学习进度（第 25 步 Dashboard）

    /// 是否停在学习进度页（占中间栏，与其他页互斥）。
    public var showingProgress = false
    /// 学习进度快照（进页面时汇总一次）。**UI 只读它，不自己统计**。
    public internal(set) var progressSnapshot: ProgressSnapshot = .empty()
    /// 近一年的练习分布（年度记录卡）。与 `progressSnapshot` 一样是只读缓存。
    ///
    /// 初值是**一整张全空的网格**而不是空数组：年度卡一进页面就有正确的尺寸，
    /// 数据到了只是把格子染上色，Layout 不会跳一下。
    public internal(set) var annualRecap: AnnualRecap = .empty()
    /// 树根年轮徽记的原料（#418-B）：从年度缓存里折出的两个字段（练了多少天 / 最长连续）。
    ///
    /// 年度数据**按需加载**（树面板到场后由 MainView 拉起一次，见 `ensureAnnualRecapLoaded`），
    /// 没加载 / 全年没练时是空摘要 —— 徽记不画，树根干干净净。
    public var annualTreeSummary: TreeAnnualSummary { TreeAnnualSummary(recap: annualRecap) }
    /// 正在汇总进度（首次进入时的 loading 态）。
    public internal(set) var isLoadingProgress = false
    /// 统计窗口天数（7 / 14 / 30 天，UI 可切换）。
    public var progressWindowDays = ProgressAggregator.defaultDays

    /// 今日任务推荐（PRD §7.1）。由 `DailyPlanner` 纯函数从快照排出来，UI 只读它。
    ///
    /// 快照还没汇总时排出来是空计划 —— 页面会显示「今天没有安排」，
    /// 而不是编一份看着热闹但不基于任何记录的假清单。
    ///
    /// ⚠️ 带上 `dailyTaskFloor`（当天高水位）：三项指标的完成量**只增不减**，
    /// 任务一旦完成就固定为已完成 —— 复盘清流水、删气泡、清除学习记忆都不许让它回退。
    public var dailyPlan: DailyPlan {
        DailyPlanner.plan(
            snapshot: progressSnapshot,
            mode: product.dailyGoalMode,
            floor: dailyTaskFloor,
            // ⚠️ stance 决定今天各项**加减多少**（见 `DailyPlanTuning`）。不传就用默认的
            // `.observing` —— 那等于自适应永远不改安排，只有建议卡在动。
            stance: adaptivePath.stance
        )
    }

    // MARK: 今日作业（老师黑板）

    /// 黑板是否展开。**不持久化**：每次启动都是收起的，展开与否是「这一次」的事。
    public var isBlackboardExpanded = false

    /// 今日完成的庆祝信号：每次 +1 让右侧森林的小动物跳一次（**一天只放一次**）。
    public internal(set) var celebrationTick = 0
    /// 正在放庆祝（黑板上盖章 + 烟花，几秒后自动收，不留常驻动画）。
    public internal(set) var isCelebratingToday = false
    /// 点黑板上的小图标 → 切到「学习进度」并滚到今日任务卡（每次 +1 触发一次滚动）。
    public internal(set) var progressFocusTick = 0
    /// 「切过去之后还要滚到某张卡」这个意图**还没被学习进度页消费**（nil = 没有意图）。
    /// 与 tick 并行存在：tick 管「已经在这一页时再点一次」，它管「页面是刚被切出来的」。
    var progressFocusPending: ProgressFocusTarget?
    /// 年度汇总跑过没有。
    ///
    /// 开屏那一下**故意不跑**全年（`refreshTodayPanel`：53×7 的热力图不该挂在启动关键路径上），
    /// 所以「进度快照是新的」并**不**意味着年度卡有内容。火苗徽章跳过去时要按它判断，
    /// 否则会把人送到一张空网格上。
    var hasAnnualRecap = false
    /// 年度汇总**正在跑**（它有自己的在途锁，不搭 `isLoadingProgress` 那班车）。
    ///
    /// ⚠️ 两件取数必须各管各的在途：`isLoadingProgress` 锁的是「窗口快照正在跑」，
    /// 而开屏那一轮恰好**只查窗口**。火苗徽章点得早就撞上它，被那道重入保护直接弹回，
    /// 年度汇总永远不跑、也没有任何东西会再来补 —— 用户停在空网格上。
    var isLoadingAnnualRecap = false

    static let todayCelebratedDayKey = "today.celebratedDayKey"
    static let todayBoardAutoExpandedDayKey = "today.boardAutoExpandedDayKey"
    static let todayTaskFloorKey = "today.taskFloor"
    /// 上次庆祝过的 `dayKey`（**持久化**：同一天重开应用不再重复放烟花）。
    var celebratedDayKey: String {
        get { UserDefaults.standard.string(forKey: Self.todayCelebratedDayKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.todayCelebratedDayKey) }
    }
    /// 上次「开屏自动展开黑板」的 `dayKey`（**持久化**：一天最多自动展开一次）。
    var boardAutoExpandedDayKey: String {
        get { UserDefaults.standard.string(forKey: Self.todayBoardAutoExpandedDayKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.todayBoardAutoExpandedDayKey) }
    }
    /// 当天各项完成量的**高水位**（`DailyTaskFloor`：三项指标 + 练习时长；**持久化**，一行）。
    ///
    /// ⚠️ 写成 get/set 直落 `UserDefaults` 的**计算属性**，而不是带默认值的存储属性：
    /// 后者一旦忘了在 `init` 里加载，编译器一声不响，而用户的「今天已完成」
    /// 会在重开应用之后静默归零（这正是用户报障的情形）。
    /// 高水位自己带 `dayKey`，换天取不到就自动作废 —— 不需要谁来清。
    var dailyTaskFloor: DailyTaskFloor {
        get {
            let today = ShadowingDailyRule.dayKey()
            guard let stored = DailyTaskFloor.parse(
                UserDefaults.standard.string(forKey: Self.todayTaskFloorKey)
            ), stored.dayKey == today else { return .empty(dayKey: today) }
            return stored
        }
        set { UserDefaults.standard.set(newValue.storageText, forKey: Self.todayTaskFloorKey) }
    }
    /// 汇总节流：一轮对话就全量汇总一次没必要（本地聚合也有代价）。
    var lastTodayPanelRefreshAt: Date = .distantPast
    /// 后台开场任务（学员一开口就让它让位，见 `learnerEngagedThisLaunch`）。
    var openingTask: Task<Void, Never>?
    /// 开屏时**后台预生成今天的短文阅读**（#330）。排在开场白之后跑，
    /// 只落库不上屏；`openReading` 进页面时会**先等它**，免得生成出今天第二篇。
    var readingPrefetchTask: Task<Void, Never>?
    /// 学员在本轮启动里已经开口 —— 后台开场**不许再动会话**（不能把人家刚说的话清掉）。
    var learnerEngagedThisLaunch = false
    /// 本轮启动里黑板已经自动展开过（收起后不许再自己弹开）。
    var didAutoExpandBoardThisLaunch = false

    /// 「认识」计数的持久化键（UserDefaults：轻量 [word: count]，不值得为此建表）。
    static let dailyRecognitionStorageKey = "vocabulary.dailyRecognitions"
    /// 上次重置时间的持久化键。
    static let dailyResetAtKey = "vocabulary.dailyProgressResetAt"
    /// 上次重置时已学词数的持久化键。
    static let dailyResetLearnedKey = "vocabulary.dailyProgressResetLearned"
    /// 累计认识满此次数 → 不再推荐。
    public static let dailyRecognitionRetireCount = 3

    /// 产品配置缓存（Sendable，可在 MainActor 直接修改后整体回写）。
    var product: ProductConfig = ProductConfig()
    /// 结算提示的自动收起任务。
    var rewardDismissTask: Task<Void, Never>?
    /// 课程覆盖度判定卡的自动收起任务（与奖励条各管各的）。
    var assessmentDismissTask: Task<Void, Never>?
    /// 启停弹框的自动收起任务。
    var toastDismissTask: Task<Void, Never>?
    /// 资源管理巡检器（第 27 步）：start() 里创建并启动，随应用生命周期常驻。
    var lifecycle: ModelLifecycleManager?
    /// 本地定时练习提醒（#226）：start() 里静默同步配置；开关/时刻改动时重新排。
    /// ⚠️ 必须常驻持有 —— 通知 delegate 是弱引用，实例被释放点通知就没响应了。
    let reminders = PracticeReminderService()
    /// 提醒授权是否被系统拒绝（设置页如实展示一句指引）。
    public internal(set) var reminderAuthorizationDenied = false
    /// 情景结算卡还挂着时今日庆祝先不放（防堆叠）；卡收起后的那次刷新补放。
    var rewardCelebrationPending = false
    /// 节流跳过后的**收尾补刷**：完成最后一项任务的那一轮若被 15s 节流吞掉，
    /// 最多 15s 后补一次 —— 庆祝仪式不许因为节流而缺席。
    var trailingRefreshTask: Task<Void, Never>?
    /// 跨天监察（2026-09-24 报障）：常量轮询「今天是哪天」，一变就自动刷新今日面板。
    var dayRolloverTask: Task<Void, Never>?
    /// 上一次见到的日子键（`ShadowingDailyRule.dayKey`）。**只在内存里** ——
    /// 它描述的是「这个进程见过哪一天」，不该跨启动恢复。
    var lastSeenDayKey: String = ShadowingDailyRule.dayKey()

    /// 注入外部装配好的服务（**测试专用**：真实 `CoachServices` 会去启停本机模型服务，
    /// 单测必须换掉它，否则会误杀用户正在运行的 TTS/ASR 进程）。
    init(services: CoachServices) {
        self.services = services
        self.chat = ChatService(services: services)
        // 森林地基：服务层落库点（收词 / 纠错 / 复盘）发出的事件 → 树与林间的回应。
        // 凭证存成属性：订阅随 AppState 活、随 AppState 走。
        self.forestSubscription = forest.attach(to: services.events)
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
        // 快捷键绑定表（同样手写加载；缺的动作由 `decode` 用出厂键补齐）。
        self.shortcutBindings = Self.loadShortcutBindings()
        // 词典「最近查过」（同样手写加载）。
        self.recentDictionaryWords = Self.loadRecentDictionaryWords()
        // 改错练习的连对账本（同样手写加载）。
        self.errorDrillStreaks = Self.loadErrorDrillStreaks()
        // 精听当天账本（同样手写加载；读进来的还会过一道跨天归零）。
        self.listeningLog = Self.loadListeningLog()
        // 上次的入学定级结果（同样手写加载）。
        self.placementResult = Self.loadPlacementResult()
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
        // 轻音效（批次六 · F）：同一班事件里再挑两类转成声音 cue。
        // ⚠️ 必须放在 init 末尾：闭包捕获 self，两段式初始化要求全部存储属性先就位。
        // `enabled` 默认关 —— cue 内部有守卫，开没开都不用调用方操心。
        self.soundSubscription = services.events.subscribe { [weak self] event in
            Task { @MainActor in self?.playSoundCueIfEnabled(for: event) }
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

    /// 当前时刻（24 小时制，带分钟小数）：天体沿弧线走要的是**连续**位置，
    /// 不是每小时跳一格。
    public var clockHour: Double {
        let now = Date()
        let calendar = Calendar.current
        return Double(calendar.component(.hour, from: now))
            + Double(calendar.component(.minute, from: now)) / 60
    }

    /// 当前月份（1...12）：季节的判据。
    public var clockMonth: Int { Calendar.current.component(.month, from: Date()) }

    /// 年内日序（1...366）：天气的判据（#418-A）。
    public var clockDayOfYear: Int {
        Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
    }

    /// 森林是否跟随真实时间（设置开关，默认关）。
    public var forestFollowsClock: Bool { product.forestFollowsClock }

    /// 森林叶色是否随真实季节（设置开关，默认关；与时间开关各管各的）。
    public var forestFollowsSeason: Bool { product.forestFollowsSeason }

    /// 森林天气是否随真实日期（#418-A，默认关）。
    public var forestFollowsWeather: Bool { product.forestFollowsWeather }

    public var theme: ForestTheme {
        ForestThemeResolver.resolve(mode: themeMode, systemIsDark: systemIsDark,
                                    hour: Int(clockHour.rounded(.down)), month: clockMonth,
                                    followsClock: product.forestFollowsClock,
                                    followsSeason: product.forestFollowsSeason,
                                    followsWeather: product.forestFollowsWeather,
                                    dayOfYear: clockDayOfYear)
    }

    // 供设置页读取的产品字段
    public var productPracticeMode: PracticeMode { product.practiceMode }
    public var learningLanguage: String { product.learningLanguage }
    /// 学习语言的**语言全名**（`English`），语音链路（识别 / 朗读 / 试听）专用。
    ///
    /// 配置里存的是 BCP-47（`en-US`），但 ASR / TTS 收的是语言名 ——
    /// 以前这条链路上每个调用点各写一份 `"English"` 字面量，加语言时漏一处
    /// 就表现为「识别莫名其妙变差」且不报错。现在只有这一处换算。
    public var learningLanguageName: String {
        LearningLanguage(bcp47: product.learningLanguage).serviceName
    }
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
    /// 教师朗读调门（半音，0 = 原声）。
    public var speechPitch: Double { product.speechPitch }
    /// 教师朗读风格 / 情感（供应商自定义取值；空串 = 不指定）。
    public var speechStyle: String { product.speechStyle }
    public var speechEmotion: String { product.speechEmotion }
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
    /// 学员的小伙伴（陪着一起爬树的那一只）。
    ///
    /// 没选过就按 `ForestCompanion` 的伙伴规则自动配一只（每个学员物种有固定搭档）——
    /// 「伙伴是要认得的」，所以默认不是随机的。
    public var companionAnimalKind: AnimalKind {
        if !product.studentCompanion.isEmpty, let kind = AnimalKind(rawValue: product.studentCompanion) {
            return kind
        }
        return ForestCompanion.partner(for: studentAnimalKind)
    }

    /// 小学员的当前配饰（批次三成长线）：攒星换装——红领巾 → 小背包 → 望远镜 → 毕业帽。
    /// 各页面的学员形象统一从这读，档位判据只此一份（`StudentProgression`）。
    public var studentAccessory: AnimalAccessory {
        StudentProgression.accessory(totalStars: progress.totalStars)
    }

    /// 中间栏连胜飞鸟的数据（批次三；nil = 连胜还没开始，不显示）。
    /// 判据与侧栏火苗徽章同源（`TodayPanel.streakBadge`），两处永远说同一个数。
    public var streakBadgeForChat: TodayPanel.StreakBadge? {
        TodayPanel.streakBadge(
            streakDays: progressSnapshot.streakDays,
            hasPracticeToday: progressSnapshot.today.hasPractice
        )
    }

    /// 点连胜飞鸟跳年度学习记录（与侧栏火苗徽章同一去处）。
    public func requestOpenAnnualRecap() {
        Task { await openAnnualRecapInProgress() }
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
        // 全局快捷键（#279）：装上本地按键监听，切页 / 复习卡按键从此刻起可用。
        installShortcutMonitor()
        let configuration = await services.configuration
        product = configuration.product
        themeMode = configuration.product.themeMode
        motionMode = configuration.product.motionMode
        typeSize = configuration.product.typeSize
        interfaceDensity = configuration.product.interfaceDensity
        // 非 View 上下文（withAnimation(.app(...))）读不到环境，走这个静态覆盖档。
        AppMotionDescriptor.appOverride = motionMode
        // 同理：AppKit 侧的划词/对话正文（`NSAttributedString`）读不到排版环境值，
        // 字号档要同步到静态镜像上，否则切「大」字号时正文一个点都不动。
        AppTypography.appTextScale = typeSize.scale
        autoSpeak = configuration.product.autoSpeak
        // 轻音效开关跟随配置（默认关；设置页切换时也走这条同步）。
        sound.enabled = configuration.product.soundEffects
        chat.profile.learningLanguage = configuration.product.learningLanguage
        chat.profile.nativeLanguage = configuration.product.nativeLanguage
        progress = await services.loadProgress()
        // ③ AI 排的课：读一次课目录，把课内情景挂成大树上的关卡。
        // ⚠️ 必须**在** `loadProgress()` **之后** —— `applyScenarioBindings` 会把关卡的
        // `scenarioID` 覆盖成绑定表里的值，而它不在 `levels` 表里、每次都要重挂（见 `syncCourseLevels`）。
        // 放在这里而不是等情景面板打开：树是开屏就在画的，课内关卡晚一拍出现等于「先看到树、
        // 滚上去才发现少了几格」。
        await refreshScenarioCatalog()
        // 批次八 · H：全新学员的第一次进入 → 林子欢迎一下（只此一次，落库记名）。
        // 这里只**记名**不演 —— 地面带还没上屏，现在发脉冲 onChange 收不到。
        await markForestWelcomeIfNeeded()
        // 备份恢复（#209）：本轮启动若应用了待恢复内容，说明要让用户看见。
        restoreNote = await services.restoreNote
        // 落库健康：**开屏就查一次**（此前库打不开只写日志，界面上一行字都没有，
        // 用户练一整天，退出重进才发现历史是空的）。
        await refreshPersistenceHealth()
        // 自动备份（#415）：开了才查一次，且只在「距上次备份超过间隔」时补一份。
        // 后台跑 —— 备份要读整个学习库，绝不能挡在开屏路径上。
        Task { [weak self] in await self?.ensureAutoBackupIfNeeded() }

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
        // 开屏后台预生成今天的短文阅读（#330）：与开场白**并行发出、串行执行** ——
        // 它自己在里面等开场白跑完（见 `prefetchTodaysReading`），
        // 所以这里不必再排一次序，也不会把首屏拖住。
        readingPrefetchTask?.cancel()
        readingPrefetchTask = Task { [weak self] in await self?.prefetchTodaysReading() }
        // 跨天监察（2026-09-24 报障）：应用开着跨过零点，每日任务 / 打卡也要自动换天，
        // 不许等用户点一下徽章才刷新（那次点击还会撞上换天瞬间的旧快照）。
        startDayRolloverWatch()
    }

    /// 跨天监察：常驻低频轮询「今天是哪天」，一变就强刷今日面板。
    ///
    /// ⚠️ 用轮询不用「睡到零点」：睡大觉对系统休眠 / 时钟调整没有抵抗力，
    /// 醒来一觉睡过头就又回到「不自动刷新」的老病。30s 一次的 `dayKey` 字符串
    /// 比较（三次取整）是纳秒级开销，换来对任何时钟跳变的即时收敛。
    /// 任务持有 `weak self`：AppState 析构后循环自然退出，不需要谁来取消。
    func startDayRolloverWatch() {
        dayRolloverTask?.cancel()
        dayRolloverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                let key = ShadowingDailyRule.dayKey()
                guard key != self.lastSeenDayKey else { continue }
                self.lastSeenDayKey = key
                await self.refreshTodayPanel(force: true)
                self.refreshTodayTokens()
                await self.refreshQuestRecords()
                // 换天时顺带料理两件「按天算」的事（2026-10-01 补）：
                // ① 自动备份：macOS 应用常年不退出，「每 N 天补一份」不能只在
                //    启动那一刻兑现一次（设置页那句文案就是假的）；
                // ② 年度网格：年轮圈数 / 热力图都按天变，隔天不重取就停在昨天。
                await self.ensureAutoBackupIfNeeded()
                await self.ensureAnnualRecapLoaded(force: true)
            }
        }
    }

    /// 后台开场：老师先开口 / 续做上一段（需求 6）。
    ///
    /// ⚠️ 三条让位规则（学员一旦开口，这段会话就归他）：
    /// 1. 开场还没跑完学员就开口 → 整段放弃，绝不撤他的会话
    ///    （背景里那次「复盘上一段」会把人家刚说的话一起清掉）；
    /// 2. `resumeOrOpenPractice` 的破坏性分支（隐藏历史 → 复盘 → 清空）会**再查一次**；
    /// 3. 人在别的板块 → 只在左栏标一个提示点，不抢画面。
    func openInBackground() async {
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
    func syncKeyDraft(_ providerID: String, kind: AIProviderKind) async -> Bool {
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
    func validateExternalKeyIfNeeded(
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
    func resolvedExternalAPIKey(providerID: String) async -> String {
        keyDraft(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 配置里这把 Key 的指纹（保存成功后刷新展示）。
    func remoteKeyFingerprint(providerID: String) async -> String? {
        let configuration = await services.configuration
        return configuration.providers.first { $0.id == providerID }?.keyFingerprint
    }

    // MARK: - 主题

    public func setThemeMode(_ mode: ThemeMode) async {
        themeMode = mode
        product.themeMode = mode
        await persistProduct()
    }

    /// 切换应用内动效档位。除持久化外要同步写 `AppMotionDescriptor.appOverride`：
    /// 漏了的话设置页看着切了、`withAnimation(.app(...))` 那条链路还是旧档。
    public func setMotionMode(_ mode: MotionMode) async {
        motionMode = mode
        product.motionMode = mode
        AppMotionDescriptor.appOverride = mode
        await persistProduct()
    }

    /// 切换字号档（#416）。字号有两处落地：
    /// SwiftUI 那一侧靠根视图的环境注入传导，AppKit 那一侧（划词/对话正文的
    /// `NSAttributedString`）读不到环境值，必须同步写静态镜像，否则正文不动。
    public func setTypeSize(_ mode: FontSizeMode) async {
        typeSize = mode
        product.typeSize = mode
        AppTypography.appTextScale = mode.scale
        await persistProduct()
    }

    /// 切换界面密度档（#416）。
    public func setInterfaceDensity(_ mode: DensityMode) async {
        interfaceDensity = mode
        product.interfaceDensity = mode
        await persistProduct()
    }

    public func toggleDayNight() async {
        // ⚠️ 开着「跟随时间」时，手动点太阳/月亮必须先**收回自动**：
        // 否则时刻说了算，点了跟没点一样（按钮看着是活的，实际是死的）。
        if product.forestFollowsClock {
            product.forestFollowsClock = false
            await setThemeMode(theme.isNight ? .day : .night)
            return
        }
        await setThemeMode(Self.themeAfterCelestialTap(isNight: theme.isNight))
    }

    /// 首次进入欢迎：判据 = 配置没记过欢迎 **且** 进度全新（一颗星都没有）。
    /// 老用户升级（有进度）永远不演；0 星老用户升级只演这一次。
    private func markForestWelcomeIfNeeded() async {
        guard !product.forestWelcomed, progress.totalStars == 0 else { return }
        pendingForestWelcome = true
        product.forestWelcomed = true
        await persistProduct()
    }

    /// MainView 在地面带到场后调用：把待演的欢迎真正发到 `forest.welcome()`。
    public func consumeForestWelcome() {
        guard pendingForestWelcome else { return }
        pendingForestWelcome = false
        forest.welcome()
    }

    /// 切换「跟随时间」（天黑切夜景、太阳沿弧线走）。
    public func setForestFollowsClock(_ on: Bool) async {
        product.forestFollowsClock = on
        await persistProduct()
    }

    /// 切换「跟随季节」（春华秋实换叶色，日夜档位不动）。
    public func setForestFollowsSeason(_ on: Bool) async {
        product.forestFollowsSeason = on
        await persistProduct()
    }

    /// 切换「跟随天气」（#418-A：晴 / 多云 / 雨，只改插画层）。
    public func setForestFollowsWeather(_ on: Bool) async {
        product.forestFollowsWeather = on
        await persistProduct()
    }

    // MARK: 轻音效（批次六 · F）

    /// 轻音效开关（设置页「轻音效」卡；默认关）。
    public var soundEffectsEnabled: Bool { product.soundEffects }

    /// 切换轻音效：配置与内存里的 `enabled` 要**同一笔**落下，
    /// 漏了后者就是「设置页看着开了、林子里一声不吭」。
    public func setSoundEffects(_ on: Bool) async {
        product.soundEffects = on
        sound.enabled = on
        await persistProduct()
    }

    /// 服务层事件 → 音效的映射（批次六 · F 只挑两类，其余静默）：
    /// 收词 = 一声「叮」；通关 = 一小段琶音。纠错 / 提问不打扰。
    private func playSoundCueIfEnabled(for event: LearningEvent) {
        switch event {
        case .wordCollected:
            sound.cue(.collectWord)
        case .levelCompleted:
            sound.cue(.levelFanfare)
        default:
            break
        }
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
        // 森林仪式：通关是里程碑——树冠抖三抖、落叶缤纷、放烟花（学员攀爬
        // 不用事件，`climbFraction` 变了它自己会顺着树干爬上去）。
        forest.ingest(.levelCompleted(levelID: levelID))
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

    /// 教师朗读调门：落到最接近的档位（与语速同一套自愈口径）。
    ///
    /// 与语速分开存、分开播：语速改**快慢**、调门改**音高**，两条旋钮互不影响。
    public func setSpeechPitch(_ value: Double) async {
        let pitch = SpeechPitch.nearest(to: value)
        guard pitch.rawValue != product.speechPitch else { return }
        product.speechPitch = pitch.rawValue
        await persistProduct()
    }

    /// 教师朗读风格 / 情感（供应商自定义取值；空串 = 不指定）。
    ///
    /// 不做取值校验：取值表由供应商给（`speechToneOptions`），应用不认识这些词，
    /// 校验只会把「供应商新加了一个取值」变成「用户选不了」。
    public func setSpeechStyle(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != product.speechStyle else { return }
        product.speechStyle = trimmed
        await persistProduct()
    }

    public func setSpeechEmotion(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != product.speechEmotion else { return }
        product.speechEmotion = trimmed
        await persistProduct()
    }

    /// 按能力写回朗读语气 —— UI 那边只有这一个入口（它只知道自己在改哪一行，不必知道是风格还是情感）。
    public func setSpeechTone(_ capability: VoiceCapability, _ value: String) async {
        switch capability {
        case .style: await setSpeechStyle(value)
        case .emotion: await setSpeechEmotion(value)
        // 音色克隆与音高各有自己的入口：前者要授权与本地文件，后者由播放侧实现。
        default: break
        }
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

    /// 设置小伙伴（传 nil = 回到自动配对）。
    public func setCompanionAnimal(_ kind: AnimalKind?) async {
        product.studentCompanion = kind?.rawValue ?? ""
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
        if showingListening { return .listening }
        if showingVocabulary { return .vocabulary }
        if showingProgress { return .progress }
        if showingDictionary { return .dictionary }
        if showingScenarios { return .scenarios }
        return .practice
    }

    /// 把「当前页」切到 `section`：**九个页面标记一次写齐**。
    ///
    /// 所有 `open*()` 都走这里，别再各自手写一串 `showingXxx = false` ——
    /// `openScenarios()` 当初就漏了 `showingRecords`，于是「学习记录」和「情景对话」会同时高亮。
    /// 只碰页面标记，**绝不碰 `showingSettings`**（理由见 `activeSection`）。
    func applySection(_ section: AppSection) {
        showingRecords = section == .records
        showingShadowing = section == .shadowing
        showingWriting = section == .writing
        showingReading = section == .reading
        showingListening = section == .listening
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
        case .listening: await openListening()
        case .dictionary: await openDictionary()
        case .vocabulary: await openVocabulary()
        case .scenarios: await openScenarios()
        case .progress: await openProgress()
        case .records: await openRecords()
        }
    }

    // MARK: - 划词 / 进度的存储状态（#267：扩展不能放存储属性，留驻类体）

    /// 划词气泡的浮层宿主：整份 App 一份，注入环境后由各页面的句子共用。
    ///
    /// 气泡为什么不住在句子里：句子都在滚动容器（聊天区还带渐隐 `mask`）里，
    /// 句内 overlay 会被裁掉、也会被后面的兄弟视图盖住。交给这一层就没有遮挡问题。
    /// （消费方在 AppState+WordSelection.swift）
    public let lookupBubble = WordLookupBubblePresenter()

    /// 当前划词气泡的内容（nil = 没有气泡）。
    ///
    /// 内容是**异步**来的（本地词库几乎瞬时，问模型要几秒），探测的那一刻通常还没有，
    /// 所以任何一次赋值都要把它推给浮层 —— 浮层自己记着这次划的是哪句话。
    public internal(set) var wordLookupCard: WordLookupCard? {
        didSet { lookupBubble.updateCard(wordLookupCard) }
    }
    /// 已经问过模型的词：**同一个词一个会话只问一次**。
    /// 鼠标来回扫过同一句话是常态，没有这道闸门就会反复烧 token。
    ///
    /// ⚠️ 键是用户划过的词（#S3-6）：长会话里也是只涨不落。
    /// 到顶**整体清空**（与词典查词缓存同一口径）—— 代价只是被忘掉的那几个词
    /// 允许再问一次，而不是攒到几千个字符串常驻。
    var wordLookupAttempted: Set<String> = []
    /// 上面这道闸门的容量上限（超过就整锅倒掉）。
    static let wordLookupAttemptLimit = 500
    /// 划词请求的序号：慢的那个回来时若已经不是当前词，直接丢弃（不然会闪回上一个词）。
    var wordLookupTicket = 0

    /// 「本周小结 / 月环比」（#228）。与快照一起刷新；nil = 数据还不够 / 数据库不可用。
    public internal(set) var weeklyInsight: WeeklyInsight?

    // MARK: - 快捷键（#279：同样是扩展放不了的存储属性）

    /// 每个动作当前绑的键。
    ///
    /// ⚠️ 刻意不给默认值（与 `dailyRecognitions` 同一条纪律）：这是跨启动恢复的
    /// 持久化状态，由手写 `init(services:)` 加载。给了 `= [:]` 就等于给编译器一条退路 ——
    /// 哪天加载那行被删掉，它一声不响，只有用户会发现「设好的快捷键全回出厂了」。
    public internal(set) var shortcutBindings: [ShortcutAction: ShortcutBinding]
    /// 设置页「快捷键中心」正在录制的动作（nil = 没在录）。
    public var capturingShortcutAction: ShortcutAction?
    /// 改键结果的提示（撞键时那句「已被 X 占用」；成功为空）。
    public var shortcutNotice: String?
    /// 全局按键监听（`start()` 里装一次，进程内常驻）。
    var shortcutMonitor: ShortcutMonitor?

}
