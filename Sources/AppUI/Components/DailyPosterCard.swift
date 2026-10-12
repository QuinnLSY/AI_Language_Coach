import AIDomain
import SwiftUI

/// 今日战绩海报（⑦-D）：把今天练出来的东西画成一张能发出去的图。
///
/// 单独成组件的理由同 `AnnualRecapCard`：它既要摆在进度页里看，也要**离屏渲染成 PNG**
/// （`ReportExporter.dailyPosterPNG`），两处必须是同一张脸 ——
/// 分开画就会出现「页面上一版、导出出去另一版」。
///
/// ⚠️ 本视图**不做任何编排**：日期、标题、哪几行数据、收尾那句话全是
/// `DailyPoster` 的纯函数算好的，这里只负责摆。
/// ⚠️ 所有数字都是**插出来的真值**，没有一个写死的「8 轮 / 5 天」。
struct DailyPosterCard: View {

    @Environment(\.forestTheme) private var theme

    var poster: DailyPoster

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            headline
            if !poster.subhead.isEmpty { subhead }
            metrics
            Divider().overlay(theme.divider)
            closing
        }
        .appPadding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: - 各块

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sun.max.fill")
                .appFont(13, weight: .semibold)
                .foregroundStyle(theme.accent)
            Text("今日战绩")
                .appFont(13, weight: .bold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 0)
            Text(poster.dateText)
                .appFont(12, weight: .medium, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
        }
    }

    private var headline: some View {
        Text(poster.headline)
            .appFont(26, weight: .bold, design: .rounded)
            .foregroundStyle(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var subhead: some View {
        Text(poster.subhead)
            .appFont(13, weight: .semibold, design: .rounded)
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 10)
            .appPadding(.vertical, 4)
            .background(Capsule().fill(theme.accent.opacity(0.12)))
    }

    /// 数据行：一行摆不下就两行（海报宽度会跟着导出尺寸变）。
    ///
    /// ⚠️ 用 `LazyVGrid` 而不是写死一行四列：只有一行数据时写死的格子会留出三个空洞。
    private var metrics: some View {
        let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(poster.metrics) { metric in
                metricTile(metric)
            }
        }
    }

    private func metricTile(_ metric: DailyPoster.Metric) -> some View {
        HStack(spacing: 9) {
            Image(systemName: metric.systemImage)
                .appFont(14, weight: .semibold)
                .foregroundStyle(theme.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(metric.value)
                    .appFont(15, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(metric.title)
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .appPadding(10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.7))
        )
    }

    private var closing: some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf.fill")
                .appFont(10, weight: .semibold)
                .foregroundStyle(theme.accent)
            Text(poster.closing)
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
