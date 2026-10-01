import AIDomain
import AppKit
import SwiftUI

/// 听力卡（写作答的那两种形式）：屏幕上**不给任何文字**，只听、只写，交了再对。
///
/// 为什么单独做一张卡（而不是给跟读卡加个开关）：跟读页那张卡把句子摊在最显眼处，
/// 那是「看着念」的界面；听力要的恰好相反 —— 作答之前**一个字都不能露**。
/// 两种界面互相打架，硬塞进一张卡必然有人顺手把原文留在上面。
/// 本卡因此只读 `drill.id` / `drill.text`（且 `text` **只在提交后**取用），
/// 提示区那几行文案全部来自 `ListeningRule.chrome`（可被断言不含原文的词）。
///
/// ⚠️ #309 起它同时服务**精听默写**与**关键词捕捉**两种形式：两者的「听 + 写 + 对照」
/// 是同一套，差别只在对照那一屏（整句逐词 vs 命中的关键信息词）。
/// 拆成两张卡会有两份播放按钮、两份慢速开关、两份输入框 —— 那三样是同一件事，
/// 分开写迟早会分叉（一边改了配色另一边没改）。
public struct ListeningDrillCard: View {

    @Environment(\.forestTheme) private var theme

    private let mode: ListeningMode
    private let index: Int
    private let total: Int
    /// 刚提交的那一句（nil = 还在听 / 写）。
    private let attempt: ListeningAttempt?
    /// 关键词捕捉刚提交的对照（仅 `.keyword` 用）。
    private let keyword: KeywordCapture?
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
    /// 划词上下文（页面从 `AppState.wordLookupContext` 递进来；nil = 不可划词，
    /// 离屏渲染与单测走这条退路）。**只影响对照屏**：作答之前这张卡里没有原文，
    /// 没什么可划 —— 「不给原文」的不变量不因划词而破。
    var wordLookup: WordLookupContext?

    @State private var inputHeight: CGFloat = 0
    @State private var isInputFocused = false

    /// 界面文案的**唯一来源**（`ListeningRule.chrome`）。
    ///
    /// ⚠️ 别在这里另写字面量：「作答前不许出现原文」这条规则的断言挂在
    /// `ListeningRule.leaksReference` 上，而它只能检查从 `chrome` 组装出来的那几行。
    /// 就地再写一句说明，就等于绕过那条断言 —— 而这正是最容易出事的地方。
    private var chrome: ListeningRule.ListeningChrome {
        ListeningRule.chrome(
            index: index, total: total, playCount: playCount, slow: isSlow, mode: mode
        )
    }

