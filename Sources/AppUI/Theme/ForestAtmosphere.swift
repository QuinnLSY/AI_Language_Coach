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

/// 天气（#418-A 建立，2026-10 收窄为晴 / 下雨 / 下雪三档）。
///
/// ⚠️ 原先是 clear / cloudy / rain 三档，用户明确要「天气只有下雨、下雪」——
/// 「多云」去掉，云量不再单独表达，改成「有降水的天云更密」（见 `ForestSky` 的
/// `Clouds(dense:)`）：真实世界里雨雪天本就少见晴空白云，这样反而更自然。
///
/// 与时刻 / 季节一样**只改插画层** —— 下不下雨、下不下雪，语义色一行不碰。
/// 夜里也下（雨丝换亮一档、雪片换亮一档的颜色），「跟随天气」不挑时候。
public enum ForestWeather: String, CaseIterable, Sendable, Identifiable {

    /// 晴（无降水）。**载体不能省**：跟随天气开着而今天晴时，`ForestTheme.weather`
    /// 需要一个非 nil 值来表达「看了天气、结论是无降水」—— 否则「晴」与「不跟随天气」
    /// 会挤在同一个 nil 上，渲染层分不开（手动选天气也只有下雨 / 下雪两个选项，
    /// 晴天是自动识别或关掉天气时的样子）。
    case clear
    case rain
    case snow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clear: "晴"
        case .rain: "下雨"
        case .snow: "下雪"
        }
    }
}

/// 学习节奏（#600：学业数据驱动森林氛围的三档）。
///
/// 与季节 / 天气的分工：那两者表达「林子自己长到哪 / 天上什么天气」，
/// 这一档表达「**你**最近学得怎么样」—— 连胜一周且今日目标达成时林子进入丰季。
///
/// ⚠️ **非惩罚性设计**：停滞档没有任何负面效果（叶色不衰、天气不加码），
/// 只有丰季有正反馈。学得断了一天不该被森林「脸色」二次打击。
public enum ForestMomentum: String, CaseIterable, Sendable, Identifiable {

    /// 停滞：今天没练、连胜 0。
    case resting
    /// 成长：今天练过，或连胜还没断。
    case growing
    /// 丰季：连胜 ≥ 7 天**且**今日目标已达成（两个都要，「学得久」与「今天达标」各表一半）。

    case flourishing

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .resting: "休憩"
        case .growing: "成长"
        case .flourishing: "丰季"
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

    // MARK: - 学习节奏（#600）

    /// 学业数据 → 学习节奏（纯函数，便于单测）。
    ///
    /// 三个输入都来自 `ProgressSnapshot`（UI 只读它，不自己做统计）：
    /// - `streakDays`：连续练习天数（今天没练则从昨天往前数）；
    /// - `goalReached`：今日目标（分钟）已达成；
    /// - `hasPracticeToday`：今天有没有练过（与 `streakDays > 0` 不是一回事 ——
    ///   连胜可以从昨天继承，今天还没开口）。
    ///
    /// 判据：
    /// - `flourishing`（丰季）= 连胜 ≥ 7 **且** 今日达标。两个都要：
    ///   只答一条说明「底子厚但今天没学」或「今天学了但没连续」，都够不上丰季；
    /// - `growing`（成长）= 今天练过，或连胜还没断（≥ 1 天）；
    /// - `resting`（休憩）= 都没占上。
    public static func momentum(streakDays: Int, goalReached: Bool,
                                hasPracticeToday: Bool) -> ForestMomentum {
        if streakDays >= 7 && goalReached { return .flourishing }
        if streakDays >= 1 || hasPracticeToday { return .growing }
        return .resting
    }

