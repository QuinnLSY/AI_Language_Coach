import SwiftUI

// MARK: - 浮层统一 ESC（#体验闭环 / #S2-1 栈顶仲裁）

extension View {
    /// 给浮层挂「按 Esc = 关闭」。
    ///
    /// 实现走 `keyboardShortcut(.escape)`（与设置页右上角 × 同一机制 —— 那是全应用
    /// 第一处 ESC 关闭，本修饰器把这条约定推广到所有全屏浮层）：
    /// - 挂在一个透明零尺寸按钮上，不参与布局、不进无障碍树；
    /// - 录制快捷键期间（快捷键录制器的事件监视器先吃按键）ESC 不会漏进来，安全。
    ///
    /// ⚠️ **`isActive` 不能省**：浮层**可以同屏叠放**（情景面板 + 上传材料 / 描述场景 /
    /// 再叠设置页，最多三个），而每个 `escCloses` 都是一个彼此平等、毫不知情的
    /// `.escape` 键等价项 —— 谁被命中由 SwiftUI 内部顺序决定，仓库里判定不了。
    /// 同屏时一次 Esc 关掉底下那层、顶层还挂着，就是这个前提没守住的结果。
    /// 传 `isActive: state.escDismissLayer == .xxx`，由 `EscDismissLayer.topmost` 选唯一栈顶。
    ///
    /// 刻意**不挂**的浮层：
    /// - 入学定级（`placementOverlay`）：答题中途误按 Esc 太亏，与「点遮罩不关」同一哲学；
    /// - 划词气泡：收起走 hover 宽限机制（`WordLookupBubblePresenter`），焦点不在浮层窗口。
    func escCloses(_ action: @escaping () -> Void, isActive: Bool = true) -> some View {
        background {
            if isActive {
                Button(action: action) {
                    Text("关闭")
                }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
    }

    /// 只在 `isActive` 时挂 Esc 键等价。
    ///
    /// 给**不能删掉原按钮**的场景用（设置页右上角 × 是真按钮，只是它的 Esc 要参与栈顶仲裁）：
    /// 先无条件 `escShortcut(isActive:)` 再无条件 `keyboardShortcut(.escape)` 的话，
    /// 后挂的那个会覆盖前者，退化成「永远可关」—— 那正是要修的毛病。
    @ViewBuilder
    func escShortcut(isActive: Bool) -> some View {
        if isActive {
            keyboardShortcut(.escape, modifiers: [])
        } else {
            self
        }
    }
}