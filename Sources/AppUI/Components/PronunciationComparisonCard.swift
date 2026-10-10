import AIDomain
import SwiftUI

/// 发音的「最近 vs 之前」（④ 的纵向那一半）。
///
/// 单次报告只看得见一次开口，回答不了「我有没有变好」。这张卡把最近那批跟读按
/// **前后两段**比一比 —— 只画不算，判据全在 `PronunciationComparisonRule`。
///
/// ⚠️ 样本不够时**整块不出现**（`compare` 返回 nil）：两三次开口的分数差几乎必然是噪声，
/// 拿噪声写一句「进步了」比什么都不写更糟。
struct PronunciationComparisonCard: View {

    let comparison: PronunciationComparison
    /// false = 由外层提供卡壳（页面里并排摆放时用）。
    var showsContainer: Bool = true

    @Environment(\.forestTheme) private var theme

    var body: some View {
        if showsContainer {
            content
                .appPadding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(theme.surface)
                        .appElevation(.card)
                )
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .appFont(12)
                    .foregroundStyle(theme.accent)
                Text("进步了吗")
                    .appFont(13, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 6)
                Text("\(comparison.sampleCount) 次")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }

            if let headline = comparison.headline {
                Text(headline)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 7) {
                ForEach(comparison.rows) { item in
                    comparisonRow(item)
                }
            }

            Text("前后各取一半比均值，不是拿首尾两次比 —— 中间夹一次特别好的，结论不该被它翻过去。")
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func comparisonRow(_ row: PronunciationComparison.Row) -> some View {
        HStack(spacing: 8) {
            Text(row.title)
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .frame(width: 66, alignment: .leading)

            Text(row.beforeText)
                .appFont(11, weight: .medium, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()

            Image(systemName: "arrow.right")
                .appFont(9)
                .foregroundStyle(theme.secondaryText.opacity(0.7))

            Text(row.afterText)
                .appFont(12, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .monospacedDigit()

            Spacer(minLength: 6)

            // 变好是绿、变差是橘；1 分以内的抖动一律不标色（说明不了任何事）。
            Text(row.deltaText)
                .appFont(10, weight: .semibold, design: .rounded)
                .foregroundStyle(row.isBetter ? theme.success
                                 : (row.isWorse ? theme.warning : theme.secondaryText))
                .monospacedDigit()
        }
    }

    private var accessibilityText: String {
        let parts = comparison.rows.map { "\($0.title) \($0.beforeText) 到 \($0.afterText)，\($0.deltaText)" }
        return ((comparison.headline.map { [$0] } ?? []) + parts).joined(separator: "；")
    }
}
