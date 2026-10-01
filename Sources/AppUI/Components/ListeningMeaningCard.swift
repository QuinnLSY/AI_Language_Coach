import AIDomain
import SwiftUI

/// 听句选义卡：只听一句，从**四个释义**里挑一个。
///
/// 三条口径：
/// ① 答之前屏幕上**没有英文原文** —— 题干只有四行释义（`MeaningQuestion` 这个类型
///    本身就不含参考句，所以「答题时露了原文」在类型层面就做不到）。
/// ② **点下去即判**，没有「提交」那一步：这个模式问的就是第一反应，
///    加一个提交按钮只会让人反复回听、把正确率刷成假的高。
/// ③ 判完**停在这一句**：把原文与译文亮出来（这时才第一次出现），
///    要用户点「下一句」才推进 —— 一答就跳走等于没告诉他错在哪。
public struct ListeningMeaningCard: View {

    @Environment(\.forestTheme) private var theme

    private let index: Int
    private let total: Int
    /// 这一句的题（nil = 这一句出不了题，卡由上层换成提示）。
    private let question: MeaningQuestion
    /// 学员已经选了哪个（nil = 还没答）。
    private let selection: Int?
    private let reference: String
    private let playCount: Int
    private let isPlaying: Bool
    private let isSlow: Bool
    private let isLast: Bool

    private let onPlay: () -> Void
    private let onToggleSlow: () -> Void
    private let onChoose: (Int) -> Void
    private let onAdvance: () -> Void
    private let onCancel: () -> Void
    /// 划词上下文（页面从 `AppState.wordLookupContext` 递进来；nil = 不可划词）。
    /// **只用于判完后的原文**：答题前这张卡没有英文 —— 不变量不因划词而破。
    var wordLookup: WordLookupContext?

    private var chrome: ListeningRule.ListeningChrome {
        ListeningRule.chrome(
            index: index, total: total, playCount: playCount, slow: isSlow, mode: .meaning
        )
    }

    public init(
        index: Int,
        total: Int,
        question: MeaningQuestion,
        selection: Int?,
        reference: String,
        playCount: Int,
        isPlaying: Bool,
        isSlow: Bool,
        isLast: Bool,
        wordLookup: WordLookupContext? = nil,
        onPlay: @escaping () -> Void,
        onToggleSlow: @escaping () -> Void,
        onChoose: @escaping (Int) -> Void,
        onAdvance: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.index = index
        self.total = total
        self.question = question
        self.selection = selection
        self.reference = reference
        self.playCount = playCount
        self.isPlaying = isPlaying
        self.isSlow = isSlow
        self.isLast = isLast
        self.onPlay = onPlay
        self.onToggleSlow = onToggleSlow
        self.onChoose = onChoose
        self.onAdvance = onAdvance
        self.onCancel = onCancel
        self.wordLookup = wordLookup
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Text(chrome.subtitle)
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ListeningPlaybackControls(
                chrome: chrome,
                playCount: playCount,
                isPlaying: isPlaying,
                isSlow: isSlow,
                onPlay: onPlay,
                onToggleSlow: onToggleSlow
            )
            options
            if selection != nil {
                reveal
                HStack(spacing: 10) {
                    Text(selection == question.correctIndex ? "听对了。" : "再听一遍这句，注意主干词。")
                        .appFont(12, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: 0)
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
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .appPadding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .appElevation(.card)
        )
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: ListeningMode.meaning.symbol)
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
            .accessibilityLabel("退出这一轮")
        }
    }

    // MARK: - 四个选项

    /// 选项**竖排**而不是两列网格：释义有长有短，两列会让长短差变成「哪一行更值得看」
    /// 的假线索；竖排一列读下来才是「逐条比一比」的正常读法。
    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { offset, text in
                optionRow(offset, text: text)
            }
        }
    }

    private func optionRow(_ offset: Int, text: String) -> some View {
        let answered = selection != nil
        let isCorrect = offset == question.correctIndex
        let isPicked = selection == offset
        // 判完之后：正确项打绿，选错的那一项打红，其余压暗（不再抢注意力）。
        let tint: Color = {
            guard answered else { return theme.secondaryText }
            if isCorrect { return theme.success }
            if isPicked { return theme.danger }
            return theme.secondaryText
        }()
        return Button {
            onChoose(offset)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(tint.opacity(answered ? 0.7 : 0.4), lineWidth: 1)
                        .frame(width: 18, height: 18)
                    if answered, isCorrect || isPicked {
                        Image(systemName: isCorrect ? "checkmark" : "xmark")
                            .appFont(9, weight: .bold)
                            .foregroundStyle(tint)
                    }
                }
                Text(text)
                    .appFont(13, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .appPadding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        answered && (isCorrect || isPicked)
                            ? tint.opacity(0.12)
                            : theme.surfaceAlt.opacity(0.6)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        answered && (isCorrect || isPicked) ? tint.opacity(0.55) : theme.divider,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.appPressable)
        // ⚠️ 判完之后整排锁死：还能点的话就变成「一路点到对为止」，正确率没有意义了。
        .disabled(answered)
        .opacity(answered && !isCorrect && !isPicked ? 0.55 : 1)
        .accessibilityLabel(text)
    }

    // MARK: - 判完才亮出来的原文

    /// ⚠️ 这一块只在 `selection != nil` 之后才被构造 —— 这是本卡「答之前不给原文」的
    /// 唯一落点。参考句是当参数传进来的（不像精听卡那样由 `ListeningAttempt` 带出来），
    /// 所以这条不变量靠**这里谁都不许提前调它**来守，回归测试钉的是出图：
    /// 未作答的卡上不该出现任何 ≥4 个字母的英文单词。
    private var reveal: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 判完亮出的原文走 `LookupText`：有划词上下文就能悬停 / 拖选出气泡
            // （与默写对照屏同一套划词链路），没有就退回普通 `Text`。
            LookupText(
                text: reference,
                fontSize: 14,
                weight: .semibold,
                color: theme.primaryText,
                context: wordLookup
            )
        }
        .appPadding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.7))
        )
        .transition(.opacity)
    }
}
