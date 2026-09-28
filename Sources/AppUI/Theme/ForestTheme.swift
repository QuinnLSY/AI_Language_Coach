import AIDomain
import AppCore
import SwiftUI

// MARK: - 色板

public enum ForestPalette: String, CaseIterable, Sendable, Identifiable {
    case day
    case night

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .day: "白天森林"
        case .night: "夜晚森林"
        }
    }

    public var iconName: String {
        switch self {
        case .day: "sun.max.fill"
        case .night: "moon.stars.fill"
        }
    }
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// 统一语义色板。**禁止在 View 里写死颜色字面量**（AGENTS.md §10A）。
public struct ForestTheme: Sendable, Equatable {

    public let palette: ForestPalette
    /// 一天里的时刻（nil = 不跟随时间，用色板本来的天空）。
    ///
    /// ⚠️ 与 `season` 一样**只改插画层**：天空、山丘、叶色。下面那些
    /// `accent` / `warning` / `streak` / 文本与表面色一个都不看它 ——
    /// 它们被 `ThemeContrastTests` 用对比度和 ΔE 钉住，随时刻漂会当场失真。
    public let moment: ForestMoment?
    /// 季节（nil = 不分季节）。同样只改插画层。
    public let season: ForestSeason?

    public init(palette: ForestPalette, moment: ForestMoment? = nil, season: ForestSeason? = nil) {
        self.palette = palette
        self.moment = moment
        self.season = season
    }

    public var isNight: Bool { palette == .night }

    // 天空
    public var sky: [Color] {
        // 夜档不看时刻：夜里就是夜里的天空（时刻只用来给白天的天空上色）。
        if isNight {
            return [Color(hex: 0x0A1230), Color(hex: 0x152347), Color(hex: 0x24405A)]
        }
        guard let moment else {
            return [Color(hex: 0x7FD4F0), Color(hex: 0xB6EAFA), Color(hex: 0xE9F8DE)]
        }
        switch moment {
        case .dawn:
            // 上头还蓝着、地平线已经暖起来
            return [Color(hex: 0x8FB6DE), Color(hex: 0xD6DCF0), Color(hex: 0xFFD9AE)]
        case .morning:
            return [Color(hex: 0x7FD4F0), Color(hex: 0xB6EAFA), Color(hex: 0xE9F8DE)]
        case .noon:
            return [Color(hex: 0x6BCDF2), Color(hex: 0xA6E6FB), Color(hex: 0xDCF6E6)]
        case .afternoon:
            return [Color(hex: 0x86CBEE), Color(hex: 0xC2E6F5), Color(hex: 0xF5F3DA)]
        case .dusk:
            // 太阳压到山脊上：整片天被染成蜜橘色
            return [Color(hex: 0x5A7CA8), Color(hex: 0xE08A5A), Color(hex: 0xF7C97C)]
        case .night:
            return [Color(hex: 0x0A1230), Color(hex: 0x152347), Color(hex: 0x24405A)]
        }
    }

    /// 插画层的季节取色：夜里一律用色板原色（夜里看不出叶色，改了只会把夜景改坏），
    /// 白天才按季节换 —— 春嫩 / 夏盛（= 原色）/ 秋黄 / 冬雪。
    private func seasonal(day: UInt32, night: UInt32,
                          spring: UInt32, autumn: UInt32, winter: UInt32) -> Color {
        if isNight { return Color(hex: night) }
        guard let season else { return Color(hex: day) }
        switch season {
        case .spring: return Color(hex: spring)
        case .summer: return Color(hex: day)
        case .autumn: return Color(hex: autumn)
        case .winter: return Color(hex: winter)
        }
    }

    // 远景山丘 / 林冠
    public var hillFar: Color {
        seasonal(day: 0xA8DCC0, night: 0x16324A,
                 spring: 0xBCE7C6, autumn: 0xCFC294, winter: 0xDCEBF2)
    }
    public var hillMid: Color {
        seasonal(day: 0x74C79A, night: 0x143B38,
                 spring: 0x8AD3A2, autumn: 0xC2A863, winter: 0xC9DCE6)
    }
    public var hillNear: Color {
        seasonal(day: 0x3F9E67, night: 0x0F2E2B,
                 spring: 0x4FB072, autumn: 0x9E8B45, winter: 0xAFCBD8)
    }

