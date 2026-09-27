import AIDomain
import AppKit
import SwiftUI

// MARK: - 年度记录的悬停浮卡（#5）
//
// 报障：悬停某天时当日明细被压在 footer 一行里（`lineLimit(1)` + 中间省略），
// 练得多的日子后半截全被「…」吃掉。
// 改法：鼠标旁浮出一张**列式**卡片，一天里干过的每件事各占一行，
// 有几行亮几行 —— 高度随内容自适应。
//
// 二轮（#5 后续）：
// ① 宽度也随内容自适应（原来写死 216，两三行的日子右边一大片空）；
// ② 每行前面画该板块的图标，一眼看出做的是什么学习内容。

/// 板块 → SF Symbol 的映射（UI 层的事：领域层不该认得图标名）。
extension RecapDetailKind {
    var symbolName: String {
        switch self {
        case .date: "calendar"
        case .duration: "clock"
        case .conversation: "ellipsis.bubble"
        case .shadowing: "waveform"
        case .vocabulary: "text.book.closed"
        case .writing: "pencil"
        case .reading: "book"
        case .goal: "flag.checkered"
        case .tasks: "checkmark.circle"
        case .idle: "moon.zzz"
        }
    }
}

/// 当日明细浮卡：第一行日期（加重），其后逐条一行（次级色），每行带板块图标。
struct AnnualDayDetailCard: View {

    let items: [RecapDetailItem]

    @Environment(\.forestTheme) private var theme

    /// 图标列宽 + 图标与文字的间距。
    static let iconColumn: CGFloat = 11
    static let iconGap: CGFloat = 5

    /// 内容自适应宽度：量出最长一行的自然宽，加图标列与内边距。
    ///
    /// 用 `NSAttributedString` 量而不是交给 SwiftUI 自己 hug：落点钳制要在
    /// 布局前拿到宽度，渲染与钳制必须用**同一个数**，否则要么截字、要么右边露缝。
    /// ⚠️ 必须按 **rounded 设计**的字体量：拿系统字体量出来的宽度偏窄，
    /// 最长一行会被挤到换行（实测 8 行量成 9 条墨带）。
    static func measuredWidth(items: [RecapDetailItem]) -> CGFloat {
        guard !items.isEmpty else { return 90 }
        let titleFont = Self.roundedFont(ofSize: 11, weight: .semibold)
        let bodyFont = Self.roundedFont(ofSize: 10, weight: .regular)
        var longest: CGFloat = 0
        for (index, item) in items.enumerated() {
            let font = index == 0 ? titleFont : bodyFont
            let size = (item.text as NSString).size(withAttributes: [.font: font])
            longest = max(longest, ceil(size.width))
        }
        return min(max(longest + iconColumn + iconGap + 20 + 6, 90), 260)
    }

    /// SwiftUI `.rounded` 设计对应的 AppKit 字体（量宽用）。
    private static func roundedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// 高度估算（落点钳制要在布局前拿到尺寸用）：
    /// 首行 13pt、其余 12pt、行距 5、内边距 10。与真实渲染的偏差由钳制的余量吸收。
    static func estimatedHeight(items: [RecapDetailItem]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let lines = CGFloat(items.count)
        return 20 + lines * 13 + (lines - 1) * 5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: Self.iconGap) {
                    Image(systemName: item.kind.symbolName)
                        .font(.system(size: index == 0 ? 10 : 9, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: Self.iconColumn)
                    Text(item.text)
                        .font(.system(
                            size: index == 0 ? 11 : 10,
                            weight: index == 0 ? .semibold : .regular,
                            design: .rounded
                        ))
                        .foregroundStyle(index == 0 ? theme.primaryText : theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(width: Self.measuredWidth(items: items), alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surface)
                .appElevation(.card)
        )
    }
}

/// 浮卡跟随层（#5.3）：目标点变化时用弹簧动画逼近，而不是瞬间跳过去 —— 拖拽感。
///
/// 抽成独立组件的原因：离屏渲染驱动不了鼠标（`onContinuousHover` 不触发），
/// 只有独立组件才能在回归测试里直接驱动 `target` 抓中途帧。
/// 首次出现不拖拽（`smoothed` 还是 nil，直接落在目标上）；之后每次目标移动，
/// `onChange` 里自建弹簧事务逼近新目标 —— ⚠️ 动画必须由组件**自己**的
/// `withAnimation` 创建：测试里裸改状态不吃外部事务（见 `RecordsDisclosureRenderTests`）。
struct AnnualTooltipFollower: View {

