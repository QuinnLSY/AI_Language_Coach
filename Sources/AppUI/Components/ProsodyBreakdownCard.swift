import AIDomain
import SwiftUI

/// 逐词韵律条（④ 高级发音分析）：`LATTE ▲ ‿ please` —— 重读 / 弱读 + 词间连读 + 语调轮廓。
///
/// **为什么单独成组件**（与 `PhonemeBreakdownCard` 同一个理由）：它是发音评测卡里
/// 唯一能单独离屏渲染回归的部分 —— 整页渲染看不出它到底有没有真画出来，
/// 独立组件让测试能直接渲染它、量它的高度与墨迹。
///
/// 数据全部来自 `ProsodyAnalysis`，这里**不做任何判断**：
/// 重音档位来自 `WordStressAnalyzer`、连读来自 `LinkingHeuristic`、加分来自 `ProsodyBonus`。
/// 页面只负责把已经算好的东西画出来。
///
/// ⚠️ 两条展示纪律（对应两处最容易「看着对、其实是假的」）：
/// ① **`level == nil` 不许画成「正常」** —— 那是没量到，不是读得刚好；
/// ② **连读只提示、不扣分**：没连上画成虚线灰提示，绝不画成红色 ✗。
///    它是启发式（用户 2026-10-10 拍板），判错一次的代价不能是扣分。
struct ProsodyBreakdownCard: View {

    @Environment(\.forestTheme) private var theme

    let analysis: ProsodyAnalysis
    /// 韵律加分（0...10）。**由调用方从 `report.prosodyBonus` 传进来** ——
    /// 加分口径只有领域层一处（本组件不自己算，免得两处算法漂移）。
    var bonus: Double = 0
    /// 独立展示时自带一层浅底 + 圆角（嵌在别人的卡里时由外层提供）。
    var showsContainer: Bool = false

