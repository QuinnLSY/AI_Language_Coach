import AIDomain
import AppKit
import SwiftUI

/// 聊天输入框（第 2 项需求）：固定行宽、超宽自动换行、**向上拓宽、最多 5 行**，
/// 超过 5 行只显示最后 5 行并由滚动条浏览全部内容。
///
/// 为什么用 `NSTextView` 而不是 SwiftUI 的 `TextEditor`：
/// 1. `TextEditor` 没法区分「回车发送」与「Shift+回车换行」—— 而多行输入框必须有这个区分，
///    否则用户永远打不出第二行；
/// 2. 高度要按**真实排版结果**算（中英混排 + 换行后的视觉行数），
///    只有 TextKit 的 `usedRect` 能给出这个数；靠字符数估算会出现「第 5 行被切一半」。
///
/// 高度规则本身在 `AIDomain.ComposerMetrics`（纯函数、有测试），这里只负责量出内容高度。
struct MultilineComposerField: NSViewRepresentable {

    @Binding var text: String
    /// 上报**夹取后**的显示高度，由父视图用它设置 frame。
    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool

    var fontSize: CGFloat = 14
    var textColor: NSColor
    var insertionColor: NSColor
    /// 回车（不带 Shift）时回调：发送。
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // 滚动条：内容超过 5 行时**常显**，让「还能往下看」这件事看得见。
        //
        // 这里敢关掉 `autohidesScrollers`，是因为样式固定为 `.overlay` ——
        // 滚动条浮在文字之上、**不参与布局**，因此不会出现「滚动条一出现就把文字挤窄、
        // 行数变化又让滚动条消失」的抖动循环（那才是自动隐藏要避免的问题）。
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.usesFindPanel = false
        textView.font = Self.font(fontSize)
        textView.textColor = textColor
        textView.insertionPointColor = insertionColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // 宽度跟随、高度自己管：`isVerticallyResizable = false` + 手工设 frame，
        // 让「内容高于可视区就滚动」这件事是确定性的，而不是交给 autoresizing 去猜。
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        // 初值：先按一行上报，避免第一帧高度为 0（那会看到输入框「跳」一下）。
        DispatchQueue.main.async {
            context.coordinator.reportHeight(notify: true)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self

        // ⚠️ 只在**真正不同**时写回文本：无条件赋值会把光标顶到文末，
        // 表现为「打一个字光标就跳到结尾」，中间插字完全没法用。
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let limit = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, limit), length: 0))
            context.coordinator.reportHeight(notify: true)
        }

        textView.font = Self.font(fontSize)
        textView.textColor = textColor
        textView.insertionPointColor = insertionColor

        // 可视区高度变了（内容变短 / 窗口缩放）→ 重算一次 document 高度，
        // 否则 text view 会一直保持着上一次的较高尺寸，能往空白处滚。
        // 这里**不上报** measuredHeight：那会与「父视图改 frame」形成回环。
        if abs(context.coordinator.lastVisibleHeight - scrollView.contentSize.height) > 0.5 {
            context.coordinator.lastVisibleHeight = scrollView.contentSize.height
            context.coordinator.reportHeight(notify: false)
        }

        // 焦点：由 SwiftUI 侧的意图单向驱动，并且**只在需要时改**，
        // 否则每帧抢一次 first responder，用户点别处就再也移不开焦点。
        let window = scrollView.window
        if isFocused, let window, window.firstResponder !== textView {
            DispatchQueue.main.async { window.makeFirstResponder(textView) }
        }
    }

    static func font(_ size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Coordinator

    /// `@unchecked Sendable` 的理由：本对象**只在主线程被创建与访问**
    /// （SwiftUI 建视图在主线程、AppKit 的 delegate 回调也在主线程），
    /// 之所以要显式声明，是因为高度上报要走一次 `DispatchQueue.main.async`
    /// （在 `updateNSView` 里同步写绑定额度=「视图更新期间改状态」的运行期警告）。
    final class Coordinator: NSObject, NSTextViewDelegate, @unchecked Sendable {
        var parent: MultilineComposerField
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        /// 上一次上报的高度：用于去重，避免「上报 → 父视图改 frame → 再上报」的抖动循环。
        private var lastReported: CGFloat = 0
        /// 上一次的可视区高度：变化时重算 document 高度（内容变短后不留空白可滚区）。
        var lastVisibleHeight: CGFloat = 0

        init(parent: MultilineComposerField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            reportHeight(notify: true)
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused {
                DispatchQueue.main.async { [weak self] in self?.parent.isFocused = true }
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused {
                DispatchQueue.main.async { [weak self] in self?.parent.isFocused = false }
            }
        }

        /// 回车 = 发送；**Shift + 回车 = 换行**。
        ///
        /// 没有这个分支，多行输入框就永远只有一行：回车被提交吃掉，用户打不出第二行；
        /// 反过来若回车一律换行，就只剩「点发送按钮」一条路 —— 那是聊天框最不该有的手感。
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shift {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }

        /// 量出内容真实高度并夹到 5 行以内，同时把 text view 撑到「内容高度」，
        /// 让 NSScrollView 在超出可视区时自然出现滚动条。
        func reportHeight(notify: Bool) {
            guard let textView, let scrollView else { return }
            // ⚠️ 行高必须问 TextKit 要，不能用 `fontSize × 1.25` 估：
            // 系统字体的真实行高（14pt → 17.0）比那个估值（18）小，
            // 用估值封顶会让「5 行」实际能塞下 6 行；反过来字体换大时又会把第 5 行切掉。
            let lineHeight = Self.realLineHeight(textView)
            let inset = textView.textContainerInset.height
            let natural = Self.naturalContentHeight(textView)
            let clamped = ComposerMetrics.clampedHeight(
                contentHeight: natural, lineHeight: lineHeight, inset: inset
            )

            let visibleHeight = scrollView.contentSize.height
            let documentHeight = max(natural, visibleHeight)
            if abs(textView.frame.height - documentHeight) > 0.5 {
                textView.frame = NSRect(
                    x: 0, y: 0,
                    width: max(scrollView.contentSize.width, 1),
                    height: documentHeight
                )
            }
            guard notify, abs(clamped - lastReported) > 0.5 else { return }
            lastReported = clamped
            DispatchQueue.main.async { [weak self] in self?.parent.measuredHeight = clamped }
        }

        /// TextKit 的真实行高。字体测量失败时退回 `ComposerMetrics.lineHeight`，
        /// 保证返回值永远是正的（零行高会让封顶算式退化）。
        static func realLineHeight(_ textView: NSTextView) -> CGFloat {
            let font = textView.font ?? NSFont.systemFont(ofSize: 14)
            if let measured = textView.layoutManager?.defaultLineHeight(for: font), measured > 0 {
                return measured
            }
            return ComposerMetrics.lineHeight(fontSize: font.pointSize)
        }

        /// TextKit 的真实排版高度（含上下 inset）。中英混排 / 长单词折行都算得准。
        static func naturalContentHeight(_ textView: NSTextView) -> CGFloat {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return 0 }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            return (used + textView.textContainerInset.height * 2).rounded(.up)
        }
    }
}
