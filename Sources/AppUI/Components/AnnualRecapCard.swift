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

    /// 某一列（一周）的**整列条带**：从第一行到第七行，含行间距。
    ///
    /// 给浮卡的禁入区用（见 `AnnualTooltipPlacement.origin(…avoiding:)`）。
    /// 为什么是整列而不是被查看那一格：鼠标沿列上下移动时浮卡会跟着上下走，
    /// 只躲一格的话它立刻又压住上面/下面那格 —— 用户要「看同列其他方格」就看不成了。
    func columnStrip(column: Int) -> CGRect {
        CGRect(
            x: origin(column: column, row: 0).x,
            y: monthRowHeight,
            width: cell,
            height: CGFloat(Self.rows) * cell + CGFloat(Self.rows - 1) * spacing
        )
    }
}

/// 年度学习记录卡。
public struct AnnualRecapCard: View {

    @Environment(\.forestTheme) private var theme
    let recap: AnnualRecap

    /// 鼠标悬停的那天 + 落点（跟着走）。
    ///
    /// internal：离屏渲染驱动不了鼠标，回归测试靠 `previewFocus` 注入同款值出图。
    struct Focus: Equatable {
        var day: Date
        var point: CGPoint
    }
    @State private var hovered: Focus?
    /// 点住的那天（点一下把明细留在卡片上，不被鼠标移开冲掉）。
    @State private var pinned: Focus?
    /// 测试钩子：注入的焦点优先于 hover 状态（正常使用恒为 nil）。
    private let previewFocus: Focus?

    /// 热图画布在**整卡**坐标系里的位置（浮卡挂在整卡层，要把热图里的
    /// 鼠标点换算过去）。
    ///
    /// ⚠️ 曾经用 `PreferenceKey` 从热图的 `GeometryReader` 传上来 —— **那是错的**：
    /// preference 要等一次 SwiftUI 更新回合才回灌，而落点每一帧都要用。
    /// 实测它在本机**从来没到过**（探针读数恒为 `.zero`，离屏与实机都一样），
    /// 于是浮卡少掉这一截偏移，被画到鼠标的**左上方**（横 −16 / 纵 −43）——
    /// 2026-09-24 报障「浮卡压住了要看的方格和同列上下其他格子」正是这么来的：
    /// 它其实偏到了被查看的那一列上。
    ///
    /// 现在改成**按已知布局解析算**：卡内边距 + 表头固定高 + 间距，宽度 = 卡宽 − 两侧内边距。
    /// 三个常量都用在布局自身（见 `body` / `header`），改布局时不会与这里脱节。
    private struct Layout {
        static let cardPadding: CGFloat = 16
        static let sectionSpacing: CGFloat = 10
        /// 表头固定高。**必须固定**：热图的纵坐标由它推出来，跟着字高浮动就等于
        /// 让浮卡落点跟着字体版本漂。
        static let headerHeight: CGFloat = 18
    }

    public init(recap: AnnualRecap) {
        self.init(recap: recap, previewFocus: nil)
    }

    init(recap: AnnualRecap, previewFocus: Focus?) {
        self.recap = recap
        self.previewFocus = previewFocus
    }

    private var columns: Int { recap.weeks.count }

    /// 热图在整卡坐标里的位置（纯推算，不依赖任何时序）。
    private func heatmapFrame(in containerSize: CGSize) -> CGRect {
        let width = max(containerSize.width - Layout.cardPadding * 2, 1)
        let height = width / AnnualHeatmapMetrics.aspectRatio(columns: columns)
        return CGRect(
            x: Layout.cardPadding,
            y: Layout.cardPadding + Layout.headerHeight + Layout.sectionSpacing,
            width: width,
            height: height
        )
    }

    /// 当前要解释的那一格：优先「测试注入的」，其次「点住的」，再次「悬停的」。
    private var focusedFocus: Focus? {
        previewFocus ?? pinned ?? hovered
    }

