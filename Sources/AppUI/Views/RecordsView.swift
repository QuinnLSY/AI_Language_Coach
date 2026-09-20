import AIDomain
import AIServices
import AppCore
import Foundation
import SwiftUI

/// 学习记录页里可以被别的页面**指定跳过来**的锚点。
///
/// 目前只有错题本一处需要（学习进度页的「最近错题」卡片点进来要落在它上面）。
/// 加一个锚点 = 加一个 case + 给对应卡片挂上 `.id(focus.anchorID)`。
public enum RecordsFocus: String, Sendable, CaseIterable {
    case mistakes

    /// `ScrollViewReader` 用的 id（带上前缀，免得和别处的 id 撞）。
    public var anchorID: String { "records-\(rawValue)" }
}

/// 学习记录页：最近练习（会话总结）+ 错题本（老师批注的纠错）。
public struct RecordsView: View {

    @Environment(\.forestTheme) private var theme
    let state: AppState

    /// 被别的页面点名跳过来时，短暂圈一下目标卡片 ——
    /// 滚过去但没有标记，人只会看到一屏陌生的内容，不知道落在哪。
    @State private var highlighted: RecordsFocus?
    /// 展开的练习记录（需求 5：点卡片向下展开复盘详情，再点收起）。
    @State private var expandedSessionID: UUID?

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        statsRow
                        reviewCard
                        LearningMemoryCard(
                            memory: state.learningMemory,
                            notice: state.learningMemoryNotice
                        ) {
                            await state.clearLearningMemory()
                        }
                        mistakesCard.id(RecordsFocus.mistakes.anchorID)
                        sessionsCard
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task {
                    await state.loadRecords()
                    await jumpToPendingCard(proxy)
                }
            }
        }
        .background(theme.surfaceAlt.opacity(0.35))
    }

    // MARK: - 跨页跳转

    /// 消费一次 `state.recordsFocus`：滚过去 + 圈一下 + 自己收掉。
    private func jumpToPendingCard(_ proxy: ScrollViewProxy) async {
        guard let focus = state.recordsFocus else { return }
        // 先消费掉：跳转是「这一次点击」的意图，不该变成本页的默认行为。
        state.recordsFocus = nil
        highlighted = focus
        // 等一帧让刚加载出来的卡片真正落位，否则 `scrollTo` 会滚到旧的内容高度上。
        try? await Task.sleep(nanoseconds: 160_000_000)
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(focus.anchorID, anchor: .top)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation(.easeOut(duration: 0.5)) { highlighted = nil }
    }

    // MARK: - 头部（64pt 顶栏对齐）

    private var header: some View {
        HStack(spacing: 12) {
            CuteAnimalView(kind: state.studentAnimalKind, isSleeping: theme.isNight, size: 40, accessory: .student)
            VStack(alignment: .leading, spacing: 2) {
                Text("学习记录")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("每一次攀爬都被大树记住了")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Button {
                Task { await state.loadRecords() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("刷新")
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // MARK: - 汇总

    private var statsRow: some View {
        HStack(spacing: 12) {
            statTile(icon: "tree.fill", value: "\(state.progress.totalStars)", label: "累计星星")
            statTile(icon: "bubble.left.and.bubble.right.fill", value: "\(totalMessages)", label: "累计对话")
            statTile(icon: "pencil.and.list.clipboard", value: "\(state.mistakes.count)", label: "错题收集")
        }
    }

    private var totalMessages: Int { state.records.reduce(0) { $0 + $1.messageCount } }

    private func statTile(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(theme.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 8, x: 0, y: 3)
        )
    }

    // MARK: - 练习复盘（学习记忆：一次练习沉淀一份总结）

    private var reviewCard: some View {
        card(title: "练习复盘", systemImage: "sparkles", trailing: {
            // 标题行右侧两个胶囊：**生成**（主色）+ **跳去练**（冷紫次色）。
            HStack(spacing: 8) {
                reviewActionButton
                vocabularyJumpButton
            }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                if state.isGeneratingReview {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("老师正在回看这次练习…")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                        Spacer(minLength: 0)
                    }
                }

                if let review = state.latestReview {
                    reviewBody(review)
                } else {
                    emptyHint("还没有复盘。每次练习结束（换新练习 / 重新打开应用）都会自动复盘；模型没起来时也可以在这里手动补一次。")
                }
            }
        }
    }

    /// 「手动补一次复盘」：复盘已经默认自动生成（需求 5），这个按钮是**兜底** ——
    /// 自动那次赶上模型没起来时，学员还能自己补上，而不是就此失去这段练习的总结。
    private var reviewActionButton: some View {
        headerCapsule(
            state.latestReview == nil ? "立即复盘这次练习" : "重新复盘",
            systemImage: "wand.and.stars",
            tint: theme.accent
        ) {
            Task { await state.generateSessionReview() }
        }
        .disabled(state.isGeneratingReview || state.chat.messages.isEmpty)
        .help(state.chat.messages.isEmpty
              ? "先和老师聊几句，再来复盘"
              : "每次练习结束会自动复盘；模型没起来时用这里补一次")
    }

    /// 「前往词汇本练习」：复盘给的是结论，练才是把结论变成本事的一步 —— 把这条
    /// 路做成一个按钮，而不是让用户自己回去找词汇本在哪。
    ///
    /// 图标用「转出去」的箭头（与「重新生成」的魔杖同类角色：左侧一个图标 + 文字），
    /// 颜色取冷紫 `theme.accentCool`：与主操作区分，又不会因为变浅而看不清。
    private var vocabularyJumpButton: some View {
        headerCapsule("前往词汇本练习", systemImage: "arrowshape.turn.up.right.fill", tint: theme.accentCool) {
            Task { await state.openVocabulary() }
        }
        .help("去词汇本背/考这次复盘里的新词")
    }

    /// 卡片标题行胶囊按钮的统一版式（两个操作共用，改样子只需改这里）。
    private func headerCapsule(
        _ title: String, systemImage: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(tint))
        }
        .buttonStyle(.plain)
    }

    private func reviewBody(_ review: SessionReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 一句话总结 + 时长/轮次
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "quote.bubble.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accent)
                Text(review.headline)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
            }
            Text("\(review.durationText) · \(review.messageCount) 轮对话 · \(review.correctionCount) 处批注")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()

            if !review.newWords.isEmpty {
                reviewSection("值得记住", systemImage: "textformat.abc", tint: Color(hex: 0x6FB1FC)) {
                    WrappingChips(items: review.newWords, tint: Color(hex: 0x6FB1FC))
                }
            }
            if !review.strengths.isEmpty {
                reviewSection("做得好", systemImage: "hand.thumbsup.fill", tint: Color(hex: 0x8FD694)) {
                    bulletList(review.strengths)
                }
            }
            if !review.improvements.isEmpty {
                reviewSection("再练练", systemImage: "arrow.up.and.down.text.horizontal", tint: Color(hex: 0xF7B32B)) {
                    bulletList(review.improvements)
                }
            }
            if !review.suggestion.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0xF7B32B))
                    Text(review.suggestion)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(hex: 0xF7B32B).opacity(0.12))
                )
            }

            if review.source == .heuristic {
                Text("本地模型暂不可用，以上为基础统计总结。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func reviewSection<Content: View>(_ title: String, systemImage: String, tint: Color,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(theme.secondaryText.opacity(0.6))
                        .frame(width: 4, height: 4)
                        .padding(.top, 5)
                    Text(items[index])
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - 错题本

    private var mistakesCard: some View {
        card(title: "错题本", systemImage: "pencil.and.list.clipboard") {
            if state.mistakes.isEmpty {
                emptyHint("还没有错题。大胆去说，老师会悄悄帮你记下需要改进的地方。")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(state.mistakes.prefix(10)) { mistake in
                        mistakeRow(mistake)
                    }
                    if state.mistakes.count > 10 {
                        Text("还有 \(state.mistakes.count - 10) 条更早的错题…")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.accentCool, lineWidth: 2)
                .opacity(highlighted == .mistakes ? 1 : 0)
                .allowsHitTesting(false)
        )
    }

    private func mistakeRow(_ mistake: GrammarCorrection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(mistake.original)
                    .font(.system(size: 12, design: .rounded))
                    .strikethrough()
                    .foregroundStyle(theme.secondaryText)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.accent)
                Text(mistake.corrected)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            }
            if !mistake.explanation.isEmpty {
                Text(mistake.explanation)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.accent.opacity(0.06))
        )
    }

    // MARK: - 最近练习

    private var sessionsCard: some View {
        card(title: "最近练习", systemImage: "clock.arrow.circlepath") {
            if state.records.isEmpty {
                emptyHint("还没有练习记录。回到练习页和老师打个招呼吧！")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.records.prefix(12), id: \.sessionID) { record in
                        sessionRow(record)
                    }
                }
            }
        }
    }

    private func sessionRow(_ record: SessionSummary) -> some View {
        let scenarioTitle = state.scenarioTitle(for: record.scenarioID)
        let review = state.review(for: record.sessionID)
        let isExpanded = expandedSessionID == record.sessionID
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: scenarioTitle == nil ? "leaf.fill" : "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        if let scenarioTitle {
                            Text(scenarioTitle)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(theme.accent.opacity(0.14)))
                        }
                    }
                    Text(durationText(record))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Text("\(record.messageCount) 条对话")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
                // 需求 5：复盘已经默认生成了，所以这里给的是「点开看」而不是「去生成」。
                Text(review == nil ? "暂无复盘" : (isExpanded ? "收起" : "看复盘"))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(review == nil ? theme.secondaryText : theme.accentCool)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedSessionID = isExpanded ? nil : record.sessionID
                }
            }

            if isExpanded {
                Group {
                    if let review {
                        reviewBody(review)
                    } else {
                        emptyHint("这次练习还没复盘。下次换新练习或重新打开应用时会自动补上。")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isExpanded ? theme.accent.opacity(0.5) : .clear, lineWidth: 1)
        )
    }

    private func durationText(_ record: SessionSummary) -> String {
        let seconds = max(Int(record.endedAt.timeIntervalSince(record.startedAt)), 0)
        if seconds < 60 { return "时长 \(seconds) 秒" }
        return String(format: "时长 %d 分 %d 秒", seconds / 60, seconds % 60)
    }

    // MARK: - 通用

    private func emptyHint(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(theme.accent)
            Text(text)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.vertical, 10)
    }

    private func card<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        card(title: title, systemImage: systemImage, trailing: { EmptyView() }, content: content)
    }

    /// 带右上角操作区的卡片。练习复盘的「重新生成」就挂在**标题行右侧**，
    /// 不再单独占一行 —— 那一行只有右边一个按钮，会在标题和正文之间留出一道空白。
    private func card<Content: View, Trailing: View>(
        title: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 8)
                trailing()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 8, x: 0, y: 3)
        )
    }
}

// MARK: - 小标签自动换行（复盘新词 / 短语展示）
//
// 用 `FlowRow`（`Layout` 自动换行）而不是 LazyVGrid：网格的列宽是固定的，
// 长单词会被硬拆到两行（实测 "precipitation" 被拆成 "precipitatio / n"）。
// FlowRow 按每个 chip 的**自然宽度**排布 —— 单词整体展示、短词组尽量保持一行，
// 只有整句级别的长文本才在词边界折行（不会在单词中间断开）。

private struct WrappingChips: View {
    let items: [String]
    let tint: Color

    var body: some View {
        FlowRow(spacing: 6, lineSpacing: 6, wrapsLongItems: true) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tint.opacity(0.14)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
