import AIDomain
import SwiftUI
import UniformTypeIdentifiers

// #663 自 ChatView.swift 拆出（2026-10-24）：原文件 2896 行、单结构体 + 5 个尾部类型，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ChatView {

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
    var composer: some View {
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
        // ⚠️ 这里**不再**挂 `keyboardShortcut`（#617）：发送键已进快捷键注册表，
        // 由全局监听统一分发（两处都接 = 同键双触发，一条消息发两遍）。
        // 「生成中不给快捷键」改由 resolver 的 `isChatActive` 上下文把关。
        .help(sendButtonHelp)
        // VoiceOver：这颗粒按钮的内容是图标，读屏读不出「发送 / 停止」的区别 ——
        // 而它恰恰是**同一个控件在两种语义之间切换**，不读出来等于没有出口。
        .accessibilityLabel(chat.isGenerating ? "停止生成" : "发送")
    }

    private var sendButtonHelp: String {
        if chat.isGenerating { return "停止" }
        if modelStoppedNotice != nil { return "请先启动对话模型" }
        // 读当前绑定（#617）：用户在设置里改了键，提示得跟着改 —— 否则界面在撒谎。
        return "发送（\(sendShortcutHint)）"
    }

    /// 输入区下排按钮的统一外观：**同一形状（圆）、同一尺寸、同一描边**。
    ///
    /// 需求要求「添加文件」与「说话」两个按钮外观一致、下排功能按钮形状大小统一。
    /// 把它做成一个修饰器而不是各自写一遍 `frame + background + overlay`，
    /// 是为了让这件事成为**结构性约束** —— 三处不可能再各自漂移。
    struct ComposerButtonChrome: ViewModifier {

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

}
