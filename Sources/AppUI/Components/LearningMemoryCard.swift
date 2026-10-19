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
    /// 就这些错练一遍（nil = 不显示入口，比如正在练的时候）。
    private let onStartDrill: (() -> Void)?
    /// 忘记一处反复犯的错（删掉它在库里的全部记录）。
    private let onForget: (RecurringError) async -> Void
    /// 修改一处反复犯的错（改正 / 说明；原句不可改）。
    private let onEdit: (RecurringError, String, String) async -> Void

    /// 二次确认：第一次点只是把按钮变成「确认清除」。
    ///
    /// 清除不可逆，一次点击就删掉几个月攒下的纠错记录，是最典型的误操作。
    @State private var confirmingClear = false

    public init(
        memory: LearningMemory,
        notice: String? = nil,
        onStartDrill: (() -> Void)? = nil,
        onForget: @escaping (RecurringError) async -> Void = { _ in },
        onEdit: @escaping (RecurringError, String, String) async -> Void = { _, _, _ in },
        onClear: @escaping () async -> Void
    ) {
        self.memory = memory
        self.notice = notice
        self.onStartDrill = onStartDrill
        self.onForget = onForget
        self.onEdit = onEdit
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
        .appPadding(16)
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
            Image(systemName: "brain")
                .foregroundStyle(theme.accent)
            Text("老师记住了你什么")
                .appFont(14, weight: .semibold, design: .rounded)
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
            .appFont(12, weight: .semibold, design: .rounded)
            // 常态描边、确认态实底：两级视觉强度，让人一眼看出「这一步不一样」。
            .foregroundStyle(confirmingClear ? .white : theme.danger)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                Capsule().fill(confirmingClear ? theme.danger : theme.danger.opacity(0.12))
            )
        }
        .buttonStyle(.appPressable)
        .disabled(memory.isEmpty)
        .opacity(memory.isEmpty ? 0.45 : 1)
        .help("清除后无法恢复：会删掉纠错记录、练习复盘、跟读记录与复习流水（单词本和对话记录保留）")
    }

    // MARK: - 内容

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !memory.recurringErrors.isEmpty {
                section("反复犯的错", systemImage: "arrow.triangle.2.circlepath") {
                    if let onStartDrill { drillButton(onStartDrill) }
                } content: {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(memory.recurringErrors) { error in
                            RecurringErrorRow(
                                error: error,
                                onForget: onForget,
                                onEdit: onEdit
                            )
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
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Text("累计练过 \(memory.sessionsPracticed) 次 · 纠错 \(memory.totalCorrections) 条")
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.secondaryText)
        }
    }

    /// 一条「反复犯的错」+ 它自己的两个动作（改 / 忘）。
    ///
    /// **每条自成一个方框**：错条本身是两行（原句 / 纠正 + 说明），几条挨在一起时
    /// 「哪句说明属于哪条错」要靠猜——用户实测反馈「全都挤在一起很难区分」。
    /// 框的下方沿用卡片自己的 `surfaceAlt`，只做一层浅浅的层次，不抢正文。
    ///
    /// 为什么单条也能删 / 改：记忆对学员可见只是第一步，「老师老揪着这一条」
    /// 的委屈得有个出口 —— 删掉（老师别再提）或改掉（老师改错了）。
    /// 长期记忆从黑盒变成学员能自己修的资产。
    ///
    /// 三个内部状态（编辑中 / 待确认忘记 / 两份草稿）**必须住在这一层**：
    /// 放父视图按 index 管，就会出现「展开 A 的编辑框时 B 的也跟着展开」。
    private struct RecurringErrorRow: View {
        @Environment(\.forestTheme) private var theme

        let error: RecurringError
        let onForget: (RecurringError) async -> Void
        let onEdit: (RecurringError, String, String) async -> Void

        @State private var editing = false
        @State private var confirmingForget = false
        @State private var draftCorrected = ""
        @State private var draftExplanation = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if editing {
                    editForm
                } else {
                    displayLine
                }
                if confirmingForget {
                    forgetConfirm
                }
            }
            .appPadding(.horizontal, 10)
            .appPadding(.vertical, 8)
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

        // MARK: - 展示态

        private var displayLine: some View {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(error.original)
                            .strikethrough()
                            .foregroundStyle(theme.secondaryText)
                        Image(systemName: "arrow.right")
                            .appFont(9)
                            .foregroundStyle(theme.accent)
                        Text(error.corrected)
                            .foregroundStyle(theme.primaryText)
                        if error.count > 1 {
                            Text("×\(error.count)")
                                .appFont(10, weight: .semibold, design: .rounded)
                                .foregroundStyle(theme.accentAlt)
                        }
                    }
                    .appFont(12, design: .rounded)
                    // 长句必须能折行：原来没有 `fixedSize` 时，长原句会被压成一行截断。
                    .fixedSize(horizontal: false, vertical: true)

                    if !error.explanation.isEmpty {
                        Text(error.explanation)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                actionButtons
            }
        }

        /// 两个小按钮固定在行的右上角，不参与正文折行 ——
        /// 混在文字流里的话，长句一换行按钮就被挤到不知哪儿去了。
        private var actionButtons: some View {
            HStack(spacing: 4) {
                Button {
                    // 每次展开都从当前文本重新取草稿：记忆可能在收起期间被刷新过。
                    draftCorrected = error.corrected
                    draftExplanation = error.explanation
                    confirmingForget = false
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                        .appFont(11)
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 26, height: 26)
                        .background(Capsule().fill(theme.surface))
                        .overlay(Capsule().strokeBorder(theme.divider, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.appPressable)
                .help("修改这一处的改正与说明（原句是当时真实说出的话，不能改）")

                Button {
                    confirmingForget = true
                } label: {
                    Image(systemName: confirmingForget ? "trash.fill" : "trash")
                        .appFont(11)
                        .foregroundStyle(confirmingForget ? .white : theme.danger)
                        .frame(width: 26, height: 26)
                        .background(Capsule().fill(confirmingForget ? theme.danger : theme.danger.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.appPressable)
                .help(confirmingForget ? "再点一次确认忘记" : "忘记这一处：删掉它的全部记录，老师以后不再提")
            }
        }

        // MARK: - 编辑态

        private var editForm: some View {
            VStack(alignment: .leading, spacing: 8) {
                // 原句只读：学员当时真实说出的话，改它等于伪造历史。想抹掉只能删。
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    fieldLabel("原句")
                    Text(error.original)
                        .strikethrough()
                        .appFont(12, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                labeledField("改正", placeholder: "改正后的句子", text: $draftCorrected)
                labeledField("说明", placeholder: "为什么这样改（可留空）", text: $draftExplanation)

                Text("这一处共 \(error.count) 条记录，会一起更新。")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button {
                        editing = false
                    } label: {
                        formButtonLabel("取消", systemImage: "xmark")
                    }
                    .buttonStyle(.appPressable)
                    .help("不改了，退回原来的样子")

                    Button {
                        editing = false
                        Task { await onEdit(error, draftCorrected, draftExplanation) }
                    } label: {
                        formButtonLabel("保存", systemImage: "checkmark", filled: true)
                    }
                    .buttonStyle(.appPressable)
                    .disabled(draftCorrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draftCorrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                    .help("把这一处全部记录都改成新文本")
                }
            }
        }

        // MARK: - 忘记前的确认

        /// 二级确认 + **自带取消**（#178 的教训：只有确认没有退路时，
        /// 人心虚只能硬着头皮点下去）。警示文案里带上是几条记录 ——
        /// 「×3」意味着这一删是三份历史，不是一条。
        private var forgetConfirm: some View {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .appFont(11)
                    .foregroundStyle(theme.danger)
                Text("忘记后老师不会再提这一处（\(error.count) 条记录），无法恢复。")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    confirmingForget = false
                } label: {
                    formButtonLabel("取消", systemImage: "xmark")
                }
                .buttonStyle(.appPressable)
                .help("什么都不删，退回原来的样子")
                Button {
                    confirmingForget = false
                    Task { await onForget(error) }
                } label: {
                    formButtonLabel("确认忘记", systemImage: "trash.fill", filled: true, danger: true)
                }
                .buttonStyle(.appPressable)
                .help("删掉这一处的全部记录")
            }
            .appPadding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.danger.opacity(0.10))
            )
        }

        // MARK: - 小件

        private func fieldLabel(_ text: String) -> some View {
            Text(text)
                .appFont(10, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .frame(width: 28, alignment: .leading)
        }

        private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
            HStack(alignment: .center, spacing: 6) {
                fieldLabel(label)
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(theme.divider, lineWidth: 1)
                    )
                    .onSubmit {
                        if !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            editing = false
                            Task { await onEdit(error, draftCorrected, draftExplanation) }
                        }
                    }
            }
        }

        private func formButtonLabel(
            _ title: String,
            systemImage: String,
            filled: Bool = false,
            danger: Bool = false
        ) -> some View {
            let tint = danger ? theme.danger : theme.accent
            return HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
            .appFont(11, weight: .semibold, design: .rounded)
            .foregroundStyle(filled ? .white : theme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule().fill(filled ? tint : theme.surface)
            )
            .overlay(
                Capsule().strokeBorder(filled ? tint : theme.divider, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(theme.accent)
            Text("老师还没记住什么。多练几次，这里会长出你常犯的错、该复习的词和练过的话题。")
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.secondaryText)
        }
        .appPadding(.vertical, 10)
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
                    .appFont(11, design: .rounded)
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
                    .appFont(11, weight: .semibold, design: .rounded)
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
                .buttonStyle(.appPressable)
                .help("什么都不删，退回原来的样子")
            }
        }
        .appPadding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.danger.opacity(0.10))
        )
    }

    private func noticeLine(_ text: String) -> some View {
        Text(text)
            .appFont(11, design: .rounded)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 小件

    private func section<Content: View, Trailing: View>(
        _ title: String, systemImage: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .appFont(10)
                    .foregroundStyle(theme.accent)
                Text(title)
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 4)
                trailing()
            }
            content()
        }
    }

    /// 就这些错练一遍。
    ///
    /// 为什么放在**这一节**的标题行而不是卡片头部：它练的就是这一节列出的这几处，
    /// 挂在离它们最近的地方，才看得出「练一遍」练的是什么。
    private func drillButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "pencil.and.scribble")
                    .appFont(10)
                Text("练一遍")
            }
            .appFont(11, weight: .semibold, design: .rounded)
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(theme.accent.opacity(0.12)))
        }
        .buttonStyle(.appPressable)
        .help("把这几次反复犯的错拿出来改一遍（不消耗模型请求）")
    }

    private func chips(_ items: [String], tint: Color) -> some View {
        FlowRow(spacing: 6, lineSpacing: 6, wrapsLongItems: true) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .appFont(11, weight: .medium, design: .rounded)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 8)
                    .appPadding(.vertical, 3)
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
