import AIDomain
import SwiftUI

/// 通勤连播（⑦-D）：跟读页顶部那张「一路放下去」的卡。
///
/// 跟读页原本每句都要按一次「听示范」，通勤路上 / 做饭时腾不出手 ——
/// 这张卡把「按 N 次」压成「按一次」。
///
/// ⚠️ 本视图**不排队、不计时**：队列多大、第几句、还剩多久全是 `CommuteQueue`
/// 的纯函数给的，这里只负责画；播放循环在 `AppState+Commute`。
/// ⚠️ 只有句子模式才出现：段落模式本来就是一次读完一整段，再叠一层连播是重复盖楼。
struct CommuteCard: View {

    @Environment(\.forestTheme) private var theme

    /// 连播队列（nil = 今天没有句子，整张卡不画）。
    var queue: CommuteQueue?
    /// 是否正在放。
    var isRunning: Bool
    /// 正在放的时候界面上要显示「忙」（示范音在合成 / 朗读）。
    var isBusy: Bool = false

    var onStart: () -> Void = {}
    var onStop: () -> Void = {}

    var body: some View {
        // ⚠️ 判空用 `queue == nil` 而不是 `isRunning`：没在放的时候也要画（那是入口卡），
        // 只有「今天压根没有句子」才整张不出现。
        if let queue {
            card(queue)
        }
    }

    private func card(_ queue: CommuteQueue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isRunning ? "waveform" : "music.note.list")
                .appFont(17, weight: .semibold)
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(theme.accent.opacity(isRunning ? 0.2 : 0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("通勤连播")
                        .appFont(13, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    if isRunning {
                        Text(queue.progressText)
                            .appFont(10, weight: .semibold, design: .rounded)
                            .foregroundStyle(theme.onAccentFill)
                            .padding(.horizontal, 7)
                            .appPadding(.vertical, 2)
                            .background(Capsule().fill(theme.accentFill))
                            .monospacedDigit()
                    }
                }
                Text(detail(queue))
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)

            Button(action: isRunning ? onStop : onStart) {
                HStack(spacing: 5) {
                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                        .appFont(9, weight: .bold)
                    Text(isRunning ? "停止" : "开始")
                        .appFont(12, weight: .semibold, design: .rounded)
                }
                .foregroundStyle(theme.onAccentFill)
                .padding(.horizontal, 14)
                .appPadding(.vertical, 7)
                .background(Capsule().fill(theme.accentFill))
                .contentShape(Capsule())
            }
            // ⚠️ 不写 `.buttonStyle(.plain)`：按压反馈由 MainView 根上统一注入
            //（`MotionTokenWiringTests` 钉着这条）。
            .help(helpText(queue))
            .accessibilityLabel(helpText(queue))
        }
        .appPadding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isRunning ? theme.accent.opacity(0.7) : theme.divider,
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: - 文案

    private func detail(_ queue: CommuteQueue) -> String {
        if isRunning {
            // 正在放：说这一句是什么 + 还剩几句，让人知道还要多久。
            let sentence = queue.currentDrill?.text ?? ""
            return sentence.isEmpty ? queue.remainingText : "\(sentence) · \(queue.remainingText)"
        }
        return "\(queue.summaryText) · 每句念完留 \(Int(queue.gapSeconds)) 秒给你跟读，手不用碰"
    }

    private func helpText(_ queue: CommuteQueue) -> String {
        isRunning
            ? "停在当前这一句；再按「开始」就从这句接着放"
            : "从当前这句开始，一路放到最后一句（\(queue.summaryText)）"
    }
}
