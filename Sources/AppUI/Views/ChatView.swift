import AIDomain
import AIInterfaces
import AIServices
import AppCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct ChatView: View {

    @Environment(\.forestTheme) var theme

    let chat: ChatService
    let modelName: String?
    let health: ProviderHealth
    /// 启动装配中（`AppState.isBooting`）：本地服务在拉起来、模型还没接上。
    ///
    /// ⚠️ 它**不再**决定对话区给不给等待卡（2026-10-14 报障）：开屏已不再自动开场，
    /// 装配期直接显示引导卡，「老师正在准备…」那张卡只在 `isTeacherPreparing` 时出现。
    /// 这个参数留着是因为自动朗读要挡它 —— 续做决策走完会揭开上次那段历史，
    /// 那一下「条数从 0 跳上来」不该被念出来（见 `onChange(of: chat.visibleMessages.count)`）。
    var isBooting: Bool = false
    /// 状态栏用：生效 Provider 名称（本地模型 / DeepSeek / OpenRouter…）。
    var providerLabel: String = ""
    /// 上下文窗口长度（token）；nil = 未知，只展示估算用量。
    var contextLimit: Int? = nil
    /// 生效模型的推理强度（low / medium / high；nil = 标准）。
    var reasoningLabel: String? = nil
    /// AI 老师形象（头部 / 回复气泡头像）。
    let teacherKind: AnimalKind
    /// 小学员形象（学员消息头像 / 空态引导）。
    let studentKind: AnimalKind
    /// 小学员当前配饰（批次三成长线：攒星换装；nil = 默认红领巾，离屏/测试兜底）。
    var studentAccessory: AnimalAccessory = .student
    /// 连胜数据（批次三中间栏飞鸟；nil = 不显示——连胜还没开始）。
    var streakBadge: TodayPanel.StreakBadge? = nil
    /// 点飞鸟跳年度学习记录（与侧栏火苗徽章同一去处）。
    var onOpenStreak: (() -> Void)? = nil
    // 语音（第 17/18 步）
    /// 语音输入的阶段（唯一真相）。三颗语音相关的按钮**全部**从它取语义：
    /// 以前这里是 `isRecording` + `isTranscribing` 两个布尔，而「识别中」
    /// 那一格从未被点亮过 —— 识别期间按钮看着还是「录音中」，
    /// 点下去执行的是「开始录音」，用户想停却停不掉（见 `VoiceInputPhase`）。
    var voicePhase: VoiceInputPhase = .idle
    var autoSpeak: Bool = false
    /// 点击麦克风：开始录音 / 停止并识别。
    var onMicStart: (() async -> Void)? = nil
    var onMicStop: (() async -> String?)? = nil
    /// 取消这次录音（丢掉，不识别）。
    var onCancelVoiceInput: (() -> Void)? = nil
    /// 语音输入错误（录音 / 识别失败）；显示在输入框上方，可关闭。
    var voiceError: String? = nil
    /// 关闭语音错误提示。
    var onDismissVoiceError: (() -> Void)? = nil
    /// 朗读某段教师回复。
    var onSpeakTap: ((String) -> Void)? = nil
    /// 停止当前朗读（朗读中再点按钮 = 停）。
    var onStopSpeak: (() -> Void)? = nil
    /// 当前朗读相位（准备中 / 朗读中 / 空闲）。
    var speechPhase: SpeechPhase = .idle
    /// 正在朗读的原文：用于让对应消息的按钮显示「准备中 / 朗读中」。
    var speakingText: String? = nil
    /// 当前教师朗读语速（倍速，1 = 正常）；nil = 不显示速度选择器。
    var speechRate: Double = SpeechRate.x1.rawValue
    /// 克隆音色生效提示（nil = 内置音色）。
    ///
    /// 需求要求「cleared indication when a cloned voice is active」——
    /// 用户在任何一句被朗读的时候都该知道那不是内置声音，而这里正是他听的地方。
    var voiceIndicator: String? = nil
    /// 切换语速（设置页与对话区共用同一份配置，双向同步）。
    var onSpeechRateChange: ((Double) -> Void)? = nil
    /// 进行中的情景对话（nil = 普通练习）：头部显示场景胶囊，下方显示目标条。
    var scenario: ScenarioProgress? = nil
    /// 打开情景选择面板。
    var onOpenScenarios: (() -> Void)? = nil
    /// 结束当前情景。
    var onEndScenario: (() -> Void)? = nil
    /// 录音过程中实时识别出的文本（流式写进输入框；nil = 没在录音）。
    var voiceTranscript: String? = nil
    /// 对话模型被关闭时的提示（非 nil 时输入框上方常驻提示并禁用发送）。
    var modelStoppedNotice: String? = nil
    /// 输入框为空时轮换展示的预设学员提问（数据来自资源文件）；点发送即发送当前这一条。
    var starterQuestions: [String] = []
    /// 开屏话题卡（今天聊什么）。**依据不足时是空数组** —— 那时只画问候，不画装饰。
    ///
    /// 与 `starterQuestions` 的区别：轮换提问是**输入框的占位提示**，想用得自己打一遍；
    /// 话题卡是能点一下就开口的一整句话。
    var kickoffs: [KickoffSuggestion] = []
    /// 点一张话题卡。nil = 只读展示（渲染回归用）。
    var onKickoff: ((KickoffSuggestion) -> Void)? = nil
    /// 离屏注入的「鼠标停在哪张卡上」（真机 hover 在离屏里不产生，只能靠参数喂）。
    var forcedHoveredKickoffID: String? = nil

    // MARK: 继续上次对话（2026-10-14 引导卡改造）
    /// 有没有「上次」可继续（启动时只读地算好：内存里有恢复历史，或库里有会话行）。
    ///
    /// ⚠️ false 时那颗按钮**不画**：第一次打开、什么都没有的时候，
    /// 凑一颗点下去只会收到一句泛泛招呼的按钮，比没有更糟。
    var canContinueLast: Bool = false
    /// 「继续上次对话」正在跑（总结上次 → 发起聊天）。这期间引导卡让位给等待卡，
    /// 按钮也用不着画禁用态 —— 它所在的空态整块都不显示了。
    var isPreparingOpening: Bool = false
    /// 点「继续上次对话」。nil = 只读展示（渲染回归用）。
    var onContinueLast: (() -> Void)? = nil
    /// 离屏注入的「鼠标停在这颗按钮上」（真机 hover 在离屏里不产生，只能靠参数喂，
    /// 与 `forcedHoveredKickoffID` 同款处理 —— 底色一致了，悬停色也得一起钉住）。
    var forcedHoveredContinueLast: Bool = false

    // MARK: 碎片热身（⑦-B②）
    /// 这一轮热身能做哪几步（nil = 一步都排不出来 → 整块不画，不留空壳）。
    var warmUpPlan: WarmUpPlan? = nil
    /// 正在跑 / 已跑完的那一轮（nil = 画入口卡）。
    var warmUp: WarmUpProgress? = nil
    /// 热身卡自己的提示（麦克风打不开 / 没听清这类）。
    var warmUpNotice: AppNotice? = nil
    /// 这一步刚读出来的发音分。
    var warmUpStepScore: Double? = nil
    /// 这一步听到的原话。
    var warmUpHeardText: String? = nil
    var isWarmUpRecording = false
    var isWarmUpBusy = false
    var onStartWarmUp: (() -> Void)? = nil
    var onGradeWarmUpWord: ((Bool) -> Void)? = nil
    var onPlayWarmUpSentence: (() -> Void)? = nil
    var onToggleWarmUpRecording: (() -> Void)? = nil
    var onContinueWarmUp: (() -> Void)? = nil
    var onSkipWarmUpStep: (() -> Void)? = nil
    var onSendWarmUpSpoken: (() -> Void)? = nil
    var onDismissWarmUp: (() -> Void)? = nil
    var onDismissWarmUpNotice: (() -> Void)? = nil
    /// 离开对话页时收掉热身的录音（麦克风不能跟着走到别的页面）。
    var onCancelWarmUpRecording: (() -> Void)? = nil
    /// 取某条消息的译文（再点一次收起）。
    var onTranslate: ((UUID) async -> Void)? = nil
    /// 翻译失败提示（可关闭）。
    var translationError: String? = nil
    /// 关闭翻译失败提示。
    var onDismissTranslationError: (() -> Void)? = nil
    /// 划词上下文（对话正文与纠错卡里的英文都能划过看释义）。
    /// nil = 不启用划词（离屏渲染 / 既有测试走这条路，不受影响）。
    var wordLookup: WordLookupContext? = nil

    // MARK: 练习模式 / 前情提要（需求 3 / 4）
    /// 当前练习模式：随口练与情景对话在界面上要区分得开。
    var practiceMode: PracticeMode = .conversation
    /// 「开启新练习」：先复盘上一段、再进随口练。
    var onStartFreeTalk: (() async -> Void)? = nil
    /// 「开启新练习」正在跑（S4-4）：按钮据此置灰，挡住第二次点击。
    var isStartingFreeTalk: Bool = false
    /// 当前任务的前情提要（情景模式下的引导卡；nil = 不显示）。
    var briefing: ScenarioBriefing? = nil
    /// 上一段练习自动复盘的结果提示（nil = 不显示）。
    /// ⚠️ 文案与动作是**一个值**（`AppNotice`）：「去看复盘」跳到哪一条不能另外存一份。
    var practiceNotice: AppNotice? = nil
    var onDismissPracticeNotice: (() -> Void)? = nil

    // MARK: 考试模式（雅思口语 / 面试问答）
    /// 考场条数据（nil = 没在考试）。有值时对话区顶部换成考场条、
    /// 输入框不再轮换预设提问 —— 考场上学员该自己开口，不是挑一句现成的说。
    var exam: ExamBarModel? = nil
    var onExamTimeout: (() -> Void)? = nil
    var onExamSkip: (() -> Void)? = nil
    var onExamFinish: (() -> Void)? = nil

    // 附件（第 3 项需求：图片 / 视频 / 文件）
    /// 已选好、还没发出去的附件。
    var pendingAttachments: [ChatAttachment] = []
    /// 附件提示（超限 / 导入失败），显示在输入框上方，可关闭。
    var attachmentNotice: String? = nil
    /// 附件**下载成功**的回执。
    ///
    /// ⚠️ 这个状态一度只被写入、从来没被显示过：`downloadAttachment` 把
    /// `attachmentSaveNotice` 置上，却没有一个视图读它 —— 用户点了下载，文件落到了
    /// 选择的目录，界面上**一点反应都没有**（回执永远不会被清除，因为它压根没出现过）。
    var attachmentSaveNotice: String? = nil
    /// 当前生效的模型能不能**真的读图**（false = 图片只会以文件名告诉老师）。
    var llmSupportsVision: Bool = true
    /// 正在导入附件。
    var isImportingAttachments: Bool = false
    /// 选中一批文件（由外部导入；面板在视图层弹，状态在 AppState）。
    var onAddAttachments: (([URL]) -> Void)? = nil
    /// 移除一个待发附件。
    var onRemoveAttachment: ((UUID) -> Void)? = nil
    /// 下载某个附件。
    var onDownloadAttachment: ((ChatAttachment) -> Void)? = nil
    /// 附件在本机的位置（渲染用）。
    var attachmentLocation: ((ChatAttachment) -> URL)? = nil
    /// 关闭附件提示。
    var onDismissAttachmentNotice: (() -> Void)? = nil
    /// 关闭「已保存」回执。
    var onDismissAttachmentSaveNotice: (() -> Void)? = nil
    /// 清空待发附件（一次删掉全部；单个移除走 `onRemoveAttachment`）。
    var onClearAttachments: (() -> Void)? = nil
    /// 发送（带附件）：发送动作收在 AppState 里，视图不自己拼「取附件 + 清空」的顺序。
    var onSend: ((String) -> Void)? = nil
    /// 「发送」快捷键的触发票（#617）：AppState 每分发一次 +1，本视图
    /// `onChange` 到就替快捷键跑一次发送（按钮上那颗写死的 keyboardShortcut
    /// 已让位给全局监听，避免同键双触发）。
    var sendShortcutTicket: Int = 0
    /// 发送键当前绑的键（设置页可改）：悬停提示与 VoiceOver 读它，不写死 ⌘↩。
    var sendShortcutHint: String = "⌘↩"
    /// 删掉一条学员消息（连同它的老师回复）。
    var onDeleteMessage: ((UUID) -> Void)? = nil
    /// 气泡内编辑后重发：从此处重新开始对话。
    var onResendEditedMessage: ((UUID, String) -> Void)? = nil
    /// 重新生成某条老师回复。
    var onRegenerateReply: ((UUID) -> Void)? = nil
    /// 这条对话现在改不改得动（生成中 / 考试中不改，见 `AppState.canMutateChatMessages`）。
    var canMutateMessages: Bool = true
    /// **离屏渲染用的悬停注入**。
    ///
    /// 真机上的悬停由鼠标驱动，而离屏没有鼠标事件 —— 不给这个入口，
    /// 「悬停时气泡到底长什么样」就永远没法回归（这与 `DictionaryBookCard`
    /// 把 `isHovered` 交给外层的理由是同一件事）。
    var forcedHoveredMessageID: UUID? = nil
    /// **离屏渲染用的「正在编辑」注入**（理由同上：点「编辑」是鼠标动作，离屏点不了）。
    var forcedEditingMessageID: UUID? = nil
    /// 编辑框里的初始草稿（配合 `forcedEditingMessageID` 出图用）。
    var forcedEditingDraft: String? = nil

    @State var input: String = ""
    /// 输入框当前高度（由 `MultilineComposerField` 按真实排版量出并夹到 5 行以内）。
    @State var inputHeight: CGFloat = 0
    @State var isInputFocused: Bool = false
    /// 本段语音在输入框里的位置记忆（前缀 + 上次写入的语音段）。
    ///
    /// 合并规则见 `VoiceTranscriptMerge`：用户没动过就整段替换（流畅、不滚长），
    /// 用户改过字就**保留他的手改**、只把识别的增量补在后面 —— 后者是 2026-09-27
    /// 报障的修复点（以前每一步都按录音前快照重算，用户改的字会被冲回去）。
    @State var voiceMerge = VoiceMergeState()
    /// 预设提问轮换状态（状态下沉，#440）：父 body 不读下标，
    /// 只有占位子视图订阅它 —— 轮换一跳不再重算整个对话视图。
    @State var rotator = StarterQuestionRotator()
    /// 录音中且尚未发送：只有这段时间才允许流式结果往输入框里写。
    /// （发送后必须彻底断开，否则正在录音时发送会被下一轮流式结果原样填回来。）
    @State var isMergingVoice = false
    /// 聊天区是否处于「上翻」状态（距底部超过阈值）——
    /// 决定「回到底部」按钮与输入框上方的虚化是否出现。
    @State var isScrolledUp = false
    /// 鼠标停在**哪一条**消息上（学员气泡的三颗图标据此由 30% 变 100%）。
    ///
    /// ⚠️ 悬停态放在这里而不是气泡组件内部：组件自己 `onHover` 就没法在离屏渲染里
    /// 验证「悬停时到底长什么样」，而那一行按钮正是这次新增的全部视觉。
    @State var hoveredMessageID: UUID?
    /// 正在就地编辑的消息（nil = 没有）。
    @State var editingMessageID: UUID?
    /// 编辑框里的草稿。与消息正文分开存：取消这次编辑时原文必须**一字不动**。
    @State var editingDraft: String = ""
    /// 删除确认的两步状态（点垃圾桶只登记，确认之后才真删）。
    @State var deleteConfirmation = DeleteConfirmation()
    /// 「继续上次对话」的悬停态。与话题卡同款：真机由 `onHover` 喂，
    /// 离屏渲染靠 `forcedHoveredContinueLast` 参数喂。
    @State var continueLastHovered = false

    /// 学员气泡那三颗图标**常驻时的透明度**（悬停时 100%）。
    ///
    /// ⚠️ 为什么不是 0：要够到它们得先把鼠标移到气泡右下角，而 0 的那一下图标是隐形的 ——
    /// 用户看不到自己在往哪儿移，鼠标一偏图标又没了（2026-09-23 用户口径：改成常驻）。
    /// ⚠️ 为什么不再往上：三颗是**次要动作**，30% 已经在「看得见」的边缘，
    /// 再亮就和正文抢注意力了。
    nonisolated static let learnerActionIdleOpacity: Double = 0.3

    /// 相隔超过该时长的两条消息之间才显示时间戳。
    let timestampGap: TimeInterval = 5 * 60

    public init(chat: ChatService, modelName: String?, health: ProviderHealth,
                isBooting: Bool = false,
                providerLabel: String = "", contextLimit: Int? = nil, reasoningLabel: String? = nil,
                teacherKind: AnimalKind = .panda, studentKind: AnimalKind = .bear,
                studentAccessory: AnimalAccessory = .student,
                streakBadge: TodayPanel.StreakBadge? = nil,
                onOpenStreak: (() -> Void)? = nil,
                voicePhase: VoiceInputPhase = .idle,
                autoSpeak: Bool = false,
                onMicStart: (() async -> Void)? = nil,
                onMicStop: (() async -> String?)? = nil,
                onCancelVoiceInput: (() -> Void)? = nil,
                voiceError: String? = nil,
                onDismissVoiceError: (() -> Void)? = nil,
                onSpeakTap: ((String) -> Void)? = nil,
                onStopSpeak: (() -> Void)? = nil,
                speechPhase: SpeechPhase = .idle,
                speakingText: String? = nil,
                speechRate: Double = SpeechRate.x1.rawValue,
                voiceIndicator: String? = nil,
                onSpeechRateChange: ((Double) -> Void)? = nil,
                scenario: ScenarioProgress? = nil,
                onOpenScenarios: (() -> Void)? = nil,
                onEndScenario: (() -> Void)? = nil,
                voiceTranscript: String? = nil,
                modelStoppedNotice: String? = nil,
                starterQuestions: [String] = [],
                kickoffs: [KickoffSuggestion] = [],
                onKickoff: ((KickoffSuggestion) -> Void)? = nil,
                forcedHoveredKickoffID: String? = nil,
                canContinueLast: Bool = false,
                isPreparingOpening: Bool = false,
                onContinueLast: (() -> Void)? = nil,
                forcedHoveredContinueLast: Bool = false,
                warmUpPlan: WarmUpPlan? = nil,
                warmUp: WarmUpProgress? = nil,
                warmUpNotice: AppNotice? = nil,
                warmUpStepScore: Double? = nil,
                warmUpHeardText: String? = nil,
                isWarmUpRecording: Bool = false,
                isWarmUpBusy: Bool = false,
                onStartWarmUp: (() -> Void)? = nil,
                onGradeWarmUpWord: ((Bool) -> Void)? = nil,
                onPlayWarmUpSentence: (() -> Void)? = nil,
                onToggleWarmUpRecording: (() -> Void)? = nil,
                onContinueWarmUp: (() -> Void)? = nil,
                onSkipWarmUpStep: (() -> Void)? = nil,
                onSendWarmUpSpoken: (() -> Void)? = nil,
                onDismissWarmUp: (() -> Void)? = nil,
                onDismissWarmUpNotice: (() -> Void)? = nil,
                onCancelWarmUpRecording: (() -> Void)? = nil,
                onTranslate: ((UUID) async -> Void)? = nil,
                translationError: String? = nil,
                onDismissTranslationError: (() -> Void)? = nil,
                wordLookup: WordLookupContext? = nil,
                pendingAttachments: [ChatAttachment] = [],
                attachmentNotice: String? = nil,
                attachmentSaveNotice: String? = nil,
                llmSupportsVision: Bool = true,
                isImportingAttachments: Bool = false,
                onAddAttachments: (([URL]) -> Void)? = nil,
                onRemoveAttachment: ((UUID) -> Void)? = nil,
                onDownloadAttachment: ((ChatAttachment) -> Void)? = nil,
                attachmentLocation: ((ChatAttachment) -> URL)? = nil,
                onDismissAttachmentNotice: (() -> Void)? = nil,
                onDismissAttachmentSaveNotice: (() -> Void)? = nil,
                onClearAttachments: (() -> Void)? = nil,
                practiceMode: PracticeMode = .conversation,
                onStartFreeTalk: (() async -> Void)? = nil,
                isStartingFreeTalk: Bool = false,
                briefing: ScenarioBriefing? = nil,
                practiceNotice: AppNotice? = nil,
                onDismissPracticeNotice: (() -> Void)? = nil,
                exam: ExamBarModel? = nil,
                onExamTimeout: (() -> Void)? = nil,
                onExamSkip: (() -> Void)? = nil,
                onExamFinish: (() -> Void)? = nil,
                onSend: ((String) -> Void)? = nil,
                /// 「发送」快捷键的触发票（#617）：每按一次 +1，`onChange` 到就替
                /// 快捷键跑一次发送。为什么要绕这一圈见 `chatComposerSendTicket` 的注释。
                sendShortcutTicket: Int = 0,
                /// 发送键当前绑的是什么（设置页可改）—— 悬停提示读它，不写死 ⌘↩。
                sendShortcutHint: String = "⌘↩",
                onDeleteMessage: ((UUID) -> Void)? = nil,
                onResendEditedMessage: ((UUID, String) -> Void)? = nil,
                onRegenerateReply: ((UUID) -> Void)? = nil,
                canMutateMessages: Bool = true,
                forcedHoveredMessageID: UUID? = nil,
                forcedEditingMessageID: UUID? = nil,
                forcedEditingDraft: String? = nil) {
        self.chat = chat
        self.modelName = modelName
        self.health = health
        self.isBooting = isBooting
        self.providerLabel = providerLabel
        self.contextLimit = contextLimit
        self.reasoningLabel = reasoningLabel
        self.teacherKind = teacherKind
        self.studentKind = studentKind
        self.studentAccessory = studentAccessory
        self.streakBadge = streakBadge
        self.onOpenStreak = onOpenStreak
        self.voicePhase = voicePhase
        self.autoSpeak = autoSpeak
        self.onMicStart = onMicStart
        self.onMicStop = onMicStop
        self.onCancelVoiceInput = onCancelVoiceInput
        self.voiceError = voiceError
        self.onDismissVoiceError = onDismissVoiceError
        self.onSpeakTap = onSpeakTap
        self.onStopSpeak = onStopSpeak
        self.speechPhase = speechPhase
        self.speakingText = speakingText
        self.speechRate = speechRate
        self.voiceIndicator = voiceIndicator
        self.onSpeechRateChange = onSpeechRateChange
        self.scenario = scenario
        self.onOpenScenarios = onOpenScenarios
        self.onEndScenario = onEndScenario
        // ⚠️ 下面这批必须显式赋值：属性声明处有默认值（`= nil` / `= []`），
        // 手写 init 漏掉它们**不会编译报错**，而是静默保持默认值
        // → 表现为「模型关闭提示条不出现」「语音流式结果写不进输入框」
        //   「预设提问不轮换」「翻译按钮点了没反应」。
        self.voiceTranscript = voiceTranscript
        self.modelStoppedNotice = modelStoppedNotice
        self.starterQuestions = starterQuestions
        self.kickoffs = kickoffs
        self.onKickoff = onKickoff
        self.forcedHoveredKickoffID = forcedHoveredKickoffID
        // ⚠️ 这三个也必须显式赋值（同上一段）：漏一个的表现是
        // 「有上次对话却不显示继续按钮」/「点了之后界面毫无反馈」。
        self.canContinueLast = canContinueLast
        self.isPreparingOpening = isPreparingOpening
        self.onContinueLast = onContinueLast
        self.forcedHoveredContinueLast = forcedHoveredContinueLast
        self.warmUpPlan = warmUpPlan
        self.warmUp = warmUp
        self.warmUpNotice = warmUpNotice
        self.warmUpStepScore = warmUpStepScore
        self.warmUpHeardText = warmUpHeardText
        self.isWarmUpRecording = isWarmUpRecording
        self.isWarmUpBusy = isWarmUpBusy
        self.onStartWarmUp = onStartWarmUp
        self.onGradeWarmUpWord = onGradeWarmUpWord
        self.onPlayWarmUpSentence = onPlayWarmUpSentence
        self.onToggleWarmUpRecording = onToggleWarmUpRecording
        self.onContinueWarmUp = onContinueWarmUp
        self.onSkipWarmUpStep = onSkipWarmUpStep
        self.onSendWarmUpSpoken = onSendWarmUpSpoken
        self.onDismissWarmUp = onDismissWarmUp
        self.onDismissWarmUpNotice = onDismissWarmUpNotice
        self.onCancelWarmUpRecording = onCancelWarmUpRecording
        self.onTranslate = onTranslate
        self.translationError = translationError
        self.onDismissTranslationError = onDismissTranslationError
        self.wordLookup = wordLookup
        self.pendingAttachments = pendingAttachments
        self.attachmentNotice = attachmentNotice
        self.attachmentSaveNotice = attachmentSaveNotice
        self.llmSupportsVision = llmSupportsVision
        self.isImportingAttachments = isImportingAttachments
        self.onAddAttachments = onAddAttachments
        self.onRemoveAttachment = onRemoveAttachment
        self.onDownloadAttachment = onDownloadAttachment
        self.attachmentLocation = attachmentLocation
        self.onDismissAttachmentNotice = onDismissAttachmentNotice
        self.onDismissAttachmentSaveNotice = onDismissAttachmentSaveNotice
        self.onClearAttachments = onClearAttachments
        self.practiceMode = practiceMode
        self.onStartFreeTalk = onStartFreeTalk
        self.isStartingFreeTalk = isStartingFreeTalk
        self.briefing = briefing
        self.practiceNotice = practiceNotice
        self.onDismissPracticeNotice = onDismissPracticeNotice
        self.exam = exam
        self.onExamTimeout = onExamTimeout
        self.onExamSkip = onExamSkip
        self.onExamFinish = onExamFinish
        self.onSend = onSend
        self.sendShortcutTicket = sendShortcutTicket
        self.sendShortcutHint = sendShortcutHint
        self.onDeleteMessage = onDeleteMessage
        self.onResendEditedMessage = onResendEditedMessage
        self.onRegenerateReply = onRegenerateReply
        self.canMutateMessages = canMutateMessages
        self.forcedHoveredMessageID = forcedHoveredMessageID
        self.forcedEditingMessageID = forcedEditingMessageID
        self.forcedEditingDraft = forcedEditingDraft
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            // 考场条取代情景胶囊与目标条：考场上只需要「第几题 / 还剩多久 / 怎么结束」。
            if let exam {
                ExamSessionBar(
                    model: exam,
                    onTimeout: { onExamTimeout?() },
                    onSkip: { onExamSkip?() },
                    onFinish: { onExamFinish?() }
                )
                Divider().overlay(theme.divider)
            }
            if let scenario {
                scenarioStrip(scenario)
                Divider().overlay(theme.divider)
            }
            if let briefing, briefing.lines.isEmpty == false {
                briefingStrip(briefing)
                Divider().overlay(theme.divider)
            }
            messageArea
            // 林间空地**已搬进右侧林子**（2026-09-29 用户口径：植物该长在大树下的草坪上，
            // 而不是悬浮在聊天区挡视线）。轮次取数口在 `ChatService.learnerTurnCount`。
            practiceNoticeBanner
            if let modelStoppedNotice {
                modelStoppedBanner(modelStoppedNotice)
            }
            voiceErrorBanner
            translationErrorBanner
            attachmentErrorBanner
            attachmentSavedBanner
            composer
        }
        .background(theme.surfaceAlt.opacity(0.35))
        // ⚠️ 离开对话页要收掉语音输入（2026-09-27）：切页只销毁视图，
        // `AppState` 里的录音状态还在 —— 麦克风会一直开着跟到下一个页面。
        // 用户切去词典查个词，回来时录音还没停，中间那几分钟全被采进去了。
        .onDisappear {
            if voicePhase != .idle { onCancelVoiceInput?() }
            // 同上：热身走到「读一遍 / 说这句」时切页，麦克风同样不能跟着走。
            if isWarmUpRecording { onCancelWarmUpRecording?() }
        }
        // 「发送」快捷键（#617）：全局监听是唯一分发器，它只负责敲票，
        // 真正的发送在这里跑 —— 输入框内容 / 预设轮换 / 待发附件都在本视图的
        // @State 里，AppState 复现不了那套顺序（见 `chatComposerSendTicket`）。
        .onChange(of: sendShortcutTicket) { _, _ in
            send()
        }
        // 教师回复完成后自动朗读（设置里可关）；挂在最外层，空态切换分支也不丢事件。
        // ⚠️ 一律读 `visibleMessages`：启动时被「藏起来待复盘」的上一段对话既不该上屏，
        // 也不该在开屏时被念出来（`messages` 里那一刻装的正是它）。
        // ⚠️ 还要挡住 `isBooting`：续做决策走完之后会**揭开**上次那段历史（情景续做 / 接着聊），
        // 那一下同样是「条数从 0 跳上来」，但它揭开的是旧消息，念出来就是「开屏自己说话」。
        .onChange(of: chat.visibleMessages.count) { previous, count in
            guard !isBooting else { return }
            // ⚠️ S4-9：只有**条数变多**才谈得上「老师刚回了一条」。
            // 只看 `count > 0` 的话，删掉一条消息（条数减少但仍有内容）会把
            // 上一条早就存在的回复重新念一遍 —— 用户会以为老师又说话了。
            guard count > previous else { return }
            if autoSpeak, let last = chat.visibleMessages.last, last.role == .assistant {
                onSpeakTap?(last.content)
            }
        }
        // 流式语音输入：录音期间识别结果实时写入输入框（只替换「本次语音」那一段，
        // 用户手打的内容原样保留；用户在录音期间改过的字同样保留，见 `applyVoiceText`）。
        .onChange(of: voiceTranscript) { _, text in
            guard let text, voicePhase.isCapturing, isMergingVoice else { return }
            applyVoiceText(text)
        }
        // 预设提问轮换：时钟已下沉到占位子视图（RollingStarterQuestionView），
        // 根级不再挂 Timer。这里只把最新的预设提问同步进 rotator。
        .onAppear { rotator.update(questions: starterQuestions) }
        .onChange(of: starterQuestions) { _, questions in
            rotator.update(questions: questions)
        }
        // 删除确认（2026-09-23）。三颗图标常驻之后，「先精确悬停」那层阻力没有了，
        // 而误点的代价是一整轮问答（学员那句 + 老师紧邻的那句回复）——
        // 于是把阻力加回到**最该加的那一步**上（编辑 / 复制不必陪着受罪）。
        //
        // ⚠️ 真正调 `onDeleteMessage` 的**只有**这里那颗红色按钮：
        // 垃圾桶那一颗只 `request`（登记），这就保证了「点错一下」不会删掉任何东西。
        // ⚠️ `set` 分支要接住 Esc / 点框外：`isPresented` 变 false 一律当「放弃」，
        // 否则待确认的那条会一直挂着，下一次点垃圾桶还弹同一个人的名字。
        .confirmationDialog(
            BubbleDeletePrompt.title,
            isPresented: Binding(
                get: { deleteConfirmation.isPresented },
                set: { if !$0 { deleteConfirmation.cancel() } }
            ),
            titleVisibility: .visible,
            presenting: deleteConfirmation.pending
        ) { id in
            Button("删除", role: .destructive) {
                if let confirmed = deleteConfirmation.confirm() {
                    onDeleteMessage?(confirmed)
                }
            }
            Button("取消", role: .cancel) { deleteConfirmation.cancel() }
        } message: { id in
            Text(BubbleDeletePrompt.message(for: pendingDeleteText(id)))
        }
    }

    /// 待删除那条的正文（确认框里拿它写摘要）。
    private func pendingDeleteText(_ id: UUID) -> String {
        chat.visibleMessages.first { $0.id == id }?.content ?? ""
    }

    /// 把一次识别文本落到输入框 —— **流式与定稿共用这一个入口**。
    ///
    /// 规则只有一份（`VoiceTranscriptMerge`），所以「边说边出字」与「松手后的最终结果」
    /// 不可能对同一段话给出两种写法；用户在录音期间改过的字也不会被后面的推送抹掉。
    func applyVoiceText(_ incoming: String) {
        let outcome = VoiceTranscriptMerge.apply(voiceMerge, incoming: incoming, current: input)
        voiceMerge = outcome.state
        input = outcome.text
    }
}
