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
    /// 这一颗的**语义色**。nil = 沿用「次要文字 → accent」的默认口径。
    ///
    /// 只有破坏性动作（删除）会传 `danger`：一颗红色的垃圾桶说的是「这一颗会删东西」，
    /// 而不是在礼貌地邀请你去点它。另两颗**刻意保持中性** ——
    /// 三颗都上色等于三颗都没上色（`LearnerBubbleActionRow.tint(for:theme:)`）。
    var tint: Color? = nil
    var accessibilityText: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    private var isLit: Bool { (isHovering || isHighlighted) && isEnabled }
    private var litColor: Color { tint ?? theme.accent }
    private var idleColor: Color { (tint ?? theme.secondaryText).opacity(0.8) }

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isLit ? litColor : idleColor)
                .frame(width: 20, height: 20)
                .background(Circle().fill(isLit ? litColor.opacity(0.14) : Color.clear))
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

/// 学员气泡上的动作条：删除 / 编辑 / 复制。
///
/// 顺序与产品给的参考图一致（删除在最左）：
/// 三个都是**破坏性递减**的排列 —— 最左最危险，最右最无害。
///
/// ⚠️ 三颗是**常驻**的（2026-09-23 用户口径），由外层控制透明度：
/// 未悬停 30%、悬停 100%。以前是「悬停才浮现」，问题出在**要够到它们得先精确停在气泡上**——
/// 鼠标往右下角移过去的那一下，图标先消失了，于是永远点不着。
/// 常驻之后「看得见」与「点得动」是同一件事（外层不再 `allowsHitTesting(false)`），
/// 误点由删除那一颗的**确认框**兜住（见 `DeleteConfirmation`）。
struct LearnerBubbleActionRow: View {

    @Environment(\.forestTheme) private var theme

    /// 三颗图标各自的动作。**颜色口径按它来**（见 `tint(for:theme:)`）。
    enum Action: String, CaseIterable, Sendable {
        case delete
        case edit
        case copy
    }

    /// 三颗图标的着色口径：**只有删除是破坏性的**，用 `danger`；编辑与复制保持中性。
    ///
    /// ⚠️ 抽成静态纯函数是为了**能把它钉住**：离屏渲染过一次色彩空间换算，
    /// 渲染断言里不能比色值（见技能 `macos-ui-verify`），
    /// 「用的是不是 `danger`」只能在「选了哪个令牌」这一层证。
    static func tint(for action: Action, theme: ForestTheme) -> Color? {
        switch action {
        case .delete: theme.danger
        case .edit, .copy: nil
        }
    }

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
                tint: Self.tint(for: .delete, theme: theme),
                accessibilityText: "删除这一轮对话"
            ) {
                onDelete()
            }
            BubbleIconButton(
                systemImage: "pencil",
                help: "改一改这句话再发",
                isEnabled: isEnabled,
                tint: Self.tint(for: .edit, theme: theme),
                accessibilityText: "编辑这条消息"
            ) {
                onEdit()
            }
            CopyIconButton(text: text)
        }
    }
}

/// 删除确认：**点垃圾桶只是登记，真正删要等确认**。
///
/// ① 为什么要有这一步：三颗图标改成**常驻**之后，删除不再需要「先精确悬停」——
///    阻力的那一层没了，误点的代价却是删掉一整轮问答（学员那句 + 老师那句）。
///    确认框把阻力加回到了**最该加的那一步**上，而编辑 / 复制不必陪着受罪。
/// ② 为什么单独成一个纯值类型，而不是在 View 里放一个 `@State UUID?`：
///    对话框本身离屏渲染不出来、合成点击又会 abort 整个测试进程（见技能），
///    「确认前不许删」这条**只能**在状态机这一层证 —— 见 `BubbleDeleteTests`。
struct DeleteConfirmation: Equatable {

    /// 待确认的那一条（nil = 没有待确认的删除）。
    private(set) var pending: UUID?

    init(pending: UUID? = nil) {
        self.pending = pending
    }

    /// 对话框此刻该不该弹。
    var isPresented: Bool { pending != nil }

    /// 点了垃圾桶：**只登记**。这里绝不触发删除。
    mutating func request(_ id: UUID) {
        pending = id
    }

    /// 点了「取消」/ 按了 Esc：什么都不做地散场。
    mutating func cancel() {
        pending = nil
    }

    /// 点了「删除」：交出要删的 id（没有待确认的就交 nil），并清场。
    mutating func confirm() -> UUID? {
        defer { pending = nil }
        return pending
    }
}

/// 删除确认框里的文案（纯函数，可单测）。
///
/// ⚠️ 「删掉的是什么」必须说准：删除会把**紧邻的那条老师回复一起带走**
/// （见 `ChatService.deleteMessage`），而纠错 / 复盘 / 生词这些**学习记录不动**。
/// 两件事都得写出来 —— 用户点之前有权知道边界在哪。
enum BubbleDeletePrompt {

    static let title = "删除这一轮对话？"

    /// 摘要里最多留几个字（约一行）。
    static let previewLimit = 24

    static func message(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "这条消息和老师的那句回复会一起删掉。纠错、复盘、生词这些学习记录不受影响。"
        }
        return "「\(preview(of: trimmed))」和老师的那句回复会一起删掉。"
            + "纠错、复盘、生词这些学习记录不受影响。"
    }

    /// 正文摘要：先压掉换行与连续空白（多行消息塞进一句话里会变成一坨），再按长度截断。
    static func preview(of text: String) -> String {
        let flattened = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard flattened.count > previewLimit else { return flattened }
        return String(flattened.prefix(previewLimit)) + "…"
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
