import AIDomain
import AIInterfaces
import AIServices
import AppCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct ChatView: View {

    @Environment(\.forestTheme) private var theme

    let chat: ChatService
    let modelName: String?
    let health: ProviderHealth
    /// 启动装配中（`AppState.isBooting`）：模型还没接上，对话区要给等待态 ——
    /// 此时显示「和老师打个招呼」是在说谎，那一刻打招呼不会有回应。
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

    @State private var input: String = ""
    /// 输入框当前高度（由 `MultilineComposerField` 按真实排版量出并夹到 5 行以内）。
    @State private var inputHeight: CGFloat = 0
    @State private var isInputFocused: Bool = false
    /// 本段语音在输入框里的位置记忆（前缀 + 上次写入的语音段）。
    ///
    /// 合并规则见 `VoiceTranscriptMerge`：用户没动过就整段替换（流畅、不滚长），
    /// 用户改过字就**保留他的手改**、只把识别的增量补在后面 —— 后者是 2026-09-27
    /// 报障的修复点（以前每一步都按录音前快照重算，用户改的字会被冲回去）。
    @State private var voiceMerge = VoiceMergeState()
    /// 预设提问轮换状态（状态下沉，#440）：父 body 不读下标，
    /// 只有占位子视图订阅它 —— 轮换一跳不再重算整个对话视图。
    @State private var rotator = StarterQuestionRotator()
    /// 录音中且尚未发送：只有这段时间才允许流式结果往输入框里写。
    /// （发送后必须彻底断开，否则正在录音时发送会被下一轮流式结果原样填回来。）
    @State private var isMergingVoice = false
    /// 聊天区是否处于「上翻」状态（距底部超过阈值）——
    /// 决定「回到底部」按钮与输入框上方的虚化是否出现。
    @State private var isScrolledUp = false
    /// 鼠标停在**哪一条**消息上（学员气泡的三颗图标据此由 30% 变 100%）。
    ///
    /// ⚠️ 悬停态放在这里而不是气泡组件内部：组件自己 `onHover` 就没法在离屏渲染里
    /// 验证「悬停时到底长什么样」，而那一行按钮正是这次新增的全部视觉。
    @State private var hoveredMessageID: UUID?
    /// 正在就地编辑的消息（nil = 没有）。
    @State private var editingMessageID: UUID?
    /// 编辑框里的草稿。与消息正文分开存：取消这次编辑时原文必须**一字不动**。
    @State private var editingDraft: String = ""
    /// 删除确认的两步状态（点垃圾桶只登记，确认之后才真删）。
    @State private var deleteConfirmation = DeleteConfirmation()

    /// 学员气泡那三颗图标**常驻时的透明度**（悬停时 100%）。
    ///
    /// ⚠️ 为什么不是 0：要够到它们得先把鼠标移到气泡右下角，而 0 的那一下图标是隐形的 ——
    /// 用户看不到自己在往哪儿移，鼠标一偏图标又没了（2026-09-23 用户口径：改成常驻）。
    /// ⚠️ 为什么不再往上：三颗是**次要动作**，30% 已经在「看得见」的边缘，
    /// 再亮就和正文抢注意力了。
    nonisolated static let learnerActionIdleOpacity: Double = 0.3

    /// 相隔超过该时长的两条消息之间才显示时间戳。
    private let timestampGap: TimeInterval = 5 * 60

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
    private func applyVoiceText(_ incoming: String) {
        let outcome = VoiceTranscriptMerge.apply(voiceMerge, incoming: incoming, current: input)
        voiceMerge = outcome.state
        input = outcome.text
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            CuteAnimalView(kind: teacherKind, isSleeping: theme.isNight, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(teacherKind.displayName)老师")
                    .appFont(16, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                HStack(spacing: 5) {
                    // 「老师正在准备」时状态行跟着转：顶栏与对话区必须说同一件事，
                    // 不能底下在等、上面看着像闲着。
                    if isTeacherPreparing {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                    }
                    Text(statusLine)
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Spacer()

            // 连胜飞鸟（批次三）：连胜 ≥1 天才出现，扑翅动效只在 +1 那一刻；
            // 点按去处与侧栏火苗徽章一致（年度学习记录）。
            if let streakBadge {
                StreakBirdBadge(badge: streakBadge, onTap: { onOpenStreak?() })
            }

            // 克隆音色生效提示：与情景胶囊并列，位置显眼但不抢戏。
            if let voiceIndicator {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.badge.mic")
                        .appFont(9, weight: .semibold)
                    Text(voiceIndicator)
                        .appFont(10, weight: .semibold, design: .rounded)
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 8)
                .appPadding(.vertical, 4)
                .background(Capsule().fill(theme.accent.opacity(0.14)))
                .help("当前使用的是克隆音色，不是内置音色")
            }

            if let scenario {
                HStack(spacing: 6) {
                    Image(systemName: scenario.scenario.icon)
                        .appFont(10, weight: .semibold)
                    Text("\(scenario.scenario.titleZh) · \(scenario.turnsText)")
                        .appFont(10, weight: .semibold, design: .rounded)
                    if scenario.isFinalTurn {
                        Text("收尾")
                            .appFont(9, weight: .semibold, design: .rounded)
                            .padding(.horizontal, 5)
                            .appPadding(.vertical, 1)
                            .background(Capsule().fill(theme.accent.opacity(0.22)))
                    }
                    Button {
                        onEndScenario?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .appFont(11)
                    }
                    .buttonStyle(.appPressable)
                    .help("结束情景对话")
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 9)
                .appPadding(.vertical, 4)
                .background(Capsule().fill(theme.selection))
            } else {
                Button {
                    onOpenScenarios?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "map.fill")
                            .appFont(10, weight: .semibold)
                        Text("情景")
                            .appFont(10, weight: .semibold, design: .rounded)
                    }
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 9)
                    .appPadding(.vertical, 4)
                    .background(Capsule().fill(theme.hover))
                }
                .buttonStyle(.appPressable)
                .help("选择情景对话场景")
            }

            if let modelName, !modelName.isEmpty {
                Text(headerModelCaption(modelName))
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .appPadding(.vertical, 4)
                    .background(Capsule().fill(theme.surfaceAlt))
            }

            // 「开启新练习」（需求 4）：结束当前这一段（自动复盘）并进随口练。
            // 与情景对话的区别写在按钮的 hover 提示里 —— 学员按下之前就该知道两件事不一样。
            Button {
                // 双击防线（S4-4）：AppState 里还有一道，这里只负责「别白起一个 Task」。
                guard let onStartFreeTalk, !isStartingFreeTalk else { return }
                Task { await onStartFreeTalk() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .appFont(10, weight: .semibold)
                    Text(isStartingFreeTalk
                         ? "正在开始…"
                         : (practiceMode == .freeTalk ? "重开随口练" : "开启新练习"))
                        .appFont(10, weight: .semibold, design: .rounded)
                }
                .foregroundStyle(theme.onAccentFill)
                .padding(.horizontal, 10)
                .appPadding(.vertical, 4)
                .background(Capsule().fill(theme.accentFill))
                .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .disabled(onStartFreeTalk == nil || isStartingFreeTalk)
            .opacity(isStartingFreeTalk ? 0.6 : 1)
            .help("换一段自由练习：你定话题、老师跟着你聊，多给建议与纠错（上一段会自动复盘收进学习记录）")
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // MARK: - 前情提要条（需求 3：进任务先讲清「上次练到哪」）

    /// 老师进任务前先交代的内容。与 `scenarioStrip`（角色 / 轮次）分工不同：
    /// 那条说「你在演谁」，这条说「我们上次做到哪、这次先做什么」。
    private func briefingStrip(_ briefing: ScenarioBriefing) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .appFont(10, weight: .semibold)
                    .foregroundStyle(theme.accent)
                Text(briefing.isFirstTime ? "今天的任务" : "前情提要")
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                if briefing.quest.total > 0 {
                    Text(briefing.quest.summary)
                        .appFont(10, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.accentCool)
                        .padding(.horizontal, 6)
                        .appPadding(.vertical, 1)
                        .background(Capsule().fill(theme.hover))
                }
                Spacer(minLength: 0)
            }
            ForEach(briefing.lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 5) {
                    Circle()
                        .fill(theme.accent.opacity(0.7))
                        .frame(width: 3, height: 3)
                        .appPadding(.top, 5)
                    Text(line)
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(.horizontal, 18)
        .appPadding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.selection.opacity(0.5))
    }

    /// 上一段练习自动复盘的结果（需求 5：复盘变成自动，所以必须给一句回执）。
    ///
    /// 复盘的正文在学习记录页里，学员看到「已收进学习记录」之后**第一件想做的事就是去看它** ——
    /// 所以这条回执自带一个「去看复盘」：跳过去、并顺手展开**那一条**的复盘。
    /// 目标会话跟着 `AppNotice` 的值一起走，界面上没有第二处需要同步的状态。
    @ViewBuilder
    private var practiceNoticeBanner: some View {
        if let practiceNotice {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .appFont(11)
                    .foregroundStyle(theme.accent)
                Text(practiceNotice.text)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                if let action = practiceNotice.action {
                    NoticeActionButton(
                        action: action,
                        helpText: "\(action.title)：到学习记录里看这一段的复盘内容",
                        context: practiceNotice.text
                    )
                }
                Button { onDismissPracticeNotice?() } label: {
                    Image(systemName: "xmark")
                        .appFont(9, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.appPressable)
            }
            .padding(.horizontal, 18)
            .appPadding(.vertical, 6)
            .background(theme.surfaceAlt.opacity(0.9))
            .overlay(alignment: .top) { Divider().overlay(theme.divider) }
            .overlay(alignment: .bottom) { Divider().overlay(theme.divider) }
        }
    }

    // MARK: - 情景目标条（数据来自场景本体，UI 不解释语义）

    private func scenarioStrip(_ progress: ScenarioProgress) -> some View {
        let scenario = progress.scenario
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "target")
                .appFont(11)
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("你是 \(scenario.learnerRole)")
                        .appFont(10, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    Text("· \(scenario.level) · 纠错\(scenario.correctionMode.displayName)")
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }
                if !scenario.objective.isEmpty {
                    Text(scenario.objective)
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !scenario.targetVocabulary.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(scenario.targetVocabulary.prefix(6), id: \.self) { word in
                            Text(word)
                                .appFont(9, design: .rounded)
                                .foregroundStyle(theme.secondaryText)
                                .padding(.horizontal, 6)
                                .appPadding(.vertical, 2)
                                .background(Capsule().fill(theme.surfaceAlt))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .appPadding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.selection.opacity(0.35))
    }

    /// 右上角胶囊：模型名 · 推理强度（如「qwen3:8b · 高」）。
    private func headerModelCaption(_ model: String) -> String {
        if let reasoningLabel, !reasoningLabel.isEmpty {
            return "\(model) · \(reasoningLabel)"
        }
        return model
    }

    private var statusLine: String {
        var parts: [String] = []
        if let modelName, !modelName.isEmpty { parts.append(modelName) }
        parts.append(health.userFacingDescription)
        return parts.joined(separator: " · ")
    }

    // MARK: - 消息区

    /// 老师开场白 / 启动装配期间：这两段都没有流式内容，却可能是最长的一次等待
    /// （冷启动实测 30–60s），必须由专门的等待卡承接（见 `pendingCard`）。
    private var isTeacherPreparing: Bool { isBooting || chat.isGreeting }

    @ViewBuilder
    private var messageArea: some View {
        // ⚠️ 判据走 `ChatEmptyStateRule`（纯函数、有单测）：这条逻辑漏一个条件，
        // 界面就开始说谎 —— 启动装配那几秒的「和老师打个招呼」正是这么来的。
        if ChatEmptyStateRule.showsInvitation(
            messageCount: chat.visibleMessages.count,
            hasStreamingText: !chat.streamingText.isEmpty,
            hasStreamingReasoning: !chat.streamingReasoning.isEmpty,
            isGenerating: chat.isGenerating,
            isBooting: isBooting
        ) {
            // 空态：小动物相对整个对话区垂直居中。
            GeometryReader { geo in
                emptyHint
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // LazyVStack：长会话只渲染屏幕内外的少量气泡（历史几十上百条时
                    // 一次性全部搭出来是滚动卡顿的主因）。间距与对齐和原 VStack 一致。
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(chat.visibleMessages.enumerated()), id: \.element.id) { index, message in
                            VStack(alignment: .leading, spacing: 6) {
                                // 距上一条超过 5 分钟才显示时间戳；首条消息必显示。
                                if index == 0
                                    || message.createdAt.timeIntervalSince(chat.visibleMessages[index - 1].createdAt) > timestampGap {
                                    timestamp(message.createdAt)
                                }
                                bubble(message)
                            }
                            .id(message.id.uuidString)
                            // 新消息从底部推入（#357）：看得出来「刚到」，而不是凭空出现。
                            // 移除保持纯淡出 —— 换会话时整列表退场，滑动会乱。
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }

                        // 判据同样走纯函数：`isBooting` 那段 `isGenerating` 还是 false，
                        // 漏掉就是几秒全白（消息也是空的）。
                        if ChatEmptyStateRule.showsPendingCard(
                            isGenerating: chat.isGenerating, isBooting: isBooting
                        ) {
                            pendingCard
                                .id("streaming")
                        }

                        if let errorMessage = chat.errorMessage {
                            errorBanner(errorMessage)
                        }
                    }
                    .padding(.horizontal, 18)
                    .appPadding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 消息插入/移除的动画事务（#357）：没有它，上面的 .transition
                    // 从不带动画、新消息是瞬间蹦出来的。挂在 count 上 —— 追加新消息
                    // 与换会话重置列表都会触发；换会话时旧行纯淡出（见行的 asymmetric）。
                    .appAnimation(.reveal, value: chat.visibleMessages.count)
                }
                // 内容不足一屏时不硬弹（#360）：空会话 / 只有一两条时上下拖动
                // 会把整段内容拽起来又弹回去，像皮筋。basedOnSize 只在真的
                // 能滚的时候才允许回弹。
                .scrollBounceBehavior(.basedOnSize)
                // 需求 2：聊天区上翻时，输入框**正上方**出现快速回底按钮，
                // 并且输入框上方那一条文字有轻微虚化（见 `messageFadeMask`）。
                .mask { messageFadeMask }
                .overlay(alignment: .bottom) { jumpToBottomButton(proxy) }
                // 「在上翻吗」由滚动几何量决定，不靠监听手势：
                // 触控板惯性滚动、拖滚动条、程序化 scrollTo 都会更新 contentOffset，
                // 只有读几何量才三种情况都跟得上。
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    ChatScrollMetrics.distanceFromBottom(
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height,
                        contentOffsetY: geometry.contentOffset.y,
                        bottomInset: geometry.contentInsets.bottom
                    )
                } action: { _, distance in
                    isScrolledUp = ChatScrollMetrics.shouldOfferJumpToBottom(
                        distanceFromBottom: distance
                    )
                }
                // S4-1：跟着滚到底**只在没上翻时**做。三处原先都是无条件 `scrollToBottom`，
                // 于是生成回复期间上翻看历史，每来一个 token 就被拽回底部 ——
                // 上翻阅在生成期间完全不可用。
                .onChange(of: chat.visibleMessages.count) { _, _ in
                    autoScrollIfFollowing(
                        proxy,
                        // 自己刚发出一条：即使之前在上翻也拉到底（那是他要看的东西）。
                        userSentMessage: chat.visibleMessages.last?.role == .user
                    )
                }
                .onChange(of: chat.streamingText) { autoScrollIfFollowing(proxy, userSentMessage: false) }
                .onChange(of: chat.streamingReasoning) { _, _ in
                    // 思考阶段也保持滚动到底（面板自动跟随最新内容）
                    if chat.streamingText.isEmpty {
                        autoScrollIfFollowing(proxy, userSentMessage: false)
                    }
                }
                .task {
                    // #6：练习页是 if/else 切出来的 —— 从别的页面回来时本视图是
                    // **重建**的，ScrollView 初始停在对话开头。等一帧让消息真正
                    // 落位，再**无动画**定位到最后（带动画会从顶飞到底，更糟）。
                    await positionAtLatestOnAppear(proxy)
                }
            }
        }
    }

    /// 内容变化时的自动跟滚（S4-1）：**用户上翻就暂停跟随**。
    ///
    /// 口径是纯函数（`ChatScrollMetrics.shouldAutoScrollOnContentChange`），
    /// 这里只负责把当前状态喂进去 —— 判据写在视图里就没法把边界值钉死。
    private func autoScrollIfFollowing(_ proxy: ScrollViewProxy, userSentMessage: Bool) {
        guard ChatScrollMetrics.shouldAutoScrollOnContentChange(
            isScrolledUp: isScrolledUp, userSentMessage: userSentMessage
        ) else { return }
        scrollToBottom(proxy)
    }

    /// 「回到底部」按钮：与主流 Agent 一致 —— 一条消息都没错过时不出现，
    /// 一旦上翻就浮在**输入框正上方居中**，点一下回到最新。
    @ViewBuilder
    private func jumpToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        if isScrolledUp {
            Button {
                // 不在这里手工把 `isScrolledUp` 置回 false：滚动过程本身会持续上报距离，
                // 越滚越近时它会自然跨过阈值。手工抢先置位反而会在动画途中闪一下。
                scrollToBottom(proxy)
            } label: {
                Image(systemName: "arrow.down")
                    .appFont(12, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.surface))
                    .overlay(Circle().strokeBorder(theme.divider, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.14), radius: 4, y: 2)
            }
            .buttonStyle(.appPressable)
            .help("回到最新消息")
            .appPadding(.bottom, 10)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    /// 输入框上方那层「轻微虚化」：把聊天区最底下的一条渐隐掉。
    ///
    /// 用**渐变蒙版**而不是盖一块底色：对话框的背景是 `surfaceAlt.opacity(0.35)`
    /// 叠在窗口底色上，想在日夜两套主题下都配出一模一样的实色几乎不可能，
    /// 一旦差一点就会看到一条色带。蒙版是让文字自己淡出、露出**它本来就在的那层背景**，
    /// 天然不可能有色差。
    private var messageFadeMask: some View {
        GeometryReader { geometry in
            let start = ChatScrollMetrics.fadeStartFraction(containerHeight: geometry.size.height)
            ZStack {
                // 没上翻时这一层是实心黑 → 蒙版全开（完全不虚化）；
                // 上翻时它淡到 0，只剩下面那层渐变 → 底部渐隐。
                //
                // ⚠️ 必须这样叠，不能只留渐变：`mask` 按 **alpha** 生效，
                // 若底层也是半透明，两层会在合成时互相「补」回来（alpha 混合是
                // out = top + bottom×(1-top)）→ 渐隐根本看不出来。
                Color.black.opacity(isScrolledUp ? 0 : 1)
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: start),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(isScrolledUp ? 1 : 0)
            }
            .appAnimation(.reveal, value: isScrolledUp)
        }
    }

    /// 生成中该显示哪张卡：老师开场白 / 启动装配 → 等待卡；其余 → 流式卡。
    ///
    /// 两者不合并：等待卡报的是「已等待 N 秒」这个事实，而流式卡兜底的那三个跳点
    /// 从第一秒起就没有变化，用户看到的「卡住」与「在算」是同一种样子。
    @ViewBuilder
    private var pendingCard: some View {
        if isTeacherPreparing {
            // 真实阶段：装配（拉服务 / 加载模型）→ 生成开场白。分界线是
            // `isBooting` / `chat.isGreeting` 这两个真实信号，不是按秒数编的。
            TeacherPreparingCard(
                teacherKind: teacherKind,
                stage: isBooting ? .booting : .greeting
            )
        } else {
            streamingCard
        }
    }

    /// 生成中的卡片：思考面板（实时增长）+ 流式正文。
    @ViewBuilder
    private var streamingCard: some View {
        let streamingMessage = ChatMessage(role: .assistant, content: chat.streamingText)
        if !chat.streamingReasoning.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                CuteAnimalView(kind: teacherKind, isSleeping: false, size: 30)
                ThinkingPanel(reasoning: chat.streamingReasoning, isStreaming: chat.streamingText.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if !chat.streamingText.isEmpty {
            bubble(streamingMessage)
        } else if chat.isThinking {
            HStack(spacing: 8) {
                CuteAnimalView(kind: teacherKind, isSleeping: false, size: 30)
                Text("思考中…")
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                TypingDots(color: theme.secondaryText)
            }
        } else {
            HStack(spacing: 8) {
                CuteAnimalView(kind: teacherKind, isSleeping: false, size: 30)
                TypingDots(color: theme.secondaryText)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let target: String? = chat.isGenerating ? "streaming" : chat.visibleMessages.last?.id.uuidString
        guard let target else { return }
        if animated {
            withAnimation(.app(.reveal)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    /// #6：进入练习页时的落位。睡一拍等首帧布局完成（消息尺寸还是估算值时
    /// `scrollTo` 会停在中途），然后无动画直落底部。
    private func positionAtLatestOnAppear(_ proxy: ScrollViewProxy) async {
        try? await Task.sleep(nanoseconds: 120_000_000)
        scrollToBottom(proxy, animated: false)
        // LazyVStack 的到场项是按需搭的：第一跳之后中段气泡才陆续建出来，
        // 估算高度会漂 —— 补一跳落准（两次都无动画，用户看不出过程）。
        try? await Task.sleep(nanoseconds: 120_000_000)
        scrollToBottom(proxy, animated: false)
    }

    /// 每条消息上方的时间戳：`9月9日 周三 18:57`（仅间隔 > 5 分钟才出现）。
    private func timestamp(_ date: Date) -> some View {
        Text(Self.stamp(date))
            .appFont(10, design: .rounded)
            .foregroundStyle(theme.secondaryText.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .center)
            .appPadding(.top, 4)
    }

    /// 手写格式化：避免 DateFormatter 的 locale/并发坑，输出顺序固定为「月日 周 时分」。
    public nonisolated static func stamp(_ date: Date) -> String {
        Timestamps.stamp(date)
    }

    private var emptyHint: some View {
        let copy = PeriodGreeting.emptyStateLines(hour: Calendar.current.component(.hour, from: Date()))
        return VStack(spacing: 10) {
            CuteAnimalView(kind: studentKind, isSleeping: theme.isNight, size: 92, accessory: studentAccessory)
            Text(copy.greeting)
                .appFont(15, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Text(copy.invite)
                .appFont(14, design: .rounded)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warning)
            Text(message)
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Spacer()
        }
        .appPadding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.warning.opacity(0.14))
        )
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        // 悬停态：鼠标在哪一条上（真机由 `onHover` 写，离屏由参数注入 —— 见 `forcedHoveredMessageID`）。
        let isHovered = hoveredMessageID == message.id || forcedHoveredMessageID == message.id
        // 「重新生成」得有一条可重跑的问题：这条回复之前必须有学员说过话。
        // 老师主动开场那一条前面没有学员，按钮只能是死的（点不动的按钮比没有按钮更让人困惑，
        // 所以这里把它的可用性算出来，交给按钮自己显示成禁用态）。
        let canRegenerate: Bool = {
            guard !isUser,
                  let index = chat.visibleMessages.firstIndex(where: { $0.id == message.id })
            else { return false }
            return chat.visibleMessages[..<index].contains { $0.role == .user }
        }()
        return HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 36) }
            if !isUser {
                CuteAnimalView(kind: teacherKind, isSleeping: false, size: 30)
            }
            bubbleColumn(message, isUser: isUser, isHovered: isHovered, canRegenerate: canRegenerate)
            if isUser {
                CuteAnimalView(kind: studentKind, isSleeping: false, size: 28, accessory: .student)
            }
            if !isUser { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// 气泡那一列（正文 + 译文 + 纠错 + 动作行），编辑态与正常态二选一。
    ///
    /// ⚠️ 悬停判定区钉在**这一整块**上（气泡 + 三颗图标 + 译文 + 纠错），
    /// 但**不含**头像与外侧留白 —— 用户 2026-09-23 的口径是「整体判定区」，
    /// 指的就是这一块；把整行（含 `Spacer` 的空白）都算进来的话，
    /// 鼠标飘到对话区左边那一大片空里图标也亮着，那是噪声不是反馈。
    @ViewBuilder
    private func bubbleColumn(
        _ message: ChatMessage,
        isUser: Bool,
        isHovered: Bool,
        canRegenerate: Bool
    ) -> some View {
        let corrections = isUser ? [] : (chat.correctionsByMessage[message.id] ?? [])
        let translation = chat.translationsByMessage[message.id]
        let isTranslating = chat.translatingMessageIDs.contains(message.id)
        // 编辑态：气泡**整条换成一条独立输入框**（与产品给的参考图一致）。
        // 这一条消息本身没有被改动 —— 取消就还是原来那句话，草稿存在 `editingDraft` 里。
        if isUser, isEditing(message) {
            MessageEditBox(
                text: editBinding(for: message),
                onCancel: { cancelEditing() },
                onSend: { commitEditing(message) }
            )
        } else {
            // 学员气泡靠右 → 内容列 .trailing；老师靠左 → .leading。
            // ⚠️ 译文卡片**不挂任何宽度 frame**：裸 HStack[Text] 是「内容自然宽度、
            // 超宽自动换行」，与正文气泡完全同构；挂了 `frame(maxWidth: .infinity)`
            // 才会变成弹性视图、与 Spacer 平分宽度把正文挤向中间（第一轮翻车根因），
            // 挂了 `frame(width: 量宽)` 则会撑出行宽（第二轮翻车根因）。
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                // 思考过程：对话卡片内嵌的折叠面板，正文在其下方。
                if !isUser, let reasoning = message.reasoning, !reasoning.isEmpty {
                    ThinkingPanel(reasoning: reasoning, isStreaming: false)
                }
                // 附件排在正文**上方**：和主流 Agent 一致 —— 先看到「我发了什么」，
                // 再读配的那句话，读起来是「这张图 + 这句话」而不是反过来。
                ForEach(message.attachments) { attachment in
                    MessageAttachmentView(
                        attachment: attachment,
                        fileURL: attachmentLocation?(attachment)
                    ) {
                        onDownloadAttachment?(attachment)
                    }
                }
                // 气泡本体：翻译按钮贴在气泡外侧（学员在左 / 老师在右），
                // 这一层 HStack 用 .bottom 对齐 —— 按钮因此**始终与气泡底线齐平**，
                // 下方再挂纠错卡或朗读按钮也不会把它拽下去。
                //
                // 只有附件、没打字时不出空气泡：一个空圆角框看起来像渲染坏了。
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(alignment: .bottom, spacing: 6) {
                        if isUser {
                            TranslateButton(isOn: translation != nil, isLoading: isTranslating) {
                                Task { await onTranslate?(message.id) }
                            }
                        }
                        MarkdownText(message.content, fontSize: 14, color: theme.primaryText, lookup: wordLookup)
                            // #2 二轮（用户 2026-09-24）：学员气泡的地板宽度 = 它自己那三颗
                            // 图标行的整宽（64 − 左右内边距 28 = 36）。极短的一句（"Ok."）
                            // 否则会缩得比动作行还窄，看着像被压瘪了。
                            // 老师气泡不设：它下面那一排（朗读 / 语速 / 复制 / 重答）更宽，
                            // 拿哪一颗当基准都是猜。
                            .frame(
                                minWidth: isUser ? LearnerBubbleActionRow.minimumBubbleContentWidth : nil,
                                alignment: .leading
                            )
                            .padding(.horizontal, 14)
                            .appPadding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(isUser ? theme.bubbleUser : theme.bubbleCoach)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(theme.divider, lineWidth: 1)
                            )
                        if !isUser {
                            TranslateButton(isOn: translation != nil, isLoading: isTranslating) {
                                Task { await onTranslate?(message.id) }
                            }
                        }
                    }
                }
                if let translation {
                    translationCard(translation, isUser: isUser)
                }
                ForEach(corrections) { correction in
                    correctionCard(correction)
                }
                // 老师气泡的底部动作行：朗读 / 语速 / 复制 / 重新生成。
                //
                // ⚠️ 顺序按产品要求：复制与重新生成**排在语速按钮右边**，且**始终显示**
                // （与学员气泡「悬停才浮现」相反 —— 这两颗不改动对话内容，
                //  而「老师这句没听懂 / 没答好」是最常发生的即时需求）。
                if !isUser {
                    HStack(spacing: 6) {
                        if let onSpeakTap {
                            SpeakButton(text: message.content,
                                        phase: speakingText == message.content ? speechPhase : .idle,
                                        action: onSpeakTap,
                                        onStop: onStopSpeak)
                            if onSpeechRateChange != nil {
                                SpeechRateMenu(rate: speechRate) { rate in onSpeechRateChange?(rate) }
                            }
                        }
                        CoachBubbleActionRow(
                            text: message.content,
                            isEnabled: canMutateMessages && canRegenerate,
                            onRegenerate: { onRegenerateReply?(message.id) }
                        )
                        Spacer(minLength: 0)
                    }
                }
                // 学员气泡的动作行：贴在气泡**下方**、右对齐（与老师气泡同一排法）。
                //
                // ⚠️ 为什么不在气泡**里面**：叠在右下角时，短句的最后一行文字末尾会被
                // 那三颗盖住（出图实测；用户看过图之后把位置定在了气泡外）。
                // ⚠️ 为什么用「常驻占位 + 只改透明度」而不是 `if isHovered`：后者会让
                // 气泡在鼠标进入的瞬间长高、整段对话跟着上下跳；占位高度恒定，跳就不可能发生。
                // ⚠️ 三颗**常驻**（未悬停 30%、悬停 100%），不再 `allowsHitTesting(false)`：
                // 「看得见」与「点得动」必须是同一件事 —— 看得见却点不动是最气人的那种 UI。
                // 误点由删除那一颗的确认框兜住（`DeleteConfirmation`）。
                if isUser {
                    LearnerBubbleActionRow(
                        text: message.content,
                        isEnabled: canMutateMessages,
                        onDelete: { deleteConfirmation.request(message.id) },
                        onEdit: { beginEditing(message) }
                    )
                    .opacity(isHovered ? 1 : Self.learnerActionIdleOpacity)
                    .appAnimation(.press, value: isHovered)
                }
            }
            // ⚠️ 判定区就是**这一整块**（气泡 + 三颗图标 + 译文 + 纠错）：
            // 用户口径是「整体判定区」，而不是只认气泡本体。
            // `contentShape` 不能省：块内的行间距（6pt 那条缝）本来不可命中，
            // 鼠标从气泡往图标那一条移过去时会先掉出判定区 —— 图标闪一下再亮，很难看。
            .contentShape(Rectangle())
            .onHover { inside in updateHover(inside, on: message) }
        }
    }

    /// 这条消息此刻是不是在就地编辑（真机由 `editingMessageID` 写，离屏由参数注入）。
    private func isEditing(_ message: ChatMessage) -> Bool {
        editingMessageID == message.id || forcedEditingMessageID == message.id
    }

    /// 编辑框的草稿绑定。
    ///
    /// ⚠️ 离屏注入的那条走 `.constant`：出图只关心「长什么样」，
    /// 而这个分支在真机上永远不会进（`forcedEditingMessageID` 默认 nil）。
    private func editBinding(for message: ChatMessage) -> Binding<String> {
        if forcedEditingMessageID == message.id, let forced = forcedEditingDraft {
            return .constant(forced)
        }
        return $editingDraft
    }

    /// 悬停进 / 出。    ///
    /// ⚠️ 移出时**只在「当前悬停的还是我」时才清**：从 A 滑到 B 时，A 的 `mouseExited`
    /// 完全可能晚于 B 的 `mouseEntered`，无脑置 nil 会把 B 刚点亮的按钮又灭掉。
    private func updateHover(_ inside: Bool, on message: ChatMessage) {
        if inside {
            hoveredMessageID = message.id
        } else if hoveredMessageID == message.id {
            hoveredMessageID = nil
        }
    }

    /// 进入气泡就地编辑：草稿取**当前正文**，取消时原文一字不动。
    private func beginEditing(_ message: ChatMessage) {
        editingDraft = message.content
        editingMessageID = message.id
    }

    private func cancelEditing() {
        editingMessageID = nil
        editingDraft = ""
    }

    /// 提交编辑：先收起输入框，再交给上层「截断其后 + 重发」。
    ///
    /// ⚠️ 顺序不能反。反过来的话，重发生成已经开始、而编辑框还挂在屏幕上，
    /// 用户会以为没点上，然后再点一次 —— 那就是第二次截断与第二次生成。
    private func commitEditing(_ message: ChatMessage) {
        let text = editingDraft
        cancelEditing()
        onResendEditedMessage?(message.id, text)
    }

    /// 译文卡片：默认不显示，点翻译按钮才出现在气泡下方。
    ///
    /// 对齐跟随**内容列**（学员 .trailing / 老师 .leading）：
    /// 学员译文与正文气泡**右缘对齐**（正文位置不动，译文出现在其下方）；
    /// 老师译文左对齐。两侧因此永不重叠，一眼就能分出这句话是谁说的。
    ///
    /// ⚠️ 布局与正文气泡**完全同构**（2026-09-11 定版）：不做任何宽度测量、
    /// 不挂任何 `frame(width:)` —— 内容自然宽度、超过可用宽度自动换行，
    /// 可用宽度与正文气泡一模一样（同处一个 VStack，收到同一个宽度提案）。
    /// 只保留两处刻意差异：底色不同、多一个引号图标。
    /// 历史教训：量宽方案（自然宽 ×1.04、动态上限）连续翻车 —— 忘减内边距就
    /// 把整行撑出窗口。Text 本来就会在提案宽度处换行，根本不需要手工量。
    private func translationCard(_ text: String, isUser: Bool) -> some View {
        HStack(alignment: .top, spacing: Self.translationMarkGap) {
            if isUser {
                translationText(text)
                translationMark(isUser: isUser)
            } else {
                translationMark(isUser: isUser)
                translationText(text)
            }
        }
        .padding(.horizontal, Self.translationPadding)
        .appPadding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.28), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// 引号方向跟着卡片走：老师在**左**用左引号，学员在**右**用右引号。
    private func translationMark(isUser: Bool) -> some View {
        Image(systemName: isUser ? "quote.closing" : "quote.opening")
            .appFont(9, weight: .semibold)
            .foregroundStyle(theme.accent)
            .appPadding(.top, 2)
    }

    private func translationText(_ text: String) -> some View {
        Text(text)
            .appFont(12, design: .rounded)
            .foregroundStyle(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 译文卡片装饰常量

    /// 译文卡片左右内边距。
    nonisolated static let translationPadding: CGFloat = 12
    /// 引号图标与文字之间的间距。
    nonisolated static let translationMarkGap: CGFloat = 6

    /// 翻译按钮：**按需翻译**的入口。
    ///
    /// 译文不是生成时就一起产出的 —— 那会让每条回复的 token 与延迟翻倍，
    /// 而绝大多数气泡学员根本不会点开。这里只负责「点一下才去要译文」，
    /// 结果有缓存，重复点开（含收起再展开）都是零成本。
    private struct TranslateButton: View {
        @Environment(\.forestTheme) private var theme

        let isOn: Bool
        let isLoading: Bool
        let action: () -> Void

        var body: some View {
            Button {
                action()
            } label: {
                Group {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                            .tint(theme.accent)
                    } else {
                        Image(systemName: "translate")
                            .appFont(11, weight: .semibold)
                            .foregroundStyle(isOn ? theme.accent : theme.secondaryText.opacity(0.75))
                    }
                }
                .frame(width: 20, height: 20)
                .background(Circle().fill(isOn ? theme.accent.opacity(0.16) : Color.clear))
            }
            .buttonStyle(.appPressable)
            .disabled(isLoading)
            .help(isOn ? "收起翻译" : "翻译成中文")
            .accessibilityLabel(isOn ? "收起翻译" : "翻译成中文")
        }
    }

    /// 「改一改」纠错卡片：原句 → 改正 + 一句话说明。
    private func correctionCard(_ correction: GrammarCorrection) -> some View {
        CorrectionCard(correction: correction, context: wordLookup) {
            // 「再练一次」：把**原句**放回输入框 —— 学员要练的是把这句重说对，
            // 而不是照抄改后句（改后句就在卡片上，划词即可细看）。
            input = correction.original
        }
    }

    /// 错题卡（「改一改」）。
    ///
    /// 独立成子视图的原因：展开状态是**每张卡自己的**（一个会话可能有多张卡），
    /// 放在 ChatView 根级就得维护「哪张卡展开了」的下标表。
    private struct CorrectionCard: View {
        @Environment(\.forestTheme) private var theme

        let correction: GrammarCorrection
        let context: WordLookupContext?
        let onPracticeAgain: () -> Void

        /// 解析说明默认收两行，点「展开」看全文（解释常比原句还长，全铺开会淹掉对话）。
        @State private var isExplanationExpanded = false

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "pencil.and.list.clipboard")
                        .appFont(10, weight: .semibold)
                    Text("改一改")
                        .appFont(10, weight: .bold, design: .rounded)
                }
                .foregroundStyle(theme.accent)

                Text(correction.original)
                    .appFont(12, design: .rounded)
                    .strikethrough()
                    .foregroundStyle(theme.secondaryText)
                // 「改一改」里的改后句是最值得划词的：它就是要学员记住的那一句。
                LookupText(
                    text: correction.corrected,
                    fontSize: 12,
                    weight: .medium,
                    color: theme.primaryText,
                    context: context
                )
                if !correction.explanation.isEmpty {
                    explanation
                }

                HStack(spacing: 6) {
                    Button {
                        onPracticeAgain()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("再练一次")
                        }
                        .appFont(10, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8)
                        .appPadding(.vertical, 4)
                        .background(Capsule().fill(theme.accent.opacity(0.1)))
                        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.appPressable)
                    .help("把原句放回输入框，重说一遍试试")
                    .accessibilityLabel("再练一次：\(correction.original)")

                    Spacer(minLength: 0)
                }
                .appPadding(.top, 2)
            }
            .padding(.horizontal, 12)
            .appPadding(.vertical, 8)
            .frame(maxWidth: 320, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.accent.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
            )
        }

        /// 解析说明：默认两行，长解释给「展开 / 收起」。
        @ViewBuilder
        private var explanation: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(correction.explanation)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(isExplanationExpanded ? nil : 2)
                if isExplanationExpanded || isExplanationTruncated {
                    Button {
                        isExplanationExpanded.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: isExplanationExpanded ? "chevron.up" : "chevron.down")
                            Text(isExplanationExpanded ? "收起" : "展开")
                        }
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                    }
                    .buttonStyle(.appPressable)
                    .accessibilityLabel(isExplanationExpanded ? "收起解析说明" : "展开解析说明")
                }
            }
        }

        /// 粗判「说明是不是被截断了」：超过约一行半的量（含标点）才值得给开关。
        /// SwiftUI 拿不到真实折行数，这里按字符数兜底 —— 太短的说明不给开关（免得点开没变化）。
        private var isExplanationTruncated: Bool { correction.explanation.count > 44 }
    }

    /// 朗读按钮：三态反馈（空闲 / 准备中 / 朗读中）。
    ///
    /// 本地 TTS 首句合成需要几秒，这段等待必须有可见反馈，否则用户会以为没点到；
    /// 有了「准备中」转圈 + 「朗读中」高亮，再点一次即可停止。
    private struct SpeakButton: View {
        @Environment(\.forestTheme) private var theme

        let text: String
        let phase: SpeechPhase
        let action: (String) -> Void
        var onStop: (() -> Void)? = nil

        /// 按下中（按住不放）。
        @State private var isPressing = false
        /// 点中后的余辉：松开仍保持约 0.6 秒的高亮。
        @State private var didFlash = false

        private var isActive: Bool { phase != .idle }
        private var isHighlighted: Bool { isPressing || didFlash || isActive }

        private var labelText: String {
            switch phase {
            case .idle: "听老师读"
            case .preparing: "准备中…"
            case .speaking: "朗读中"
            }
        }

        var body: some View {
            Button {
                flash()
                if isActive { onStop?() } else { action(text) }
            } label: {
                HStack(spacing: 4) {
                    icon
                    Text(labelText)
                }
                .appFont(10, weight: .semibold, design: .rounded)
                .foregroundStyle(isHighlighted ? theme.onAccentFill : theme.secondaryText)
                .padding(.horizontal, 8)
                .appPadding(.vertical, 4)
                .background(
                    Capsule().fill(isHighlighted ? theme.accentFill : theme.surfaceAlt)
                )
                .overlay(
                    Capsule().strokeBorder(theme.accent, lineWidth: isHighlighted ? 2 : 0)
                )
                .scaleEffect(isPressing ? 0.94 : 1)
            }
            .buttonStyle(.appPressable)
            // 按住期间即高亮（simultaneous 不吞掉点击）
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in withAnimation(.app(.press)) { isPressing = true } }
                    .onEnded { _ in withAnimation(.app(.press)) { isPressing = false } }
            )
            .appAnimation(.reveal, value: isHighlighted)
            .help(isActive ? "点击停止朗读" : "听老师朗读这句")
        }

        @ViewBuilder
        private var icon: some View {
            switch phase {
            case .idle:
                Image(systemName: isHighlighted ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
            case .preparing:
                // 首句正在合成：转圈表示「点了，正在准备」
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 11, height: 11)
                    .tint(.white)
            case .speaking:
                Image(systemName: "speaker.wave.3.fill")
            }
        }

        private func flash() {
            withAnimation(.app(.press)) { didFlash = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.6))
                withAnimation(.app(.reveal)) { didFlash = false }
            }
        }
    }

    /// 语速选择：与设置页共用同一套下拉控件（形状/描边/箭头都由 `ForestSelect` 保证）。
    private struct SpeechRateMenu: View {
        let rate: Double
        let onSelect: (Double) -> Void

        /// 控件宽度：按**最宽的档位标签**（`2.5×` / `0.5×`）实测得出。
        ///
        /// 2026-09-14 反馈「老师朗读的速率未正常显示」：原先写死 62pt，
        /// 而图标 + 内边距 + 间隙 + 箭头已占约 47pt，留给「2.5×」的不到 16pt，
        /// 值被压成「2…」。改成实测量宽后，字体或档位再变也不会重演。
        private static let chipWidth = ForestSelect<Double>.Metrics.compact
            .widthFitting(SpeechRate.allCases.map(\.label))

        var body: some View {
            ForestSelect(
                icon: "speedometer",
                selection: Binding(
                    get: { SpeechRate.nearest(to: rate).rawValue },
                    set: { onSelect($0) }
                ),
                options: SpeechRate.allCases.map {
                    ForestSelectOption(value: $0.rawValue, title: $0.label)
                },
                metrics: .compact,
                width: Self.chipWidth,
                help: "教师朗读语速（当前 \(SpeechRate.nearest(to: rate).label)）"
            )
        }
    }

    // MARK: - 输入区

    /// 对话模型被关闭时的常驻提示：用户一开始打字就能看到「该启动哪个模型」。
    private func modelStoppedBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .appFont(12)
                .foregroundStyle(.red)
            Text(message)
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .appPadding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .appPadding(.top, 10)
    }

    /// 语音输入失败提示（录音/识别出错时贴在输入框上方，可关闭）。
    /// 没有它时，点麦克风失败在对话区是**完全静默**的，用户只会觉得「没反应」。
    @ViewBuilder
    private var voiceErrorBanner: some View {
        if let voiceError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .appFont(11)
                    .foregroundStyle(theme.warning)
                Text(voiceError)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    onDismissVoiceError?()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(10, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.appPressable)
                .help("关闭提示")
            }
            .padding(.horizontal, 12)
            .appPadding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.warning.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.warning.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .appPadding(.top, 10)
            .transition(.opacity)
        }
    }

    /// 翻译失败提示（贴在输入框上方，可关闭）。
    @ViewBuilder
    private var translationErrorBanner: some View {
        if let translationError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .appFont(11)
                    .foregroundStyle(theme.warning)
                Text(translationError)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    onDismissTranslationError?()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(10, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.appPressable)
                .help("关闭提示")
            }
            .padding(.horizontal, 12)
            .appPadding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.warning.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.warning.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .appPadding(.top, 10)
            .transition(.opacity)
        }
    }

    /// 附件提示（超限 / 导入失败）：说清楚哪个文件为什么没加上，可关闭。
    @ViewBuilder
    private var attachmentErrorBanner: some View {
        if let attachmentNotice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .appFont(11)
                    .foregroundStyle(theme.warning)
                Text(attachmentNotice)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    onDismissAttachmentNotice?()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(10, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.appPressable)
                .help("关闭提示")
            }
            .padding(.horizontal, 12)
            .appPadding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.warning.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.warning.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .appPadding(.top, 10)
            .transition(.opacity)
        }
    }

    /// 「当前模型不读图」的提醒。
    ///
    /// 适配器对这类模型的降级是「把图片换成一句『附了一张图 xxx.png』」——**合理但静默**：
    /// 用户以为老师看见了照片，其实只看见文件名。带图之前先说实话。
    @ViewBuilder
    private var visionFallbackHint: some View {
        if !llmSupportsVision, pendingAttachments.contains(where: { $0.isImage }) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "eye.slash.fill")
                    .appFont(10)
                    .foregroundStyle(theme.warning)
                Text("当前模型不读图：这些图片会以文件名告诉老师。想让它真的看图，去设置里换一个声明了视觉能力的模型。")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    /// 附件下载成功的回执。与「导入失败」共用一套外观骨架，但语气是**成功**：
    /// 下载是个没有界面变化的动作（文件落到了用户自己挑的目录里），不给回执，
    /// 用户只能去 Finder 里翻，翻不到就会以为没成功、再点一次。
    @ViewBuilder
    private var attachmentSavedBanner: some View {
        if let attachmentSaveNotice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .appFont(11)
                    .foregroundStyle(.green)
                Text(attachmentSaveNotice)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    onDismissAttachmentSaveNotice?()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(10, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.appPressable)
                .help("关闭回执")
            }
            .padding(.horizontal, 12)
            .appPadding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.green.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .appPadding(.top, 10)
            .transition(.opacity)
        }
    }

    // MARK: - 输入区（整体布局参考主流 Agent 的输入区）

    /// 输入区：**一个圆角矩形，上下两段**。
    ///
    /// ```
    /// ┌──────────────────────────────────────────────┐
    /// │ [附件][附件]              ← 有添加项时才出现    │
    /// ├──────────────────────────────────────────────┤ ← 浅灰分隔线
    /// │ 输入框（1…5 行，超过可滚动）                    │
    /// ├──────────────────────────────────────────────┤ ← 浅灰分隔线
    /// │ [+]            「本地模型 · qwen3:8b」◎ 🎤 ➤  │
    /// └──────────────────────────────────────────────┘
    /// ```
    ///
    /// 为什么把添加项放进**同一个矩形内部**而不是浮在上方：
    /// 浮在上方时「粘在输入框上的那几块」与「输入框本身」是两套边界，
    /// 用户看不出哪些内容会跟着这条消息一起发出去。同一个圆角框 + 一条浅灰分隔线，
    /// 「这些会一起发」这件事一眼可见；矩形上边框也随添加项自动上抬（需求 3）。
    private var composer: some View {
        VStack(spacing: 0) {
            if !pendingAttachments.isEmpty {
                attachmentTray
                composerSeparator
            }
            inputField
            composerSeparator
            composerToolbar
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .appPadding(.top, 10)
        .appPadding(.bottom, 10)
    }

    /// 上下两段之间的浅灰分隔线（需求 3：添加项与输入区之间要有线以示区分）。
    ///
    /// ⚠️ 只用「隐约看得见」的浓度：直接用 `theme.divider` 全浓度在浅色主题下太抢，
    /// 一条实线会把输入框切成两个框、看不出是一个整体。降到约一半浓度即可
    /// （需求：提高透明度，肉眼能区分上下段就行，不要太明显）。
    /// ⚠️ 两端各留一小段渐变收进框线：实色线生硬地顶到圆角边框会「撞线」，
    /// 渐变收尾才像从左右框线上自然长出来（需求：两端做很短的透明渐变连接到框线）。
    private var composerSeparator: some View {
        // 用同一个颜色的「零透明度」而不是 `.clear`（黑色零透明）：后者的中间过渡
        // 会偏暗，渐变段看起来比实线段脏一点。
        let line = theme.divider.opacity(0.5)
        return HStack(spacing: 0) {
            LinearGradient(
                colors: [line.opacity(0), line],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Self.separatorFadeLength)
            Rectangle().fill(line).frame(height: 1)
            LinearGradient(
                colors: [line, line.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Self.separatorFadeLength)
        }
        .frame(height: 1)
    }

    /// 分隔线两端的渐变长度（pt）。用**固定值**而不是比例：需求要的是「很短」，
    /// 按比例做会让宽窗口上的渐变拖成一大段，失去「收到框线上」的意思。
    private static let separatorFadeLength: CGFloat = 18

    /// 待发附件：贴在矩形**顶部**，一行放不下时自动换行（不再横向滚动）。
    ///
    /// 原来用横向 `ScrollView`：chip 一多就被窗口右边裁掉，用户看不到「还有几个」，
    /// 也点不到被裁掉那个的移除按钮。换成流式换行后，「一共选了几个」一眼可见。
    /// 行划分规则见 `AIDomain/AttachmentTrayLayout`（纯函数），
    /// `FlowLayout` 只负责把行划分落成位置。
    private var attachmentTray: some View {
        VStack(alignment: .leading, spacing: 7) {
            visionFallbackHint
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(pendingAttachments) { attachment in
                    AttachmentChip(
                        attachment: attachment,
                        fileURL: attachmentLocation?(attachment)
                    ) {
                        onRemoveAttachment?(attachment.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 一次清空。**两个及以上才出现**：只剩一个时 chip 自己那个 × 就够，
            // 再摆一个「清空」是纯噪音 —— 两个按钮做同一件事只会让人犹豫点哪个。
            if pendingAttachments.count > 1, let onClearAttachments {
                HStack {
                    Spacer(minLength: 0)
                    Button(action: onClearAttachments) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .appFont(9)
                            Text("全部移除")
                                .appFont(10, weight: .semibold, design: .rounded)
                        }
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(theme.surfaceAlt))
                        .overlay(Capsule().strokeBorder(theme.divider, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.appPressable)
                    .help("把 \(pendingAttachments.count) 个待发附件全部移除")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .appPadding(.top, 12)
        .appPadding(.bottom, 10)
    }

    /// 下排：功能按钮 + 信息显示。
    ///
    /// 布局（需求）：左边「+」，信息显示**正中间**，右侧麦克风 + 发送。
    /// ⚠️ 三个按钮**共用同一个外观修饰器** `ComposerButtonChrome`：
    /// 「形状、大小统一」因此是结构上被保证的，而不是靠改代码时记得同步三处。
    private var composerToolbar: some View {
        ZStack {
            // 信息显示：当前生效的 Provider · 模型 + 上下文占用圆环，**正中间**。
            //
            // 为什么用 ZStack 而不是「两侧各加一个 Spacer」：左右两组按钮宽度不等
            // （左 1 个、右 2 个），Spacer 只能让信息落在「剩余空间的中心」，
            // 实测会明显偏左；ZStack 让它相对**整条栏**居中，与两侧宽度无关。
            // 放在底层：按钮那层在上，重叠时点击优先给按钮，而圆环自身仍可悬停。
            if !contextSummary.isEmpty {
                HStack(spacing: 6) {
                    Text(contextSummary)
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ContextGauge(
                        used: chat.estimatedContextTokens,
                        limit: contextLimit,
                        tooltip: contextDescription,
                        track: theme.divider
                    )
                }
                // 限宽：窗口很窄时信息只截断自己，不会把两侧功能按钮挤出去。
                .frame(maxWidth: 280)
            }

            HStack(spacing: 8) {
                attachButton
                Spacer(minLength: 8)
                // 「取消」：紧跟麦克风左侧 —— 语义相邻（都是「这段语音」的操作），
                // 且不与左侧「+」抢位置。
                // ⚠️ **录音中与识别中都要出现**：识别开始之后用户仍然可能「这段我不要了」，
                // 而识别往往要等好几秒（本地 whisper 更久）。只在录音中给出口，
                // 等于把用户锁在「必须等它识别完、再把字删掉」的流程里。
                if voicePhase != .idle { cancelVoiceButton }
                micButton
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .appPadding(.vertical, 8)
    }

    /// 发送 / 停止。与左侧按钮**同形状同大小**，只靠「实心强调色」表达主操作。
    private var sendButton: some View {
        Button {
            chat.isGenerating ? chat.cancel() : send()
        } label: {
            Image(systemName: chat.isGenerating ? "stop.fill" : "paperplane.fill")
                .appFont(13, weight: .semibold)
                .modifier(ComposerButtonChrome(
                    tint: chat.isGenerating ? .white : theme.onAccentFill,
                    fill: chat.isGenerating ? Color.red.opacity(0.85) : theme.accentFill,
                    border: .clear
                ))
        }
        .buttonStyle(.appPressable)
        .disabled(chat.isGenerating ? false : !canSend)
        // ⌘↩ 发送。
        // ⚠️ 生成中**不给**快捷键：此时这颗按钮是「停止」，把 ⌘↩ 绑成中止只是让人误触
        // （输入框是多行控件，回车本身不会发送，所以这里不会与换行打架）。
        .keyboardShortcut(
            (canSend && !chat.isGenerating)
                ? KeyboardShortcut(.return, modifiers: .command)
                : nil
        )
        .help(sendButtonHelp)
        // VoiceOver：这颗粒按钮的内容是图标，读屏读不出「发送 / 停止」的区别 ——
        // 而它恰恰是**同一个控件在两种语义之间切换**，不读出来等于没有出口。
        .accessibilityLabel(chat.isGenerating ? "停止生成" : "发送")
    }

    private var sendButtonHelp: String {
        if chat.isGenerating { return "停止" }
        if modelStoppedNotice != nil { return "请先启动对话模型" }
        return "发送（⌘↩）"
    }

    /// 输入区下排按钮的统一外观：**同一形状（圆）、同一尺寸、同一描边**。
    ///
    /// 需求要求「添加文件」与「说话」两个按钮外观一致、下排功能按钮形状大小统一。
    /// 把它做成一个修饰器而不是各自写一遍 `frame + background + overlay`，
    /// 是为了让这件事成为**结构性约束** —— 三处不可能再各自漂移。
    private struct ComposerButtonChrome: ViewModifier {

        /// 按钮直径：下排所有按钮共用这一个值。
        static let side: CGFloat = 32

        var tint: Color
        var fill: Color
        var border: Color

        func body(content: Content) -> some View {
            content
                .foregroundStyle(tint)
                .frame(width: Self.side, height: Self.side)
                .background(Circle().fill(fill))
                .overlay(Circle().strokeBorder(border, lineWidth: 1))
                // 圆形按钮的点击区要显式声明：默认的矩形命中区会与相邻按钮抢点击。
                .contentShape(Circle())
        }
    }

    /// 「+」添加附件（图片 / 视频 / 文件）。
    ///
    /// 用菜单而不是一个「添加任意文件」的按钮：macOS 的文件面板按类型过滤要显式声明，
    /// 让用户先说明「我要加的是哪一类」比让他从一堆不可选的文件里找要快得多
    /// （这也是主流 Agent 输入框的做法）。
    ///
    /// ⚠️ **菜单不能交给 SwiftUI `Menu` 弹**（2026-09-14 与 ForestSelect 同一批修）：
    /// 它的 label 必须近乎透明（外观层在 ZStack 下层自绘），而透明 label 的
    /// `Menu` 命中区退化成 6×14 ——「+」看着有 34×34，实际只有中间一小条能点。
    /// 现在弹菜单的活交给 `MenuPopUpHitArea`（与 ForestSelect 同一份实现），
    /// `isCircular: true` 让命中范围与圆形按钮重合，不抢旁边麦克风的点击。
    private var attachButton: some View {
        ZStack {
            // 外观：与麦克风共用同一份修饰器 —— 一致性因此是结构性的。
            Color.clear.modifier(ComposerButtonChrome(
                tint: theme.accent,
                fill: theme.surfaceAlt,
                border: theme.divider
            ))
            .allowsHitTesting(false)

            Group {
                if isImportingAttachments {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .appFont(14, weight: .semibold)
                        .foregroundStyle(theme.accent)
                }
            }
            .allowsHitTesting(false)

            if !isImportingAttachments {
                MenuPopUpHitArea(
                    titles: ["添加图片", "添加视频", "添加文件"],
                    selectedIndex: nil,
                    isEnabled: !isImportingAttachments,
                    accessibilityTitle: "添加附件",
                    tooltip: "添加图片 / 视频 / 文件",
                    isCircular: true,
                    onSelect: { index in
                        switch index {
                        case 0: pickAttachments(kind: .image)
                        case 1: pickAttachments(kind: .video)
                        default: pickAttachments(kind: nil)
                        }
                    }
                )
                .frame(width: ComposerButtonChrome.side, height: ComposerButtonChrome.side)
            }
        }
        .fixedSize()
        .disabled(isImportingAttachments)
        .help("添加图片 / 视频 / 文件")
    }

    /// 弹系统文件面板并把结果交给外部导入。
    private func pickAttachments(kind: ChatAttachment.Kind?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "添加"
        switch kind {
        case .image:
            panel.message = "选择要发送的图片（最多 \(AttachmentPolicy.maxPerMessage) 个）"
            panel.allowedContentTypes = AttachmentClassifier.imageContentTypes.compactMap {
                UTType(filenameExtension: $0)
            }
        case .video:
            panel.message = "选择要发送的视频（最多 \(AttachmentPolicy.maxPerMessage) 个）"
            panel.allowedContentTypes = AttachmentClassifier.videoContentTypes.compactMap {
                UTType(filenameExtension: $0)
            }
        default:
            panel.message = "选择要发送的文件（最多 \(AttachmentPolicy.maxPerMessage) 个）"
            panel.allowedContentTypes = []
        }
        guard panel.runModal() == .OK else { return }
        onAddAttachments?(panel.urls)
    }

    /// 输入框：空着的时候用浅灰字**轮换**展示预设提问（点发送即发送当前这一条）。
    ///
    /// 多行规则见 `MultilineComposerField` / `ComposerMetrics`：
    /// 固定行宽、超宽换行、向上拓宽、最多 5 行，超过则只显示最后 5 行 + 下拉条
    /// （未超过 5 行时**不显示**下拉条）。
    ///
    /// ⚠️ 这里**不再自带底色与描边**：它已经是 `composer` 圆角矩形的上段，
    /// 再画一层框就会出现「框里套框」，上下两段也分不开了。
    private var inputField: some View {
        ZStack(alignment: .topLeading) {
            MultilineComposerField(
                text: $input,
                measuredHeight: $inputHeight,
                isFocused: $isInputFocused,
                textColor: NSColor(theme.primaryText),
                insertionColor: NSColor(theme.accent),
                onSubmit: { send() }
            )
            // ⚠️ frame 的高度就是**滚动的可视区**高度，必须与上报值**一模一样**：
            // 曾经在这里额外 +20（想给文字留上下呼吸位），结果可视区比封顶高 20pt，
            // 「最多 5 行」实际显示成 6 行 —— 呼吸位由外层 `.appPadding(.vertical, 10)` 给，
            // 不能再叠一层，否则封顶形同虚设。
            .frame(height: max(inputHeight, ComposerMetrics.lineHeight(fontSize: 14)))
            .padding(.horizontal, 14)
            .appPadding(.vertical, 10)

            // 轮换占位提示（考试模式不显示：考场上出现一句现成的话，
            // 学员会以为把那句念出来就算答过了 —— 口径与原 `currentStarterQuestion` 一致）。
            if input.isEmpty, exam == nil {
                RollingStarterQuestionView(rotator: rotator, isGenerating: chat.isGenerating)
                    .padding(.leading, 14)
                    .padding(.trailing, 20)
                    .appPadding(.top, 10)
                    .allowsHitTesting(false)
            }

            // 考试模式：输入框里写的是「这一问的要求」，不是一句可以照念的话。
            if input.isEmpty, let exam {
                Text(Self.examComposerHint(exam))
                    .appFont(13, design: .rounded)
                    .foregroundStyle(theme.secondaryText.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 14)
                    .padding(.trailing, 20)
                    .appPadding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 能不能发送：模型被关闭时一律不行；否则「有手打内容」「有待发附件」「有预设提问」都行。
    ///
    /// ⚠️ 这里用 **index-free** 判断（exam == nil 且有预设即 true），不读轮换下标：
    /// `canSend` 在父 body 里求值，读了下标父级就会订阅它，状态下沉就白做了。
    private var canSend: Bool {
        guard modelStoppedNotice == nil else { return false }
        if !pendingAttachments.isEmpty { return true }
        if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return exam == nil && !starterQuestions.isEmpty
    }

    /// 这一整段语音不要了：不识别、不填进输入框（识别已经开始的，结果作废）。
    ///
    /// 为什么单开一颗：麦克风按钮的语义是「停止并**识别**」，所以「我刚才是说错了」
    /// 原本没有出口，只能让它识别完、再把输入框里的字删掉。
    ///
    /// ⚠️ 取消要把输入框退回**本段语音之前**的样子（`voiceMerge.prefix`）：
    /// 流式结果已经往里面写过字了。但**用户手改的部分要留着** —— 他只说「这段语音不要」，
    /// 没说「把我打的字也删掉」。所以退的是「前缀」，而不是整段复原成录音前的快照。
    private var cancelVoiceButton: some View {
        Button {
            stopMergingVoice()
            onCancelVoiceInput?()
        } label: {
            Image(systemName: "xmark")
                .appFont(12, weight: .semibold)
                .modifier(ComposerButtonChrome(
                    tint: theme.secondaryText,
                    fill: theme.surfaceAlt,
                    border: theme.divider
                ))
        }
        .buttonStyle(.appPressable)
        .help(voicePhase.isBusy ? "放弃这次识别（已识别的结果不会填进输入框）" : "取消这次录音（不识别、不填入输入框）")
        .accessibilityLabel("取消语音输入")
    }

    /// 结束本段语音的写入并复原输入框：识别结果不再回流，语音段本身被摘掉。
    private func stopMergingVoice() {
        isMergingVoice = false
        input = voiceMerge.prefix
        voiceMerge = VoiceMergeState()
    }

    /// 麦克风按钮：点击说话 → 录音期间流式出字 → 再点识别并纠正拼写后定稿。
    ///
    /// ⚠️ 三件事**全部由 `voicePhase` 决定**（`primaryAction`）：
    /// 以前只有「录音中 / 否则」两个分支，识别期间 `isRecording` 仍为 true
    /// 而在途的是识别 —— 用户点一下想「停」，落进的却是「停止并再识别一次」，
    /// 第二次 `recorder.stop()` 拿到空音频，报出假的「没有录到声音」。
    /// 现在识别中点击的语义是**放弃这次识别**（服务端请求掐不断，但结果可以作废）。
    private var micButton: some View {
        Button {
            switch voicePhase.primaryAction {
            case .start:
                // 记住本段语音之前的内容：流式结果只追加在它后面。
                voiceMerge = VoiceMergeState(prefix: input)
                isMergingVoice = true
                Task { @MainActor in await onMicStart?() }
            case .stopAndTranscribe:
                // 先断开流式回流，随后**定稿文本走同一套合并规则**：
                // 用户在录音期间改过的字不会被这一下抹掉。
                isMergingVoice = false
                Task { @MainActor in
                    if let text = await onMicStop?(), !text.isEmpty {
                        applyVoiceText(text)
                    }
                    isInputFocused = true
                }
            case .cancelTranscribe:
                stopMergingVoice()
                onCancelVoiceInput?()
            }
        } label: {
            Group {
                if voicePhase.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: voicePhase.isCapturing ? "waveform" : "mic.fill")
                        .appFont(14, weight: .semibold)
                        // 录音中波形做迭代变色（#358）：不用 ProgressView 也看得出「正在采」。
                        .symbolEffect(.variableColor.iterative, options: .repeating,
                                      isActive: voicePhase.isCapturing)
                }
            }
            // ⚠️ 尺寸/形状/描边全部来自 `ComposerButtonChrome`（与「+」同一份）：
            // 需求要求这两个按钮外观一致，各自写一套样式迟早会漂。
            .modifier(ComposerButtonChrome(
                tint: voicePhase == .idle ? theme.accent : Color.red,
                fill: voicePhase == .idle ? theme.surfaceAlt : Color.red.opacity(0.12),
                border: voicePhase == .idle ? theme.divider : Color.red.opacity(0.5)
            ))
        }
        .buttonStyle(.appPressable)
        .help(Self.micButtonHelp(voicePhase))
        .accessibilityLabel(Self.micButtonAccessibilityLabel(voicePhase))
    }

    /// 主按钮的悬停说明（按阶段说清「点下去会发生什么」）。
    ///
    /// `nonisolated`：纯查表、不碰任何视图状态，却会被 `View` 的 `@MainActor` 连坐成
    /// 主 actor 隔离 —— 那样测试与非隔离上下文都用不了（见 MEMORY 的标准修法①）。
    nonisolated static func micButtonHelp(_ phase: VoiceInputPhase) -> String {
        switch phase {
        case .idle: return "点击说话"
        case .recording: return "停止并识别"
        case .transcribing: return "放弃这次识别"
        }
    }

    /// VoiceOver 文案：识别中这颗按钮读成「取消录音」会误导 —— 那时麦克风早就关了。
    nonisolated static func micButtonAccessibilityLabel(_ phase: VoiceInputPhase) -> String {
        switch phase {
        case .idle: return "语音输入"
        case .recording: return "停止录音并识别"
        case .transcribing: return "放弃这次识别"
        }
    }

    // MARK: - 输入区信息显示

    /// 「本地模型 · qwen3:8b」
    private var contextSummary: String {
        var parts: [String] = []
        if !providerLabel.isEmpty { parts.append(providerLabel) }
        if let modelName, !modelName.isEmpty { parts.append(modelName) }
        return parts.joined(separator: " · ")
    }

    private var contextDescription: String {
        let used = chat.estimatedContextTokens
        if let contextLimit, contextLimit > 0 {
            let fraction = min(Double(used) / Double(contextLimit), 1)
            return "上下文 ≈\(Self.tokenCount(used)) / \(Self.tokenCount(contextLimit))（\(Int(fraction * 100))%）"
        }
        return "上下文 ≈\(Self.tokenCount(used)) tokens"
    }

    /// token 数缩写：1234 → 1.2k。
    public nonisolated static func tokenCount(_ tokens: Int) -> String {
        tokens >= 1000 ? String(format: "%.1fk", Double(tokens) / 1000) : "\(tokens)"
    }

    /// 考场态输入框的占位提示：说清「第几问、要答多长」，不提供可以照念的句子。
    static func examComposerHint(_ exam: ExamBarModel) -> String {
        if exam.minimumWords > 0 {
            return "第 \(exam.questionNumber)/\(exam.totalQuestions) 问 · 至少 \(exam.minimumWords) 词，答完自动进下一题"
        }
        return "第 \(exam.questionNumber)/\(exam.totalQuestions) 问 · 答完自动进下一题"
    }

    private func send() {
        // 生成中按回车：**什么都不做**（输入原样留着）。
        // 这时 `ChatService.send` 会被自己的 `guard !isGenerating` 挡下，而下面那句
        // `input = ""` 已经执行 —— 用户打的那句就这么没了，还以为是发失败。
        // 那颗按钮此刻的语义是「停止」，回车不该替它决定。
        // ⚠️ 例外必须放行：老师正在**打招呼**时是可以抢话的（`ChatService.send` 专门
        // 撤掉招呼来接这一句，注释写着「绝不能让这句话石沉大海」），而那也是一次生成。
        guard !chat.isGenerating || chat.isGreeting else { return }
        // 对话模型被关闭时，输入不丢、也不发出去；用户按提示启动模型即可。
        guard modelStoppedNotice == nil else { return }
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空着点发送 = 发送当前轮换到的预设提问（浅灰那条）；只带附件不带文字时不再兜底提问。
        // ⚠️ 在 action 闭包里读 rotator（闭包不订阅）—— 取的是「此刻」轮换到的那条。
        let text: String
        if !typed.isEmpty {
            text = typed
        } else if pendingAttachments.isEmpty {
            text = exam == nil ? (rotator.current ?? "") : ""
        } else {
            text = ""
        }
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        // 还在录音 / 识别时点发送：先把这一段语音收掉（不识别、不填入）。
        // ⚠️ 必须**停麦克风**，不能只断开回流：以前这里只清 `isMergingVoice`，
        // 麦克风继续开着，用户接着说的话会被录进一个已经发出去的消息里，
        // 而且那颗主按钮还显示「录音中」——他以为自己没发出去。
        if voicePhase != .idle {
            stopMergingVoice()
            onCancelVoiceInput?()
        }
        // 手打与语音一视同仁：发出去后输入框彻底清空。
        // 同时丢弃本段语音的位置记忆 —— 否则「还录着音就点发送」时，
        // 下一轮流式结果会按旧前缀把内容原样填回来。
        input = ""
        isMergingVoice = false
        voiceMerge = VoiceMergeState()
        // 发送（含附件）收在 AppState 里：视图不自己拼「取附件 + 清空」的顺序，
        // 那个顺序漏一步就会「下一句把同一张图重发一遍」。
        if let onSend {
            onSend(text)
        } else {
            chat.send(text)
        }
        isInputFocused = true
    }
}

// MARK: - 思考过程折叠面板

/// 推理模型的思考过程：卡片内嵌面板，箭头切换展开/收起（默认展开）。
/// 高度自适应：最多露出 6 行（超出可滚动回看全部），不足 6 行时按实际内容收窄。
/// 背景为半透明灰（比原先更透，避免遮挡底层内容）。
struct ThinkingPanel: View {

    @Environment(\.forestTheme) private var theme
    let reasoning: String
    /// 流式阶段为 true：内容持续增长，自动吸底显示最新思考。
    let isStreaming: Bool

    @State private var isExpanded = true
    /// 实测正文高度（含内边距）。
    @State private var contentHeight: CGFloat = 0
    /// 实测「6 行」参考高度（含内边距）；未测得前用兜底值。
    @State private var sixLineHeight: CGFloat = 0

    /// 最多显示的行数。
    private let maxLines = 6
    /// 字体与内边距（正文与参考测量必须一致）。
    private let bodyFontSize: CGFloat = 11
    private let horizontalPadding: CGFloat = 10
    private let bottomPadding: CGFloat = 8
    /// 参考高度尚未测得时的兜底（约 6 行）。
    private let fallbackPanelHeight: CGFloat = 96

    /// 面板高度：内容不足 6 行按实际高度，超出则封顶 6 行并可滚动。
    private var panelHeight: CGFloat {
        let cap = sixLineHeight > 0 ? sixLineHeight : fallbackPanelHeight
        guard contentHeight > 0 else { return cap }
        return min(contentHeight, cap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.app(.reveal)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .appFont(9, weight: .bold)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(isStreaming ? "正在思考…" : "思考过程")
                        .appFont(10, weight: .semibold, design: .rounded)
                    Spacer()
                }
                .foregroundStyle(theme.secondaryText)
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .appPadding(.vertical, 6)
            }
            .buttonStyle(.appPressable)

            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(reasoning)
                            .appFont(bodyFontSize, design: .rounded)
                            .foregroundStyle(theme.primaryText.opacity(0.82))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.bottom, bottomPadding)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                            .id("thinking-bottom")
                    }
                    .frame(height: panelHeight)
                    .onChange(of: reasoning) { _, _ in
                        guard isStreaming else { return }
                        proxy.scrollTo("thinking-bottom", anchor: .bottom)
                    }
                    .onAppear {
                        proxy.scrollTo("thinking-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .background(alignment: .topLeading) {
            // 隐藏的 6 行参考文本：仅用于实测「6 行」高度上限（不参与布局）。
            Text(String(repeating: "\n", count: maxLines - 1) + "M")
                .appFont(bodyFontSize, design: .rounded)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, bottomPadding)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sixLineHeight = $0 }
                .hidden()
                .accessibilityHidden(true)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.divider.opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - 上下文占用圆环

/// 圆环仪表：淡灰整圈 = 模型上下文窗口，白色弧 = 已用占比；悬停显示文字气泡。
struct ContextGauge: View {

    let used: Int
    let limit: Int?
    let tooltip: String
    let track: Color

    @State private var isHovering = false

    private var fraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(Double(used) / Double(limit), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, lineWidth: 3)
            if limit != nil {
                Circle()
                    .trim(from: 0, to: max(fraction, 0.02))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 13, height: 13)
        // 悬浮详情在圆环**上方**弹出：状态栏贴着窗口底边，向下弹会被裁出窗外（这就是之前看不到的原因）
        .overlay(alignment: .top) {
            if isHovering {
                SpeechBubble(text: tooltip, maxWidth: 220)
                    .fixedSize()
                    .offset(y: -34)
                    .zIndex(10)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Circle().inset(by: -8))
        .onHover { hovering in
            withAnimation(.app(.press)) { isHovering = hovering }
        }
        .help(tooltip)
    }
}

struct TypingDots: View {
    let color: Color
    @State private var phase = 0

    @Environment(\.appMotion) private var motion

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .offset(y: phase == index ? -4 : 0)
            }
        }
        .padding(.horizontal, 14)
        .appPadding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.10)))
        // ⚠️ 走 `Timer.publish(...).autoconnect()` + `onReceive`，不用 `Timer.scheduledTimer`：
        // 后者被 RunLoop 一直持有、闭包还捕获着视图，而这里既没保存引用也没在
        // `onDisappear` 里 invalidate —— 每出现一次「正在输入」就**永久多一个** 0.35 秒定时器，
        // 应用久开之后定时器越攒越多，闲着也在周期性叫醒主线程。
        // `autoconnect` 跟着视图生命周期自动断开，不需要谁记得去取消。
        .onReceive(Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()) { _ in
            // 「减弱动态效果」下三点**静止**：这一排点本身已经把「正在等待」说清楚了，
            // 反复跳动只是修饰 —— 而它偏偏是等待期间唯一一直动的东西（最刺眼的一个）。
            // 静止不等于没画出来，三个点仍在原位。
            guard !motion.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.25)) { phase = (phase + 1) % 3 }
        }
    }
}