    // 树
    public var trunk: Color { isNight ? Color(hex: 0x4A3626) : Color(hex: 0xA9743F) }
    public var trunkShade: Color { isNight ? Color(hex: 0x33251A) : Color(hex: 0x7E5228) }
    public var foliage: Color {
        seasonal(day: 0x4FA96B, night: 0x1E5346,
                 spring: 0x6CC476, autumn: 0xC08A3E, winter: 0x7FA8A0)
    }
    public var foliageDeep: Color {
        seasonal(day: 0x2E7D55, night: 0x143A31,
                 spring: 0x3E9B5C, autumn: 0x8E6428, winter: 0x5F8A84)
    }

    /// 飘落物的颜色（收词飘的那片叶子 / 通关时的落叶缤纷）。
    ///
    /// 秋天是金的、冬天是雪白的 —— 同一套飘落动画换个颜色，季节就自己说出来了。
    public var fallingFlake: Color {
        switch season {
        case .autumn: return Color(hex: isNight ? 0x6E4A22 : 0xE9A23C)
        case .winter: return Color(hex: 0xE8F4FA)
        default: return foliage
        }
    }

    // 强调
    /// 主强调色（琥珀金）：用于**文字 / 图标 / 描边 / 淡底**。
    ///
    /// ⚠️ 白档的亮度有**两条硬上限**（都不是审美，是算出来的）：
    ///
    /// 1. 它还要压在自己 `opacity(0.12)` 的淡底上当字用（「回到最初」那种描边胶囊），
    ///    黄一调亮、那层淡底跟着一起亮，有效对比度反而往下掉 —— 卡在亮度 ≈0.213；
    /// 2. 旁边那颗紫按钮（`accentCool`）在白卡片上是 **4.80:1**，用户是拿它当
    ///    「看得清」的参照说的，黄不许落后太多 —— 卡在亮度 ≈0.183。
    ///
    /// 第 2 条更紧，所以白档的黄**提不了多少**：这是「黄字压在白底上」这件事本身的
    /// 死结 —— 对比度要够，黄就必须深，而深黄在 sRGB 里就是褐色。
    ///
    /// ⚠️ 这一档改了三轮，三轮的诉求各不相同，只看最后一轮会再踩回去：
    ///
    /// - 起点 `0xFFB703`：白卡上只有 1.75:1，用户说「白天看不清」；
    /// - 09-16 压到 `0x937008`（色相 45° 金黄）：对比度达标了，但用户说
    ///   「已经变成棕色了」；
    /// - 09-21 用户要**橘色**，色相从 45° 挪到 24°（`0xBE4E04`）。
    ///
    /// ⚠️ 为什么「压暗」在黄身上必然发褐，而这不是调参能解决的：
    /// 黄在 sRGB 里亮度一旦掉到 0.18 以下，**饱和度再高也读成土黄/褐** ——
    /// 人对低亮度黄绿区的感知就是「脏」。同一个亮度下，只有把色相往橙红推
    /// （把黄绿成分退出去），低亮度才不会显脏。09-21 这一轮走的正是这条路：
    /// 亮度不动（0.164），只把色相 45°→24°、饱和度提到 96%。
    ///
    /// 两条硬上限仍然成立（都不是审美，是算出来的）：
    ///
    /// 1. 它还要压在自己 `opacity(0.12)` 的淡底上当字用（「回到最初」那种描边胶囊），
    ///    底色跟着它一起走，有效对比度会掉一截；
    /// 2. 旁边那颗紫按钮（`accentCool`）在白卡片上是 **4.80:1**，用户是拿它当
    ///    「看得清」的参照说的 —— 橙不许落后太多。
    ///
    /// | 场景 | 原色 `0xFFB703` | `0x937008`（褐） | 现在 `0xBE4E04`（橘） |
    /// |---|---|---|---|
    /// | 白天：压在白卡片上 | 1.75:1 | 4.60:1 | **4.91:1**（紫是 4.80） |
    /// | 白天：压在自己的 0.12 淡底上 | 1.73:1 | 3.97:1 | **4.16:1** |
    /// | 夜晚：压在暗底上 | 11.78:1（刺眼） | 6.86:1 | **6.24:1** |
    ///
    /// 想真正亮起来的橙只能走 `accentFill`（它上压深墨字，不受这两条约束）。
    public var accent: Color { isNight ? Color(hex: 0xE08F52) : Color(hex: 0xBE4E04) }

