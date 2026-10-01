import AIDomain
import AppKit
import SwiftUI

/// 每日短文阅读页（#231）。
///
/// 一次阅读 = 一次模型请求（文章 + 3-5 道四选一 + 答案 + 溯源句 + 解析 + 错因）；
/// **判分纯本地零请求**（`ReadingGrader`）—— 交卷只做对错标记。
/// 交卷后每题向下展开解析卡：溯源原文（在原文里的句子逐字引用）+ 讲解；
/// 答对绿、答错红，错题额外给「错因复盘」（结合选项分析 + 英语知识）。
///
/// 文章与题干都是英文 —— 全部走 `LookupText` 接划词气泡（收生词在气泡里直接点）。
///
/// **正文的划词只认拖选**（`hoverLookupEnabled: false`）：阅读时鼠标会习惯性地
/// 跟着读进度走，悬停就弹翻译等于在书页上不停的弹窗（#233）。
/// **除正文外整页光标都是箭头**（`showsIBeamCursor: false`）：页面满是按钮 /
/// 卡片 / 浮层气泡，I 型插入符只会误导；判定由 `CursorPolicy` 按命中测试做
/// （AppKit 的窗口光标矩形不理会浮层遮挡，只改矩形治不了——#233 四轮）。
public struct ReadingView: View {