    public init(
        mode: ListeningMode = .dictation,
        index: Int,
        total: Int,
        attempt: ListeningAttempt?,
        keyword: KeywordCapture? = nil,
        playCount: Int,
        isPlaying: Bool,
        isSlow: Bool,
        isLast: Bool,
        typed: Binding<String>,
        wordLookup: WordLookupContext? = nil,
        onPlay: @escaping () -> Void,
        onToggleSlow: @escaping () -> Void,
        onSubmit: @escaping () -> Void,
        onAdvance: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.index = index
        self.total = total
        self.attempt = attempt
        self.keyword = keyword
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
        self.wordLookup = wordLookup
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let keyword {
                keywordFeedback(keyword)
            } else if let attempt {
                feedback(attempt)
            } else {
                prompt
            }
        }
        .appPadding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .appElevation(.card)
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
                .appFont(12)
                .foregroundStyle(theme.accent)
            Text(chrome.title)
                .appFont(14, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Text(chrome.counterText)
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
            Spacer(minLength: 8)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .appFont(11, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appPressable)
            .help(chrome.cancelHelp)
            .accessibilityLabel("退出听写")
        }
    }

    // MARK: - 听 + 写

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chrome.subtitle)
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ListeningPlaybackControls(
                    chrome: chrome,
                    playCount: playCount,
                    isPlaying: isPlaying,
                    isSlow: isSlow,
                    onPlay: onPlay,
                    onToggleSlow: onToggleSlow
                )
            }

            inputField

            HStack(spacing: 10) {
                Button(action: onSubmit) {
                    HStack(spacing: 5) {
                        Image(systemName: "text.magnifyingglass")
                            .appFont(11, weight: .semibold)
                        Text(chrome.submitButton)
                            .appFont(12, weight: .semibold, design: .rounded)
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
                .buttonStyle(.appPressable)
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
                .help(chrome.submitHelp)
                .accessibilityLabel(chrome.submitButton)

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 输入框

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
                    .appFont(14, design: .rounded)
                    .foregroundStyle(theme.secondaryText.opacity(0.62))
                    .appPadding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 14)
        .appPadding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    // MARK: - 对照（① 精听默写：整句逐词）

    private func feedback(_ attempt: ListeningAttempt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("\(attempt.accuracyPercent)%")
                    .appFont(32, weight: .bold, design: .rounded)
                    .foregroundStyle(stepColor(attempt.step))
                    .monospacedDigit()

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: attempt.step.symbol)
                            .appFont(11)
                        Text(attempt.step.displayName)
                            .appFont(13, weight: .semibold, design: .rounded)
                    }
                    .foregroundStyle(stepColor(attempt.step))

                    Text(playedText(attempt))
                        .appFont(11, design: .rounded)
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

            // ⚠️ 原文只在这里出现 —— 作答之前这张卡里没有任何一处读 `reference`。
            revealCard(
                reference: attempt.reference,
                translation: attempt.translation,
                typed: attempt.typed
            )

            Text(attempt.step.advice)
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if !attempt.missedWords.isEmpty {
                    Text("没听出来：\(attempt.missedWords.prefix(6).joined(separator: "、"))")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.warning)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                advanceButton
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - 对照（② 关键词捕捉：命中的关键信息词）

    /// 关键词捕捉的对照屏。
    ///
    /// 与默写**故意长得不一样**：默写是逐词上色（差在哪个词），
    /// 这里是「抓住了 / 没抓住」两排（差在哪些信息）。两者若共用一套颜色语义，
    /// 学员会以为漏掉的虚词也要背 —— 而这个模式压根不考虚词。
    private func keywordFeedback(_ capture: KeywordCapture) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("\(capture.hitPercent)%")
                    .appFont(32, weight: .bold, design: .rounded)
                    .foregroundStyle(hitColor(capture.hitRatio))
                    .monospacedDigit()

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: hitSymbol(capture))
                            .appFont(11)
                        Text(capture.scoreText)
                            .appFont(13, weight: .semibold, design: .rounded)
                    }
                    .foregroundStyle(hitColor(capture.hitRatio))

                    Text(playedText(capture.playCount))
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            Text("这一句该抓住的信息词：")
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)

            FlowRow(spacing: 6, lineSpacing: 6) {
                ForEach(capture.keyWords, id: \.self) { word in
                    wordChip(word, isHit: capture.caught.contains(word))
                }
            }

            revealCard(
                reference: capture.reference,
                translation: capture.translation,
                typed: capture.typedWords.joined(separator: " ")
            )

            Text(hitAdvice(capture))
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if !capture.missed.isEmpty {
                    Text("没抓住：\(capture.missed.prefix(6).joined(separator: "、"))")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.warning)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                advanceButton
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// 「抓住了 3 / 4」上面那颗图标：全中给实心章，没全中给「还差几个」的提示。
    private func hitSymbol(_ capture: KeywordCapture) -> String {
        if capture.total > 0 && capture.caughtCount == capture.total { return "checkmark.seal.fill" }
        return capture.caughtCount == 0 ? "ear.trianglebadge.exclamationmark" : "target"
    }

    private func hitColor(_ ratio: Double) -> Color {
        if ratio >= Double(ListeningRule.firstPassAccuracy) { return theme.success }
        if ratio >= Double(ListeningRule.understoodAccuracy) { return theme.accent }
        return theme.warning
    }

    /// 一句话建议（对着人说话，不是评分术语）。
    private func hitAdvice(_ capture: KeywordCapture) -> String {
        if capture.total > 0 && capture.caughtCount == capture.total {
            return "主干全抓住了。换成精听默写，把细节也抠下来。"
        }
        if capture.caughtCount == 0 {
            return "一个都没抓住不要紧：先只听两遍、每次只盯一个问题（谁？做了什么？），再来。"
        }
        return "抓住了主干就好。没抓住的那几个多半在句尾 —— 听的时候给结尾留一段注意力。"
    }

    /// 「原文 + 译文 + 我写的」那一块（两种写作答的形式共用）。
    ///
    /// ⚠️ 这是全文里**唯一**读参考句的地方：作答之前谁都不许调它。
    /// 原文一行走 `LookupText`：有划词上下文就是可划词的（悬停 / 拖选出气泡），
    /// 没有就退回普通 `Text` —— 排版与旧实现一致。
    private func revealCard(reference: String, translation: String, typed: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LookupText(
                text: reference,
                fontSize: 14,
                weight: .semibold,
                color: theme.primaryText,
                context: wordLookup
            )
            if !translation.isEmpty {
                Text(translation)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "pencil.line")
                    .appFont(10)
                    .foregroundStyle(theme.secondaryText)
                Text("我写的：\(typed)")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .appPadding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.7))
        )
    }

    /// 关键词的「抓住 / 没抓住」小片。
    private func wordChip(_ word: String, isHit: Bool) -> some View {
        Text(word)
            .appFont(12, weight: .medium, design: .rounded)
            .foregroundStyle(isHit ? theme.primaryText : theme.danger)
            .padding(.horizontal, 8)
            .appPadding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((isHit ? theme.success : theme.danger).opacity(isHit ? 0.14 : 0.18))
            )
            .help(isHit ? "这个信息词你抓住了" : "这个词没抓住")
    }

    /// 「下一句 / 看总结」那颗（两种形式共用）。
    private var advanceButton: some View {
        Button(action: onAdvance) {
            HStack(spacing: 5) {
                Text(isLast ? "看总结" : "下一句")
                    .appFont(12, weight: .semibold, design: .rounded)
                Image(systemName: "arrow.right")
                    .appFont(10, weight: .semibold)
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
        .buttonStyle(.appPressable)
        .accessibilityLabel(isLast ? "看总结" : "下一句")
    }

    private func playedText(_ attempt: ListeningAttempt) -> String {
        playedText(attempt.playCount, usedSlowRate: attempt.usedSlowRate)
    }

    private func playedText(_ playCount: Int, usedSlowRate: Bool = false) -> String {
        let plays = playCount == 0 ? "没有播放记录" : "听了 \(playCount) 遍"
        return usedSlowRate ? "\(plays) · 用过慢速" : plays
    }

    private func tokenChip(_ token: ShadowingToken) -> some View {
        let color: Color = switch token.status {
        case .matched: theme.success
        case .missing: theme.danger
        case .extra: theme.warning
        }
        let prefix = token.status == .extra ? "+" : ""
        return Text(prefix + token.word)
            .appFont(12, weight: .medium, design: .rounded)
            .foregroundStyle(token.status == .matched ? theme.primaryText : color)
            .strikethrough(token.status == .missing, color: color)
            .padding(.horizontal, 8)
            .appPadding(.vertical, 4)
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
