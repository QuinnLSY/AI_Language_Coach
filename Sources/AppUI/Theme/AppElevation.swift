import SwiftUI

// MARK: - 阴影档位（2026-09-27 第三批 #361）

/// 卡片离页面的「高度」分档。
///
/// 为什么收成档：改之前全项目散着 4 / 5 / 6 / 8 / 10 / 14 / 30 七种阴影半径，
/// 同一层级的东西在不同页面浮起的高度不一样，看不出「谁压着谁」——
/// 这是界面显得杂乱的一个隐性来源，与配色无关，纯粹缺一层约定。
///
/// **分档依据是浮起的原因，不是页面**：
/// - `card` 贴在内容流里，只比背景高一点点；
/// - `raised` 悬停在内容上方（黑板 / 划词卡 / 侧栏浮卡），要明显脱离下层；
/// - `overlay` 全局浮层（toast / 结算卡），在一切之上；
/// - `sheet` 盖住整栏的浮层面板。
public enum AppElevation: Sendable, CaseIterable {

    case card
    case raised
    case overlay
    case sheet

    /// 阴影参数。`x` 恒为 0：光从正上方来，斜着的光会让两档看起来方向不一致。
    public var style: AppElevationStyle {
        switch self {
        case .card: AppElevationStyle(radius: 8, y: 3)
        case .raised: AppElevationStyle(radius: 10, y: 4)
        case .overlay: AppElevationStyle(radius: 14, y: 6)
        case .sheet: AppElevationStyle(radius: 30, y: 14)
        }
    }
}

/// 一档阴影的几何参数（颜色由主题 `shadow` 出，不在这里）。
public struct AppElevationStyle: Sendable, Equatable {
    public let radius: CGFloat
    public let y: CGFloat

    public init(radius: CGFloat, y: CGFloat) {
        self.radius = radius
        self.y = y
    }
}

public extension View {

    /// 按档位加阴影（颜色走主题 `shadow`，日夜自动跟随）。
    ///
    /// ⚠️ 例外（有意不走这套的，别「顺手统一」）：
    /// - `ModelToast` 的阴影用**自发光色**（成功绿 / 失败红的 tint 光晕）——
    ///   那是「状态发光」这另一套表达手段，不是层级；
    /// - 插画里的光（`ForestSky` 星星、`AppLogo`）是装饰，不是层级。
    func appElevation(_ level: AppElevation) -> some View {
        modifier(AppElevationModifier(level: level))
    }
}

private struct AppElevationModifier: ViewModifier {
    @Environment(\.forestTheme) private var theme
    let level: AppElevation

    func body(content: Content) -> some View {
        let style = level.style
        content.shadow(color: theme.shadow, radius: style.radius, x: 0, y: style.y)
    }
}

// MARK: - 浮层材质

public extension View {

    /// 浮层表面（材质体系）：系统未开「降低透明度」时，超薄材质垫底 +
    /// 主题 panel 半透明叠色 —— 毛玻璃让浮层「透出底下还有内容」，这是
    /// 浮层和普通卡片在**质感**上的分界；开了「降低透明度」就整层退回实底 panel。
    ///
    /// 只给**悬停在内容上方**的浮层用（结算 toast / 侧栏浮卡 / 划词卡）；
    /// 内容流里的卡片永远实底 —— 一页全是毛玻璃等于没有层级。
    func floatingSurface<S: Shape>(in shape: S) -> some View {
        modifier(FloatingSurfaceModifier(shape: shape))
    }
}

private struct FloatingSurfaceModifier<S: Shape>: ViewModifier {
    @Environment(\.forestTheme) private var theme
    @Environment(\.appMotion) private var motion
    let shape: S

    func body(content: Content) -> some View {
        content.background {
            if motion.reduceTransparency {
                shape.fill(theme.panel)
            } else {
                shape
                    .fill(theme.panel.opacity(0.78))
                    .background(.ultraThinMaterial, in: shape)
            }
        }
    }
}
