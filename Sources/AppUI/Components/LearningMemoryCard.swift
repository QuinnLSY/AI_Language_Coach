import AIDomain
import SwiftUI

/// 学习记忆卡（第 15 步）：把「老师记住了你什么」摊开给学员看。
///
/// 为什么要有这张卡：记忆一直是**单向**的——老师知道你常犯哪个错、该复习哪个词，
/// 学员却看不见，于是「老师怎么老揪着这一条」变成了莫名其妙的针对。
/// 看得见，才谈得上信任；也才谈得上清掉。
///
/// 每条内容都只摆**真实记录**：没有话题就不显示话题行，样本不够就不下趋势结论，
/// 空态直说「还没记住什么」，不用好听的话把空白填成内容。
public struct LearningMemoryCard: View {

    @Environment(\.forestTheme) private var theme

    private let memory: LearningMemory
    private let notice: String?
    private let onClear: () async -> Void

    /// 二次确认：第一次点只是把按钮变成「确认清除」。
    ///
    /// 清除不可逆，一次点击就删掉几个月攒下的纠错记录，是最典型的误操作。
    @State private var confirmingClear = false

    public init(memory: LearningMemory, notice: String? = nil, onClear: @escaping () async -> Void) {
        self.memory = memory
        self.notice = notice
        self.onClear = onClear
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if confirmingClear { confirmBanner }
            if memory.isEmpty {
                emptyState
            } else {
                content
            }
            if let notice { noticeLine(notice) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 8, x: 0, y: 3)
        )
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain")
                .foregroundStyle(theme.accent)
            Text("老师记住了你什么")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 8)
            clearButton
        }
    }

    private var clearButton: some View {
        Button {
            if confirmingClear {
                confirmingClear = false
                Task { await onClear() }
            } else {
                confirmingClear = true
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: confirmingClear ? "trash.fill" : "trash")
                Text(confirmingClear ? "确认清除" : "清除记忆")
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            // 常态描边、确认态实底：两级视觉强度，让人一眼看出「这一步不一样」。
            .foregroundStyle(confirmingClear ? .white : theme.danger)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                Capsule().fill(confirmingClear ? theme.danger : theme.danger.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .disabled(memory.isEmpty)
        .opacity(memory.isEmpty ? 0.45 : 1)
        .help("清除后无法恢复：会删掉纠错记录、练习复盘、跟读记录与复习流水（单词本和对话记录保留）")
    }

    // MARK: - 内容

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !memory.recurringErrors.isEmpty {
                section("反复犯的错", systemImage: "arrow.triangle.2.circlepath") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(memory.recurringErrors) { error in
                            recurringErrorRow(error)
                        }
                    }
                }
            }

            if !memory.focusWords.isEmpty {
                // 图标别用 `textformat.abc`：中文环境下它会被换成「甲乙丙」，
                // 看着像排版事故而不是「单词」。
                section("该复习的词", systemImage: "book.closed") {
                    chips(memory.focusWords, tint: theme.accentCool)
                }
            }

            if !memory.weakDimensions.isEmpty {
                section("偏弱的发音", systemImage: "waveform") {
                    chips(
                        memory.weakDimensions.map { "\($0.displayName) \(Int($0.averageScore.rounded()))" },
                        tint: theme.accentAlt
                    )
                }
            }

            if !memory.recentTopics.isEmpty {
                // 话题用琥珀 `accent`：`foliage` 在夜间是深绿（0x1E5346），压在深色卡上
                // 等于看不见 —— 语义色也得先满足「读得清」再谈好看。
                section("最近练过", systemImage: "bubble.left.and.bubble.right") {
                    chips(memory.recentTopics, tint: theme.accent)
                }
            }

            if let trend = trendText {
                HStack(spacing: 6) {
                    Image(systemName: trendIcon)
                        .foregroundStyle(theme.accent)
                    Text(trend)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Text("累计练过 \(memory.sessionsPracticed) 次 · 纠错 \(memory.totalCorrections) 条")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
    }

    /// 一条「反复犯的错」：**每条自成一个方框**。
    ///
    /// 为什么要有框：错条本身是两行（原句 / 纠正 + 说明），几条挨在一起时
    /// 「哪句说明属于哪条错」要靠猜——用户实测反馈「全都挤在一起很难区分」。
    /// 框的下方沿用卡片自己的 `surfaceAlt`，只做一层浅浅的层次，不抢正文。
    private func recurringErrorRow(_ error: RecurringError) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(error.original)
                    .strikethrough()
                    .foregroundStyle(theme.secondaryText)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.accent)
                Text(error.corrected)
                    .foregroundStyle(theme.primaryText)
                if error.count > 1 {
                    Text("×\(error.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.accentAlt)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, design: .rounded))
            // 长句必须能折行：原来没有 `fixedSize` 时，长原句会被压成一行截断。
            .fixedSize(horizontal: false, vertical: true)

            if !error.explanation.isEmpty {
                Text(error.explanation)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(theme.accent)
            Text("老师还没记住什么。多练几次，这里会长出你常犯的错、该复习的词和练过的话题。")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.vertical, 10)
    }

    /// 二次确认横幅：**必须自带「取消」**。
    ///
    /// 用户实测反馈「只有二次确认但没有取消按钮，无法回退」——确认态一旦进入，
    /// 唯一的出口就变成了头部那颗红色按钮，点心虚的人只能硬着头皮点下去。
    /// 现在警告旁边就有「取消」，点它原地退出，一条记录都不会动。
    private var confirmBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.danger)
                Text("再点一次「确认清除」就会删掉纠错记录、练习复盘、跟读记录与复习流水，无法恢复。单词本和对话记录会保留。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    confirmingClear = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("取消")
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(
                        Capsule().fill(theme.surface)
                    )
                    .overlay(
                        Capsule().strokeBorder(theme.divider, lineWidth: 1)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("什么都不删，退回原来的样子")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.danger.opacity(0.10))
        )
    }

    private func noticeLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 小件

    private func section<Content: View>(
        _ title: String, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            content()
        }
    }

    private func chips(_ items: [String], tint: Color) -> some View {
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

    // MARK: - 趋势口径

    private var trendText: String? {
        switch memory.practiceTrend.direction {
        case .unknown:
            return nil
        case .improving:
            return "最近每轮被纠正的次数比之前少了 —— 越说越顺"
        case .steady:
            return "最近和之前差不多，没有明显变化"
        case .slipping:
            return "最近比之前更容易卡住 —— 可以先放慢一点"
        }
    }

    private var trendIcon: String {
        switch memory.practiceTrend.direction {
        case .improving: return "arrow.up.right"
        case .slipping: return "arrow.down.right"
        case .steady, .unknown: return "arrow.right"
        }
    }
}
