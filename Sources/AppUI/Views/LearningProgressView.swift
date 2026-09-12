import AIDomain
import AppCore
import SwiftUI

/// 学习进度页（Dashboard，第 25 步）。
///
/// 版式依据 Implementation Plan §26：
/// `Today → Practice time → Recent mistakes → Vocabulary → Pronunciation → Learning goals`
/// 以及六类进度视图：语法趋势 / 词汇增长 / 发音趋势 / 开口时长 / 练习频率 / 技能分布。
///
/// **本页只读 `AppState.progressSnapshot`**（应用层数据），不碰数据库、不自己算统计。
///
/// 命名注意：**不能叫 `ProgressView`** —— 会与 SwiftUI 的同名控件冲突，
/// 本模块内自己的类型优先，`ProgressView()` 就变成了递归引用。
public struct LearningProgressView: View {

    @Environment(\.forestTheme) private var theme
    let state: AppState

    /// 「练习节奏」卡片当前展示的口径。
    private enum RhythmMode: String, CaseIterable, Identifiable {
        case minutes, messages, shadowing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .minutes: "开口时长"
            case .messages: "对话轮次"
            case .shadowing: "跟读次数"
            }
        }
    }

    @State private var rhythmMode: RhythmMode = .minutes

    public init(state: AppState) { self.state = state }

    private var snapshot: ProgressSnapshot { state.progressSnapshot }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    todayCard
                    rhythmCard
                    grammarCard
                    vocabularyCard
                    pronunciationCard
                    skillsCard
                    mistakesCard
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.surfaceAlt.opacity(0.35))
        .task {
            // 进入页面汇总一次；已汇总过（同一次启动内来回切页）不重复计算。
            if snapshot.activity.isEmpty || state.isLoadingProgress {
                await state.reloadProgress()
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            CuteAnimalView(kind: state.studentAnimalKind, isSleeping: theme.isNight, size: 40, accessory: .student)
            VStack(alignment: .leading, spacing: 2) {
                Text("学习进度")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("今天的每一句话，都在树上多长一片叶子")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()

            // 统计窗口
            HStack(spacing: 4) {
                ForEach([7, 14, 30], id: \.self) { days in
                    Button {
                        Task { await state.setProgressWindow(days) }
                    } label: {
                        Text("\(days) 天")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(state.progressWindowDays == days ? .white : theme.secondaryText)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(
                                Capsule().fill(state.progressWindowDays == days ? theme.accent : theme.hover)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("统计最近 \(days) 天")
                }
            }

            Button {
                Task { await state.reloadProgress() }
            } label: {
                if state.isLoadingProgress {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .help("重新汇总")
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // MARK: - Today / Practice time / Learning goals

    private var todayCard: some View {
        card(title: "今天", systemImage: "sun.max.fill") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    tile(icon: "clock.fill", value: snapshot.todayDurationText, label: "练习时长")
                    tile(icon: "bubble.left.and.bubble.right.fill",
                         value: "\(snapshot.today.messages)", label: "对话轮次")
                    tile(icon: "waveform.badge.mic",
                         value: "\(snapshot.today.shadowingAttempts)", label: "跟读")
                }

                // Learning goals：今日目标完成度（目标值写产品配置，持久化）
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: snapshot.goalReached ? "checkmark.seal.fill" : "target")
                            .font(.system(size: 11))
                            .foregroundStyle(snapshot.goalReached ? Color(hex: 0x8FD694) : theme.accent)
                        Text(snapshot.goalReached ? "今天的目标已完成" : "每日目标")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("\(snapshot.today.minutes) / \(snapshot.goalMinutes) 分钟")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .monospacedDigit()
                        Spacer(minLength: 4)
                        goalStepper
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.divider.opacity(0.7))
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [theme.accent, Color(hex: 0x8FD694)],
                                    startPoint: .leading, endPoint: .trailing
                                ))
                                .frame(width: proxy.size.width * CGFloat(snapshot.goalProgress))
                        }
                    }
                    .frame(height: 8)

                    Text("连续练习 \(snapshot.streakDays) 天 · 近 \(snapshot.days) 天里有 \(snapshot.activeDays) 天开过口")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    /// 目标分钟数的加减（5 分钟一档，5...180）。
    private var goalStepper: some View {
        HStack(spacing: 6) {
            goalButton(systemImage: "minus", enabled: snapshot.goalMinutes > 5) {
                Task { await state.setDailyGoalMinutes(snapshot.goalMinutes - 5) }
            }
            goalButton(systemImage: "plus", enabled: snapshot.goalMinutes < 180) {
                Task { await state.setDailyGoalMinutes(snapshot.goalMinutes + 5) }
            }
        }
    }

    private func goalButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? theme.primaryText : theme.secondaryText.opacity(0.5))
                .frame(width: 20, height: 20)
                .background(Circle().fill(theme.hover))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(systemImage == "plus" ? "调高每日目标 5 分钟" : "调低每日目标 5 分钟")
    }

    // MARK: - Practice frequency / speaking time

    private var rhythmCard: some View {
        card(
            title: "练习节奏",
            systemImage: "chart.bar.fill",
            trailing: { rhythmPicker }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if snapshot.activity.allSatisfy({ !$0.hasPractice }) {
                    emptyHint("这段时间还没有练习记录，去和老师聊几句吧。")
                } else {
                    ProgressBarChart(points: rhythmPoints, tint: theme.accent, showsValueOnTop: true)
                    Text(rhythmCaption)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    private var rhythmPicker: some View {
        HStack(spacing: 4) {
            ForEach(RhythmMode.allCases) { mode in
                Button {
                    rhythmMode = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(rhythmMode == mode ? .white : theme.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(rhythmMode == mode ? theme.accent : theme.hover))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var rhythmPoints: [TrendPoint] {
        switch rhythmMode {
        case .minutes:
            return snapshot.activity.map {
                TrendPoint(label: ProgressAggregator.shortLabel($0.day, calendar: .current),
                           value: Double($0.minutes),
                           detail: "\(ProgressAggregator.longLabel($0.day, calendar: .current)) · \($0.minutes) 分钟")
            }
        case .messages:
            return snapshot.activity.map {
                TrendPoint(label: ProgressAggregator.shortLabel($0.day, calendar: .current),
                           value: Double($0.messages),
                           detail: "\(ProgressAggregator.longLabel($0.day, calendar: .current)) · \($0.messages) 轮对话")
            }
        case .shadowing:
            return snapshot.activity.map {
                TrendPoint(label: ProgressAggregator.shortLabel($0.day, calendar: .current),
                           value: Double($0.shadowingAttempts),
                           detail: "\(ProgressAggregator.longLabel($0.day, calendar: .current)) · \($0.shadowingAttempts) 次跟读")
            }
        }
    }

    private var rhythmCaption: String {
        let total = snapshot.activity.reduce(0) { $0 + $1.seconds }
        switch rhythmMode {
        case .minutes:
            return "近 \(snapshot.days) 天共开口 \(ProgressAggregator.durationText(total))，日均 \(ProgressAggregator.durationText(total / Double(max(snapshot.days, 1))))"
        case .messages:
            let messages = snapshot.activity.reduce(0) { $0 + $1.messages }
            return "近 \(snapshot.days) 天共 \(messages) 轮对话，活跃 \(snapshot.activeDays) 天"
        case .shadowing:
            let attempts = snapshot.activity.reduce(0) { $0 + $1.shadowingAttempts }
            return "近 \(snapshot.days) 天共跟读 \(attempts) 次"
        }
    }

    // MARK: - Grammar trend

    private var grammarCard: some View {
        card(title: "语法趋势", systemImage: "text.badge.checkmark") {
            VStack(alignment: .leading, spacing: 8) {
                if snapshot.totalCorrections == 0 {
                    emptyHint("还没有批注。说得越多，这里的曲线越有参考价值。")
                } else {
                    ProgressLineChart(points: snapshot.grammarTrend, tint: Color(hex: 0x6FB1FC), valueSuffix: " 处")
                    Text("柱线越低说明老师批注越少。近 \(snapshot.days) 天共 \(snapshot.activity.reduce(0) { $0 + $1.corrections }) 处，累计 \(snapshot.totalCorrections) 处。")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    // MARK: - Vocabulary

    private var vocabularyCard: some View {
        card(title: "词汇增长", systemImage: "text.book.closed.fill") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    tile(icon: "textformat.abc", value: "\(snapshot.vocabulary.total)", label: "词汇总量")
                    tile(icon: "clock.badge.exclamationmark", value: "\(snapshot.vocabulary.due)", label: "今日待复习")
                    tile(icon: "checkmark.circle.fill", value: "\(snapshot.vocabulary.mastered)", label: "已掌握")
                }
                if snapshot.vocabulary.total == 0 {
                    emptyHint("词汇本还是空的。跟读、复盘和情景里的新词都可以收进来。")
                } else {
                    ProgressLineChart(points: snapshot.vocabularyGrowth, tint: Color(hex: 0xF2A65A), valueSuffix: " 词")
                    Text("已配中文释义 \(snapshot.vocabulary.defined) / \(snapshot.vocabulary.total) 词。")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    // MARK: - Pronunciation

    private var pronunciationCard: some View {
        card(title: "发音趋势", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    tile(icon: "star.fill",
                         value: snapshot.shadowing.bestPronunciation.map { "\(Int($0.rounded()))" } ?? "—",
                         label: "发音最佳")
                    tile(icon: "waveform.path.ecg",
                         value: snapshot.shadowing.averagePronunciation.map { "\(Int($0.rounded()))" } ?? "—",
                         label: "发音平均")
                    tile(icon: "text.bubble.fill",
                         value: snapshot.shadowing.lastAccuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                         label: "最近匹配率")
                }
                if snapshot.pronunciationTrend.count < 2 {
                    emptyHint("录音跟读两次以上，这里就会出现发音曲线。")
                } else {
                    ProgressLineChart(points: snapshot.pronunciationTrend, tint: Color(hex: 0xC08BF0), valueSuffix: " 分")
                    Text("共跟读 \(snapshot.shadowing.attempts) 次，平均匹配率 \(Int((snapshot.shadowing.averageAccuracy * 100).rounded()))%。")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    // MARK: - Skill distribution

    private var skillsCard: some View {
        card(title: "技能分布", systemImage: "chart.pie.fill") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(snapshot.skills) { skill in
                    SkillBar(skill: skill)
                }
                Text("分数口径：语法按每轮批注密度，词汇按掌握度与释义完成度，发音/流利度取自跟读评测，跟读模仿取匹配率。没有数据的维度不评分。")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Recent mistakes

    private var mistakesCard: some View {
        card(title: "最近错题", systemImage: "pencil.and.list.clipboard") {
            if snapshot.recentMistakes.isEmpty {
                emptyHint("还没有错题。大胆去说，老师会悄悄帮你记下需要改进的地方。")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.recentMistakes) { mistake in
                        mistakeRow(mistake)
                    }
                    Text("完整错题本在「学习记录」里。")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
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
                Spacer(minLength: 0)
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

    // MARK: - 通用

    private func tile(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(theme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.7))
        )
    }

    private func emptyHint(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(theme.accent)
            Text(text)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private func card<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        card(title: title, systemImage: systemImage, trailing: { EmptyView() }, content: content)
    }

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
