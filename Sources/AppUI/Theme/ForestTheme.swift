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

    public init(palette: ForestPalette) { self.palette = palette }

    public var isNight: Bool { palette == .night }

    // 天空
    public var sky: [Color] {
        isNight
            ? [Color(hex: 0x0A1230), Color(hex: 0x152347), Color(hex: 0x24405A)]
            : [Color(hex: 0x7FD4F0), Color(hex: 0xB6EAFA), Color(hex: 0xE9F8DE)]
    }

    // 远景山丘 / 林冠
    public var hillFar: Color { isNight ? Color(hex: 0x16324A) : Color(hex: 0xA8DCC0) }
    public var hillMid: Color { isNight ? Color(hex: 0x143B38) : Color(hex: 0x74C79A) }
    public var hillNear: Color { isNight ? Color(hex: 0x0F2E2B) : Color(hex: 0x3F9E67) }

    // 树
    public var trunk: Color { isNight ? Color(hex: 0x4A3626) : Color(hex: 0xA9743F) }
    public var trunkShade: Color { isNight ? Color(hex: 0x33251A) : Color(hex: 0x7E5228) }
    public var foliage: Color { isNight ? Color(hex: 0x1E5346) : Color(hex: 0x4FA96B) }
    public var foliageDeep: Color { isNight ? Color(hex: 0x143A31) : Color(hex: 0x2E7D55) }

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
    /// | 场景 | 原色 `0xFFB703` | 现在 |
    /// |---|---|---|
    /// | 白天：压在自己的 0.12 淡黄底上 | 1.73:1 | **3.96:1** |
    /// | 白天：压在白卡片上 | 1.75:1 | **4.60:1**（紫是 4.80:1） |
    /// | 夜晚：压在暗底上 | 11.78:1（刺眼） | **6.86:1** |
    ///
    /// 白档从 `0x96670E` 提到 `0x937008`（色相 39°→**45°**、亮度 0.162→0.178）。
    /// 起因是用户反馈「白天的颜色已经变成棕色了」，根因是**色相偏橙**，所以这一档
    /// 主要靠**往金黄方向挪色相**来救，亮度只是顺带。想真正亮起来的黄只能走
    /// `accentFill`（它上压深墨字，不受这两条约束）。
    public var accent: Color { isNight ? Color(hex: 0xD2A34C) : Color(hex: 0x937008) }

    /// 黄底胶囊的**填充色** —— 它上面压的是 `onAccentFill`（白档深墨、夜档白字）。
    ///
    /// ⚠️ 别和 `accent` 合成一个令牌：同一个黄既要当「暗底上的前景」（得亮），
    /// 又要当「字脚下的底」，这俩在白档直接打架 —— 硬合成的结果就是旧的 `0xB07C12`
    /// （亮度 0.24、色相 40°），用户看了直说「已经变成棕色了」。
    ///
    /// ⚠️ 更要紧的一条：**黄底上压白字，等于把黄底钉死**。白字要求底够暗，而
    /// 「够暗的黄」在 sRGB 里就是褐色 —— 这是色彩空间层面的死结，调参解不开。
    /// 白档因此改成**亮金底 + 深墨字**（`0xEAC541` 承 `0x3D2B00`，实测 8.1:1），
    /// 黄这才亮得起来；夜档维持深金底 + 白字（用户实测认可 3.80:1）不动。
    ///
    /// ⚠️ 反过来，白档这支也有**上限**，判据是「它和所在的白卡片还能不能分开」：
    /// 金底越亮，那个实心胶囊就越像糊进白卡片里。守卫线设在 1.5:1（现 1.67:1），
    /// 到 `0xEFCB4E` 附近就只剩 1.5 了 —— 再往上不是「更亮的金」，是「看不清的块」。
    public var accentFill: Color { isNight ? Color(hex: 0xA87B26) : Color(hex: 0xEAC541) }

    /// 压在上面那支黄底上的**字色**。白档是深墨褐（黄要亮，字就得深），夜档是白字。
    /// ⚠️ 别在 View 里再写死 `.white`：白档会直接退化成读不出的白字。
    public var onAccentFill: Color { isNight ? Color(hex: 0xFFFFFF) : Color(hex: 0x3D2B00) }

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
    /// 所以取同一族里更偏橙的那支（色相 28° vs `accent` 的 40°，绿通道差一大截，
    /// 一眼能分开），亮度同样压住：白天 4.97:1，夜晚在暗底上 5.04:1。
    public var warning: Color { isNight ? Color(hex: 0xCA8030) : Color(hex: 0xAC5A10) }
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
}
