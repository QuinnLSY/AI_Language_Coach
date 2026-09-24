import SwiftUI

// MARK: - 统一的按压反馈

/// 全应用统一的按钮按压反馈（2026-09-25 第一批）。
///
/// **为什么只做不透明度、不做缩放**：本项目有 165 处 `Button`，形状从纯图标
/// 到「整张卡片就是按钮」都有。`.scaleEffect(0.96)` 作用在后者身上，按下时整张
/// 卡的边缘会抖一下 —— 在 macOS 上那不是反馈，是穿帮。**不改布局的反馈才是
/// 安全的反馈**：本 styles 不引入任何几何变化，命中区与周围布局完全不受影响。
///
/// **为什么是 `ButtonStyle` 而不是 `PrimitiveButtonStyle`**：后者要自己挂点击手势
/// 和键盘响应，一旦漏挂就把 VoiceOver / 键盘可达性弄丢了（与 MEMORY「协议要求
/// 的签名绝不能删」是同一类教训）。前者只接管外观，激活行为继续由系统负责。
///
/// **为什么不管禁用态**：系统 `.disabled()` 已经会弱化 label；这里再叠一层透明度
/// 会让自绘的禁用色淡到看不清（模块炼就习惯里最常踩的一类「双重弱化」）。
public struct AppButtonStyle: ButtonStyle {

    /// 按下时的不透明度。0.6 ≈ macOS 系统控件按下的观感。
    var pressedOpacity: Double

    @Environment(\.appMotion) private var motion

    public init(pressedOpacity: Double = 0.6) {
        self.pressedOpacity = pressedOpacity
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(motion.animation(.press), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == AppButtonStyle {

    /// 默认按压反馈（`.buttonStyle(.appPressable)`）。
    static var appPressable: AppButtonStyle { AppButtonStyle() }

    /// 更克制的按压反馈 —— 给本身就很大、变暗 40% 会过于明显的整块区域。
    static func appPressable(opacity: Double) -> AppButtonStyle {
        AppButtonStyle(pressedOpacity: opacity)
    }
}