// MARK: - 预设提问轮换（状态下沉）

/// 预设提问的轮换状态（#440 优化）。
///
/// 轮换下标是**输入框占位提示**的私有状态 —— 以前放在 ChatView 根级 `@State`，
/// 每 3.4 秒一跳就把整个对话视图的 body 全部重算一遍（长会话里每一跳都是一次
/// 全量 diff）。`@Observable` 的细粒度订阅让**只有读下标的占位子视图**跟着刷新，
/// 父视图的 body 不再因为占位提示换了一句话而重算。
///
/// ⚠️ 父视图只有 `send()` 的 action 闭包读 `current`（闭包不订阅）；
/// `canSend` 用 `exam == nil && !starterQuestions.isEmpty` 的 index-free 判断，
/// 全程不给父级制造下标订阅。
@MainActor
@Observable
final class StarterQuestionRotator {
    private(set) var index: Int = 0
    private(set) var questions: [String] = []

    /// 当前轮换到的那条（没有预设时 nil）。
    var current: String? {
        guard !questions.isEmpty else { return nil }
        return questions[index % questions.count]
    }

    /// 换一批预设提问（内容没变就不动，避免把轮换归零）。
    func update(questions: [String]) {
        guard self.questions != questions else { return }
        self.questions = questions
        index = 0
    }

