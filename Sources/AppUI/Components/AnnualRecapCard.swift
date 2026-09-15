import AIDomain
import SwiftUI

// MARK: - 年度学习记录卡（学习进度页）
//
// 照 GitHub 贡献图的版式：53 列 × 7 行，一格一天。
// 与「今天」「今日任务」两张卡片**同源**：这一格有多深，取决于那天
//   ① 每日目标有没有达成（「今天」卡片上那根进度条满没满）；
//   ② 三项任务做完了几项（「今日任务」卡片上的 `N / 3`）。
// 口径与推算全在 `AnnualRecapBuilder`（纯函数），这里只负责画。

/// 年历网格的几何。**所有尺寸都按格子边长成比例**（连标签宽度、月份行高也是）。
///
/// 为什么坚持成比例：只有这样整块绘图才有**恒定的宽高比**，才能用
/// `.aspectRatio(_:contentMode:.fit)` 让高度由宽度推出来。
/// 否则就得 `GeometryReader` + `@State` 走两趟布局 —— 而离屏渲染往往只跑一趟
/// 就出图，会画出高度不对的版本（本次验证全程熄屏走离屏渲染，这条是硬约束）。
struct AnnualHeatmapMetrics {

    /// 左侧星期标签宽度 = 1.5 格。
    static let labelRatio: CGFloat = 1.5
    /// 顶部月份标签行高 = 1.5 格。
    static let monthRowRatio: CGFloat = 1.5
    /// 格间距 = 0.35 格。
    static let spacingRatio: CGFloat = 0.35
    static let rows = 7

    let columns: Int
    /// 格子边长（正方形）。
    let cell: CGFloat

    init(width: CGFloat, columns: Int) {
        let count = max(columns, 1)
        self.columns = count
        let denominator = Self.labelRatio
            + CGFloat(count)
            + CGFloat(count - 1) * Self.spacingRatio
        self.cell = max(width / max(denominator, 1), 1)
    }

    var spacing: CGFloat { cell * Self.spacingRatio }
    var labelWidth: CGFloat { cell * Self.labelRatio }
    var monthRowHeight: CGFloat { cell * Self.monthRowRatio }

    /// 整块的宽高比（与宽度无关，恒为常数）。
    static func aspectRatio(columns: Int) -> CGFloat {
        let count = CGFloat(max(columns, 1))
        let width = labelRatio + count + (count - 1) * spacingRatio
        let height = monthRowRatio + CGFloat(rows) + CGFloat(rows - 1) * spacingRatio
        return width / height
    }

    /// 某一格的左上角。
    func origin(column: Int, row: Int) -> CGPoint {
        CGPoint(
            x: labelWidth + CGFloat(column) * (cell + spacing),
            y: monthRowHeight + CGFloat(row) * (cell + spacing)
        )
    }

    /// 命中测试：鼠标落在哪一格。落在格与格之间的缝里也算最近的那一格 ——
    /// 不然鼠标横向移动时会一路闪空。
    func locate(_ point: CGPoint) -> (column: Int, row: Int)? {
        let x = point.x - labelWidth
        let y = point.y - monthRowHeight
        guard x >= 0, y >= 0 else { return nil }
        let stride = cell + spacing
        guard stride > 0 else { return nil }
        let column = min(Int(x / stride), columns - 1)
        let row = min(Int(y / stride), Self.rows - 1)
        guard column >= 0, row >= 0 else { return nil }
        return (column, row)
    }
}

/// 年度学习记录卡。
public struct AnnualRecapCard: View {

    @Environment(\.forestTheme) private var theme
    let recap: AnnualRecap

    /// 鼠标悬停的那天（跟着走）。
    @State private var hovered: Date?
    /// 点住的那天（点一下把明细留在卡片上，不被鼠标移开冲掉）。
    @State private var pinned: Date?

    public init(recap: AnnualRecap) { self.recap = recap }

    private var columns: Int { recap.weeks.count }

    /// 当前要解释的那一格：优先「点住的」，其次「悬停的」。
    private var focused: AnnualRecap.Cell? {
        cell(on: pinned) ?? cell(on: hovered)
    }

    private func cell(on day: Date?) -> AnnualRecap.Cell? {
        guard let day else { return nil }
        let target = Calendar.current.startOfDay(for: day)
        return recap.weeks.flatMap { $0 }.compactMap { $0 }.first { $0.day == target }
    }

