import AIDomain
import AIInterfaces
import AIServices
import AppCore
import SwiftUI

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

    @State private var input: String = ""
    @FocusState private var isInputFocused: Bool
    /// 本次录音开始前输入框里的内容：流式识别结果拼在它后面，绝不覆盖用户手打的字。
    @State private var voiceBase: String = ""
    /// 当前轮换到的预设提问下标。
    @State private var questionIndex: Int = 0
    /// 录音中且尚未发送：只有这段时间才允许流式结果往输入框里写。
    /// （发送后必须彻底断开，否则正在录音时发送会被下一轮流式结果原样填回来。）
    @State private var isMergingVoice = false

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
                onSpeechRateChange: ((Double) -> Void)? = nil,
                scenario: ScenarioProgress? = nil,
                onOpenScenarios: (() -> Void)? = nil,
                onEndScenario: (() -> Void)? = nil,
                voiceTranscript: String? = nil,
                modelStoppedNotice: String? = nil,
                starterQuestions: [String] = [],
                onTranslate: ((UUID) async -> Void)? = nil,
                translationError: String? = nil,
                onDismissTranslationError: (() -> Void)? = nil) {
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
            inputBar
            contextStrip
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
                .onChange(of: chat.messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: chat.streamingText) { scrollToBottom(proxy) }
                .onChange(of: chat.streamingReasoning) { _, _ in
                    // 思考阶段也保持滚动到底（面板自动跟随最新内容）
                    if chat.streamingText.isEmpty { scrollToBottom(proxy) }
                }
            }
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
            VStack(alignment: .leading, spacing: 6) {
                // 思考过程：对话卡片内嵌的折叠面板，正文在其下方。
                if !isUser, let reasoning = message.reasoning, !reasoning.isEmpty {
                    ThinkingPanel(reasoning: reasoning, isStreaming: false)
                }
                // 气泡本体：翻译按钮贴在气泡外侧（学员在左 / 老师在右），
                // 这一层 HStack 用 .bottom 对齐 —— 按钮因此**始终与气泡底线齐平**，
                // 下方再挂纠错卡或朗读按钮也不会把它拽下去。
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
                if let translation {
                    translationCard(translation)
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
    private func translationCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "quote.closing")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(text)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 340, alignment: .leading)
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

    /// 语速选择：样式与「听老师读」一致的小胶囊，点开即选倍速。
    private struct SpeechRateMenu: View {
        @Environment(\.forestTheme) private var theme

        let rate: Double
        let onSelect: (Double) -> Void

        var body: some View {
            Menu {
                ForEach(SpeechRate.allCases) { option in
                    Button {
                        onSelect(option.rawValue)
                    } label: {
                        if abs(option.rawValue - rate) < 0.01 {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "speedometer")
                    Text(SpeechRate.nearest(to: rate).label)
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.surfaceAlt))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("教师朗读语速（当前 \(SpeechRate.nearest(to: rate).label)）")
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

    private var inputBar: some View {
        HStack(spacing: 10) {
            micButton

            inputField

            Button {
                chat.isGenerating ? chat.cancel() : send()
            } label: {
                Image(systemName: chat.isGenerating ? "stop.fill" : "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(chat.isGenerating ? Color.red.opacity(0.85) : theme.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(chat.isGenerating ? false : !canSend)
            .help(chat.isGenerating ? "停止" : (modelStoppedNotice != nil ? "请先启动对话模型" : "发送"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    /// 输入框：空着的时候用浅灰字**轮换**展示预设提问（点发送即发送当前这一条）。
    private var inputField: some View {
        ZStack(alignment: .leading) {
            TextField("", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(theme.divider, lineWidth: 1)
                )
                .focused($isInputFocused)
                .onSubmit { send() }

            if input.isEmpty, let hint = currentStarterQuestion {
                rollingQuestion(hint)
                    .padding(.leading, 14)
                    .padding(.trailing, 20)
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

    /// 能不能发送：模型被关闭时一律不行；否则「有手打内容」或「有预设提问」都行。
    private var canSend: Bool {
        guard modelStoppedNotice == nil else { return false }
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
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(isRecording ? Color.red : theme.accent)
            .frame(width: 40, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isRecording ? Color.red.opacity(0.12) : theme.surfaceAlt)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isRecording ? Color.red.opacity(0.5) : theme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(isRecording ? "停止并识别" : "点击说话")
    }

    // MARK: - 上下文状态栏（输入框下方：整体居中，占用用圆环表示）

    private var contextStrip: some View {
        HStack(spacing: 8) {
            Spacer()
            Text(contextSummary)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            ContextGauge(
                used: chat.estimatedContextTokens,
                limit: contextLimit,
                tooltip: contextDescription,
                track: theme.divider
            )
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

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
        // 空着点发送 = 发送当前轮换到的预设提问（浅灰那条）。
        let text = typed.isEmpty ? (currentStarterQuestion ?? "") : typed
        guard !text.isEmpty else { return }
        // 手打与语音一视同仁：发出去后输入框彻底清空。
        // 同时断开语音回流 —— 否则「还录着音就点发送」时，下一轮流式结果会把内容原样填回来。
        input = ""
        voiceBase = ""
        isMergingVoice = false
        chat.send(text)
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
