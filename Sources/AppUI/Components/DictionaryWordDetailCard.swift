import AIDomain
import SwiftUI

/// 查词结果页（纯展示组件）。
///
/// 信息排布参考用户给的词典截图，但**视觉沿用本应用**（浅色卡片 + 语义色）：
/// 词头 + 音标 → 释义 → 固定搭配（**直接展开**，不像截图那样要按钮）→ 例句 →
/// 构词拆分 → 词源 → 派生词 / 近义 / 反义。
///
/// 两条硬口径：
/// 1. **有则展示、没有则整段不出现**（用户原话）：模型没给构词拆分，
///    页面就不该留一个空标题在那儿装样子；只有一栏「近义」时，
///    那一栏就占满整行（不是空着两个格）。
/// 2. 每条例句（**含固定搭配里的例句**）都要有朗读按钮。
///
/// 组件不读 `AppState`：朗读状态用闭包注入，这样它才能被离屏渲染单独验证。
public struct DictionaryWordDetailCard: View {

    @Environment(\.forestTheme) private var theme

    private let detail: DictionaryDetail
    private let isLoading: Bool
    private let canGoBack: Bool
    private let canReturnToOrigin: Bool
    private let isInVocabulary: Bool
    private let isSpeaking: (String) -> Bool
    private let isPreparing: (String) -> Bool
    private let onSpeak: (String) -> Void
    private let onStopSpeak: () -> Void
    private let onBack: () -> Void
    private let onReturnToOrigin: () -> Void
    private let onAddToReview: () -> Void
    private let onOpenRelated: (String) -> Void
    /// 忽略缓存重查一次（模型这次给的条目不好用时，用户有办法再来一次）。
    private let onRelookUp: () -> Void
    /// 划词上下文（固定搭配 / 例句里的每个词都能划过看释义）。
    /// nil = 只读展示（离屏渲染与单测走这条路，不牵进 `AppState`）。
    private let lookup: WordLookupContext?

    /// 悬停的词（派生词 / 近义 / 反义里的词，鼠标移上去轻微高亮）。
    @State private var hoveredWord: String?

    public init(
        detail: DictionaryDetail,
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canReturnToOrigin: Bool = false,
        isInVocabulary: Bool = false,
        isSpeaking: @escaping (String) -> Bool = { _ in false },
        isPreparing: @escaping (String) -> Bool = { _ in false },
        onSpeak: @escaping (String) -> Void = { _ in },
        onStopSpeak: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {},
        onReturnToOrigin: @escaping () -> Void = {},
        onAddToReview: @escaping () -> Void = {},
        onOpenRelated: @escaping (String) -> Void = { _ in },
        onRelookUp: @escaping () -> Void = {},
        lookup: WordLookupContext? = nil
    ) {
        self.detail = detail
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canReturnToOrigin = canReturnToOrigin
        self.isInVocabulary = isInVocabulary
        self.isSpeaking = isSpeaking
        self.isPreparing = isPreparing
        self.onSpeak = onSpeak
        self.onStopSpeak = onStopSpeak
        self.onBack = onBack
        self.onReturnToOrigin = onReturnToOrigin
        self.onAddToReview = onAddToReview
        self.onOpenRelated = onOpenRelated
        self.onRelookUp = onRelookUp
        self.lookup = lookup
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            navigationRow
            if detail.isEmpty {
                placeholder
            } else {
                headword
                if !detail.baseForm.isEmpty || !detail.formNote.isEmpty { formRow }
                if !detail.phoneticUS.isEmpty || !detail.phoneticUK.isEmpty { phoneticRow }
                if !detail.senses.isEmpty { sensesSection }
                // 固定搭配在截图里要点图标才展开，本应用**直接展开**（用户口径）。
                if !detail.collocations.isEmpty { collocationsSection }
                if !detail.examples.isEmpty { examplesSection }
                if !detail.morphology.isEmpty { morphologySection }
                if !detail.etymology.isEmpty { etymologySection }
                if detail.hasRelated { relatedSection }
                // 词族树排在三列关联词**之后**：先看「直接相关的一圈」，再顺着词根成串地看。
                if !detail.family.isEmpty {
                    WordFamilyCard(
                        family: detail.family,
                        currentWord: detail.word,
                        isSpeaking: isSpeaking,
                        isPreparing: isPreparing,
                        onSpeak: onSpeak,
                        onStopSpeak: onStopSpeak,
                        onOpenRelated: onOpenRelated
                    )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 8, x: 0, y: 3)
        )
    }

    // MARK: - 导航条（返回上一页 / 回到最初 / 添加复习）

