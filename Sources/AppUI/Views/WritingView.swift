import AIDomain
import AppKit
import SwiftUI

/// 写作练习页（#230）。
///
/// 一天一题（内置题库按 `dayKey` 轮换，出题零请求）→ 写 80–120 词 →
/// 交给老师批改（**一次写作 = 一次模型请求**）→
/// 看逐条批改 + 整段改写对比 + 值得记的词。
///
/// 改写对比的高亮来自 `WritingDiff` 词级对齐：**没被改动的词不标色** ——
/// 模型漏改的词不会被误报成「改过」。
public struct WritingView: View {

    @Environment(\.forestTheme) private var theme
    let state: AppState

    /// 编辑框的固定高度（写作比聊天长，但也不必无限高 —— 滚动兜底）。
    private static let editorHeight: CGFloat = 168

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let topic = state.writingTopic {
                        topicCard(topic)
                        editorCard
                        submitRow
                        if let review = state.writingReview {
                            scoreCard(review)
                            if !review.fixes.isEmpty {
                                fixesCard(review)
                            }
                            if !review.rewrite.isEmpty {
                                rewriteCard(review)
                            }
                            if !review.words.isEmpty {
                                wordsCard(review)
                            }
                        }
                    } else {
                        Text("今天的题目还在路上…")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    if !state.writingNotice.isEmpty {
                        noticeBanner(state.writingNotice)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.surfaceAlt.opacity(0.35))
        .task { await state.openWriting() }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            CuteAnimalView(kind: state.studentAnimalKind, isSleeping: theme.isNight, size: 40, accessory: .student)
            VStack(alignment: .leading, spacing: 2) {
                Text("写作")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("每天一小篇，写完老师当面批 —— 批改里的词可以一键收进词汇本")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            if state.writingTopic != nil {
                Text("今日一题")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
                    .help("题目按天轮换，同一天内不会变")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // MARK: - 题目卡

    private func topicCard(_ topic: WritingTopic) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(topic.kind.displayName, systemImage: topic.kind.systemImage)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
                Text("\(topic.minWords)–\(topic.maxWords) 词")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            // 题干可划词：写作时遇到不认识的词不用离开这一页。
            LookupText(
                text: topic.title,
                fontSize: 15,
                weight: .semibold,
                color: theme.primaryText,
                lineSpacing: 3,
                context: state.wordLookupContext
            )
            Text("提示：\(topic.hint)")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
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

    // MARK: - 编辑区

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("你的作文")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
                // 词数进度：目标 80–120，够 30 才能交（少一点也能先改）。
                Text("\(state.writingWordCount) 词")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(wordCountColor)
                    .monospacedDigit()
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { state.writingDraft },
                    set: { state.writingDraft = $0 }
                ))
                .font(.system(size: 13, design: .rounded))
                .scrollContentBackground(.hidden)
                .foregroundStyle(theme.primaryText)
                .frame(height: Self.editorHeight)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.hover.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.divider, lineWidth: 1)
                )
                if state.writingDraft.isEmpty {
                    Text("Write in English here…")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        // 占位符不接事件，点击要落到下面的编辑器上。
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
        )
    }

    private var wordCountColor: Color {
        switch state.writingWordCount {
        case ..<30: theme.secondaryText
        case 30..<80: theme.warning
        case 80...120: theme.success
        default: theme.secondaryText
        }
    }

    // MARK: - 提交行

    private var submitRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await state.submitWriting() }
            } label: {
                HStack(spacing: 6) {
                    if state.isWritingReviewing {
                        ProgressView().controlSize(.small)
                        Text("老师正在批改…")
                    } else {
                        Image(systemName: "checkmark.seal.fill")
                        Text("交给老师批改")
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.onAccentFill)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(theme.accentFill))
                .opacity(state.isWritingReviewing ? 0.7 : 1)
            }
            .buttonStyle(.plain)
            .disabled(state.isWritingReviewing || state.writingWordCount < 30)
            .help("一次批改 = 一次模型请求，请确保老师的大脑已就绪")

            if state.writingReview != nil {
                Button {
                    state.dismissWritingReview()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("改一改再写")
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accentCool)
                }
                .buttonStyle(.plain)
                .help("收起这份批改，改完再交一次")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 分数 + 重点建议

    private func scoreCard(_ review: WritingReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let score = review.score {
                    Text("\(score)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accent)
                        .monospacedDigit()
                    Text("/ 100")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            if !review.advice.isEmpty {
                Text(review.advice)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
        )
    }

    // MARK: - 逐条批改

    private func fixesCard(_ review: WritingReview) -> some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text("逐条批改")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                ForEach(Array(review.fixes.enumerated()), id: \.offset) { _, fix in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            // 原文片段：定位到了就画红底高亮，没定位到也照样展示；可划词。
                            LookupText(
                                text: fix.original,
                                fontSize: 12,
                                weight: .medium,
                                color: theme.primaryText,
                                context: state.wordLookupContext
                            )
                            .strikethrough(fix.offset != nil, color: theme.danger.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(theme.danger.opacity(fix.offset != nil ? 0.14 : 0.06))
                            )
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(theme.secondaryText)
                            LookupText(
                                text: fix.corrected,
                                fontSize: 12,
                                weight: .semibold,
                                color: theme.primaryText,
                                context: state.wordLookupContext
                            )
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(theme.accent.opacity(0.14))
                            )
                        }
                        if !fix.note.isEmpty {
                            Text(fix.note)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - 整段改写（diff 对比）

    private func rewriteCard(_ review: WritingReview) -> some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                Text("改写对比（删除线 = 改掉，加重 = 新写，其余原样保留）")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                diffText(review)
            }
        }
    }

    /// 词级 diff 渲染（改写侧视角）：`.same` 原样、`.added` 加重强调、
    /// `.removed` 不出现 —— 删掉的东西在「逐条批改」里已经用 原文→改正 说清楚了。
    ///
    /// 直接构建 `NSAttributedString` 交给 `WordLookupSentence`：改写是英文正文，
    /// 学员要能划词（SwiftUI `AttributedString` 桥到 NSAttributedString 会丢字体属性，
    /// 所以这里一开始就用 AppKit 属性建）。
    private func diffText(_ review: WritingReview) -> some View {
        let segments = WritingDiff.align(
            original: state.writingDraft,
            revised: review.rewrite
        )
        let attributed = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            // 段与段之间补一个空格（词内部原样保留，见 WritingDiff）。
            if index > 0 {
                attributed.append(NSAttributedString(string: " "))
            }
            switch segment {
            case .same(let text):
                attributed.append(
                    NSAttributedString(
                        string: text,
                        attributes: [
                            .font: WordLookupTextBuilder.font(size: 13),
                            .foregroundColor: NSColor(theme.primaryText),
                        ]
                    )
                )
            case .added(let text):
                attributed.append(
                    NSAttributedString(
                        string: text,
                        attributes: [
                            .font: WordLookupTextBuilder.font(size: 13, weight: .bold),
                            .foregroundColor: NSColor(theme.accent),
                        ]
                    )
                )
            case .removed:
                continue
            }
        }
        return WordLookupSentence(attributed: attributed, context: state.wordLookupContext)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 生词

    private func wordsCard(_ review: WritingReview) -> some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                Text("值得记下来的词")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                ForEach(review.words) { word in
                    HStack(spacing: 8) {
                        Text(word.word)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        if !word.pos.isEmpty {
                            Text(word.pos)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                        }
                        if !word.meaning.isEmpty {
                            Text(word.meaning)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button {
                            Task { await state.addWritingWord(word) }
                        } label: {
                            Text("收进词汇本")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .overlay(
                                    Capsule().strokeBorder(theme.accent.opacity(0.7), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("加入词汇本，之后可以在词汇本里复习")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - 通用

    private func cardContainer(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.surface)
            )
    }

    private func noticeBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(theme.primaryText)
            .lineSpacing(3)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.hover)
            )
    }
}
