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
    /// 「去词典查」当前绑的键（#619；空 = 不显示提示行）。
    private let dictionaryHint: String
    /// 「加入复习」当前绑的键（#619；空 = 不显示提示行）。
    private let addReviewHint: String

    public init(
        card: WordLookupCard,
        isSpeaking: Bool = false,
        onSpeak: @escaping () -> Void = {},
        onStopSpeak: @escaping () -> Void = {},
        onOpenDictionary: @escaping () -> Void = {},
        onAddToReview: @escaping () -> Void = {},
        onRetryLookup: @escaping () -> Void = {},
        dictionaryHint: String = "",
        addReviewHint: String = ""
    ) {
        self.card = card
        self.isSpeaking = isSpeaking
        self.onSpeak = onSpeak
        self.onStopSpeak = onStopSpeak
        self.onOpenDictionary = onOpenDictionary
        self.onAddToReview = onAddToReview
        self.onRetryLookup = onRetryLookup
        self.dictionaryHint = dictionaryHint
        self.addReviewHint = addReviewHint
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
                        .appFont(11, design: .rounded)
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
                            .appFont(10, weight: .semibold, design: .rounded, italic: true)
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 5)
                            .appPadding(.vertical, 1)
                            .background(Capsule().fill(theme.accent.opacity(0.14)))
                    }
                    Text(card.translation)
                        .appFont(12, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }
            }
            if !card.formNote.isEmpty {
                Text(card.formNote)
                    .appFont(10.5, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = card.notice, !notice.isEmpty {
                Text(notice)
                    .appFont(10.5, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 底部按键提示（#619）：两个动作现在也能直接按键触发。
            // 读的是**当前**绑定（设置里改过键，这行必须跟着变 —— 同复习卡的纪律）；
            // 两个提示都空（离屏渲染 / 老调用点）时不渲染，不占地方。
            if !dictionaryHint.isEmpty || !addReviewHint.isEmpty {
                shortcutHintRow(dictionaryKey: dictionaryHint, reviewKey: addReviewHint)
            }
        }
        .padding(.horizontal, 11)
        .appPadding(.vertical, 9)
        // ⚠️ 自适应增宽：maxWidth 抬到 `minCardWidth` 以上 —— 词比 268 还长时，
        // 卡片跟着词长，**绝不把单词折行**；正常词则维持 268 上限不变。
        .frame(
            minWidth: minCardWidth,
            maxWidth: max(Self.maxWidth, minCardWidth),
            alignment: .leading
        )
        // 浮层材质（#361）：划词卡悬在正文上方，毛玻璃透出底下还有内容；
        // 「降低透明度」下退回实底。
        .floatingSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .appElevation(.raised)
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
                .appFont(9, weight: .semibold)
                .foregroundStyle(theme.secondaryText)
            Text(card.lemma)
                .appFont(12, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .textSelection(.disabled)
            Text(card.formLabel)
                .appFont(9.5, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 5)
                .appPadding(.vertical, 1)
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
                .appFont(14, weight: .bold, design: .rounded)
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
            // ⚠️ 这一颗与**复习卡词条行那颗**共用同一个组件：同一个动作
            // （把这个词送去词典查）在两处必须长得一样，各写一遍就迟早会长歪。
            // 图标口径写在 `LookupDictionaryButton` 里，这里只给命中区边长。
            LookupDictionaryButton(
                side: Self.iconSide,
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
            .appFont(11, design: .rounded)
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
    }

    // MARK: - 底部按键提示（#619）

    /// 卡面上唯一的快捷键说明：一颗键盘图标 + 两枚「键面 + 动作」小芯片。
    ///
    /// 视觉语言与复习卡底部那行同款（键面浅底圆角、动作灰字）—— 同一个应用的
    /// 「哪些操作有键」应该长同一个样子。单独一行而不是塞进图标按钮：
    /// 按钮只有 22pt，塞进去键面（`⌘⇧R` 可能更长）会把图标挤没。
    private func shortcutHintRow(dictionaryKey: String, reviewKey: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .appFont(10)
                .foregroundStyle(theme.secondaryText)
            if !dictionaryKey.isEmpty { hintChip(dictionaryKey, "词典") }
            if !reviewKey.isEmpty { hintChip(reviewKey, "复习") }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("键盘快捷键：\(dictionaryKey) 去词典查，\(reviewKey) 加入复习")
    }

    private func hintChip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .appFont(10, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, 5)
                .appPadding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(theme.surfaceAlt)
                )
            Text(label)
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func iconButton(
        systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .appFont(13, weight: .semibold)
                .foregroundStyle(theme.accentCool)
                .frame(width: Self.iconSide, height: Self.iconSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.appPressable)
        .help(help)
    }
}
