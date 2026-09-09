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
    /// 朗读某段教师回复。
    var onSpeakTap: ((String) -> Void)? = nil

    @State private var input: String = ""
    @FocusState private var isInputFocused: Bool

    /// 相隔超过该时长的两条消息之间才显示时间戳。
    private let timestampGap: TimeInterval = 5 * 60

    public init(chat: ChatService, modelName: String?, health: ProviderHealth,
                providerLabel: String = "", contextLimit: Int? = nil, reasoningLabel: String? = nil,
                teacherKind: AnimalKind = .panda, studentKind: AnimalKind = .bear,
                isRecording: Bool = false, isTranscribing: Bool = false,
                autoSpeak: Bool = false,
                onMicStart: (() async -> Void)? = nil,
                onMicStop: (() async -> String?)? = nil,
                onSpeakTap: ((String) -> Void)? = nil) {
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
        self.onSpeakTap = onSpeakTap
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            messageArea
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
                ForEach(corrections) { correction in
                    correctionCard(correction)
                }
                if !isUser, let onSpeakTap {
                    speakButton(message.content, action: onSpeakTap)
                }
            }
            if isUser {
                CuteAnimalView(kind: studentKind, isSleeping: false, size: 28, accessory: .student)
            }
            if !isUser { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
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

    /// 朗读按钮：听老师念这句话。
    private func speakButton(_ text: String, action: @escaping (String) -> Void) -> some View {
        Button {
            action(text)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                Text("听老师读")
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(theme.surfaceAlt))
        }
        .buttonStyle(.plain)
        .help("听老师朗读这句")
    }

    // MARK: - 输入区

    private var inputBar: some View {
        HStack(spacing: 10) {
            micButton

            TextField("用英语说点什么…", text: $input)
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
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.isGenerating)
            .help(chat.isGenerating ? "停止" : "发送")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    /// 麦克风按钮：点击说话 → 再点识别填入输入框。
    private var micButton: some View {
        Button {
            Task { @MainActor in
                if isRecording {
                    if let text = await onMicStop?(), !text.isEmpty {
                        input = input.isEmpty ? text : input + " " + text
                    }
                    isInputFocused = true
                } else {
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
        let text = input
        input = ""
        chat.send(text)
        isInputFocused = true
    }
}

// MARK: - 思考过程折叠面板

/// 推理模型的思考过程：卡片内嵌面板，箭头切换展开/收起（默认展开）。
/// 固定高度只露出最新内容（约 10 行），滚动可回看全部；60% 透明度灰色背景。
struct ThinkingPanel: View {

    @Environment(\.forestTheme) private var theme
    let reasoning: String
    /// 流式阶段为 true：内容持续增长，自动吸底显示最新思考。
    let isStreaming: Bool

    @State private var isExpanded = true

    /// 约等于 10 行的固定高度。
    private let panelHeight: CGFloat = 150

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
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.primaryText.opacity(0.82))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.6))
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
        .overlay(alignment: .bottom) {
            if isHovering {
                SpeechBubble(text: tooltip, maxWidth: 220)
                    .fixedSize()
                    .offset(y: 40)
                    .zIndex(10)
                    .transition(.opacity)
            }
        }
        .contentShape(Circle().inset(by: -6))
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
