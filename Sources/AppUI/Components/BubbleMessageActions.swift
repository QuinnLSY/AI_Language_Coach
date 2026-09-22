import AIDomain
import AppKit
import SwiftUI

// MARK: - 气泡上的动作（复制 / 删除 / 编辑重发 / 重新生成）
//
// 为什么单独成文件：这些是**气泡级的次要动作**，与气泡正文（`MarkdownText`）无关，
// 塞进 `ChatView`（已 2000+ 行）只会让它更难读。
// 它们同时被离屏渲染回归直接使用 —— 组件独立才好摆出「悬停时到底长什么样」。

/// 复制文本到剪贴板。
///
/// 全项目只此一处 `NSPasteboard`：复制散在各处的话，
/// 「复制老师那一句」与「复制学员那一句」会各自处理换行与首尾空白，行为迟早不一致。
enum Clipboard {
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

/// 气泡上的小图标按钮：尺寸、悬停高亮、禁用态收在一处。
///
/// ⚠️ 字号刻意压到 11pt 并收在 20×20 的圆里 —— 这是**次要动作**，
/// 不能与正文抢注意力；放大到与正文同级会让整段对话看起来像工具栏。
struct BubbleIconButton: View {

    @Environment(\.forestTheme) private var theme

    let systemImage: String
    let help: String
    var isEnabled: Bool = true
    /// 强制点亮（不依赖悬停）。复制成功后的对勾用它 ——
    /// 那一瞬间鼠标可能已经移开，只靠悬停高亮的话「成功了」这个反馈会一起消失。
    var isHighlighted: Bool = false
    var accessibilityText: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    private var isLit: Bool { (isHovering || isHighlighted) && isEnabled }

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isLit ? theme.accent : theme.secondaryText.opacity(0.8))
                .frame(width: 20, height: 20)
                .background(Circle().fill(isLit ? theme.accent.opacity(0.14) : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.3)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(accessibilityText ?? help)
    }
}

/// 复制按钮：点完短暂变成对勾。
///
/// ⚠️ 没有这个反馈时，「复制」是**唯一一个点了完全没变化的动作** ——
/// 用户只能靠去别处粘贴一次来确认自己点到了没有。
struct CopyIconButton: View {

    let text: String
    var help: String = "复制内容"

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        BubbleIconButton(
            systemImage: didCopy ? "checkmark" : "doc.on.doc",
            help: didCopy ? "已复制" : help,
            isHighlighted: didCopy,
            accessibilityText: didCopy ? "已复制" : help
        ) {
            Clipboard.copy(text)
            didCopy = true
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                didCopy = false
            }
        }
    }
}

/// 学员气泡上「悬停才浮现」的动作条：删除 / 编辑 / 复制。
///
/// 顺序与产品给的参考图一致（删除在最左）：
/// 三个都是**破坏性递减**的排列 —— 最左最危险，最右最无害。
struct LearnerBubbleActionRow: View {

    let text: String
    /// 生成中 / 考试中不给改（见 `AppState.canMutateChatMessages`）。
    var isEnabled: Bool = true
    let onDelete: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            BubbleIconButton(
                systemImage: "trash",
                help: "删除这一轮对话",
                isEnabled: isEnabled,
                accessibilityText: "删除这一轮对话"
            ) {
                onDelete()
            }
            BubbleIconButton(
                systemImage: "pencil",
                help: "改一改这句话再发",
                isEnabled: isEnabled,
                accessibilityText: "编辑这条消息"
            ) {
                onEdit()
            }
            CopyIconButton(text: text)
        }
    }
}

/// 气泡就地编辑：**一条独立的输入框**（不是往气泡里塞一个单行 `TextField`）。
///
/// 三条设计口径：
/// ① 复用聊天输入框（`MultilineComposerField`）—— 同一套换行/回车发送手感，
///    用户不必学第二套；最多 5 行，超了滚动。
/// ② 底部一句说清后果（改完会发生什么），并且**文案与按钮同一行**：
///    提示挂得离「发送」太远就等于没提示。
/// ③ 框比正文气泡宽：正在编辑的东西不是「已经说过的话」，视觉上必须与气泡区分开。
struct MessageEditBox: View {

    @Environment(\.forestTheme) private var theme

    @Binding var text: String
    let onCancel: () -> Void
    let onSend: () -> Void

    /// 与聊天输入框同一口径：高度由真实排版量出（见 `ComposerMetrics`）。
    @State private var measuredHeight: CGFloat = 0
    @State private var isFocused = false

    private static let fontSize: CGFloat = 14

    /// 「改完会发生什么」。这句话是**承诺**，不是装饰：编辑会截断后面聊过的内容，
    /// 而纠错 / 复盘 / 生词这些产物不动 —— 用户点之前有权知道这两件事。
    static let consequenceHint = "编辑后将从此处重新开始对话，已有产物不会被删除"

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MultilineComposerField(
                text: $text,
                measuredHeight: $measuredHeight,
                isFocused: $isFocused,
                textColor: NSColor(theme.primaryText),
                insertionColor: NSColor(theme.accent),
                onSubmit: { if canSend { onSend() } }
            )
            // frame 高度就是滚动的可视区高度，必须与上报值一致（详见聊天输入框那处注释）。
            .frame(height: max(measuredHeight, ComposerMetrics.lineHeight(fontSize: Self.fontSize)))

            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                Text(Self.consequenceHint)
                    .font(.system(size: 11, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                cancelButton
                sendButton
            }
            .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.55), lineWidth: 1)
        )
        .frame(maxWidth: 620, alignment: .leading)
        .onAppear { isFocused = true }
    }

    private var cancelButton: some View {
        Button {
            onCancel()
        } label: {
            Text("取消")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(theme.surface))
                .overlay(Capsule().strokeBorder(theme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("放弃这次修改，保留原来的那句话")
    }

    private var sendButton: some View {
        Button {
            guard canSend else { return }
            onSend()
        } label: {
            Text("发送")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.onAccentFill)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Capsule().fill(canSend ? theme.accentFill : theme.accentFill.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help(canSend ? "用改过的这句话重新问老师" : "先写点什么再发")
    }
}

/// 老师气泡上的动作条：复制 + 重新生成。
///
/// ⚠️ 与学员气泡的口径**故意不同**：这两颗是**始终显示**的（不悬停才浮现）。
/// 学员气泡上那三颗会改动对话内容，需要一层「停下来才动手」的阻力；
/// 复制与重新生成不改数据，且「老师这句没听懂/没答好」正是最常发生的即时需求。
struct CoachBubbleActionRow: View {

    let text: String
    var isEnabled: Bool = true
    let onRegenerate: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            CopyIconButton(text: text)
            BubbleIconButton(
                systemImage: "arrow.clockwise",
                help: "让老师换一种说法重答",
                isEnabled: isEnabled,
                accessibilityText: "重新生成这条回复"
            ) {
                onRegenerate()
            }
        }
    }
}