    private func day(at point: CGPoint, width: CGFloat) -> Date? {
        let metrics = AnnualHeatmapMetrics(width: width, columns: columns)
        guard let hit = metrics.locate(point),
              hit.column < recap.weeks.count,
              hit.row < recap.weeks[hit.column].count
        else { return nil }
        return recap.weeks[hit.column][hit.row]?.day
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            heatmap
            footer
            footnote
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 8, x: 0, y: 3)
        )
    }

    // MARK: - 标题行

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(theme.accent)
            Text("年度学习记录")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 8)
            Text(recap.headline)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent)
                .monospacedDigit()
        }
    }

    // MARK: - 年历

    private var heatmap: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .aspectRatio(AnnualHeatmapMetrics.aspectRatio(columns: columns), contentMode: .fit)
        .overlay {
            // 命中测试要拿到真实尺寸，所以放进 overlay 的 `GeometryReader`：
            // 它量到的就是上面那块画布的大小，两边算出的几何必然一致。
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            hovered = day(at: point, width: proxy.size.width)
                        case .ended:
                            hovered = nil
                        }
                    }
                    .gesture(
                        // 用 `DragGesture(minimumDistance: 0)` 而不是 `onTapGesture`：
                        // 后者在 macOS 上不给点击位置，没法知道点的是哪一格。
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let tapped = day(at: value.location, width: proxy.size.width)
                                pinned = (tapped != nil && tapped == pinned) ? nil : tapped
                            }
                    )
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard columns > 0 else { return }
        let metrics = AnnualHeatmapMetrics(width: size.width, columns: columns)
        let labelFont = Font.system(size: max(metrics.cell * 0.82, 7), design: .rounded)

        // 月份刻度。会不会叠字只有绘制层说得清（取决于格子边长与字号），
        // 所以「挤不下就不标这一个」的判断放在这里，领域层只给「哪一列是新月份」。
        var lastLabelRight = -CGFloat.infinity
        for marker in recap.months {
            let x = metrics.origin(column: marker.column, row: 0).x
            let width = estimatedLabelWidth(marker.title, cell: metrics.cell)
            // 贴到右边缘的刻度会被裁掉一半，宁可不画。
            guard x + width <= size.width else { continue }
            // 与上一个标签挨太近就跳过（通常是「网格起始那个月」与第一个月初挨着）。
            guard x >= lastLabelRight + metrics.cell * 0.4 else { continue }
            context.draw(
                Text(marker.title).font(labelFont).foregroundStyle(theme.secondaryText),
                at: CGPoint(x: x, y: 0),
                anchor: .topLeading
            )
            lastLabelRight = x + width
        }

        // 星期标签（只有三行有字）
        for (row, label) in recap.rowLabels.enumerated() {
            guard let label else { continue }
            let center = CGPoint(
                x: 0,
                y: metrics.origin(column: 0, row: row).y + metrics.cell / 2
            )
            context.draw(
                Text(label).font(labelFont).foregroundStyle(theme.secondaryText),
                at: center,
                anchor: .leading
            )
        }

        // 格子
        let focusedCell = focused
        for (column, week) in recap.weeks.enumerated() {
            for (row, cell) in week.enumerated() {
                guard let cell else { continue }
                let rect = CGRect(
                    origin: metrics.origin(column: column, row: row),
                    size: CGSize(width: metrics.cell, height: metrics.cell)
                )
                let path = Path(
                    roundedRect: rect,
                    cornerRadius: max(metrics.cell * 0.22, 1)
                )
                context.fill(path, with: .color(color(for: cell.intensity)))

                if cell.isToday {
                    // 今天要一眼找得到，否则一整年看下来不知道「我在哪」。
                    context.stroke(path, with: .color(theme.accentCool), lineWidth: 1)
                }
                if let focusedCell, focusedCell.day == cell.day {
                    let ring = rect.insetBy(dx: -metrics.cell * 0.16, dy: -metrics.cell * 0.16)
                    context.stroke(
                        Path(roundedRect: ring, cornerRadius: max(metrics.cell * 0.3, 1.5)),
                        with: .color(theme.accentCool),
                        lineWidth: 1
                    )
                }
            }
        }
    }

    /// 月份标签的估算宽度（「12月」比「9月」宽）。
    ///
    /// 只为「会不会叠字 / 会不会被裁」服务，不需要精确 —— 但**必须**与
    /// `labelFont` 的字号挂钩：字号是跟着格子边长缩的，写死宽度在窄窗口上会误判。
    private func estimatedLabelWidth(_ title: String, cell: CGFloat) -> CGFloat {
        CGFloat(title.count) * cell * 0.9
    }

    /// 四档深浅用琥珀（主题主色）一条色阶：越深 = 那天的两张卡片越满。
    private func color(for intensity: PracticeIntensity) -> Color {
        switch intensity {
        case .none: theme.divider.opacity(0.6)
        case .light: theme.accent.opacity(0.3)
        case .solid: theme.accent.opacity(0.62)
        case .full: theme.accent
        }
    }

    // MARK: - 图例 + 明细

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 4) {
                Text("少")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                ForEach(PracticeIntensity.allCases) { intensity in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: intensity))
                        .frame(width: 11, height: 11)
                        .help(intensity.displayName)
                }
                Text("多")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer(minLength: 8)

            // 有焦点就说那一天，没有就说这一年 —— 同一行位置切换，
            // 不给卡片额外长高（鼠标一划整页跳一下是最糟的）。
            Text(focused?.detailText() ?? recap.summaryText)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(focused == nil ? theme.secondaryText : theme.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var footnote: some View {
        Text("深浅按那天的「每日目标」与「今日任务」两件事分四档：开过口 / 达标 / 全清。复习一项按当天有复习流水记（历史每天的到期词数还原不出来）。")
            .font(.system(size: 9, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
