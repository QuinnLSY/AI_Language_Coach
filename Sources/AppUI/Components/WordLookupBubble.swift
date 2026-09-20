import AIDomain
import SwiftUI

/// 划词气泡卡：划到的文字 + 音标 + 朗读，右上角纯图标按钮；词性贴在译文左边。
///
/// 布局口径（2026-09-19 二次定稿）：
/// **第一行是「词 + 朗读 + 图标按钮」，音标另起一行放在词的下面** ——
/// 音标挤在词头行会把长单词压得折行（"convenience" 断成两截，实测报障）。
/// 词**永远一行完整展示**：卡片宽度不够时**自适应增宽**（下限就是词头行的自然宽度），
/// 不够宽时绝不折词。查不到时右上角多一个「再查一次」按钮（↻），不用离开卡片重划。
public struct WordLookupBubble: View {

    @Environment(\.forestTheme) private var theme

    /// 气泡最大宽度。窄了中文释义频繁折行，宽了会盖住半张句子卡。
    ///
    /// `nonisolated`：纯几何常量，摆位算法（非隔离）与单测都要直接读它。
    public nonisolated static let maxWidth: CGFloat = 268
    /// 还没量出真实高度时的估算值：摆位要先用第一帧把它放对，否则气泡会先闪一下再跳位。
    public nonisolated static let fallbackHeight: CGFloat = 84

    /// 图标按钮的边长（与 `iconButton` 的 frame 一致）。
    private static let iconSide: CGFloat = 22
    /// 词头行里各元素之间的间距（`HStack(spacing: 6)` + `Spacer(minLength: 4)`）。
    private static let titleRowChrome: CGFloat = 6 * 4 + 4

    private let card: WordLookupCard
    private let isSpeaking: Bool
    private let onSpeak: () -> Void
    private let onStopSpeak: () -> Void
    private let onOpenDictionary: () -> Void
    private let onAddToReview: () -> Void
    private let onRetryLookup: () -> Void

    public init(
        card: WordLookupCard,
        isSpeaking: Bool = false,
        onSpeak: @escaping () -> Void = {},
        onStopSpeak: @escaping () -> Void = {},
        onOpenDictionary: @escaping () -> Void = {},
        onAddToReview: @escaping () -> Void = {},
        onRetryLookup: @escaping () -> Void = {}
    ) {
        self.card = card
        self.isSpeaking = isSpeaking
        self.onSpeak = onSpeak
        self.onStopSpeak = onStopSpeak
        self.onOpenDictionary = onOpenDictionary
        self.onAddToReview = onAddToReview
        self.onRetryLookup = onRetryLookup
    }

    /// 查词失败（没音标、没释义、只有一句说明）→ 右上角出现「再查一次」。
    /// 正在查 / 查到了 / 短语翻译成功都不算失败。
    private var isLookupFailed: Bool {
        !card.isLoading && card.translation.isEmpty && card.phonetic.isEmpty
            && !(card.notice ?? "").isEmpty
    }

    /// 词头行**一行放下单词**所需的最小内容宽（不含卡片左右 padding）。
    ///
    /// 纯函数（词 + 图标数 → 宽度）：口径单测直接钉在这里，渲染测试只管「真不真的没折行」。
    static func titleRowContentWidth(word: String, iconCount: Int) -> CGFloat {
        let attributed = NSAttributedString(
            string: word,
            attributes: [.font: WordLookupTextBuilder.font(size: 14, weight: .bold)]
        )
        // ⚠️ 量自然宽度必须走 `boundingRect`（见 WordLookupText.naturalWidth 的教训），
        // 禁 `greatestFiniteMagnitude` 容器当宽度 —— 那会把整张卡撑成一千万点的怪物。
        let wordWidth = ceil(
            attributed.boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width
        )
        return wordWidth + iconSide * (1 + CGFloat(iconCount)) + titleRowChrome
    }

    /// 卡片宽度下限 = 词头行内容宽 + 左右 padding。这是「单词一行完整展示」的硬保底。
    static func minCardWidth(word: String, iconCount: Int) -> CGFloat {
        titleRowContentWidth(word: word, iconCount: iconCount) + 22
    }

    private var minCardWidth: CGFloat {
        Self.minCardWidth(word: card.text, iconCount: isLookupFailed ? 3 : 2)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow
            if !card.phonetic.isEmpty { phoneticRow }
            if card.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在查…")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            // 划到的是变体：先交代「这是谁的什么形式」，再看本体的释义。
            // 用户口径要的就是这一句 —— 只有本体的释义、不说清关系，等于没解释。
            if card.isInflectedForm { formRow }
            // 词性放在译文左边（2026-09-19 用户口径：词性贴着翻译）。
            if !card.translation.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !card.pos.isEmpty {
                        Text(card.pos)
                            .font(.system(size: 10, weight: .semibold, design: .rounded).italic())
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.accent.opacity(0.14)))
                    }
                    Text(card.translation)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }
            }
            if !card.formNote.isEmpty {
                Text(card.formNote)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = card.notice, !notice.isEmpty {
                Text(notice)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        // ⚠️ 自适应增宽：maxWidth 抬到 `minCardWidth` 以上 —— 词比 268 还长时，
        // 卡片跟着词长，**绝不把单词折行**；正常词则维持 268 上限不变。
        .frame(
            minWidth: minCardWidth,
            maxWidth: max(Self.maxWidth, minCardWidth),
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 10, x: 0, y: 4)
        )
        // 卡片上的光标由 `CursorPolicy` 按命中测试裁决（#233 四轮）：
        // 卡片是 SwiftUI 浮层，命中它的是 FloatLayer 的平台视图 → 箭头。
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - 变体行：`subtitle` + 「复数形式」小胶囊

    private var formRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text(card.lemma)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .textSelection(.disabled)
            Text(card.formLabel)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(theme.accent.opacity(0.14)))
            Spacer(minLength: 0)
        }
    }

    // MARK: - 第一行：词 + 朗读 + 图标按钮（音标**不**在这一行）

    /// 词必须一行完整展示：`.fixedSize()` + `.lineLimit(1)` 钉死不折行，
    /// 宽度不够由 `minCardWidth` 把卡片撑宽 —— 而不是把词压断（"convenience" 教训）。
    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(card.text)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize()
                .lineLimit(1)
                .textSelection(.disabled)

            SpeakButton(
                isActive: isSpeaking,
                isPreparing: false,
                accessibilityLabel: "朗读「\(card.text)」"
            ) {
                if isSpeaking { onStopSpeak() } else { onSpeak() }
            }

            Spacer(minLength: 4)

            if isLookupFailed {
                iconButton(
                    systemImage: "arrow.clockwise",
                    help: "再查一次「\(card.text)」",
                    action: onRetryLookup
                )
            }
            iconButton(
                systemImage: "magnifyingglass.circle",
                help: "在词典里查「\(card.text)」",
                action: onOpenDictionary
            )
            iconButton(
                systemImage: "plus.rectangle.on.folder",
                help: "把「\(card.text)」加入复习",
                action: onAddToReview
            )
        }
    }

    /// 音标**另起一行**放在词的下面（2026-09-19 二次定稿）：
    /// 挤在词头行会把长单词压折行；单独一行后超长音标自己截断，不牵连词头。
    private var phoneticRow: some View {
        Text(card.phonetic)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
    }

    private func iconButton(
        systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accentCool)
                .frame(width: Self.iconSide, height: Self.iconSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
