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
    // 语音（第 17/18 步）
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var autoSpeak: Bool = false
    /// 点击麦克风：开始录音 / 停止并识别。
    var onMicStart: (() async -> Void)? = nil
    var onMicStop: (() async -> String?)? = nil
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

    // 附件（第 3 项需求：图片 / 视频 / 文件）
    /// 已选好、还没发出去的附件。
    var pendingAttachments: [ChatAttachment] = []
    /// 附件提示（超限 / 导入失败），显示在输入框上方，可关闭。
    var attachmentNotice: String? = nil
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
    /// 发送（带附件）：发送动作收在 AppState 里，视图不自己拼「取附件 + 清空」的顺序。
    var onSend: ((String) -> Void)? = nil

    @State private var input: String = ""
    /// 输入框当前高度（由 `MultilineComposerField` 按真实排版量出并夹到 5 行以内）。
    @State private var inputHeight: CGFloat = 0
    @State private var isInputFocused: Bool = false
    /// 本次录音开始前输入框里的内容：流式识别结果拼在它后面，绝不覆盖用户手打的字。
    @State private var voiceBase: String = ""
    /// 当前轮换到的预设提问下标。
    @State private var questionIndex: Int = 0
    /// 录音中且尚未发送：只有这段时间才允许流式结果往输入框里写。
    /// （发送后必须彻底断开，否则正在录音时发送会被下一轮流式结果原样填回来。）
    @State private var isMergingVoice = false
    /// 聊天区是否处于「上翻」状态（距底部超过阈值）——
    /// 决定「回到底部」按钮与输入框上方的虚化是否出现。
    @State private var isScrolledUp = false

    /// 每条预设提问停留的秒数。
    private let rotationInterval: Double = 3.4

    /// 相隔超过该时长的两条消息之间才显示时间戳。
    private let timestampGap: TimeInterval = 5 * 60

    public init(chat: ChatService, modelName: String?, health: ProviderHealth,
                providerLabel: String = "", contextLimit: Int? = nil, reasoningLabel: String? = nil,
                teacherKind: AnimalKind = .panda, studentKind: AnimalKind = .bear,
                isRecording: Bool = false, isTranscribing: Bool = false,
                autoSpeak: Bool = false,
                onMicStart: (() async -> Void)? = nil,
                onMicStop: (() async -> String?)? = nil,
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
                pendingAttachments: [ChatAttachment] = [],
                attachmentNotice: String? = nil,
                isImportingAttachments: Bool = false,
                onAddAttachments: (([URL]) -> Void)? = nil,
                onRemoveAttachment: ((UUID) -> Void)? = nil,
                onDownloadAttachment: ((ChatAttachment) -> Void)? = nil,
                attachmentLocation: ((ChatAttachment) -> URL)? = nil,
                onDismissAttachmentNotice: (() -> Void)? = nil,
                onSend: ((String) -> Void)? = nil) {
        self.chat = chat
        self.modelName = modelName
        self.health = health
        self.providerLabel = providerLabel
        self.contextLimit = contextLimit
        self.reasoningLabel = reasoningLabel
        self.teacherKind = teacherKind
        self.studentKind = studentKind
        self.isRecording = isRecording
        self.isTranscribing = isTranscribing
        self.autoSpeak = autoSpeak
        self.onMicStart = onMicStart
        self.onMicStop = onMicStop
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
        self.pendingAttachments = pendingAttachments
        self.attachmentNotice = attachmentNotice
        self.isImportingAttachments = isImportingAttachments
        self.onAddAttachments = onAddAttachments
        self.onRemoveAttachment = onRemoveAttachment
        self.onDownloadAttachment = onDownloadAttachment
        self.attachmentLocation = attachmentLocation
        self.onDismissAttachmentNotice = onDismissAttachmentNotice
        self.onSend = onSend
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            if let scenario {
                scenarioStrip(scenario)
                Divider().overlay(theme.divider)
            }
            messageArea
            if let modelStoppedNotice {
                modelStoppedBanner(modelStoppedNotice)
            }
            voiceErrorBanner
            translationErrorBanner
            attachmentErrorBanner
            composer
        }
        .background(theme.surfaceAlt.opacity(0.35))
        // 教师回复完成后自动朗读（设置里可关）；挂在最外层，空态切换分支也不丢事件。
        .onChange(of: chat.messages.count) { _, count in
            if autoSpeak, count > 0, let last = chat.messages.last, last.role == .assistant {
                onSpeakTap?(last.content)
            }
        }
        // 流式语音输入：录音期间识别结果实时写入输入框（只替换「本次语音」那一段，
        // 用户手打的内容原样保留）。
        .onChange(of: voiceTranscript) { _, text in
            guard let text, isRecording, isMergingVoice else { return }
            input = Self.mergedInput(base: voiceBase, voice: text)
        }
        // 预设提问轮换：只在输入框为空、且没有正在等回复时滚动。
        .onReceive(Timer.publish(every: rotationInterval, on: .main, in: .common).autoconnect()) { _ in
            guard input.isEmpty, starterQuestions.count > 1, !chat.isGenerating else { return }
            withAnimation(.easeOut(duration: 0.45)) {
                questionIndex = (questionIndex + 1) % starterQuestions.count
            }
        }
    }

    /// 当前轮换到的预设提问（没有预设时返回 nil，输入框退回普通占位）。
    private var currentStarterQuestion: String? {
        guard !starterQuestions.isEmpty else { return nil }
        return starterQuestions[questionIndex % starterQuestions.count]
    }

    /// 把「语音识别结果」拼到「录音前已有内容」后面（纯函数，便于单测）。
    public nonisolated static func mergedInput(base: String, voice: String) -> String {
        let spoken = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return base }
        guard !base.isEmpty else { return spoken }
        if let last = base.last, last.isWhitespace { return base + spoken }
        return base + " " + spoken
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            CuteAnimalView(kind: teacherKind, isSleeping: theme.isNight, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(teacherKind.displayName)老师")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text(statusLine)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            // 克隆音色生效提示：与情景胶囊并列，位置显眼但不抢戏。
            if let voiceIndicator {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 9, weight: .semibold))
                    Text(voiceIndicator)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.accent.opacity(0.14)))
                .help("当前使用的是克隆音色，不是内置音色")
            }

            if let scenario {
                HStack(spacing: 6) {
                    Image(systemName: scenario.scenario.icon)
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(scenario.scenario.titleZh) · \(scenario.turnsText)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                    if scenario.isFinalTurn {
                        Text("收尾")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.accent.opacity(0.22)))
                    }
                    Button {
                        onEndScenario?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("结束情景对话")
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.selection))
            } else {
                Button {
                    onOpenScenarios?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("情景")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.hover))
                }
                .buttonStyle(.plain)
                .help("选择情景对话场景")
            }

            if let modelName, !modelName.isEmpty {
                Text(headerModelCaption(modelName))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.surfaceAlt))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // MARK: - 情景目标条（数据来自场景本体，UI 不解释语义）

    private func scenarioStrip(_ progress: ScenarioProgress) -> some View {
        let scenario = progress.scenario
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "target")
                .font(.system(size: 11))
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("你是 \(scenario.learnerRole)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("· \(scenario.level) · 纠错\(scenario.correctionMode.displayName)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                if !scenario.objective.isEmpty {
                    Text(scenario.objective)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !scenario.targetVocabulary.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(scenario.targetVocabulary.prefix(6), id: \.self) { word in
                            Text(word)
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.surfaceAlt))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
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

    @ViewBuilder
    private var messageArea: some View {
        if chat.messages.isEmpty && chat.streamingText.isEmpty && chat.streamingReasoning.isEmpty && !chat.isGenerating {
            // 空态：小动物相对整个对话区垂直居中。
            GeometryReader { geo in
                emptyHint
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                            VStack(alignment: .leading, spacing: 6) {
                                // 距上一条超过 5 分钟才显示时间戳；首条消息必显示。
                                if index == 0
                                    || message.createdAt.timeIntervalSince(chat.messages[index - 1].createdAt) > timestampGap {
                                    timestamp(message.createdAt)
                                }
                                bubble(message)
                            }
                            .id(message.id.uuidString)
                        }

                        if chat.isGenerating {
                            streamingCard
                                .id("streaming")
                        }

                        if let errorMessage = chat.errorMessage {
                            errorBanner(errorMessage)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                .onChange(of: chat.messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: chat.streamingText) { scrollToBottom(proxy) }
                .onChange(of: chat.streamingReasoning) { _, _ in
                    // 思考阶段也保持滚动到底（面板自动跟随最新内容）
                    if chat.streamingText.isEmpty { scrollToBottom(proxy) }
                }
            }
        }
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.surface))
                    .overlay(Circle().strokeBorder(theme.divider, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.14), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .help("回到最新消息")
            .padding(.bottom, 10)
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
            .animation(.easeOut(duration: 0.2), value: isScrolledUp)
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
                    .font(.system(size: 12, design: .rounded))
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let target: String? = chat.isGenerating ? "streaming" : chat.messages.last?.id.uuidString
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    /// 每条消息上方的时间戳：`9月9日 周三 18:57`（仅间隔 > 5 分钟才出现）。
    private func timestamp(_ date: Date) -> some View {
        Text(Self.stamp(date))
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(theme.secondaryText.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    /// 手写格式化：避免 DateFormatter 的 locale/并发坑，输出顺序固定为「月日 周 时分」。
    public nonisolated static func stamp(_ date: Date) -> String {
        Timestamps.stamp(date)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            CuteAnimalView(kind: studentKind, isSleeping: theme.isNight, size: 92, accessory: .student)
            Text("和老师打个招呼，开始今天的攀爬吧 🌿")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        let corrections = isUser ? [] : (chat.correctionsByMessage[message.id] ?? [])
        let translation = chat.translationsByMessage[message.id]
        let isTranslating = chat.translatingMessageIDs.contains(message.id)
        return HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 36) }
            if !isUser {
                CuteAnimalView(kind: teacherKind, isSleeping: false, size: 30)
            }
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
                        MarkdownText(message.content, fontSize: 14, color: theme.primaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
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
                if !isUser, let onSpeakTap {
                    HStack(spacing: 6) {
                        SpeakButton(text: message.content,
                                    phase: speakingText == message.content ? speechPhase : .idle,
                                    action: onSpeakTap,
                                    onStop: onStopSpeak)
                        if onSpeechRateChange != nil {
                            SpeechRateMenu(rate: speechRate) { rate in onSpeechRateChange?(rate) }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            if isUser {
                CuteAnimalView(kind: studentKind, isSleeping: false, size: 28, accessory: .student)
            }
            if !isUser { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
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
        .padding(.vertical, 8)
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
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(theme.accent)
            .padding(.top, 2)
    }

    private func translationText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .rounded))
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
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isOn ? theme.accent : theme.secondaryText.opacity(0.75))
                    }
                }
                .frame(width: 20, height: 20)
                .background(Circle().fill(isOn ? theme.accent.opacity(0.16) : Color.clear))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .help(isOn ? "收起翻译" : "翻译成中文")
        }
    }

    /// 「改一改」纠错卡片：原句 → 改正 + 一句话说明。
    private func correctionCard(_ correction: GrammarCorrection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "pencil.and.list.clipboard")
                    .font(.system(size: 10, weight: .semibold))
                Text("改一改")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(theme.accent)

            Text(correction.original)
                .font(.system(size: 12, design: .rounded))
                .strikethrough()
                .foregroundStyle(theme.secondaryText)
            Text(correction.corrected)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.primaryText)
            if !correction.explanation.isEmpty {
                Text(correction.explanation)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(isHighlighted ? Color.white : theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isHighlighted ? theme.accent : theme.surfaceAlt)
                )
                .overlay(
                    Capsule().strokeBorder(theme.accent, lineWidth: isHighlighted ? 2 : 0)
                )
                .scaleEffect(isPressing ? 0.94 : 1)
            }
            .buttonStyle(.plain)
            // 按住期间即高亮（simultaneous 不吞掉点击）
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in withAnimation(.easeOut(duration: 0.1)) { isPressing = true } }
                    .onEnded { _ in withAnimation(.easeOut(duration: 0.12)) { isPressing = false } }
            )
            .animation(.easeOut(duration: 0.18), value: isHighlighted)
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
            withAnimation(.easeOut(duration: 0.1)) { didFlash = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.6))
                withAnimation(.easeOut(duration: 0.25)) { didFlash = false }
            }
        }
    }

    /// 语速选择：与设置页共用同一套下拉控件（形状/描边/箭头都由 `ForestSelect` 保证）。
    private struct SpeechRateMenu: View {
        let rate: Double
        let onSelect: (Double) -> Void

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
                width: 62,
                help: "教师朗读语速（当前 \(SpeechRate.nearest(to: rate).label)）"
            )
        }
    }

    // MARK: - 输入区

    /// 对话模型被关闭时的常驻提示：用户一开始打字就能看到「该启动哪个模型」。
    private func modelStoppedBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    /// 语音输入失败提示（录音/识别出错时贴在输入框上方，可关闭）。
    /// 没有它时，点麦克风失败在对话区是**完全静默**的，用户只会觉得「没反应」。
    @ViewBuilder
    private var voiceErrorBanner: some View {
        if let voiceError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(voiceError)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    onDismissVoiceError?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("关闭提示")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .transition(.opacity)
        }
    }

    /// 翻译失败提示（贴在输入框上方，可关闭）。
    @ViewBuilder
    private var translationErrorBanner: some View {
        if let translationError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(translationError)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    onDismissTranslationError?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("关闭提示")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .transition(.opacity)
        }
    }

    /// 附件提示（超限 / 导入失败）：说清楚哪个文件为什么没加上，可关闭。
    @ViewBuilder
    private var attachmentErrorBanner: some View {
        if let attachmentNotice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(attachmentNotice)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    onDismissAttachmentNotice?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("关闭提示")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .padding(.top, 10)
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
        .padding(.top, 10)
        .padding(.bottom, 10)
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
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
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
                        .font(.system(size: 10, design: .rounded))
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
                micButton
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 发送 / 停止。与左侧按钮**同形状同大小**，只靠「实心强调色」表达主操作。
    private var sendButton: some View {
        Button {
            chat.isGenerating ? chat.cancel() : send()
        } label: {
            Image(systemName: chat.isGenerating ? "stop.fill" : "paperplane.fill")
                .font(.system(size: 13, weight: .semibold))
                .modifier(ComposerButtonChrome(
                    tint: .white,
                    fill: chat.isGenerating ? Color.red.opacity(0.85) : theme.accent,
                    border: .clear
                ))
        }
        .buttonStyle(.plain)
        .disabled(chat.isGenerating ? false : !canSend)
        .help(chat.isGenerating ? "停止" : (modelStoppedNotice != nil ? "请先启动对话模型" : "发送"))
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
    /// ⚠️ **外观层必须放在 `Menu` 外面**：macOS 不渲染 `Menu` label 上的自定义
    /// 底色 / 描边 / 前景色（实测：裸菜单只剩一个深色图标，连 `foregroundStyle`
    /// 都被忽略）。曾经把样式贴在 label 上，结果「+」是个没有底的裸加号，
    /// 与旁边的麦克风完全不像一套 —— 需求要的「两个按钮外观一致」当场落空。
    /// 所以外观由菜单**之外**的一层提供；`Menu` 的 label 保留原来那个同款图标
    /// （点击区与过去完全一致，不在点击上冒险），只是几乎不可见。
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .allowsHitTesting(false)

            Menu {
                Button { pickAttachments(kind: .image) } label: {
                    Label("添加图片", systemImage: "photo")
                }
                Button { pickAttachments(kind: .video) } label: {
                    Label("添加视频", systemImage: "film")
                }
                Button { pickAttachments(kind: nil) } label: {
                    Label("添加文件", systemImage: "doc")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: ComposerButtonChrome.side, height: ComposerButtonChrome.side)
                    .contentShape(Circle())
                    .opacity(0.001)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
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
            // 「最多 5 行」实际显示成 6 行 —— 呼吸位由外层 `.padding(.vertical, 10)` 给，
            // 不能再叠一层，否则封顶形同虚设。
            .frame(height: max(inputHeight, ComposerMetrics.lineHeight(fontSize: 14)))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if input.isEmpty, let hint = currentStarterQuestion {
                rollingQuestion(hint)
                    .padding(.leading, 14)
                    .padding(.trailing, 20)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.45), value: questionIndex)
    }

    /// 上下滚动的预设提问：新的一条从下方滚上来，旧的一条往上滚出去。
    private func rollingQuestion(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, design: .rounded))
            .foregroundStyle(theme.secondaryText.opacity(0.62))
            .lineLimit(1)
            .truncationMode(.tail)
            .id(text)
            .frame(height: 20)
            .clipped()
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
    }

    /// 能不能发送：模型被关闭时一律不行；否则「有手打内容」「有待发附件」「有预设提问」都行。
    private var canSend: Bool {
        guard modelStoppedNotice == nil else { return false }
        if !pendingAttachments.isEmpty { return true }
        if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return currentStarterQuestion != nil
    }

    /// 麦克风按钮：点击说话 → 录音期间流式出字 → 再点识别并纠正拼写后定稿。
    private var micButton: some View {
        Button {
            Task { @MainActor in
                if isRecording {
                    isMergingVoice = false
                    if let text = await onMicStop?(), !text.isEmpty {
                        input = Self.mergedInput(base: voiceBase, voice: text)
                    }
                    // 本次结果成为下一轮的起点：连续口述会自然接在后面。
                    voiceBase = input
                    isInputFocused = true
                } else {
                    // 记住录音前的输入，流式结果只替换「本次语音」这一段
                    voiceBase = input
                    isMergingVoice = true
                    await onMicStart?()
                }
            }
        } label: {
            Group {
                if isTranscribing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            // ⚠️ 尺寸/形状/描边全部来自 `ComposerButtonChrome`（与「+」同一份）：
            // 需求要求这两个按钮外观一致，各自写一套样式迟早会漂。
            .modifier(ComposerButtonChrome(
                tint: isRecording ? Color.red : theme.accent,
                fill: isRecording ? Color.red.opacity(0.12) : theme.surfaceAlt,
                border: isRecording ? Color.red.opacity(0.5) : theme.divider
            ))
        }
        .buttonStyle(.plain)
        .help(isRecording ? "停止并识别" : "点击说话")
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

    private func send() {
        // 对话模型被关闭时，输入不丢、也不发出去；用户按提示启动模型即可。
        guard modelStoppedNotice == nil else { return }
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空着点发送 = 发送当前轮换到的预设提问（浅灰那条）；只带附件不带文字时不再兜底提问。
        let text: String
        if !typed.isEmpty {
            text = typed
        } else if pendingAttachments.isEmpty {
            text = currentStarterQuestion ?? ""
        } else {
            text = ""
        }
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        // 手打与语音一视同仁：发出去后输入框彻底清空。
        // 同时断开语音回流 —— 否则「还录着音就点发送」时，下一轮流式结果会把内容原样填回来。
        input = ""
        voiceBase = ""
        isMergingVoice = false
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
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(isStreaming ? "正在思考…" : "思考过程")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                    Spacer()
                }
                .foregroundStyle(theme.secondaryText)
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(reasoning)
                            .font(.system(size: bodyFontSize, design: .rounded))
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
                .font(.system(size: bodyFontSize, design: .rounded))
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
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .help(tooltip)
    }
}

private struct TypingDots: View {
    let color: Color
    @State private var phase = 0

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
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.10)))
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { phase = (phase + 1) % 3 } }
            }
        }
    }
}