    private var navigationRow: some View {
        HStack(spacing: 8) {
            if canGoBack {
                pillButton("返回上一页", systemImage: "chevron.left", tint: theme.accentCool, action: onBack)
            }
            // 「回到最初」只在**多层跳转**时出现：只查了两个词时它和「上一页」是同一个目标。
            if canReturnToOrigin {
                pillButton("回到最初", systemImage: "arrow.uturn.backward", tint: theme.accent, action: onReturnToOrigin)
            }
            Spacer(minLength: 0)
            if isInVocabulary {
                Label("已在词表", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            } else {
                pillButton("添加复习", systemImage: "plus.rectangle.on.folder", tint: theme.accent, action: onAddToReview)
            }
            // 重查：模型这次给的条目不好用时（少了搭配 / 音标不对），有办法再来一次。
            if !detail.isEmpty {
                Button(action: onRelookUp) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("忽略缓存，重新查一次")
            }
        }
    }

    /// 胶囊按钮：两处导航按钮**颜色不同**（返回 = 冷紫、回到最初 = 琥珀），
    /// 免得两个长得一样的按钮并排，用户每次都要读文字才知道点哪个。
    private func pillButton(
        _ title: String, systemImage: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: - 词头

    private var headword: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(detail.word)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            speakButton(detail.word, label: "朗读单词")
            Spacer(minLength: 0)
        }
    }

