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

    public init(chat: ChatService, modelName: String?, health: ProviderHealth,
                teacherKind: AnimalKind = .panda, studentKind: AnimalKind = .bear,
                isRecording: Bool = false, isTranscribing: Bool = false,
                autoSpeak: Bool = false,
                onMicStart: (() async -> Void)? = nil,
                onMicStop: (() async -> String?)? = nil,
                onSpeakTap: ((String) -> Void)? = nil) {
        self.chat = chat
        self.modelName = modelName
        self.health = health
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
        }
        .background(theme.surfaceAlt.opacity(0.35))
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
                Text(modelName)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(theme.surfaceAlt)
                    )
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    private var statusLine: String {
        var parts: [String] = []
        if let modelName, !modelName.isEmpty { parts.append(modelName) }
        parts.append(health.userFacingDescription)
        return parts.joined(separator: " · ")
    }

    // MARK: - 消息区

    private var messageArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty && chat.streamingText.isEmpty {
                        emptyHint
                    }

                    ForEach(chat.messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            timestamp(message.createdAt)
                            bubble(message)
                        }
                        .id(message.id.uuidString)
                    }

                    if chat.isGenerating && !chat.streamingText.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            timestamp(Date())
                            bubble(ChatMessage(role: .assistant, content: chat.streamingText))
                        }
                        .id("streaming")
                    } else if chat.isGenerating {
                        HStack(spacing: 8) {
                            CuteAnimalView(kind: teacherKind, isSleeping: false, size: 30)
                            if chat.isThinking {
                                Text("思考中…")
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(theme.secondaryText)
                            }
                            TypingDots(color: theme.secondaryText)
                        }
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
            .onChange(of: chat.messages.count) { _, count in
                scrollToBottom(proxy)
                // 教师回复完成后自动朗读（设置里可关）
                if autoSpeak, count > 0, let last = chat.messages.last, last.role == .assistant {
                    onSpeakTap?(last.content)
                }
            }
            .onChange(of: chat.streamingText) { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let target: String? = chat.isGenerating ? "streaming" : chat.messages.last?.id.uuidString
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    /// 每条消息上方的时间戳：`9月9日 周三 18:57`。
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
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
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
                Text(message.content)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
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
        .padding(.vertical, 12)
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

    private func send() {
        let text = input
        input = ""
        chat.send(text)
        isInputFocused = true
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
