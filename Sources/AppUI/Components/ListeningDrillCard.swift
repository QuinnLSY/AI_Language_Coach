import AIDomain
import AppKit
import SwiftUI

/// 无文本听力卡：屏幕上**不给任何文字**，只听、只写，交了再对。
///
/// 为什么单独做一张卡（而不是给跟读卡加个开关）：跟读页那张卡把句子摊在最显眼处，
/// 那是「看着念」的界面；精听要的恰好相反 —— 提交之前**一个字都不能露**。
/// 两种界面互相打架，硬塞进一张卡必然有人顺手把原文留在上面。
/// 本卡因此只读 `drill.id` / `drill.text`（且 `text` **只在提交后**取用），
/// 提示区那几行文案全部来自 `ListeningRule.promptStrings`（可被断言不含原文的词）。
public struct ListeningDrillCard: View {

    @Environment(\.forestTheme) private var theme

    private let index: Int
    private let total: Int
    /// 刚提交的那一句（nil = 还在听 / 写）。
    private let attempt: ListeningAttempt?
    private let playCount: Int
    private let isPlaying: Bool
    private let isSlow: Bool
    private let isLast: Bool
    @Binding private var typed: String

    private let onPlay: () -> Void
    private let onToggleSlow: () -> Void
    private let onSubmit: () -> Void
    private let onAdvance: () -> Void
    private let onCancel: () -> Void

    @State private var inputHeight: CGFloat = 0
    @State private var isInputFocused = false

    /// 界面文案的**唯一来源**（`ListeningRule.chrome`）。
    ///
    /// ⚠️ 别在这里另写字面量：「提交前不许出现原文」这条规则的断言挂在
    /// `ListeningRule.leaksReference` 上，而它只能检查从 `chrome` 组装出来的那几行。
    /// 就地再写一句说明，就等于绕过那条断言 —— 而这正是最容易出事的地方。
    private var chrome: ListeningRule.ListeningChrome {
        ListeningRule.chrome(index: index, total: total, playCount: playCount, slow: isSlow)
    }

    public init(
        index: Int,
        total: Int,
        attempt: ListeningAttempt?,
        playCount: Int,
        isPlaying: Bool,
        isSlow: Bool,
        isLast: Bool,
        typed: Binding<String>,
        onPlay: @escaping () -> Void,
        onToggleSlow: @escaping () -> Void,
        onSubmit: @escaping () -> Void,
        onAdvance: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.index = index
        self.total = total
        self.attempt = attempt
        self.playCount = playCount
        self.isPlaying = isPlaying
        self.isSlow = isSlow
        self.isLast = isLast
        self._typed = typed
        self.onPlay = onPlay
        self.onToggleSlow = onToggleSlow
        self.onSubmit = onSubmit
        self.onAdvance = onAdvance
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let attempt {
                feedback(attempt)
            } else {
                prompt
            }
        }        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 8, x: 0, y: 3)
        )
        // 换句时清掉上一句的输入与焦点：留着会让人以为「这句我已经写过了」。
        .onChange(of: index) { _, _ in
            typed = ""
            inputHeight = 0
            isInputFocused = true
        }
        .onAppear { isInputFocused = true }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "ear.badge.waveform")
                .font(.system(size: 12))
                .foregroundStyle(theme.accent)
            Text(chrome.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text(chrome.counterText)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
            Spacer(minLength: 8)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(chrome.cancelHelp)
            .accessibilityLabel("退出听写")
        }
    }

    // MARK: - 听 + 写

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chrome.subtitle)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                playButton
                slowToggle
                Text(chrome.playsText)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }

            inputField

            HStack(spacing: 10) {
                Button(action: onSubmit) {
                    HStack(spacing: 5) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                        Text(chrome.submitButton)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.onAccentFill)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(theme.accentFill)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
                .help("写完再看原文，顺序反过来就不算听写了")
                .accessibilityLabel("对照原文")

                Spacer(minLength: 0)
            }
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
        .help("放这一句（屏幕上不会出现文字）")
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

    private var inputField: some View {
        ZStack(alignment: .topLeading) {
            MultilineComposerField(
                text: $typed,
                measuredHeight: $inputHeight,
                isFocused: $isInputFocused,
                textColor: NSColor(theme.primaryText),
                insertionColor: NSColor(theme.accent),
                onSubmit: onSubmit
            )
            .frame(height: max(inputHeight, ComposerMetrics.lineHeight(fontSize: 14)))

            if typed.isEmpty {
                Text(chrome.answerPlaceholder)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.62))
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    // MARK: - 对照

    private func feedback(_ attempt: ListeningAttempt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("\(attempt.accuracyPercent)%")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(stepColor(attempt.step))
                    .monospacedDigit()

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: attempt.step.symbol)
                            .font(.system(size: 11))
                        Text(attempt.step.displayName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(stepColor(attempt.step))

                    Text(playedText(attempt))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            // 逐词对照：绿=听到并写对，红=没听出来，橙=多写了
            // （与跟读页同一把尺，学员看到的三种颜色是同一个意思）。
            FlowRow(spacing: 6, lineSpacing: 6) {
                ForEach(Array(attempt.comparison.tokens.enumerated()), id: \.offset) { _, token in
                    tokenChip(token)
                }
            }

            // ⚠️ 原文只在这里出现 —— 提交之前这张卡里没有任何一处读 `reference`。
            VStack(alignment: .leading, spacing: 4) {
                Text(attempt.reference)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !attempt.translation.isEmpty {
                    Text(attempt.translation)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                    Text("我写的：\(attempt.typed)")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.surfaceAlt.opacity(0.7))
            )

            Text(attempt.step.advice)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if !attempt.missedWords.isEmpty {
                    Text("没听出来：\(attempt.missedWords.prefix(6).joined(separator: "、"))")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.warning)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: onAdvance) {
                    HStack(spacing: 5) {
                        Text(isLast ? "看总结" : "下一句")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
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
                .accessibilityLabel(isLast ? "看总结" : "下一句")
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func playedText(_ attempt: ListeningAttempt) -> String {
        let plays = attempt.playCount == 0
            ? "没有播放记录"
            : "听了 \(attempt.playCount) 遍"
        return attempt.usedSlowRate ? "\(plays) · 用过慢速" : plays
    }

    private func tokenChip(_ token: ShadowingToken) -> some View {
        let color: Color = switch token.status {
        case .matched: theme.success
        case .missing: theme.danger
        case .extra: theme.warning
        }
        let prefix = token.status == .extra ? "+" : ""
        return Text(prefix + token.word)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(token.status == .matched ? theme.primaryText : color)
            .strikethrough(token.status == .missing, color: color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(token.status == .matched ? 0.14 : 0.18))
            )
            .help(token.status == .extra ? "多写的词" : (token.status == .missing ? "没听出来" : "听到了"))
    }

    private func stepColor(_ step: ListeningStep) -> Color {
        switch step {
        case .firstPass: theme.success
        case .understood: theme.accent
        case .notYet: theme.warning
        }
    }
}
