import AIDomain
import SwiftUI

// MARK: - 年度记录的悬停浮卡（#5）
//
// 报障：悬停某天时当日明细被压在 footer 一行里（`lineLimit(1)` + 中间省略），
// 练得多的日子后半截全被「…」吃掉。
// 改法：鼠标旁浮出一张**列式**卡片，一天里干过的每件事各占一行，
// 有几行亮几行 —— 高度随内容自适应。

/// 当日明细浮卡：第一行日期（加重），其后逐条一行（次级色）。
struct AnnualDayDetailCard: View {

    let lines: [String]

    @Environment(\.forestTheme) private var theme

    /// 固定宽度：一年里最长的那条（「阅读 3 篇（答对 28/30）」）也放得下。
    static let width: CGFloat = 216

    /// 高度估算（落点钳制要在布局前拿到尺寸用）：
    /// 首行 13pt、其余 12pt、行距 5、内边距 10。与真实渲染的偏差由钳制的余量吸收。
    static func estimatedHeight(lines: Int) -> CGFloat {
        guard lines > 0 else { return 0 }
        return 20 + CGFloat(lines) * 13 + CGFloat(lines - 1) * 5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.system(
                        size: index == 0 ? 11 : 10,
                        weight: index == 0 ? .semibold : .regular,
                        design: .rounded
                    ))
                    .foregroundStyle(index == 0 ? theme.primaryText : theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 6, x: 0, y: 2)
        )
    }
}

/// 浮卡落点（纯函数）：优先出现在鼠标**右下**；右边放不下翻到左边，
/// 下面放不下翻到上边，最后钳在容器边界内。
///
/// 钳到「卡片边界」而不是窗口：这张卡几乎通栏，横向钳到卡片 ≈ 钳到窗口；
/// 纵向浮卡始终出现在鼠标附近（鼠标必须悬在年历上浮卡才在），
/// 卡片边界钳制足以保证看得见。纯函数，四条边各有一条单测。
enum AnnualTooltipPlacement {

    static func origin(
        mouse: CGPoint,
        containerSize: CGSize,
        tooltipSize: CGSize,
        margin: CGFloat = 12
    ) -> CGPoint {
        var x = mouse.x + margin
        var y = mouse.y + margin
        // 右边放不下 → 翻到鼠标左侧；下面放不下 → 翻到上方。
        if x + tooltipSize.width > containerSize.width - margin {
            x = mouse.x - margin - tooltipSize.width
        }
        if y + tooltipSize.height > containerSize.height - margin {
            y = mouse.y - margin - tooltipSize.height
        }
        // 最后钳进边界（浮卡比容器还宽/高时，前面的翻转逻辑会翻过头 —— 这里兜底）。
        // 最后钳进边界（浮卡比容器还宽/高时，前面的翻转逻辑会翻过头 —— 这里兜底）。
        x = min(max(x, margin), max(containerSize.width - tooltipSize.width - margin, margin))
        y = min(max(y, margin), max(containerSize.height - tooltipSize.height - margin, margin))
        return CGPoint(x: x, y: y)
    }
}
