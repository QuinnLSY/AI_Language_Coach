import AppKit
import SwiftUI

/// 点击「非文本输入」的地方时，让输入框放弃键盘焦点。
///
/// 为什么必须自己做：AppKit 里窗口的第一响应者**不会**因为一次鼠标点击而改变 ——
/// 点到按钮 / 下拉框 / 空白处时，输入框仍然持有第一响应者：光标继续闪，
/// 之后的按键（包括各种快捷键）也继续被这个输入框吃掉。用户实测的诉求就是这一条：
/// 「点击输入框外区域时不应继续锁定，否则快捷键始终映射到输入框里造成冲突」。
/// SwiftUI 没有「点外面就失焦」的开关，所以给窗口挂一个**本地事件监视器**：
/// 鼠标按下时若落点不在任何文本输入控件上，就把第一响应者收回来。
///
/// 安全边界（缺一不可）：
/// - 只处理**本视图所在窗口**的事件。监视器是进程级的，不圈窗口就会误伤别的窗口；
/// - 只在该窗口确实有文本输入处于编辑态（第一响应者是字段编辑器）时动手，
///   因此不会干扰按钮自身的高亮与点击；
/// - 落点若在输入框上（含它的外框），直接放行 —— 那是正常的焦点转移。
struct OutsideClickFocusRelease: NSViewRepresentable {

    /// AppKit 层面失焦**不会**自动同步回 SwiftUI 的 `@FocusState`，所以额外给一个回调。
    var onRelease: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onRelease: onRelease) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onRelease = onRelease
        // 视图真正入窗发生在 `makeNSView` 返回之后，所以在这里再试一次（幂等）。
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var onRelease: () -> Void

        private weak var window: NSWindow?
        private var monitor: Any?
        /// 视图已经拆掉（面板关闭）后不要再装监视器：`attach` 是延迟一轮执行的。
        private var isDetached = false

        init(onRelease: @escaping () -> Void) { self.onRelease = onRelease }

        func attach(to view: NSView) {
            guard monitor == nil, !isDetached else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                guard !self.isDetached, self.monitor == nil, let window = view.window else { return }
                self.window = window
                self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                    self?.handle(event)
                    return event
                }
            }
        }

        func detach() {
            isDetached = true
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            window = nil
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            // 没有文本在编辑就什么都不用做。
            // `NSTextView` 是字段编辑器本体的类型 —— 输入框获得焦点后，
            // 真正持有第一响应者的就是它，而不是 `NSTextField`。
            guard window.firstResponder is NSTextView else { return }
            guard let content = window.contentView else { return }
            let hit = content.hitTest(event.locationInWindow)
            guard !Self.isTextInput(hit) else { return }
            window.makeFirstResponder(nil)
            onRelease()
        }

        /// 落点（含祖先链）里有没有文本输入控件。
        ///
        /// 两种都要认：`NSTextView` = 字段编辑器（点在文字上）；
        /// `NSTextField` = 输入框外框（点在框的留白/边框上也算「在框里」，不该失焦）。
        private static func isTextInput(_ view: NSView?) -> Bool {
            var node: NSView? = view
            while let current = node {
                if current is NSTextView || current is NSTextField { return true }
                node = current.superview
            }
            return false
        }
    }
}

extension View {
    /// 点击文本输入之外的区域时收起键盘焦点（详见 `OutsideClickFocusRelease`）。
    func releaseKeyboardFocusOnOutsideClick(onRelease: @escaping () -> Void = {}) -> some View {
        background(
            OutsideClickFocusRelease(onRelease: onRelease)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}
