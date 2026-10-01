import AppCore
import SwiftUI

/// 排版档位：**字号倍率 + 纵向留白倍率**。
///
/// 为什么要这一层（2026-10-01）：全仓库有 1161 处 `.appFont(N)`
/// 直接写在调用点上，没有任何语义令牌。字号一散在调用点，「用户想看大一点」
/// 就只能一处一处改 —— 而这类改动的终局一定是有人漏掉某一处，界面里同时出现
/// 三种字号。于是把「档位 → 实际字号」收成**一个纯函数**，调用点只写基准值。
///
/// 标准档必须**逐字等价于**原来的 `.appFont(N)`：`scale == 1` 时
/// `font(_:weight:design:)` 与 `.system(size:weight:design:)` 完全同参，
/// 所以这次改造可以用「像素对比」证明没有回归（详见 RenderTests）。
public struct AppTypography: Sendable, Equatable {

    /// 字号倍率（1 = 设计基准，与改造前逐字一致）。
    public var textScale: CGFloat
    /// 纵向留白倍率（1 = 设计基准）。
    public var verticalScale: CGFloat

    public init(textScale: CGFloat, verticalScale: CGFloat) {
        self.textScale = textScale
        self.verticalScale = verticalScale
    }

    public init(typeSize: FontSizeMode, density: DensityMode) {
        self.init(textScale: typeSize.scale, verticalScale: density.verticalScale)
    }

    /// 标准档：**必须与未加令牌时完全一致**，这是改造无回归的前提。
    public static let standard = AppTypography(textScale: 1, verticalScale: 1)

    /// 基准字号 → 实际字号。
    ///
    /// 下限 7pt：档位再小也不该缩成看不见（ macOS 上 7pt 以下基本不可读），
    /// 且负值/0 会让 `Font` 直接抛异常。
    public func size(_ base: CGFloat) -> CGFloat {
        max(base * textScale, 7)
    }

    public func font(_ base: CGFloat,
                     weight: Font.Weight = .regular,
                     design: Font.Design = .default) -> Font {
        .system(size: size(base), weight: weight, design: design)
    }

    /// 纵向留白：卡片上下、区块之间。密度档唯一的着力点。
    public func vertical(_ base: CGFloat) -> CGFloat {
        base * verticalScale
    }

    /// 横向留白**不随密度变**。
    ///
    /// 为什么横向不缩放：横向一放大就会在固定宽度的卡片里把文字挤到裁切线外
    /// （气泡、chip、按钮都是定宽）；纵向多半能滚，撑高了看得出、也读得到。
    /// 宁可让宽松档只体现在「行与行更松」，也不要出现横向被截断的字。
    public func horizontal(_ base: CGFloat) -> CGFloat {
        base
    }
}

// MARK: - 档位 → 数值

// 档位本体（`FontSizeMode` / `DensityMode`）定义在 AppCore —— 它们要进配置文件；
// 这里的扩展只负责「档位 → 数值」这一步排版决策。

/// 字号档。倍率刻意保守：±6~10% 已经能明显改变阅读负担，
/// 再大就会开始撞固定高度的表头 / chip，把字挤出去。
public extension FontSizeMode {
    var scale: CGFloat {
        switch self {
        case .small: return 0.94
        case .regular: return 1
        case .large: return 1.1
        }
    }
}

/// 界面密度档：只改**纵向**留白（理由见 `AppTypography.horizontal`）。
public extension DensityMode {
    var verticalScale: CGFloat {
        switch self {
        case .compact: return 0.85
        case .regular: return 1
        case .spacious: return 1.2
        }
    }
}

// MARK: - 环境值

private struct AppTypographyKey: EnvironmentKey {
    static let defaultValue: AppTypography = .standard
}

public extension EnvironmentValues {

    /// 当前生效的排版档位。**必须**用 `.appTypographyRoot(...)` 在根上注入一次，
    /// 否则整棵树都拿 `.standard`（忘了注入不会报错，只会静默不生效）。
    var appTypography: AppTypography {
        get { self[AppTypographyKey.self] }
        set { self[AppTypographyKey.self] = newValue }
    }
}

// MARK: - View 便捷入口

public extension View {

    /// 在**应用根注入一次**（`MainView`）。Sheet / popover 挂在另一条分支上，
    /// 覆盖不到的地方要各自再写一次。
    func appTypographyRoot(typeSize: FontSizeMode = .regular,
                           density: DensityMode = .regular) -> some View {
        environment(\.appTypography, AppTypography(typeSize: typeSize, density: density))
    }

    /// 字号入口：替代 `.font(.system(size:weight:design:))`。
    /// 调用点写**基准值**，实际字号由档位决定。
    ///
    /// `italic` 收编了原写法 `.font(.system(...).italic())`——对 `Font` 的修饰
    /// 必须留在令牌层里做，否则调用点拿不到 `Font`、链不上 `.italic()`。
    func appFont(_ size: CGFloat,
                 weight: Font.Weight = .regular,
                 design: Font.Design = .default,
                 italic: Bool = false) -> some View {
        modifier(AppFontModifier(base: size, weight: weight, design: design, italic: italic))
    }

    /// 间距入口：替代 `.padding(_:_:)`。**只缩放纵向**（`horizontal` 保持原值）。
    ///
    /// 两个重载对应 `.padding(N)` 与 `.padding(edges, N)` 两种原形态 ——
    /// 不能用「edges 带默认值」的单签名：Swift 不允许位置实参跳过第一个参数，
    /// `appPadding(18)` 会被当成给 `edges` 传 Int 而编不过。
    func appPadding(_ length: CGFloat) -> some View {
        appPadding(.all, length)
    }

    func appPadding(_ edges: Edge.Set, _ length: CGFloat) -> some View {
        modifier(AppPaddingModifier(edges: edges, length: length))
    }
}

private struct AppFontModifier: ViewModifier {
    let base: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let italic: Bool
    @Environment(\.appTypography) private var typography

    func body(content: Content) -> some View {
        let font = typography.font(base, weight: weight, design: design)
        return content.font(italic ? font.italic() : font)
    }
}

private struct AppPaddingModifier: ViewModifier {
    let edges: Edge.Set
    let length: CGFloat
    @Environment(\.appTypography) private var typography

    func body(content: Content) -> some View {
        // `.all` 与 `.vertical` / `.top` / `.bottom` 走缩放；其余（含 `.horizontal`）
        // 原样透出 —— 横向缩放会裁字，所以这一档对它们本来就是恒等。
        // 判「是否含纵向边」而不是比对整个集合：`Edge.Set` 是 OptionSet，
        // 组合值（如 `[.top, .horizontal]`）与 `.all` 并不相等。
        let touchesVertical = edges.contains(.top)
            || edges.contains(.bottom)
            || edges == .vertical
            || edges == .all
        let scaled = touchesVertical ? typography.vertical(length) : typography.horizontal(length)
        return content.padding(edges, scaled)
    }
}