    private var rows: [ProsodyRow] { analysis.rows }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !rows.isEmpty {
                // 词与它后面的连读标记是**同一个子视图**：分开喂给 FlowRow 的话，
                // 标记会在行尾被单独挤到下一行（看着像「多出一个词」）。
                FlowRow(spacing: 7, lineSpacing: 8) {
                    ForEach(rows) { row in
                        HStack(spacing: 3) {
                            wordBlock(row)
                            if let link = row.linkAfter {
                                linkTie(link)
                            }
                        }
                    }
                }
            }
            if let contour = analysis.contour {
                contourStrip(contour)
            }
            footnote
        }
        .appPadding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(container)
    }

    @ViewBuilder
    private var container: some View {
        if showsContainer {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.5))
        } else {
            Color.clear
        }
    }

    // MARK: - 表头

    private var header: some View {
        HStack(spacing: 6) {
            Text("逐词韵律")
                .appFont(12, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            if bonus >= 1 {
                Text("+\(Int(bonus.rounded()))")
                    .appFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 7)
                    .appPadding(.vertical, 3)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
                    .help("韵律加分 \(Int(bonus.rounded())) 分，是**额外**给的，不计入上面的总分")
            }
            Spacer(minLength: 8)
            legend
        }
    }

    /// 图例：■ 重读 / □ 弱读 / ‿ 连读。
    private var legend: some View {
        HStack(spacing: 8) {
            legendItem(text: "重读", color: theme.accent, filled: true)
            legendItem(text: "弱读", color: theme.secondaryText, filled: false)
            HStack(spacing: 2) {
                LinkTie()
                    .stroke(theme.success, lineWidth: 1.2)
                    .frame(width: 11, height: 7)
                    .appPadding(.top, 3)
                Text("连读")
                    .appFont(9, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func legendItem(text: String, color: Color, filled: Bool) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(filled ? color : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(color.opacity(filled ? 0 : 0.7), lineWidth: 1)
                )
                .frame(width: 8, height: 8)
                .appPadding(.top, 1)
            Text(text)
                .appFont(9, design: .rounded)
                .foregroundStyle(color)
        }
    }

    // MARK: - 逐词

    /// 一个词：重读加粗上色、弱读缩小淡化，**没量到就是没量到**（中性、不带档位暗示）。
    private func wordBlock(_ row: ProsodyRow) -> some View {
        let color = textColor(row.level)
        return Text(row.word)
            .appFont(row.level == .reduced ? 10 : 11,
                     weight: row.level == .stressed ? .semibold : .regular,
                     design: .rounded)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .appPadding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill(row.level))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(border(row.level), lineWidth: row.level == .stressed ? 1 : 0.7)
            )
            .help(helpText(row))
            .accessibilityLabel(row.accessibilityLabel)
    }

    private func textColor(_ level: WordStressMark.Level?) -> Color {
        switch level {
        case .stressed: theme.accent
        case .normal: theme.primaryText
        case .reduced: theme.secondaryText.opacity(0.85)
        case nil: theme.secondaryText.opacity(0.6)
        }
    }

    private func fill(_ level: WordStressMark.Level?) -> Color {
        level == .stressed ? theme.accent.opacity(0.16) : theme.surface
    }

    private func border(_ level: WordStressMark.Level?) -> Color {
        switch level {
        case .stressed: theme.accent.opacity(0.45)
        case .normal: theme.divider
        case .reduced: theme.divider.opacity(0.6)
        case nil: theme.divider.opacity(0.4)
        }
    }

    /// 悬浮说明：说清「量到了什么」，不评价好坏。
    private func helpText(_ row: ProsodyRow) -> String {
        guard let level = row.level else { return "\(row.word)：这一段没量到足够的声音" }
        let ratio = analysis.stress.first { $0.word == row.word }?.ratio ?? 1
        let percent = Int((ratio * 100).rounded())
        switch level {
        case .stressed: return "\(row.word)：重读（句内中位音量的 \(percent)%）"
        case .normal: return "\(row.word)：音量与句内中位持平（\(percent)%）"
        case .reduced: return "\(row.word)：弱读（句内中位音量的 \(percent)%）"
        }
    }

    // MARK: - 连读标记

    /// 两词之间的连读标记：连上了 = 实线绿；没连上 = **虚线灰**（只提示，不扣分）。
    private func linkTie(_ span: LinkingSpan) -> some View {
        LinkTie()
            .stroke(
                span.didLink ? theme.success : theme.secondaryText.opacity(0.55),
                style: StrokeStyle(
                    lineWidth: span.didLink ? 1.6 : 1.2,
                    dash: span.didLink ? [] : [2.5, 2]
                )
            )
            .frame(width: 12, height: 8)
            .appPadding(.top, 3)
            .help(
                span.didLink
                    ? "\(span.firstWord) \(span.secondWord)：连着读出来了"
                    : "\(span.firstWord) \(span.secondWord)：按英语习惯这里可以连着读（只是提示，不扣分）"
            )
            .accessibilityLabel(
                span.didLink
                    ? "\(span.firstWord) 与 \(span.secondWord) 连读"
                    : "\(span.firstWord) 与 \(span.secondWord) 可以连读"
            )
    }

    // MARK: - 语调轮廓

    private func contourStrip(_ contour: IntonationContour) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("语调")
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.secondaryText)
            ContourSparkline(points: contour.points)
                .stroke(theme.accent, lineWidth: 1.5)
                .frame(width: 132, height: 20)
            Text(contour.shape.displayName)
                .appFont(11, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("语调轮廓：\(contour.shape.displayName)")
    }

    // MARK: - 脚注

    /// 脚注必须把「启发式」和「不扣分」说在明处：
    /// 否则用户会把「这里可以连读」当成又一个要扣分的红点。
    private var footnote: some View {
        Text("连读按英语习惯标出「这里可以连着读」，只作提示、不扣分；重读与弱读来自这一遍录音的音量对比。")
            .appFont(10, design: .rounded)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 连读标记的形状：一条小小的连接弧（**自己画**，不依赖任何字体的 `‿` 字形 ——
/// 缺字形时它会渲染成空白，而那在代码里完全看不出来，只有出图才发现）。
struct LinkTie: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.35)
        )
        return path
    }
}

/// 语调轮廓迷你图：每词中点的相对音高（半音）连成的折线。
///
/// ⚠️ 全平（`max == min`）时画**中线**而不是挤在底边：挤在底边会被读成「音高掉下去了」，
/// 而事实是「这一句没有起伏」。
struct ContourSparkline: Shape {

    var points: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
        let lowest = points.min() ?? 0
        let highest = points.max() ?? 0
        let span = max(highest - lowest, 0.001)
        let inset = rect.height * 0.15
        let usable = max(rect.height - inset * 2, 1)
        let step = rect.width / CGFloat(points.count - 1)
        for (index, value) in points.enumerated() {
            // 半音越大越靠上（与「升调向上」的直觉一致）。
            let ratio = CGFloat((value - lowest) / span)
            let y = rect.maxY - inset - ratio * usable
            let x = rect.minX + step * CGFloat(index)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}
