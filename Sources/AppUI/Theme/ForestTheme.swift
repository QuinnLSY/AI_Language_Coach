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
    public var accent: Color { isNight ? Color(hex: 0xFFD98A) : Color(hex: 0xFFB703) }
    public var accentAlt: Color { isNight ? Color(hex: 0x8AB6FF) : Color(hex: 0xFF8FA3) }
    public var star: Color { Color(hex: 0xFFF3C4) }

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
