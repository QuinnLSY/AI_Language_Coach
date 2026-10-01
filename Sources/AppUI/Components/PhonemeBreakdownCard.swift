import AIDomain
import SwiftUI

/// 逐音素明细条（第 24 步 音素级测评）：`w ✓ ɜː ✓ r △ l ✗ d ✓`。
///
/// **为什么单独成组件**：它是发音评测卡里唯一需要单独离屏渲染回归的部分 ——
/// 整页渲染看不出它到底有没有真画出来，独立组件让测试能直接渲染它、数它的字。
///
/// 数据全部来自 `PronunciationReport.phonemeWords`，这里不产生任何判断；
/// 分档阈值在 `PhonemeMark`，配色语义与 `ShadowingView.scoreColor` 一致。
///
/// **来源必须如实显示**：推断不是实测，`PhonemeSource` 决定标签文案，
/// 组件绝不把规则推断说成声学实测。
struct PhonemeBreakdownCard: View {

    @Environment(\.forestTheme) private var theme

    let report: PronunciationReport
    /// 独立展示时自带一层浅底 + 圆角（嵌在别人的卡里时由外层提供）。
    var showsContainer: Bool = false

    /// 只画参考句里有的词；多说的词没有音素，不进这一条。
    private var words: [PhonemeWordAssessment] {
        report.phonemeWords.filter { $0.status != .extra }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            FlowRow(spacing: 8, lineSpacing: 8) {
                ForEach(words) { item in
                    wordBlock(item)
                }
            }
            if let explanation = report.phonemeSource.explanation {
                Text(explanation)
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    private var header: some View {
        HStack(spacing: 6) {
            Text("逐音素明细")
                .appFont(12, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            if let label = report.phonemeSource.displayName {
                Text(label)
                    .appFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(report.phonemeSource == .acoustic ? theme.accent : theme.secondaryText)
                    .padding(.horizontal, 7)
                    .appPadding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            (report.phonemeSource == .acoustic ? theme.accent : theme.secondaryText).opacity(0.14)
                        )
                    )
            }
            Spacer(minLength: 8)
            legend
        }
    }

    /// 图例：✓ 准 / △ 偏差 / ✗ 再练。
    private var legend: some View {
        HStack(spacing: 7) {
            ForEach(PhonemeMark.allCases, id: \.self) { mark in
                HStack(spacing: 2) {
                    Text(mark.symbol)
                        .appFont(8, weight: .bold)
                    Text(markName(mark))
                        .appFont(9, design: .rounded)
                }
                .foregroundStyle(markColor(mark))
            }
        }
    }

    /// 一个词 + 它的音素串。整词漏读时只淡淡列出参考音（不带档位符号）。
    private func wordBlock(_ item: PhonemeWordAssessment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(item.word)
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                if item.status == .missing {
                    Text("漏读")
                        .appFont(9, weight: .semibold, design: .rounded)
                        .foregroundStyle(.red)
                }
            }

            if item.status == .missing {
                // 整词没读到：只把**参考音**淡淡列出来，让他知道这个词该怎么念。
                // ⚠️ 这里绝不能画红色的 ✗——他根本没发这些音，
                // 标成「发音不对」是把「没读」谎报成「读错」。
                missingPhonemes(item)
            } else if item.phonemes.isEmpty {
                Text("无音素")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            } else {
                HStack(spacing: 5) {
                    ForEach(Array(item.phonemes.enumerated()), id: \.offset) { _, rating in
                        token(rating)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .appPadding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(borderColor(item), lineWidth: 1)
        )
        .help(item.status == .missing ? "这个词没听到" : "这个词 \(item.scorePercent) 分")
    }

    /// 词框描边：整词分档与逐音素**共用同一把尺子**（`PhonemeMark`），
    /// 免得同一个词出现「框是绿的、里面音素是黄的」这种自相矛盾。
    private func borderColor(_ item: PhonemeWordAssessment) -> Color {
        item.status == .missing
            ? Color.red.opacity(0.5)
            : markColor(PhonemeMark.from(score: item.score)).opacity(0.35)
    }

    /// 漏读词的参考音串：中性灰、不带档位符号。
    @ViewBuilder
    private func missingPhonemes(_ item: PhonemeWordAssessment) -> some View {
        if item.phonemes.isEmpty {
            Text("—")
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.secondaryText)
        } else {
            HStack(spacing: 5) {
                ForEach(Array(item.phonemes.enumerated()), id: \.offset) { _, rating in
                    Text(PhonemeDisplay.ipa(for: rating.phoneme))
                        .font(.system(
                            size: 11,
                            weight: PhonemeDisplay.isStressed(rating.phoneme) ? .semibold : .regular,
                            design: .rounded
                        ))
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                }
            }
            .help("这个词没读到，这是它该有的音")
        }
    }

    /// 单个音素：IPA 符号 + 档位符号（主重音加粗）。
    private func token(_ rating: PhonemeRating) -> some View {
        let mark = PhonemeMark.from(score: rating.score)
        let color = markColor(mark)
        return HStack(spacing: 1) {
            Text(PhonemeDisplay.ipa(for: rating.phoneme))
                .font(.system(
                    size: 11,
                    weight: PhonemeDisplay.isStressed(rating.phoneme) ? .semibold : .regular,
                    design: .rounded
                ))
                .foregroundStyle(color)
            Text(mark.symbol)
                .appFont(8, weight: .bold)
                .foregroundStyle(color)
        }
        .help("\(rating.phoneme) · \(Int((rating.score * 100).rounded())) 分")
    }

    /// 音素档位配色，与 `ShadowingView.scoreColor` 同一套语义（绿=准、琥珀=偏差、红=不对）。
    private func markColor(_ mark: PhonemeMark) -> Color {
        switch mark {
        case .good: .green
        case .fair: theme.accent
        case .poor: .red
        }
    }

    private func markName(_ mark: PhonemeMark) -> String {
        switch mark {
        case .good: "准"
        case .fair: "偏差"
        case .poor: "再练"
        }
    }
}
