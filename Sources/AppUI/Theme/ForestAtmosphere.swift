import Foundation

/// 一天里的六个时刻。
///
/// ⚠️ 它只影响**插画层**（天空色、山丘、叶色），**语义色一行都不碰** ——
/// `ForestTheme` 里那些橙/紫/红是被 `ThemeContrastTests` 用对比度和 ΔE 钉住的
/// （改一处就要重算白卡与夜面板上的可读性），而天空不承担任何信息传达，
/// 它是「这一刻的林子长什么样」，可以随太阳走。
public enum ForestMoment: String, CaseIterable, Sendable, Identifiable {

    case dawn
    case morning
    case noon
    case afternoon
    case dusk
    case night

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dawn: "晨曦"
        case .morning: "上午"
        case .noon: "正午"
        case .afternoon: "午后"
        case .dusk: "黄昏"
        case .night: "夜里"
        }
    }
}

/// 四季。判据是**自然月份**，不是学习进度 —— 进度那条线已经由树冠茂密度
/// 与果实表达了（那是「你爬到哪」），季节表达的是「林子自己长到哪」。
public enum ForestSeason: String, CaseIterable, Sendable, Identifiable {

    case spring
    case summer
    case autumn
    case winter

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .spring: "春"
        case .summer: "夏"
        case .autumn: "秋"
        case .winter: "冬"
        }
    }
}

/// 天体在窗口顶部的位置（左上角坐标；`y` 是上边距）。
public struct CelestialAnchor: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}

/// 时刻 / 季节 / 天体位置的一整套纯函数（不读 `Date()`，全部由调用方传入）。
///
/// 为什么都做成纯函数：这三条判据一旦散进 View，就只能靠截图看对不对；
/// 收在这里之后，「黄昏的太阳是不是真的比正午低」这类问题是一条断言的事。
public enum ForestAtmosphere {

    /// 日出 / 日落（24 小时制）：太阳在这两点之间走完一条弧。
    public static let sunriseHour: Double = 5
    public static let sunsetHour: Double = 19

    /// 天体的固定尺寸与两侧留白（与 `CelestialToggle` 的画框一致）。
    public static let celestialSize: CGFloat = 130
    public static let celestialMargin: CGFloat = 64
    /// 弧顶的上边距（正午最高）与弧底的下坠量（日出日落最低）。
    public static let arcTop: CGFloat = 30
    public static let arcDrop: CGFloat = 90

    // MARK: - 时刻 / 季节

    /// 小时 → 时刻（越界钳回：负数按 0 点算，>23 按 23 点算）。
    public static func moment(hour: Int) -> ForestMoment {
        let hour = min(max(hour, 0), 23)
        switch hour {
        case 5..<8: return .dawn
        case 8..<11: return .morning
        case 11..<15: return .noon
        case 15..<18: return .afternoon
        case 18..<20: return .dusk
        default: return .night
        }
    }

    /// 月份 → 季节（1...12；越界钳到 1 月）。
    public static func season(month: Int) -> ForestSeason {
        switch min(max(month, 1), 12) {
        case 3...5: return .spring
        case 6...8: return .summer
        case 9...11: return .autumn
        default: return .winter
        }
    }

    /// 这一小时算不算夜里（日落之后、日出之前）。
    ///
    /// ⚠️ 与 `moment(hour:) == .night` **不是**同一件事：黄昏（18–20 点）天还亮着，
    /// 只是太阳很低 —— 「跟随时间」要的是「天黑了就切夜景」，所以看这个判据。
    public static func isNightHour(_ hour: Int) -> Bool {
        let hour = min(max(hour, 0), 23)
        return hour >= 20 || hour < 5
    }

    // MARK: - 拖天体切换日夜（批次六 · E）

    /// 拖过这个纵向距离（pt）才算「拖到了地平线以下 / 天顶以上」，轻拖不算。
    public static let celestialDragThreshold: CGFloat = 90
    /// 拖拽中视觉位移的钳制上限（pt）：太阳半径的量级，拖到底就是贴着地平线。
    public static let celestialDragClamp: CGFloat = 130

    /// 拖拽松手时该不该切换日夜（纯函数，便于单测）：
    /// 白天把太阳**往下**拖过阈值 → 入夜；夜里把月亮**往上**拖过阈值 → 回白天。
    /// 反方向拖（太阳往上 / 月亮往下）只是玩玩，不切。
    public static func shouldToggleByDrag(isNight: Bool, dragHeight: CGFloat,
                                          threshold: CGFloat = celestialDragThreshold) -> Bool {
        isNight ? dragHeight <= -threshold : dragHeight >= threshold
    }

    /// 拖拽进行中的视觉位移：只放行**该方向**的位移，越过上限就钳住 ——
    /// 有了「拖不动了」的手感，用户才知道「再拖就触发」。
    public static func clampedDragOffset(isNight: Bool, dragHeight: CGFloat,
                                         limit: CGFloat = celestialDragClamp) -> CGFloat {
        if isNight {
            return max(min(dragHeight, 0), -limit)
        }
        return min(max(dragHeight, 0), limit)
    }

    // MARK: - 天体沿弧线走

    /// 天体在窗口顶部的位置：日出从左边缘升起，正午到弧顶，日落沉到右边缘；
    /// 夜里换月亮走同一条弧。
    ///
    /// `hour` 允许带小数（分钟折算进来），位置才是连续移动的，而不是每小时跳一格。
    public static func celestialAnchor(hour: Double, width: CGFloat,
                                       size: CGFloat = celestialSize,
                                       margin: CGFloat = celestialMargin) -> CelestialAnchor {
        let hour = min(max(hour, 0), 24)
        // 白天 5→19 点，夜里 19→次日 5 点；两段都归一化成 0...1 的行程。
        let progress: Double
        if hour >= sunsetHour {
            progress = (hour - sunsetHour) / (24 - sunsetHour + sunriseHour)
        } else if hour < sunriseHour {
            progress = (hour + 24 - sunsetHour) / (24 - sunsetHour + sunriseHour)
        } else {
            progress = (hour - sunriseHour) / (sunsetHour - sunriseHour)
        }
        let clamped = min(max(progress, 0), 1)
        let travel = max(width - size - margin * 2, 0)
        let x = margin + travel * clamped
        // sin 半周期：两端低（1）、中间高（0）
        let y = arcTop + arcDrop * (1 - sin(clamped * .pi))
        return CelestialAnchor(x: x, y: y)
    }
}
