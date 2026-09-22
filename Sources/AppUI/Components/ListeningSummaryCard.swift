import AIDomain
import SwiftUI

/// 一轮无文本听力的结算。
///
/// ⚠️ 平均分**不是**这块卡的主角：听力训练真正要看的指标是「几遍才听懂」
/// （见 `ListeningSummary.firstPassCount`）。同一份 80% 的卷子，「4 句一遍过」
/// 和「每句都听三遍才对」是两种完全不同的耳朵，只报平均分就把这件事盖掉了。
public struct ListeningSummaryCard: View {

    @Environment(\.forestTheme) private var theme

    private let summary: ListeningSummary
    private let onCollectWords: () -> Void
    private let onRestart: () -> Void
    private let onClose: () -> Void

    public init(
        summary: ListeningSummary,
        onCollectWords: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.summary = summary
        self.onCollectWords = onCollectWords
        self.onRestart = onRestart
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if summary.hasAttempts {
                metrics
                if !summary.missedWords.isEmpty { missedWords }
            }
            Text(summary.verdict)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 8, x: 0, y: 3)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: summary.isFirstPassPerfect ? "checkmark.seal.fill" : "ear.badge.waveform")
                .font(.system(size: 12))
                .foregroundStyle(summary.isFirstPassPerfect ? theme.success : theme.accent)
            Text("这一轮听完了")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 0)
            Text(summary.headline)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
        }
    }

    private var metrics: some View {
        HStack(alignment: .center, spacing: 14) {
            metric("\(summary.accuracyPercent)%", accuracyLabel, theme.accent)
            metric("\(summary.firstPassCount)/\(summary.attempted)", streakLabel, theme.success)
            metric(playsText, "平均听几遍", theme.accentCool)
            Spacer(minLength: 0)
        }
    }

    /// 三个数字的**位置**在三种形式里是同一处，**说法**随形式变。
    ///
    /// ⚠️ 标签不能写死成默写那一套：「一遍就听懂」放到听句选义上会让人以为
    /// 自己得了 0 分（那个模式的 `firstPassCount` 装的是「答对句数」）。
    private var accuracyLabel: String {
        switch summary.mode {
        case .dictation: return "平均对上的词"
        case .keyword: return "平均抓住的关键词"
        case .meaning: return "答对率"
        }
    }

    private var streakLabel: String {
        switch summary.mode {
        case .dictation: return "一遍就听懂"
        case .keyword: return "整句全抓住"
        case .meaning: return "答对句数"
        }
    }

    private var missedWordsTitle: String {
        switch summary.mode {
        case .dictation: return "没听出来的词"
        case .keyword: return "没抓住的信息词"
        case .meaning: return "错句里的关键词"
        }
    }

    private var playsText: String {
        let value = summary.averagePlays
        // 一遍以内（0.95~1.0）直接显示 1；否则一位小数。
        return abs(value.rounded() - value) < 0.05
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
    }

    private func metric(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var missedWords: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "ear.trianglebadge.exclamationmark")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.warning)
                Text(missedWordsTitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("这些词是耳朵真正卡住的地方")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 8)
                Button(action: onCollectWords) {
                    Text("收进词汇本")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.accentCool)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .strokeBorder(theme.accentCool.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("把这一轮没听出来的词一次加进词汇本（不加释义，零请求）")
            }
            FlowRow(spacing: 6, lineSpacing: 6) {
                ForEach(Array(summary.missedWords.prefix(24).enumerated()), id: \.offset) { _, word in
                    Text(word)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.warning)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.warning.opacity(0.16))
                        )
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.7))
        )
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onRestart) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("再练一轮")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(theme.accent.opacity(0.14))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("从第 1 句重新开始（今天已写对的成绩保留在账本里）")

            Button(action: onClose) {
                // ⚠️ #308 起听力是**独立一页**，点它不再回到跟读页，只是结束这一轮；
                // 文案写着「回到跟读」会把用户指向一个不会发生的事。
                Text("先不练了")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(theme.surfaceAlt.opacity(0.8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(theme.secondaryText.opacity(0.35), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("结束这一轮（今天练过的成绩留在账本里，随时可以从这一页再开一轮）")

            Spacer(minLength: 0)
        }
    }
}
