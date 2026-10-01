import SwiftUI

/// 阅读题卡右端的「展开 / 收起解析」按钮（#233 后续）。
///
/// 用户实测反馈：原来那只是一个 9pt 的**裸 chevron** —— 既看不出能点，判定区也就
/// 那个箭头那么大。这里做成**带边框的按钮**：有明确边界、有悬停反馈，
/// 判定区放大到整块边框以内（`contentShape` 与边框同形，空白也吃点击）。
///
/// 图标口径跟全应用一致 —— **画的是「点下去会发生什么」，不是当前状态**：
/// 解析卡是**向下长出来**的，所以收起后用朝下的 chevron（点它 = 往下展开），
/// 展开后用朝上的（点它 = 落回去）。与今日作业黑板的 `collapseIcon` 同一套说法。
public struct ReadingQuestionToggleButton: View {

    @Environment(\.forestTheme) private var theme

    /// 展开态（决定箭头朝向与提示词）。
    public var isExpanded: Bool
    public var onToggle: () -> Void

    @State private var isHovering = false

    /// 判定区尺寸 = 可见边框尺寸。
    ///
    /// ⚠️ 单独抽成常量是给回归测试用的：这条需求的核心就是「判定区要够大」，
    /// 必须能被断言，而不是靠看。
    public static let hitSize = CGSize(width: 36, height: 28)

    /// 提示文案（收起 / 展开两种）。
    public static let expandHelp = "展开解析"
    public static let collapseHelp = "收起解析"

    public init(isExpanded: Bool, onToggle: @escaping () -> Void) {
        self.isExpanded = isExpanded
        self.onToggle = onToggle
    }

    public var body: some View {
        Button(action: onToggle) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .appFont(11, weight: .bold)
                .foregroundStyle(isHovering ? theme.accent : theme.secondaryText)
                .frame(width: Self.hitSize.width, height: Self.hitSize.height)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovering ? theme.accent.opacity(0.12) : theme.surfaceAlt.opacity(0.9))
                )
                .overlay(
                    // ⚠️ 描边不能用 `theme.divider`：那档颜色在白底上几乎看不见（实测只差 1.2:1），
                    // 用户要的就是「一眼看出是个按钮」。这里用次强调色压深，悬停再换强调色。
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isHovering ? theme.accent : theme.secondaryText.opacity(0.55),
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.appPressable)
        .onHover { isHovering = $0 }
        .help(isExpanded ? Self.collapseHelp : Self.expandHelp)
        .accessibilityLabel(isExpanded ? Self.collapseHelp : Self.expandHelp)
    }
}
