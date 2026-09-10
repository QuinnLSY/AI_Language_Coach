import AIDomain
import AIServices
import AppCore
import Foundation
import SwiftUI

/// 学习记录页：最近练习（会话总结）+ 错题本（老师批注的纠错）。
public struct RecordsView: View {

    @Environment(\.forestTheme) private var theme
    let state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statsRow
                    reviewCard
                    mistakesCard
                    sessionsCard
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.surfaceAlt.opacity(0.35))
        .task { await state.loadRecords() }
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
        card(title: "练习复盘", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if state.isGeneratingReview {
                        ProgressView().controlSize(.small)
                        Text("老师正在回看这次练习…")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await state.generateSessionReview() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "wand.and.stars")
                            Text(state.latestReview == nil ? "生成本次复盘" : "重新生成")
                        }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isGeneratingReview || state.chat.messages.isEmpty)
                    .help(state.chat.messages.isEmpty ? "先和老师聊几句，再来复盘" : "让本地模型回看这次练习并生成总结")
                }

                if let review = state.latestReview {
                    reviewBody(review)
                } else {
                    emptyHint("还没有复盘。聊上几句后点「生成本次复盘」，老师会告诉你做得好的地方和下次该练什么。")
                }
            }
        }
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
        HStack(spacing: 10) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text(durationText(record))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Text("\(record.messageCount) 条对话")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.5))
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

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
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

// MARK: - 小标签自动换行（新词/短语展示）

private struct WrappingChips: View {
    let items: [String]
    let tint: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tint.opacity(0.14)))
            }
        }
    }
}