    @Environment(\.forestTheme) private var theme
    let state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let passage = state.readingPassage {
                        passageCard(passage)
                        questionsCard(passage)
                        submitRow(passage)
                        if state.isReadingReviewed {
                            scoreRow(passage)
                        }
                    } else if state.isReadingLoading {
                        loadingCard
                    } else {
                        emptyCard
                    }
                    if !state.readingNotice.isEmpty {
                        noticeBanner(state.readingNotice)
                    }
                }
                .appPadding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 内容不足一屏时不硬弹（#360，同聊天区）。
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(theme.surfaceAlt.opacity(0.35))
        .task { await state.openReading() }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            CuteAnimalView(kind: state.studentAnimalKind, isSleeping: theme.isNight, size: 40, accessory: state.studentAccessory)
            VStack(alignment: .leading, spacing: 2) {
                Text("阅读")
                    .appFont(16, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Text("每天一篇短文几道题 —— 读不懂的词直接划词，生词随手收进词汇本")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            if state.readingPassage != nil {
                Text(state.readingEntries.count > 1 ? "今日 \(state.readingEntries.count) 篇" : "今日一篇")
                    .appFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 6)
                    .appPadding(.vertical, 2)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
                    .help("一天只自动出一篇；点「换一篇」可再加，当天每篇都能回看")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // MARK: - 短文卡（可划词）

    private func passageCard(_ passage: ReadingPassage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("今日短文", systemImage: "book.fill")
                    .appFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8)
                    .appPadding(.vertical, 3)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
                // 当天各篇的编号按钮：第 1 篇就是「1」，换一篇往右顺序加；
                // 点谁切谁 —— 当天每一篇都回得去（#233）。
                if state.readingEntries.count > 0 {
                    HStack(spacing: 4) {
                        ForEach(state.readingEntries.indices, id: \.self) { index in
                            let isSelected = index == state.readingEntryIndex
                            Button {
                                state.selectReadingEntry(at: index)
                            } label: {
                                Text("\(index + 1)")
                                    .appFont(10, weight: .bold, design: .rounded)
                                    .monospacedDigit()
                                    .foregroundStyle(isSelected ? theme.onAccentFill : theme.secondaryText)
                                    .frame(width: 20, height: 20)
                                    .background(
                                        Circle().fill(isSelected ? theme.accentFill : theme.hover)
                                    )
                                    .overlay(
                                        Circle().strokeBorder(
                                            isSelected ? Color.clear : theme.divider,
                                            lineWidth: 1
                                        )
                                    )
                            }
                            .buttonStyle(.appPressable)
                            .help("第 \(index + 1) 篇")
                        }
                    }
                }
                Spacer(minLength: 0)
                Button {
                    Task { await state.loadReading() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("换一篇")
                    }
                    .appFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.accentCool)
                }
                .buttonStyle(.appPressable)
                .disabled(state.isReadingLoading)
                .help("让老师另写一篇（一次阅读 = 一次模型请求）；今天的旧篇仍可回看")
            }
            // 标题与正文都可划词：气泡里的「收进词汇本」就是收生词的入口。
            LookupText(
                text: passage.title,
                fontSize: 15,
                weight: .semibold,
                color: theme.primaryText,
                lineSpacing: 3,
                context: state.wordLookupContext,
                showsIBeamCursor: false
            )
            // 正文按段落排（首行缩进 + 段间距），且**只认拖选划词**。
            // ⚠️ 正文**保留 I 型光标**（全文唯一保留的一处）：它是纯阅读区，
            // 插入符正是「这里能选中」的提示。浮层卡片骑在它上方也不冲突 ——
            // 整窗光标按**命中测试**裁决（`CursorPolicy`），卡片上命中的是卡片。
            WordLookupSentence(
                attributed: ReadingParagraphText.make(
                    passage.text,
                    fontSize: 13,
                    color: NSColor(theme.primaryText),
                    lineSpacing: 4
                ),
                context: state.wordLookupContext,
                hoverLookupEnabled: false
            )
        }
        .appPadding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    // MARK: - 题目卡

    private func questionsCard(_ passage: ReadingPassage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(passage.questions.enumerated()), id: \.offset) { index, question in
                questionRow(index: index, question: question, passage: passage)
            }
        }
    }

    private func questionRow(index: Int, question: ReadingQuestion, passage: ReadingPassage) -> some View {
        let reviewed = state.isReadingReviewed
        let chosen = state.readingChoices[index]
        let isCorrect = reviewed && chosen == question.correctIndex
        let rowColor: Color = !reviewed ? theme.primaryText : (isCorrect ? theme.success : theme.danger)
        let isExpanded = state.expandedReadingQuestions.contains(index)

        return VStack(alignment: .leading, spacing: 10) {
            // 题干行：交卷后整行染色 + 对错图标。
            //
            // ⚠️ 行按钮与右端的收/展按钮是**兄弟**，不是父子：嵌套 `Button` 在 AppKit 上
            // 谁吃这次点击要看响应链，收/展这种「一按就翻转状态」的控件一旦双方都触发，
            // 表现就是「点了没反应」（翻两次回到原样）。拆开就没有这个问题。
            HStack(alignment: .top, spacing: 10) {
                Button {
                    if reviewed { state.toggleReadingQuestion(index) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text("Q\(index + 1)")
                            .appFont(10, weight: .bold, design: .rounded)
                            .foregroundStyle(reviewed ? rowColor : theme.accent)
                            .padding(.horizontal, 6)
                            .appPadding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill((reviewed ? rowColor : theme.accent).opacity(0.14))
                            )
                        LookupText(
                            text: question.prompt,
                            fontSize: 13,
                            weight: .medium,
                            color: rowColor,
                            lineSpacing: 3,
                            context: state.wordLookupContext,
                            showsIBeamCursor: false
                        )
                        Spacer(minLength: 6)
                        if reviewed {
                            Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .appFont(14)
                                .foregroundStyle(rowColor)
                        }
                    }
                    // ⚠️ 显式把整行都划成判定区：`Spacer` 那段空白本身没有墨、不参与命中，
                    // 少了这一句「空白处点了没反应」，用户只会觉得判定区小（实测反馈）。
                    .contentShape(Rectangle())
                }
                .buttonStyle(.appPressable)
                .disabled(!reviewed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(reviewed ? "点按收起 / 展开解析" : "")

                // 右端：带边框的收 / 展按钮（判定区比原来那个 9pt 裸箭头大一圈）。
                if reviewed {
                    ReadingQuestionToggleButton(isExpanded: isExpanded) {
                        state.toggleReadingQuestion(index)
                    }
                }
            }

            // 选项行。
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                    optionRow(
                        question: question,
                        optionIndex: optionIndex,
                        option: option,
                        chosen: chosen,
                        reviewed: reviewed
                    )
                }
            }

            // 解析卡（交卷后向下展开；对错都给 —— 需求硬要求）。
            if reviewed && isExpanded {
                explanationCard(question: question, chosen: chosen, passage: passage, isCorrect: isCorrect)
                    .transition(.opacity)
            }
        }
        .appPadding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            // 交卷后：整题用对错色的描边圈出来（绿对红错）。
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(reviewed ? rowColor.opacity(0.55) : theme.divider, lineWidth: reviewed ? 1.5 : 1)
        )
    }

    /// 一行选项。交卷后：正确项绿、错选红、其余淡出。
    private func optionRow(
        question: ReadingQuestion,
        optionIndex: Int,
        option: String,
        chosen: Int?,
        reviewed: Bool
    ) -> some View {
        let isSelected = chosen == optionIndex
        let isCorrectOption = reviewed && optionIndex == question.correctIndex
        let isWrongChoice = reviewed && isSelected && optionIndex != question.correctIndex
        let tint: Color = isCorrectOption ? theme.success : (isWrongChoice ? theme.danger : theme.accent)
        let dimmed = reviewed && !isCorrectOption && !isWrongChoice

        return Button {
            state.chooseReadingOption(question: questionIndex(of: question), option: optionIndex)
        } label: {
            // ⚠️ 对齐必须用 `.center`：选项文本是 `LookupText`（AppKit 视图），
            // SwiftUI 取不到它的 baseline，`.firstTextBaseline` 会把圆圈顶到字上面去（实测截图）。
            HStack(alignment: .center, spacing: 8) {
                Text(String(Character(UnicodeScalar(65 + optionIndex)!)))
                    .appFont(11, weight: .bold, design: .rounded)
                    .foregroundStyle(reviewed ? tint : (isSelected ? theme.onAccentFill : theme.secondaryText))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(
                            reviewed
                                ? tint.opacity(isCorrectOption || isWrongChoice ? 0.18 : 0.06)
                                : (isSelected ? theme.accentFill : theme.hover)
                        )
                    )
                LookupText(
                    text: option,
                    fontSize: 12,
                    color: dimmed ? theme.secondaryText.opacity(0.7) : (reviewed ? tint : theme.primaryText),
                    context: state.wordLookupContext,
                    showsIBeamCursor: false
                )
                Spacer(minLength: 0)
                if isCorrectOption {
                    Image(systemName: "checkmark")
                        .appFont(10, weight: .bold)
                        .foregroundStyle(theme.success)
                }
                if isWrongChoice {
                    Image(systemName: "xmark")
                        .appFont(10, weight: .bold)
                        .foregroundStyle(theme.danger)
                }
            }
            .padding(.horizontal, 10)
            .appPadding(.vertical, 8)
            // 整行都可点（AppKit 子视图不参与 SwiftUI 命中，必须显式给 contentShape）。
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        reviewed
                            ? (isCorrectOption || isWrongChoice ? tint.opacity(0.08) : Color.clear)
                            : (isSelected ? theme.accent.opacity(0.12) : theme.hover.opacity(0.5))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        reviewed
                            ? (isCorrectOption || isWrongChoice ? tint.opacity(0.6) : Color.clear)
                            : (isSelected ? theme.accent : theme.divider),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.appPressable)
        .disabled(reviewed)
    }

    /// 反查题目下标（ForEach 用 offset 遍历，这里用 id 对回位置）。
    private func questionIndex(of question: ReadingQuestion) -> Int {
        state.readingPassage?.questions.firstIndex(where: { $0.id == question.id }) ?? 0
    }

    // MARK: - 解析卡（溯源 + 讲解 + 错因复盘）

    private func explanationCard(
        question: ReadingQuestion,
        chosen: Int?,
        passage: ReadingPassage,
        isCorrect: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 溯源原文：支撑答案的句子逐字引用（能定位就带书签图标）。
            if !question.quote.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.quote")
                        .appFont(10)
                        .foregroundStyle(isCorrect ? theme.success : theme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("原文依据")
                            .appFont(10, weight: .semibold, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                        LookupText(
                            text: question.quote,
                            fontSize: 12,
                            italic: true,
                            color: theme.primaryText,
                            lineSpacing: 3,
                            context: state.wordLookupContext,
                            showsIBeamCursor: false
                        )
                        if question.quoteOffset(in: passage.text) == nil {
                            Text("（这句在原文里没有逐字对上，意思以原文为准）")
                                .appFont(9, design: .rounded)
                                .foregroundStyle(theme.secondaryText.opacity(0.8))
                        }
                    }
                }
            }
            // 讲解：为什么选它（含英语知识）。
            if !question.explain.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .appFont(10)
                        .foregroundStyle(theme.accent)
                    Text(question.explain)
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // 错因复盘：只有答错的题给（结合所选错误项 + 易错点分析）。
            if !isCorrect, !question.trap.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .appFont(10)
                            .foregroundStyle(theme.danger)
                        Text("错因复盘")
                            .appFont(10, weight: .semibold, design: .rounded)
                            .foregroundStyle(theme.danger)
                        if let chosen {
                            Text("你选了 \(letter(optionIndex: chosen))")
                                .appFont(10, weight: .semibold, design: .rounded)
                                .foregroundStyle(theme.danger)
                                .padding(.horizontal, 5)
                                .appPadding(.vertical, 1)
                                .background(Capsule().fill(theme.danger.opacity(0.12)))
                        }
                    }
                    Text(question.trap)
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .appPadding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.danger.opacity(0.07))
                        )
                }
            }
        }
        .appPadding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.6))
        )
    }

    private func letter(optionIndex: Int) -> String {
        String(Character(UnicodeScalar(65 + min(max(optionIndex, 0), 25))!))
    }

    // MARK: - 交卷行

    private func submitRow(_ passage: ReadingPassage) -> some View {
        HStack(spacing: 12) {
            if !state.isReadingReviewed {
                Button {
                    Task { await state.submitReading() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                        Text("交卷")
                    }
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.onAccentFill)
                    .padding(.horizontal, 16)
                    .appPadding(.vertical, 8)
                    .background(Capsule().fill(theme.accentFill))
                }
                .buttonStyle(.appPressable)
                .disabled(!state.readingAllAnswered)
                .help("判分在本地完成，不花模型请求；交卷后逐题展开原文溯源与讲解")
                Text("已答 \(state.readingChoices.count) / \(passage.questions.count) 题")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    /// 分数行（交卷后）。
    private func scoreRow(_ passage: ReadingPassage) -> some View {
        let correct = ReadingGrader.correctCount(passage, choices: state.readingChoices)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(correct)")
                .appFont(30, weight: .bold, design: .rounded)
                .foregroundStyle(correct == passage.questions.count ? theme.success : theme.accent)
                .monospacedDigit()
            Text("/ \(passage.questions.count) 答对")
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.secondaryText)
            if correct == passage.questions.count {
                Image(systemName: "star.fill")
                    .appFont(13)
                    .foregroundStyle(theme.success)
            }
            Spacer(minLength: 0)
        }
        .appPadding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
        )
    }

    // MARK: - 加载 / 空态

    /// 加载态换成**骨架屏**（#359）：一次阅读是一篇短文 + 几道题（5–20s），
    /// 转圈只说「在等」，骨架先把版式摆出来 —— 知道会长成什么样，等得才安心。
    /// 老的转圈卡删了；读屏语义由骨架卡自己的 accessibilityLabel 承接。
    private var loadingCard: some View {
        SkeletonReadingCard()
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Text("今天的短文还没取到")
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Button {
                Task { await state.loadReading() }
            } label: {
                Text("请老师出一篇")
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.onAccentFill)
                    .padding(.horizontal, 14)
                    .appPadding(.vertical, 7)
                    .background(Capsule().fill(theme.accentFill))
            }
            .buttonStyle(.appPressable)
            .help("一次阅读 = 一次模型请求，请确保老师的大脑已就绪")
        }
        .appPadding(24)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
        )
    }

    // MARK: - 通用

    private func noticeBanner(_ text: String) -> some View {
        Text(text)
            .appFont(11, design: .rounded)
            .foregroundStyle(theme.primaryText)
            .lineSpacing(3)
            .padding(.horizontal, 12)
            .appPadding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.hover)
            )
    }
}

