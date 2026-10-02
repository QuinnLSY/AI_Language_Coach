import SwiftUI

// MARK: - 浮层统一 ESC（#体验闭环）

extension View {
    /// 给浮层挂「按 Esc = 关闭」。
    ///
    /// 实现走 `keyboardShortcut(.escape)`（与设置页右上角 × 同一机制 —— 那是全应用
    /// 第一处 ESC 关闭，本修饰器把这条约定推广到所有全屏浮层）：
    /// - 挂在一个透明零尺寸按钮上，不参与布局、不进无障碍树；
    /// - 浮层是条件渲染的（`if state.showingXxx`），**同屏最多一个 ESC 挂载点**，
    ///   不存在「一个 Esc 触发多层」的问题；
    /// - 录制快捷键期间（快捷键录制器的事件监视器先吃按键）ESC 不会漏进来，安全。
    ///
    /// 刻意**不挂**的浮层：
    /// - 入学定级（`placementOverlay`）：答题中途误按 Esc 太亏，与「点遮罩不关」同一哲学；
    /// - 划词气泡：收起走 hover 宽限机制（`WordLookupBubblePresenter`），焦点不在浮层窗口。
    func escCloses(_ action: @escaping () -> Void) -> some View {
        background {
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