    /// 橙底胶囊的**填充色** —— 它上面压的是 `onAccentFill`（白档深墨、夜档暖白）。
    ///
    /// ⚠️ 别和 `accent` 合成一个令牌：同一个橙既要当「暗底上的前景」（得亮），
    /// 又要当「字脚下的底」，这俩在白档直接打架 —— 硬合成的结果就是旧的 `0xB07C12`
    /// （亮度 0.24、色相 40°），用户看了直说「已经变成棕色了」。
    ///
    /// ⚠️ 更要紧的一条：**橙底上压纯白字，等于把橙底钉死**。白字要求底够暗，而
    /// 「够暗的橙」在 sRGB 里就是褐色 —— 这是色彩空间层面的死结，调参解不开。
    /// 白档因此是**亮橙底 + 深墨字**（`0xF0A24A` 承 `0x3D2B00`，实测 6.46:1）。
    ///
    /// ⚠️ 夜档 09-21 一并调整（用户反馈「胶囊里的白字太亮，看不清」）：
    /// 底 `0xA87B26`→`0x96551C`（加深），字 `#FFFFFF`→`#F2EBE0`（暖白）。
    /// **必须成对改**：只换字色会把对比度从 3.80:1 拉到 3.21:1（更糊）；
    /// 底一起加深之后是 **4.91:1** —— 白不刺眼，字反而更清楚。
    ///
    /// ⚠️ 反过来，白档这支也有**上限**，判据是「它和所在的白卡片还能不能分开」：
    /// 橙底越亮，那个实心胶囊就越像糊进白卡片里。守卫线设在 1.5:1（现 2.11:1），
    /// 再往上不是「更亮的橙」，是「看不清的块」。
    public var accentFill: Color { isNight ? Color(hex: 0x96551C) : Color(hex: 0xF0A24A) }

    /// 压在上面那支橙底上的**字色**。白档是深墨褐（底要亮，字就得深），夜档是暖白。
    ///
    /// ⚠️ 别在 View 里再写死 `.white`：白档会直接退化成读不出的白字；
    /// 夜档也要走这里 —— 09-21 起夜档不是纯白（`#FFFFFF`）而是暖白 `0xF2EBE0`，
    /// 配加深后的橙底是 4.91:1（纯白 5.75:1 更亮但刺眼，用户要的是「不刺眼且看得清」）。
    public var onAccentFill: Color { isNight ? Color(hex: 0xF2EBE0) : Color(hex: 0x3D2B00) }

    /// **只给背景插画**（太阳 / 月晕 / 星芒）的亮黄。
    ///
    /// 插画不承担信息传达，压暗它只会让太阳变成一颗土黄色的球。反过来，
    /// UI 里那份压暗的 `accent` 也**不能**拿去画太阳。两个用途，别互相借。
    public var glow: Color { isNight ? Color(hex: 0xFFD98A) : Color(hex: 0xFFB703) }

    public var accentAlt: Color { isNight ? Color(hex: 0x8AB6FF) : Color(hex: 0xFF8FA3) }
    /// **软警告**色（原来是散在四处硬编码的 `Color.orange`）。
    ///
    /// 为什么不直接拿 `accent` 顶上：它要占住「满分 / 良好 / 加油 / 重来」这类
    /// **分档**里的一档，和 `accent` 撞成同一个颜色就等于少了一档信息。
    ///
    /// ⚠️ 09-21 橘化时它**必须跟着挪**：`accent` 走到色相 24° 之后，原来那支
    /// `0xAC5A10`（色相 28°）与它只差 ΔE 14.0（`ThemeContrastTests` 要求 ≥15），
    /// 两处颜色会看起来是同一个。现在取更偏红的一支（白 `0x9E3410` 色相 13°、
    /// 夜 `0xC4682A`），白档 ΔE 16.5、夜档 15.4，都压在门槛之上，
    /// 分档仍然一眼能分开（白天 7.11:1，夜晚 4.07:1）。
    ///
    /// 注意它和 `danger`（正红、色相 6°）**不是**一回事：`danger` 表示
    /// 「不可逆危险操作」，`warning` 只是分档/风险提示，两者别互相借。
    public var warning: Color { isNight ? Color(hex: 0xC4682A) : Color(hex: 0x9E3410) }
    /// **打卡 / 连续天数**的红（首屏徽章那颗火苗）。
    ///
    /// 09-21 新增：用户要求「把 logo 右边的火苗及内外框改成红色」—— 火苗本来就是
    /// 红橙色的东西，之前借用 `accent`（黄/橘）反而怪。
    ///
    /// ⚠️ 为什么另立一支而不是复用 `danger`：`danger` 的语义是**不可逆危险操作**
    /// （清除学习记忆这类按钮），拿它画火苗会让人以为点一下会删东西。两支实测
    /// ΔE 15.8，看上去也确实是两种红（这支偏火焰橙红，`danger` 偏正红）。
    ///
    /// 亮度的选择跟 `warning` 同一把尺：白卡上它还要当 11pt 的文字色（「N 天」），
    /// 所以白天 5.07:1、夜晚压在深蓝面板上 5.44:1，两档都留足余量。
    ///
    /// ⚠️ 它与 `warning`（断签风险态）的 ΔE 是 24.1，两态不会看成一个颜色 ——
    /// 这是「安全 / 风险」两态唯一还剩下的区分手段，别把两者调到相近。
    public var streak: Color { isNight ? Color(hex: 0xF0705A) : Color(hex: 0xD42A1A) }