    /// 时钟一跳：换下一条。守卫与原根级 Timer 一致——
    /// 输入框空着、没在等回复、预设多于一条才动。
    func advance(isInputEmpty: Bool, isGenerating: Bool) {
        guard isInputEmpty, questions.count > 1, !isGenerating else { return }
        index = (index + 1) % questions.count
    }
}

/// 输入框里的轮换占位提示（浅灰那条）。
///
/// 自己持有轮换时钟：这个子视图只在「输入框为空且不在考试」时到场，
/// 时钟的生命周期天然跟着占位提示走 —— 输入框一旦有字，时钟随视图一起消失。
private struct RollingStarterQuestionView: View {
    let rotator: StarterQuestionRotator
    let isGenerating: Bool

    /// 每条预设提问停留的秒数。
    private let rotationInterval: Double = 3.4

    @Environment(\.forestTheme) private var theme

    var body: some View {
        Group {
            if let hint = rotator.current {
                Text(hint)
                    .appFont(14, design: .rounded)
                    .foregroundStyle(theme.secondaryText.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(hint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 20)
                    .clipped()
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            }
        }
        // 轮换动画归子视图：父级不再把下标当 animation value（读了就会订阅）。
        .appAnimation(.panel, value: rotator.index)
        .onReceive(Timer.publish(every: rotationInterval, on: .main, in: .common).autoconnect()) { _ in
            rotator.advance(isInputEmpty: true, isGenerating: isGenerating)
        }
    }
}