    let items: [RecapDetailItem]
    /// 跟随目标（已经是钳制后的落点）。
    let target: CGPoint

    @State private var smoothed: CGPoint?

    var body: some View {
        AnnualDayDetailCard(items: items)
            .offset(x: smoothed?.x ?? target.x, y: smoothed?.y ?? target.y)
            // 首帧后就位，之后 offset **只**走 smoothed —— 兜底 `?? target` 若一直参与，
            // 目标一变就会先把卡瞬移过去（实测弹簧从未有机会生效），onChange 里
            // 的动画就成了空转。
            .onAppear {
                if smoothed == nil { smoothed = target }
            }
            .onChange(of: target) { _, newValue in
                withAnimation(.app(.panel)) {
                    smoothed = newValue
                }
            }
    }
}

/// 浮卡落点（纯函数）：优先出现在鼠标**右下**；右边放不下翻到左边，
/// 下面放不下翻到上边，最后钳在容器边界内。
///
/// 二轮起容器是**整张卡**（不再是热图画布）：热图装不下浮卡时浮卡会纵向
/// 伸出去压住 footer/footnote，而 footer 是更晚的兄弟节点会反过来画在浮卡上面
/// —— 既难看又挡字。钳在整卡内 + 浮卡挂在整卡层，两个问题一起消失。
/// 纯函数，四条边各有一条单测。
///
/// 三轮（2026-09-24 报障「浮卡挡住了要看的那一天的方格，以及同列上下其他格子」）：
/// 光「不越界」不够 —— 浮卡还得**让开正在看的那一列**。新增 `avoiding:` 禁入区，
/// 有交点就整体挪到它的一侧。避让按**整列**（见 `AnnualHeatmapMetrics.columnStrip`）：
/// 只躲被查看那一格的话，鼠标沿列上下移动时浮卡又会压住上面/下面那格 ——
/// 用户要的正是「沿列比对」，一格都不该挡。
enum AnnualTooltipPlacement {

    /// - Parameters:
    ///   - avoid: 禁入区（被查看的那一列在**整卡坐标**里的条带）。与浮卡纵向有
    ///     交集时，浮卡必须整体落在它左侧或右侧、并留出 `margin` 空档（阴影也不许
    ///     碰到那一列）。`nil` = 没有禁入区，退回「只在边界内钳制」的老行为。
    static func origin(
        mouse: CGPoint,
        containerSize: CGSize,
        tooltipSize: CGSize,
        avoiding avoid: CGRect? = nil,
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
        // 让开禁入区（纵向不挨着就无所谓 —— 例如浮卡完全落在网格下方）。
        if let avoid,
           y < avoid.maxY, y + tooltipSize.height > avoid.minY,
           !(x + tooltipSize.width <= avoid.minX - margin || x >= avoid.maxX + margin) {
            // 优先挪到列右侧（与「鼠标右下」的默认落点同向）；右边装不下再挪到左侧。
            if avoid.maxX + margin + tooltipSize.width <= containerSize.width - margin {
                x = avoid.maxX + margin
            } else if avoid.minX - margin - tooltipSize.width >= margin {
                x = avoid.minX - margin - tooltipSize.width
            }
            // 两侧都装不下（浮卡窄于窗口时不该发生）→ 保持原样，交给下面的钳制兜底。
        }
        // 最后钳进边界（浮卡比容器还宽/高时，前面的翻转逻辑会翻过头 —— 这里兜底）。
        x = min(max(x, margin), max(containerSize.width - tooltipSize.width - margin, margin))
        y = min(max(y, margin), max(containerSize.height - tooltipSize.height - margin, margin))
        return CGPoint(x: x, y: y)
    }
}