/// 阅读正文的**段落化排版**（#233）。
///
/// 模型回的文章按 `\n` 分段；每段给**首行缩进**（约 1.6 个字号的英文段首缩进）
/// 与段前距 —— 纯文本一大坨没有呼吸感，段与段之间分不出层次。
/// 产出富文本走 `WordLookupSentence(attributed:)`，划词能力原样保留。
enum ReadingParagraphText {

    static func make(
        _ text: String,
        fontSize: CGFloat,
        color: NSColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let font = WordLookupTextBuilder.font(size: fontSize)
        // 空行（无论在头、尾还是中间）一律丢掉：分段间距由 `paragraphSpacingBefore`
        // 给，保留空段只会多出一条「看不见的行」，缩进和段距还会叠加成大空洞。
        let paragraphs = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let result = NSMutableAttributedString()
        guard !paragraphs.isEmpty else {
            return NSAttributedString(string: "", attributes: [.font: font])
        }
        for (index, paragraph) in paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.firstLineHeadIndent = fontSize * 1.6
            if index > 0 { style.paragraphSpacingBefore = 10 }
            result.append(
                NSAttributedString(
                    string: paragraph,
                    attributes: [
                        .font: font,
                        .foregroundColor: color,
                        .paragraphStyle: style,
                    ]
                )
            )
            if index < paragraphs.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
        }
        return result
    }
}