    /// 把颜色「养盛」一点：同色相、饱和度 ×1.18、亮度 ×0.92（纯函数，便于单测）。
    ///
    /// 为什么用变换而不是给丰季手搓一套色板：手搓的魔法色值三个月后没人说得清
    /// 「为什么是这个数」，而变换的规则一句话能讲完 —— 「更饱和、更深，像雨水浇过的盛叶」。
    /// 灰色（饱和度为 0）原样返回：灰没有「盛」可言。
    ///
    /// ⚠️ 只给**插画层**用（叶色 / 山丘），语义色一概不碰 —— 那是被对比度钉住的地界。
    public static func lush(_ hex: UInt32) -> UInt32 {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        guard delta > 0 else { return hex } // 灰色：没有「盛」可言
        let lightness = (maxV + minV) / 2
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if maxV == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxV == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        let boostedSaturation = min(saturation * 1.18, 1)
        // 下限 0.02：深色（夜档树阴那类）不能一遍遍压成纯黑。
        let deepenedLightness = max(lightness * 0.92, 0.02)
        let chroma = (1 - abs(2 * deepenedLightness - 1)) * boostedSaturation
        let second = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let match = deepenedLightness - chroma / 2
        let rgb: (Double, Double, Double)
        switch hue {
        case 0..<60: rgb = (chroma, second, 0)
        case 60..<120: rgb = (second, chroma, 0)
        case 120..<180: rgb = (0, chroma, second)
        case 180..<240: rgb = (0, second, chroma)
        case 240..<300: rgb = (second, 0, chroma)
        default: rgb = (chroma, 0, second)
        }
        func channel(_ value: Double) -> UInt32 {
            let scaled = ((value + match) * 255).rounded()
            return UInt32(min(max(scaled, 0), 255))
        }
        return (channel(rgb.0) << 16) | (channel(rgb.1) << 8) | channel(rgb.2)
    }

    // MARK: - 天气（#418-A 建立，2026-10 收窄为晴 / 雨 / 雪）

    /// 年内日序（1...366）→ 当天的天气。
    ///
    /// 为什么是**日期**不是随机数：天气不能在一天里翻来覆去 —— 同一天打开应用
    /// 一百次，看到的必须是同一种天气。判据用 Knuth 乘法散列把日子摊开：
    /// 相邻两天相差 `multiplier % 100 = 61`（与 100 互质），整年铺满后
    /// 恰好五成晴、其余五成看季节 —— 冬天落雪、其余落雨。落进哪档只看散列值，
    /// 没有玄学。
    ///
    /// ⚠️ 这是**本地兜底模拟**（断网 / 定位失败时的样子）。接了真天气预报之后
    /// （见 #604），自动档改问 Open-Meteo，这个函数只在取不到预报时兜底。
    ///
    /// - Parameter momentum: 学习节奏（#600）。`flourishing` 时本地模拟**偏晴**
    ///   （晴的门槛从 50 提到 85）—— 「今日目标达成，天公作美」。⚠️ 只动兜底模拟：
    ///   真天气预报拿到了仍然以真天气为准（见 `ForestThemeResolver`），绝不拿本地偏晴
    ///   去覆盖一个真实的雨天。全年分布：常态晴 183 / 雨 137 / 雪 46；
    ///   丰季晴 312 / 雨 41 / 雪 13（雪不会绝迹，冬天照样下）。
    ///
    /// 越界钳回 1...366：平年 2 月没有 366 也照算，不至于崩。
    public static func weather(dayOfYear: Int, momentum: ForestMomentum? = nil) -> ForestWeather {
        let day = min(max(dayOfYear, 1), 366)
        let hash = (day * 2_654_435_761) % 100
        let clearThreshold = momentum == .flourishing ? 85 : 50
        if hash < clearThreshold { return .clear }
        return isWinterDay(day) ? .snow : .rain
    }

    /// 这一天在不在冬季（12 / 1 / 2 月）—— **降水形态**的判据：冬雪、其余雨。
    ///
    /// 月份按年内日序近似换算（平年口径；闰年只挪 2 月 29 日一天，冬夏判据不受影响）。
    /// 单独成形而不是塞进 `weather(dayOfYear:)` 里：接入真天气预报后（#604），
    /// 「降水形态看气温还是看月份」会是同一处判据的两套数据源，先留好这个钉子。
    public static func isWinterDay(_ dayOfYear: Int) -> Bool {
        let day = min(max(dayOfYear, 1), 366)
        // 1 月 1–31、2 月 32–59、12 月 335–366（闰年 366 仍归 12 月）。
        return day <= 59 || day >= 335
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