    /// 查的是变体时，词头下面交代一句「这是谁的什么形式」。
    ///
    /// 与划词气泡同一套口径（见 `WordLookupBubble.formRow`）：用户从气泡点进词典页，
    /// 两处对同一个词的说明必须一致 —— 页面这边只有本体的释义、不说清关系会显得前后矛盾。
    @ViewBuilder
    private var formRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            if !detail.baseForm.isEmpty {
                Text(detail.baseForm)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            }
            if let label = WordForm.label(surface: detail.word, lemma: detail.baseForm) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
            }
            if !detail.formNote.isEmpty {
                Text(detail.formNote)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var phoneticRow: some View {        HStack(spacing: 8) {
            if !detail.phoneticUS.isEmpty { phoneticTag("美", detail.phoneticUS) }
            if !detail.phoneticUK.isEmpty { phoneticTag("英", detail.phoneticUK) }
            Spacer(minLength: 0)
        }
    }

    private func phoneticTag(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(theme.accent)
            Text(value)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(theme.surfaceAlt))
        .overlay(Capsule().strokeBorder(theme.divider, lineWidth: 1))
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView().progressViewStyle(.circular).controlSize(.small)
                Text("正在查「\(detail.word)」…")
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.secondaryText)
                Text("没有查到「\(detail.word)」的内容，可以再点一次查询。")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .rounded))
        .foregroundStyle(theme.secondaryText)
        .padding(.vertical, 10)
    }

    // MARK: - 释义

    private var sensesSection: some View {
        sectionBox("释义") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(detail.senses.enumerated()), id: \.offset) { _, sense in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            if !sense.pos.isEmpty {
                                Text(sense.pos)
                                    .font(.system(size: 11, weight: .bold, design: .rounded).italic())
                                    .foregroundStyle(theme.accent)
                                    .frame(width: 40, alignment: .leading)
                            }
                            Text(sense.text)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(2)
                        }
                        if !sense.explanation.isEmpty {
                            Text(sense.explanation)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(2)
                                .padding(.leading, sense.pos.isEmpty ? 0 : 47)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 固定搭配（直接展开）

    private var collocationsSection: some View {
        sectionBox("固定搭配") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(detail.collocations) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        // ⚠️ `.top` 而不是 `.firstTextBaseline`：`LookupText` 是 AppKit
                        // 视图包装，**不提供基线**，`firstTextBaseline` 会退化成按中心对齐，
                        // 搭配与译文就会一高一低。
                        HStack(alignment: .top, spacing: 8) {
                            // 搭配本身也是可划词的：`nominal fee` 里的 `nominal` 值得单独查。
                            //
                            // ⚠️ **必须 `.fixedSize`**：`LookupText` 走的是 AppKit 文本视图（`NSViewRepresentable`），
                            // 它在 SwiftUI 眼里是「弹性视图」——会连同后面的 `Spacer` 一起瓜分剩余宽度，
                            // 结果中文释义被推到卡片最右边（用户实测：译文离英文隔了大半张卡）。
                            // 钉成自然宽度后，译文就紧跟在搭配右边的 8pt 处。
                            LookupText(
                                text: item.phrase,
                                fontSize: 13,
                                weight: .bold,
                                color: theme.primaryText,
                                context: lookup
                            )
                            .fixedSize(horizontal: true, vertical: false)
                            if !item.translation.isEmpty {
                                Text(item.translation)
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(theme.primaryText.opacity(0.85))
                            }
                            Spacer(minLength: 0)
                        }
                        if !item.example.isEmpty {
                            exampleRow(item.example, item.exampleTranslation, indented: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 例句

    private var examplesSection: some View {
        sectionBox("例句") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(detail.examples) { item in
                    exampleRow(item.text, item.translation, indented: false)
                }
            }
        }
    }

    /// 一条例句 + 翻译 + **紧跟句子右侧**的朗读按钮。
    ///
    /// 英文那一行走 `LookupText`：鼠标划过任何一个词都能单独看释义，
    /// 拖选几个词还能整段翻译。中文译文保持普通文本（中文不划词）。
    ///
    /// ⚠️ 句子与按钮之间**不能用 `Spacer`**：`LookupText` 是贪心视图，
    /// 中间的 `Spacer` 会把它顶到卡片右缘，图标就跟句子隔了大半张卡（用户实测报障）。
    /// `TextWithTrailingActionRow` 负责「按钮紧贴句末、长句才退回折行」。
    private func exampleRow(_ text: String, _ translation: String, indented: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextWithTrailingActionRow(spacing: 6) {
                LookupText(
                    text: text,
                    fontSize: 12,
                    italic: true,
                    color: theme.primaryText.opacity(0.92),
                    context: lookup
                )
                speakButton(text, label: "朗读例句")
            }
            if !translation.isEmpty {
                Text(translation)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .padding(.leading, indented ? 8 : 0)
    }

    // MARK: - 构词拆分

    private var morphologySection: some View {
        sectionBox("构词拆分") {
            HStack(spacing: 6) {
                ForEach(Array(detail.morphology.parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Text("+")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    morphChip(part)
                }
                if !detail.morphology.result.isEmpty {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.accent)
                    Text(detail.morphology.result)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func morphChip(_ part: DictionaryMorphPart) -> some View {
        VStack(spacing: 2) {
            Text(part.text)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            if !part.label.isEmpty {
                Text(part.label)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    // MARK: - 词源

    private var etymologySection: some View {
        sectionBox("词源") {
            Text(detail.etymology)
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(theme.primaryText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
    }

    // MARK: - 派生词 / 近义 / 反义（三列合一）

    /// 三组里**只画存在的那几组**：只有一组时它占满整行（用户给的 diesel 截图就是这个样子）。
    private var relatedColumns: [(title: String, words: [DictionaryRelatedWord], tint: Color)] {
        var columns: [(String, [DictionaryRelatedWord], Color)] = []
        if !detail.derivatives.isEmpty { columns.append(("派生词", detail.derivatives, theme.accentCool)) }
        if !detail.synonyms.isEmpty { columns.append(("近义", detail.synonyms, theme.foliage)) }
        if !detail.antonyms.isEmpty { columns.append(("反义", detail.antonyms, theme.accentAlt)) }
        return columns
    }

    /// 三列**合一张卡**，列与列之间用竖线分隔（用户口径）。
    ///
    /// 为什么必须合成一张：三张独立的卡各按自己的内容定高，词数不一样就一高一低，
    /// 下面再接「词族树」那张卡，边缘参差不齐看着像没对齐的拼贴。
    /// 合成一张之后整块只有一个圆角外框，列高由最高的那列统一兜住。
    private var relatedSection: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(relatedColumns.enumerated()), id: \.offset) { index, column in
                if index > 0 {
                    Rectangle()
                        .fill(theme.divider)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 2)
                }
                relatedColumn(title: column.title, words: column.words, tint: column.tint)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceAlt.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    private func relatedColumn(title: String, words: [DictionaryRelatedWord], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.secondaryText)
            ForEach(words) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        // 点词 → 查这个新词（并可以在左上角回退）。
                        Button {
                            onOpenRelated(item.word)
                        } label: {
                            Text(item.word)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(hoveredWord == item.word ? tint.opacity(0.65) : tint)
                                .underline(hoveredWord == item.word, color: tint.opacity(0.65))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            hoveredWord = hovering ? item.word : (hoveredWord == item.word ? nil : hoveredWord)
                        }
                        .help("查「\(item.word)」")
                        speakButton(item.word, label: "朗读")
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 5) {
                        if !item.pos.isEmpty {
                            Text(item.pos)
                                .font(.system(size: 10, weight: .medium, design: .rounded).italic())
                                .foregroundStyle(theme.accent)
                        }
                        if !item.translation.isEmpty {
                            Text(item.translation)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.primaryText.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - 小件

    /// 段落框：标题在左上（小字），内容是下面那块。
    private func sectionBox<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.secondaryText)
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceAlt.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    private func speakButton(_ text: String, label: String) -> some View {
        SpeakButton(
            isActive: isSpeaking(text),
            isPreparing: isPreparing(text),
            accessibilityLabel: label
        ) {
            if isSpeaking(text) { onStopSpeak() } else { onSpeak(text) }
        }
    }
}
