import AIDomain
import SwiftUI

// MARK: - 听力三种形式共用的播放控件（#308 #309）
//
// 「听这一句 / 慢速 / 已经听了几遍」这三个元素在三个模式里是**同一件事**：
// 同一把声音、同一条播放链路、同一个遍数计数（`listeningPlayCount`）。
// 各写一份的话，改一处配色或文案就得记住改三处 —— 而漏掉的那一处
// 只会表现为「选了另一种形式之后按钮看着不太一样」这种没人会报的毛病。
struct ListeningPlaybackControls: View {

    @Environment(\.forestTheme) private var theme

    let chrome: ListeningRule.ListeningChrome
    let playCount: Int
    let isPlaying: Bool
    let isSlow: Bool
    let onPlay: () -> Void
    let onToggleSlow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            playButton
            slowToggle
            Text(chrome.playsText)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
    }

    private var playButton: some View {
        Button(action: onPlay) {
            HStack(spacing: 6) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(isPlaying ? chrome.stopButton : (playCount == 0 ? chrome.playButton : chrome.replayButton))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.accent.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.55), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("放这一句（作答之前屏幕上不会出现文字）")
        .accessibilityLabel(isPlaying ? "停止播放" : "听这一句")
    }

    private var slowToggle: some View {
        Button(action: onToggleSlow) {
            HStack(spacing: 5) {
                Image(systemName: isSlow ? "tortoise.fill" : "hare.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(chrome.slowLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isSlow ? theme.accentCool : theme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSlow ? theme.accentCool.opacity(0.14) : theme.surfaceAlt.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSlow ? theme.accentCool.opacity(0.55) : theme.secondaryText.opacity(0.35),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("降到 0.7 倍速 —— 听不出连读时先用它把语流拆开")
        .accessibilityLabel(chrome.fastLabel)
    }
}
