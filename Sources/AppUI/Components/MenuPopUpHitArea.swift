import AppKit
import SwiftUI

/// 下拉控件的**命中区**：一个真正的 `NSView`，鼠标按下时自己弹 `NSMenu`。
///
/// 为什么不用 SwiftUI `Menu`（2026-09-14 用户反馈「选择按钮点不动」后重做）：
/// `Menu` 的外观是可以自己画的，但**命中区不行** —— `Menu` 的 label 是透明视图时，
/// 系统给它的是「空视图」的尺寸提案，实测无障碍层读出来只有 **6×14**，
/// 于是控件看着有 250×30，实际只有中间一小块能点：用户必须点得非常准，
/// 感受就是「很难响应甚至不响应」。用 `.frame(width:height:)` 强塞尺寸也修不掉
/// （那是 label 内部拿到的提案，和我们给外层的 frame 不是一回事）。
///
/// 改成 AppKit 命中区后：
/// 1. 命中范围**就是**这个 view 的 bounds，范围可控、可读取（无障碍尺寸也正常了）；
/// 2. 菜单由 `mouseDown` 主动弹出，不再依赖系统对空 label 的处理；
/// 3. 键盘（空格 / 回车 / 下箭头）与 VoiceOver 的「按下」都能打开。
struct MenuPopUpHitArea: NSViewRepresentable {

    /// 菜单项标题，顺序即索引。
    let titles: [String]
    /// 当前选中项（画对勾）；nil 表示无选中。
    let selectedIndex: Int?
    let isEnabled: Bool
    /// 无障碍标签（VoiceOver 读出「模型：xxx」这类信息）。
    let accessibilityTitle: String
    /// 光标提示。
    let tooltip: String?
    /// 命中范围收成**圆形**（给圆形按钮用，免得矩形四角抢邻居的点击）。
    var isCircular: Bool = false
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> PopUpHitView {
        let view = PopUpHitView()
        view.apply(
            titles: titles, selectedIndex: selectedIndex, isEnabled: isEnabled,
            accessibilityTitle: accessibilityTitle, tooltip: tooltip,
            isCircular: isCircular, onSelect: onSelect
        )
        return view
    }

    func updateNSView(_ view: PopUpHitView, context: Context) {
        view.apply(
            titles: titles, selectedIndex: selectedIndex, isEnabled: isEnabled,
            accessibilityTitle: accessibilityTitle, tooltip: tooltip,
            isCircular: isCircular, onSelect: onSelect
        )
    }
}

/// 命中区实现。只负责「被点到 → 弹菜单 → 回调索引」，不画任何东西。
final class PopUpHitView: NSView {

    private var titles: [String] = []
    private var selectedIndex: Int?
    private var isEnabled = true
    private var accessibilityTitle = ""
    /// 命中范围收成圆形（圆形按钮用；nil/flat 时就是整个 bounds）。
    private var isCircular = false
    private var onSelect: ((Int) -> Void)?

    /// 与外层 SwiftUI 一致：从上往下排，菜单从下边缘往外弹更自然。
    override var isFlipped: Bool { true }
    /// 窗口未激活时的第一次点击也生效（用户从别处切回来时常直接点它）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { .zero }

    func apply(
        titles: [String], selectedIndex: Int?, isEnabled: Bool,
        accessibilityTitle: String, tooltip: String?, isCircular: Bool = false,
        onSelect: @escaping (Int) -> Void
    ) {
        self.titles = titles
        self.selectedIndex = selectedIndex
        self.isEnabled = isEnabled
        self.accessibilityTitle = accessibilityTitle
        self.isCircular = isCircular
        self.onSelect = onSelect
        self.toolTip = tooltip
        if !isEnabled { window?.makeFirstResponder(nil) }
        window?.invalidateCursorRects(for: self)
    }

    /// 命中范围：默认整个 bounds；`isCircular` 时只有圆内才算「点到了」。
    ///
    /// 为什么要收圆：圆形按钮并排时，矩形四角会伸进邻居的领地抢点击
    /// （原 `Menu` label 上是 `.contentShape(Circle())` 干这事，换成 NSView 后得自己来）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isCircular {
            let local = convert(point, from: superview)
            let dx = local.x - bounds.midX
            let dy = local.y - bounds.midY
            let radius = min(bounds.width, bounds.height) / 2
            guard dx * dx + dy * dy <= radius * radius else { return nil }
        }
        return super.hitTest(point)
    }

    /// 悬停出「可点」光标：用户反馈里「点了没反应」有很大一部分是**不确定能不能点**。
    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !titles.isEmpty else { return }
        present()
    }

    override func keyDown(with event: NSEvent) {
        // 空格 / 回车 / 下箭头打开菜单；其余交给系统（Tab 仍可移出焦点）。
        let opens: Set<UInt16> = [49, 36, 76, 125]
        if opens.contains(event.keyCode) { present() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {}

    /// 弹菜单。`popUp` 会接管后续事件直到用户选中或取消（系统行为）。
    private func present() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selectedIndex ? .on : .off
            item.toolTip = title
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        select(index: sender.tag)
    }

    /// 选中第 `index` 项并回调（菜单点击与键盘都走这里；也让 wiring 可脱机测试）。
    func select(index: Int) {
        guard titles.indices.contains(index) else { return }
        onSelect?(index)
    }

    /// 当前列出的菜单项（只读，测试与无障碍共用）。
    var menuTitles: [String] { titles }

    // MARK: - 无障碍
    //
    // 透明命中区在系统眼里默认「没有内容」，VoiceOver 完全读不到。
    // 这里显式声明成弹出按钮并给出值，读屏与自动化（AXPress）都能正常工作。

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityLabel() -> String? { accessibilityTitle }
    override func accessibilityValue() -> Any? {
        selectedIndex.flatMap { titles.indices.contains($0) ? titles[$0] : nil }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !titles.isEmpty else { return false }
        present()
        return true
    }
    override func accessibilityChildren() -> [Any]? { nil }
}
