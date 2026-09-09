import AIDomain
import AIInterfaces
import AIServices
import SwiftUI

public struct ChatView: View {

    @Environment(\.forestTheme) private var theme

    let chat: ChatService
    let modelName: String?
    let health: ProviderHealth

    @State private var input: String = ""
    @FocusState private var isInputFocused: Bool

    public init(chat: ChatService, modelName: String?, health: ProviderHealth) {
        self.chat = chat
        self.modelName = modelName
        self.health = health
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
            CuteAnimalView(kind: .owl, isSleeping: theme.isNight, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("森林英语私教")
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
        .padding(.vertical, 12)
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
                        bubble(message)
                            .id(message.id.uuidString)
                    }

                    if chat.isGenerating && !chat.streamingText.isEmpty {
                        bubble(ChatMessage(role: .assistant, content: chat.streamingText))
                            .id("streaming")
                    } else if chat.isGenerating {
                        HStack(spacing: 8) {
                            CuteAnimalView(kind: .owl, isSleeping: false, size: 30)
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
            .onChange(of: chat.messages.count) { scrollToBottom(proxy) }
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

    private var emptyHint: some View {
        VStack(spacing: 10) {
            CuteAnimalView(kind: .bear, isSleeping: theme.isNight, size: 88)
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
        return HStack(alignment: .bottom, spacing: 10) {
            if isUser { Spacer(minLength: 48) }
            if !isUser {
                CuteAnimalView(kind: .owl, isSleeping: false, size: 32)
            }
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
            if !isUser { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    // MARK: - 输入区

    private var inputBar: some View {
        HStack(spacing: 10) {
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
