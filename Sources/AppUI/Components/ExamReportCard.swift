import AIDomain
import SwiftUI

/// 考后结算卡：各维度参考分 + 原始指标 + 示范答案。
///
/// 三件事必须写在卡上，否则这张卡会骗人：
/// 1. **「参考分」** —— 这是按可量化指标折出来的相对位置，不是官方评分（`ExamScoring` 的同款声明）；
/// 2. **每一项的原始依据** —— 只给数字不给依据，学员没法核对，也没法改；
/// 3. **哪些维度是实测、哪些是文本代理指标** —— 语速与发音是量出来的，
///    词汇 / 语法 / 任务完成只是文本代理，两者混在一起展示会被当成同等可信。
///
/// ⚠️ 这里**不产星星、不写判定卡**：考试与课程 / 闯关是两套评价，
/// 混在一起学员就分不清「我没过关」和「我这次分数不高」。
struct ExamReportCard: View {

    @Environment(\.forestTheme) private var theme
    let report: ExamReport
    /// 示范答案（题号 → 回答）。
    let sampleAnswers: [Int: String]
    /// 本次给哪几问写了示范答案（写之前也用它显示题面 + 转圈）。
    let sampleTargets: [ExamSampleTarget]
    /// 示范答案没拿到时的说明（nil = 正常）。
    let sampleNotice: String?
    let isGeneratingSamples: Bool
    var onRetrySamples: () -> Void = {}
    var onSpeak: (String) -> Void = { _ in }
    var onRetake: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    scoreSection
                    metricsSection
                    if !report.highlights.isEmpty { listSection("做得好的地方", report.highlights, tint: theme.accentCool) }
                    if !report.improvements.isEmpty { listSection("可以改进的地方", report.improvements, tint: theme.warning) }
                    sampleSection
                }
                .appPadding(18)
            }
            Divider().overlay(theme.divider)
            footer
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .appFont(17)
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(theme.surfaceAlt)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(report.title)
                    .appFont(16, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Text(report.isComplete
                     ? "整场考完 · 下面是按可量化指标折出来的参考分，不是官方成绩"
                     : "这一场没考完 · 参考分只反映已经答过的部分")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 68)
    }

    // MARK: - 分数

    private var scoreSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("总评")
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                if let overall = report.overall {
                    Text(overall.displayName)
                        .appFont(30, weight: .bold, design: .rounded)
                        .foregroundStyle(theme.accent)
                    Text("/ 9")
                        .appFont(12, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                } else {
                    Text("没考到分")
                        .appFont(14, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
                Text("各项均值，缺数据的维度不计入")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(report.scores, id: \.dimension.id) { score in
                scoreRow(score)
            }
            if report.scores.isEmpty {
                Text("这次没有记录到任何作答 —— 至少完整答完一题，报告才有意义。")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func scoreRow(_ score: ExamScore) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(score.dimension.displayName)
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                // 「实测」与「文本代理指标」必须分开说：语速是量出来的，
                // 用词多样性只是文本上的代理，两者的可信度不是一回事。
                Text(score.dimension.isMeasured ? "实测" : "文本指标")
                    .appFont(9, weight: .semibold, design: .rounded)
                    .foregroundStyle(score.dimension.isMeasured ? theme.accentCool : theme.secondaryText)
                    .padding(.horizontal, 6)
                    .appPadding(.vertical, 1)
                    .background(Capsule().fill(theme.hover))
                Spacer(minLength: 0)
                Text(score.band.displayName)
                    .appFont(13, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.accent)
                    .monospacedDigit()
            }
            bar(score.band)
            Text(score.evidence)
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .appPadding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.55))
        )
    }

    /// 0–9 的刻度条。用填充长度表示分数 —— 比只写数字更容易比较。
    private func bar(_ band: ExamBand) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.hover)
                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(proxy.size.width * band.value / 9, 3))
            }
        }
        .frame(height: 5)
    }

    // MARK: - 原始指标

    private var metricsSection: some View {
        let metrics = report.metrics
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("原始指标", trailing: "分数就是这些数算出来的")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                metric("答了几问", "\(metrics.answeredCount)/\(metrics.questionCount)")
                metric("总词数", "\(metrics.totalWords)")
                // ⚠️ 口径写清楚：这里的秒数来自**作答计时**（题目出现 → 交卷），
                // 不是从录音里量出来的说话时长 —— 键盘作答时更明显。
                // 只写「说话时长」会让人以为做过音频分析（那是跟读页才干的事）。
                metric("作答计时", ExamSessionBar.clock(metrics.speakingSeconds))
                metric("语速（计时口径）", String(format: "%.0f 词/分", metrics.wordsPerMinute))
                metric("填充词", String(format: "%.1f%%", metrics.fillerRatio * 100))
                metric("用词去重", String(format: "%.0f%%", metrics.contentTypeTokenRatio * 100))
                metric("平均句长", String(format: "%.1f 词", metrics.averageSentenceWords))
                metric("带从句的句子", String(format: "%.0f%%", metrics.clauseSentenceRatio * 100))
                if let errors = metrics.errorsPerAnswer {
                    metric("平均每答错误", String(format: "%.1f 处", errors))
                } else {
                    metric("纠错数据", "没取到")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .appFont(9, design: .rounded)
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .appFont(12, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
        }
        .padding(.horizontal, 10)
        .appPadding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.5))
        )
    }

    private func listSection(_ title: String, _ lines: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle(title, trailing: "")
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(tint).frame(width: 4, height: 4).appPadding(.top, 5)
                    Text(line)
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }

    // MARK: - 示范答案

    @ViewBuilder
    private var sampleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(
                "示范答案",
                trailing: sampleTargets.isEmpty ? "每一问都答够了，不需要补" : "老师写的一版，供对照"
            )
            if !sampleTargets.isEmpty {
                if isGeneratingSamples {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在写示范答案…")
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                if let sampleNotice {
                    HStack(spacing: 8) {
                        Text(sampleNotice)
                            .appFont(10, design: .rounded)
                            .foregroundStyle(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(action: onRetrySamples) {
                            Text("重试")
                                .appFont(10, weight: .semibold, design: .rounded)
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 9)
                                .appPadding(.vertical, 4)
                                .background(Capsule().fill(theme.hover))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.appPressable)
                        .help("再让老师写一次示范答案")
                    }
                }
                ForEach(sampleTargets, id: \.questionNumber) { target in
                    sampleBlock(target)
                }
            } else {
                Text("这场考试的每一问都达到了期望长度，不再另给示范答案。")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func sampleBlock(_ target: ExamSampleTarget) -> some View {
        let answer = sampleAnswers[target.questionNumber]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Text("第 \(target.questionNumber) 问")
                    .appFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.accent)
                Text(target.prompt)
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let answer {
                    Button {
                        onSpeak(answer)
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .appFont(10)
                            .foregroundStyle(theme.accent)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(theme.hover))
                    }
                    .buttonStyle(.appPressable)
                    .help("朗读这条示范答案")
                    .accessibilityLabel("朗读第 \(target.questionNumber) 问的示范答案")
                }
            }
            if let answer {
                Text(answer)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            } else if isGeneratingSamples {
                Text("…")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            } else {
                Text("这一问的示范答案没拿到。")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .appPadding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.5))
        )
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Text("这场考试不记星星：星星说的是参与度，考试说的是参考分。")
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 0)
            Button(action: onRetake) {
                Text("再来一次")
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 14)
                    .appPadding(.vertical, 7)
                    .background(Capsule().fill(theme.hover))
                    .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .help("用同一套考卷再考一次")

            Button(action: onClose) {
                Text("完成")
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.onAccentFill)
                    .padding(.horizontal, 16)
                    .appPadding(.vertical, 7)
                    .background(Capsule().fill(theme.accentFill))
                    .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .help("收下报告")
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private func sectionTitle(_ text: String, trailing: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .appFont(10, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 0)
            if !trailing.isEmpty {
                Text(trailing)
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }
}