    private var focused: AnnualRecap.Cell? {
        cell(on: focusedFocus?.day)
    }

    /// 浮卡该出现在哪：与焦点同源（点住用点下时的落点，悬停用鼠标位置）。
    private var anchorPoint: CGPoint? {
        focusedFocus?.point
    }

    /// 被查看的那**一整列**在整卡坐标里的条带 = 浮卡的禁入区（2026-09-24 报障：
    /// 浮卡压住了要看的方格和同列上下其他格子）。
    private func focusedColumnStrip(in containerSize: CGSize) -> CGRect? {
        guard let focused, let column = columnIndex(of: focused.day) else { return nil }
        let frame = heatmapFrame(in: containerSize)
        let metrics = AnnualHeatmapMetrics(width: frame.width, columns: columns)
        return metrics.columnStrip(column: column)
            .offsetBy(dx: frame.minX, dy: frame.minY)
    }

    /// 某天落在第几列（第几周）。
    private func columnIndex(of day: Date) -> Int? {
        let target = Calendar.current.startOfDay(for: day)
        return recap.weeks.firstIndex { week in
            week.contains { $0?.day == target }
        }
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
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            header
            heatmap
            footer
            footnote
        }
        .padding(Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 8, x: 0, y: 3)
        )
        // 浮卡挂在**整卡层**而不是热图层：footer/footnote 是热图的晚兄弟，
        // 挂在热图层会被它们画在头上（#5 二轮报障）。挂在这里 = 最后画 = 悬浮最上；
        // 落点也钳在整卡内，不会再伸到下一张卡底下。
        .overlay(alignment: .topLeading) {
            GeometryReader { cardProxy in
                tooltipOverlay(containerSize: cardProxy.size)
            }
        }
    }

    @ViewBuilder
    private func tooltipOverlay(containerSize: CGSize) -> some View {
        if let focused, let anchor = anchorPoint {
            let items = focused.detailItems()
            let size = CGSize(
                width: AnnualDayDetailCard.measuredWidth(items: items),
                height: AnnualDayDetailCard.estimatedHeight(items: items)
            )
            // 落点记录在**热图坐标**里（`onContinuousHover` 给的就是它），
            // 换算到整卡坐标再钳制、再让开被查看那一列。
            let frame = heatmapFrame(in: containerSize)
            let origin = AnnualTooltipPlacement.origin(
                mouse: CGPoint(x: anchor.x + frame.minX, y: anchor.y + frame.minY),
                containerSize: containerSize,
                tooltipSize: size,
                avoiding: focusedColumnStrip(in: containerSize)
            )
            AnnualTooltipFollower(items: items, target: origin)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
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
        // 固定高：浮卡落点要用它推热图位置（见 `Layout.headerHeight`）。
        .frame(height: Layout.headerHeight)
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
                            hovered = day(at: point, width: proxy.size.width).map {
                                Focus(day: $0, point: point)
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
                    .gesture(
                        // 用 `DragGesture(minimumDistance: 0)` 而不是 `onTapGesture`：
                        // 后者在 macOS 上不给点击位置，没法知道点的是哪一格。
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                if let tapped = day(at: value.location, width: proxy.size.width),
                                   tapped == pinned?.day {
                                    pinned = nil
                                } else if let tapped = day(at: value.location, width: proxy.size.width) {
                                    pinned = Focus(day: tapped, point: value.location)
                                } else {
                                    pinned = nil
                                }
                            }
                    )
                    // 「浮卡不抢命中」这条靠它守住：浮卡盖住格子时鼠标一动悬停就断了。
                    // ⚠️ 这里**不再**往上报热图 frame —— 浮卡要按照样式算出来的
                    // `heatmapFrame(in:)`（见那里的说明：preference 从来没到过）。
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

            // #5 起当日明细改在悬停浮卡里逐条展示（一行式会被截断）；
            // footer 恒定说这一年，不再跟着焦点切换。
            Text(recap.summaryText)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
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