    /// 次要强调色（冷紫）：给「跳去别处」这类**次要但要看得见**的动作用，
    /// 与主 `accent`（琥珀）明确区分——同一行里两个按钮不该抢同一个颜色。
    /// 两档都取偏深的紫：胶囊里是白字，太浅（如 0xA79BFF）实测白字对比只有 2.5:1。
    public var accentCool: Color { isNight ? Color(hex: 0x7E6BEF) : Color(hex: 0x6F5CE8) }
    public var star: Color { Color(hex: 0xFFF3C4) }
    /// 危险操作（清除学习记忆这类**不可逆**动作）。
    ///
    /// 两档都压到偏深：胶囊里是白字，浅红实测白字对比度不足 3:1，
    /// 按钮会变成「看得出是红的、但读不清写了什么」。
    public var danger: Color { isNight ? Color(hex: 0xC9555F) : Color(hex: 0xC0392B) }
    /// 「做完了 / 达标了」的绿（今日任务的绿勾、气泡里的完成关键字）。
    ///
    /// 与 `danger` 成对：一个是「还差」，一个是「做到了」，两个都得能在
    /// 侧栏底（`surfaceAlt`）与气泡底（`panel`）上读清 —— 所以两档都取偏深的绿，
    /// 白天 5.1:1、夜晚 9.2:1。
    ///
    /// ⚠️ 别再在 View 里写 `Color(hex: 0x8FD694)`：那是「浅绿」，只在白卡片上成立，
    /// 夜档压在深蓝面板上会糊掉。
    public var success: Color { isNight ? Color(hex: 0x7BD69A) : Color(hex: 0x2E7D3A) }

    // 文本 / 表面
    public var primaryText: Color { isNight ? Color(hex: 0xEAF4EE) : Color(hex: 0x22331F) }
    public var secondaryText: Color { isNight ? Color(hex: 0x9FB6AE) : Color(hex: 0x5B6B54) }
    public var surface: Color { isNight ? Color(hex: 0x152238, opacity: 0.92) : Color(hex: 0xFFFFFF, opacity: 0.92) }
    public var surfaceAlt: Color { isNight ? Color(hex: 0x1D2C46, opacity: 0.85) : Color(hex: 0xF3F7EF, opacity: 0.9) }
    public var bubbleUser: Color { isNight ? Color(hex: 0x3A5B7A) : Color(hex: 0xDFF3E4) }
    public var bubbleCoach: Color { isNight ? Color(hex: 0x24405A) : Color(hex: 0xFFFFFF) }
    public var divider: Color { isNight ? Color(hex: 0x2A3A57) : Color(hex: 0xDCE7D6) }

    /// **短行程**分隔线：多列排布里两列之间那一条（快捷键中心的三列）。
    ///
    /// 为什么不能直接用 `divider`：它是给「横跨整张卡的长横线」用的（Section 之间），
    /// 那种线长、量大，做淡一点才不抢内容；而两列之间这条只有一格高，再用那个色
    /// 就淡得看不见了（白卡上 1.2:1）。这条取到 1.8:1 —— 够分出「这是两列」，
    /// 又不至于像描边那样把界面切成方格。
    ///
    /// ⚠️ 只给**短**分隔线用。整条横贯的关注 `divider`。
    public var columnDivider: Color { isNight ? Color(hex: 0x3A5075) : Color(hex: 0xB4C2AE) }

    /// 浮层遮罩 / 浮层面板。**任何浮层都必须用这两个语义色**，否则日夜切换会漏。
    public var scrim: Color { isNight ? Color.black.opacity(0.5) : Color(hex: 0x16301B).opacity(0.22) }
    public var panel: Color { isNight ? Color(hex: 0x1A2A45, opacity: 0.98) : Color(hex: 0xF7FBF3, opacity: 0.98) }
    /// 侧边栏选中态 / 悬停态。
    public var selection: Color { isNight ? Color(hex: 0x2C4468) : Color(hex: 0xDCEFE0) }
    public var hover: Color { isNight ? Color(hex: 0x22334F) : Color(hex: 0xEAF3E8) }

