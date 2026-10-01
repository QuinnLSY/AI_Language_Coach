import AIDomain
import SwiftUI

// MARK: - Dashboard 图表（第 25 步）
//
// 为什么手绘而不用 Swift Charts：
// 1. 全应用的美术风格是手绘森林（树、小动物都是自绘），系统图表插进来会像贴上去的；
// 2. 图表口径要自己控（空数据、全 0、单点、30 天挤标签），手绘能精确处理；
// 3. 昼夜双主题的颜色全部走 `forestTheme`，不引入第二套配色。
//
// 三条硬约束（都踩过）：
// - **空数据 / 全 0 不能出 NaN**：分母先兜底，别让 `value / max` 除零。
// - **LazyVGrid 陷阱**：这里不用懒容器，图表元素必须参与过渡动画。
// - **文字必须跟着主题**：柱、线、标签一律用主题色，不写死黑白。

// MARK: - 柱状图（练习频率 / 每日时长）

/// 按天排布的柱状图。柱高按窗口内最大值归一 —— 自己和自己比，不跟别人比。
struct ProgressBarChart: View {

    @Environment(\.forestTheme) private var theme
    let points: [TrendPoint]
    let tint: Color
    /// 柱上是否标数值（数值全为 0 时不标）。
    var showsValueOnTop = false
    var height: CGFloat = 130

    /// 归一化分母：全 0 时兜底成 1，避免除零。
    private var peak: Double { max(points.map(\.value).max() ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(points) { point in
                    VStack(spacing: 3) {
                        if showsValueOnTop, point.value > 0 {
                            Text(String(Int(point.value.rounded())))
                                .appFont(8, weight: .semibold, design: .rounded)
                                .foregroundStyle(theme.secondaryText)
                                .monospacedDigit()
                        }
                        Capsule()
                            .fill(barStyle(point.value))
                            .frame(height: barHeight(point.value))
                            .frame(maxWidth: .infinity)
                            .help(point.detail.isEmpty ? point.label : point.detail)
                        Text(axisLabel(point))
                            .appFont(8, design: .rounded)
                            .foregroundStyle(theme.secondaryText.opacity(0.9))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
        }
    }

    /// 柱高：至少 3pt，让「0」也看得见底（不然那天的柱子完全消失，像没画）。
    private func barHeight(_ value: Double) -> CGFloat {
        let ratio = min(max(value / peak, 0), 1)
        return max(height * 0.55 * ratio, 3)
    }

    private func barStyle(_ value: Double) -> LinearGradient {
        LinearGradient(
            colors: value > 0 ? [tint, tint.opacity(0.55)] : [theme.divider, theme.divider.opacity(0.5)],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// X 轴标签：点多时只标「第一 / 最后 / 每隔若干天」，否则会糊成一片。
    private func axisLabel(_ point: TrendPoint) -> String {
        guard let index = points.firstIndex(of: point) else { return "" }
        if points.count <= 8 { return point.label }
        let stride = Int((Double(points.count) / 6).rounded(.up))
        if index == 0 || index == points.count - 1 || index % max(stride, 1) == 0 {
            return point.label
        }
        return ""
    }
}

// MARK: - 折线图（语法趋势 / 词汇增长 / 发音趋势）

/// 折线 + 面积。点少于 2 时退化为一个圆点（不能画线，也不能崩）。
struct ProgressLineChart: View {

    @Environment(\.forestTheme) private var theme
    let points: [TrendPoint]
    let tint: Color
    /// Y 轴数值的展示后缀（如 " 分"）。
    var valueSuffix = ""
    var height: CGFloat = 110

    /// Y 轴区间：按数据自适应，上下各留一点余量；全平的数据给一个稳定区间。
    private var range: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        if high - low < 0.001 {
            let pad = max(high * 0.2, 1)
            return max(low - pad, 0)...(high + pad)
        }
        let pad = (high - low) * 0.18
        return max(low - pad, 0)...(high + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    // 基线
                    Rectangle()
                        .fill(theme.divider)
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .bottom)

                    if points.count == 1, let only = points.first {
                        Circle()
                            .fill(tint)
                            .frame(width: 7, height: 7)
                            .position(x: size.width / 2, y: y(only.value, in: size.height))
                    } else if points.count > 1 {
                        areaPath(in: size)
                            .fill(
                                LinearGradient(
                                    colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                        linePath(in: size)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                            Circle()
                                .fill(tint)
                                .frame(width: 5, height: 5)
                                .position(x: x(index: points.firstIndex(of: point) ?? 0, count: points.count, width: size.width),
                                          y: y(point.value, in: size.height))
                                .help(point.detail.isEmpty ? point.label : point.detail)
                        }
                    }
                }
            }
            .frame(height: height)

            // 首尾标签 + 当前值（点数多时只给这两个锚点，够看趋势了）
            HStack(spacing: 6) {
                Text(points.first?.label ?? "")
                Spacer(minLength: 0)
                if let last = points.last {
                    Text("\(Int(last.value.rounded()))\(valueSuffix)")
                        .fontWeight(.semibold)
                        .foregroundStyle(tint)
                    Text(last.label)
                }
            }
            .appFont(9, design: .rounded)
            .foregroundStyle(theme.secondaryText)
            .monospacedDigit()
        }
    }

    private func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return width / 2 }
        let step = width / CGFloat(count - 1)
        return step * CGFloat(index)
    }

    private func y(_ value: Double, in height: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        let ratio = span > 0 ? (value - range.lowerBound) / span : 0.5
        // 上下各留 6pt，圆点不会被裁掉。
        let usable = max(height - 12, 1)
        return height - 6 - usable * CGFloat(min(max(ratio, 0), 1))
    }

    private func linePath(in size: CGSize) -> Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let position = CGPoint(
                x: x(index: index, count: points.count, width: size.width),
                y: y(point.value, in: size.height)
            )
            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        return path
    }

    private func areaPath(in size: CGSize) -> Path {
        var path = linePath(in: size)
        guard points.count > 1 else { return path }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}

// MARK: - 技能分布

/// 一条技能横条。**没数据的维度明确显示「还没数据」**，不画成 0 分条。
struct SkillBar: View {

    @Environment(\.forestTheme) private var theme
    let skill: SkillScore

    private var tint: Color {
        switch skill.kind {
        case .grammar: Color(hex: 0x6FB1FC)
        case .vocabulary: Color(hex: 0xF2A65A)
        case .pronunciation: Color(hex: 0xC08BF0)
        case .shadowing: Color(hex: 0x4FC3A1)
        case .fluency: Color(hex: 0xFF8FA3)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: skill.kind.systemImage)
                    .appFont(10)
                    .foregroundStyle(tint)
                    .frame(width: 14)
                Text(skill.kind.displayName)
                    .appFont(11, weight: .medium, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 4)
                Text(skill.hasData ? "\(skill.percent)" : "—")
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(skill.hasData ? tint : theme.secondaryText)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.divider.opacity(0.7))
                    Capsule()
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * CGFloat(skill.hasData ? skill.score : 0))
                }
            }
            .frame(height: 6)

            Text(skill.detail)
                .appFont(9, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
        }
    }
}