    public var shadow: Color { isNight ? .black.opacity(0.45) : Color(hex: 0x2E4A32).opacity(0.18) }

    // MARK: - 词典封面

    /// 一本书封面的两档渐变色。
    public struct BookCover: Sendable, Equatable {
        public var top: Color
        public var bottom: Color

        public init(top: Color, bottom: Color) {
            self.top = top
            self.bottom = bottom
        }
    }

    /// 词典封面配色（六档令牌）。
    ///
    /// ⚠️ 这些**刻意压得比常规语义色深**：封面上压着白色书名，浅色配白字读不清。
    /// 六档在日夜两版都保持「深底 + 白字」，所以不跟着 `accent` 之类走。
    public func bookCover(_ style: DictionaryBook.CoverStyle) -> BookCover {
        switch style {
        case .forest:
            return isNight
                ? BookCover(top: Color(hex: 0x2A6B52), bottom: Color(hex: 0x14382C))
                : BookCover(top: Color(hex: 0x2F7D5C), bottom: Color(hex: 0x1B4D3A))
        case .ocean:
            return isNight
                ? BookCover(top: Color(hex: 0x1E5C86), bottom: Color(hex: 0x10304A))
                : BookCover(top: Color(hex: 0x1F6F9C), bottom: Color(hex: 0x14405E))
        case .sunset:
            return isNight
                ? BookCover(top: Color(hex: 0x9E4E33), bottom: Color(hex: 0x66281A))
                : BookCover(top: Color(hex: 0xB85C3A), bottom: Color(hex: 0x7E3320))
        case .plum:
            return isNight
                ? BookCover(top: Color(hex: 0x5C3F94), bottom: Color(hex: 0x35245C))
                : BookCover(top: Color(hex: 0x6A4BA8), bottom: Color(hex: 0x412C6E))
        case .slate:
            return isNight
                ? BookCover(top: Color(hex: 0x3E4C5C), bottom: Color(hex: 0x242E3A))
                : BookCover(top: Color(hex: 0x4A5A6B), bottom: Color(hex: 0x2C3846))
        case .sand:
            return isNight
                ? BookCover(top: Color(hex: 0x866A36), bottom: Color(hex: 0x584318))
                : BookCover(top: Color(hex: 0x9A7B3F), bottom: Color(hex: 0x6B5222))
        }
    }
}

// MARK: - 环境注入

private struct ForestThemeKey: EnvironmentKey {
    static let defaultValue = ForestTheme(palette: .day)
}

public extension EnvironmentValues {
    var forestTheme: ForestTheme {
        get { self[ForestThemeKey.self] }
        set { self[ForestThemeKey.self] = newValue }
    }
}

public extension View {
    func forestTheme(_ theme: ForestTheme) -> some View {
        environment(\.forestTheme, theme)
    }
}

// MARK: - 分辨率

public enum ForestThemeResolver {

    public static func resolve(mode: ThemeMode, systemIsDark: Bool) -> ForestTheme {
        switch mode {
        case .day: ForestTheme(palette: .day)
        case .night: ForestTheme(palette: .night)
        case .system: ForestTheme(palette: systemIsDark ? .night : .day)
        }
    }

    /// 「跟随时间与季节」打开后的主题（纯函数，便于单测）。
    ///
    /// 打开时**时刻说了算**：天黑了就切夜景、白天按小时挑天空色、按月份换季节。
    /// 关掉时与老行为逐字相同（`moment` / `season` 都是 nil）。
    ///
    /// ⚠️ 手动点太阳/月亮走的是「收回到手动」那条路（见 `AppState.toggleDayNight`），
    /// 不是在这里跟自动打架 —— 否则开了自动之后那个按钮点了没反应。
    public static func resolve(mode: ThemeMode, systemIsDark: Bool,
                               hour: Int, month: Int, followsClock: Bool) -> ForestTheme {
        guard followsClock else { return resolve(mode: mode, systemIsDark: systemIsDark) }
        let palette: ForestPalette = ForestAtmosphere.isNightHour(hour) ? .night : .day
        return ForestTheme(palette: palette,
                           moment: ForestAtmosphere.moment(hour: hour),
                           season: ForestAtmosphere.season(month: month))
    }
}
