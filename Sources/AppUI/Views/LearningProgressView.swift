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

    /// 「今日任务」卡的滚动锚点（黑板上的小图标点进来就定位到它）。
    private static let dailyTasksAnchorID = "progress.dailyTasks"
    /// 「年度学习记录」卡的滚动锚点（侧栏火苗徽章点进来就定位到它）。
    private static let annualRecapAnchorID = "progress.annualRecap"

    public init(state: AppState) { self.state = state }

    private var snapshot: ProgressSnapshot { state.progressSnapshot }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        todayCard
                        dailyTasksCard
                            // 黑板上的小图标点进来就滚到这里（见 `AppState.openTodayTasksInProgress`）。
                            // ⚠️ 锚点就是卡片本身，**不要给它套 `.position`**：那会让
                            // `scrollTo(anchor:)` 按整张内容画布的百分比对位（大树那条老教训）。
                            .id(Self.dailyTasksAnchorID)
                        weeklyCard
                        annualRecapCard
                            // 侧栏火苗徽章点进来就滚到这里（见 `AppState.openAnnualRecapInProgress`）。
                            // 与今日任务卡同理：锚点就是卡片本身，别套 `.position`。
                            .id(Self.annualRecapAnchorID)
                        curriculumCard
                        // 定级卡放在「能力定位」**上面**：起点（自测）→ 现状（估）
                        // 是同一个问题的两半，凑在一起看才成句。
                        entrancePlacementCard
                        placementCard
                        rhythmCard
                        grammarCard
                        vocabularyCard
                        pronunciationCard
                        writingCard
                        readingCard
                        skillsCard
                        mistakesCard
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // ⚠️ 两条路都要：`onChange` 管「已经在这一页时再点一次」；
                // `.task` 管「页面是刚被切出来的」—— 那种情况下 tick 在本视图出现**之前**
                // 就已经加过了，`onChange` 永远不补首帧（用户实测：跳转指令收到了、页面不滚）。
                .task { await jumpToFocus(proxy) }
                .onChange(of: state.progressFocusTick) { _, _ in
                    Task { await jumpToFocus(proxy) }
                }
            }
        }
        .background(theme.surfaceAlt.opacity(0.35))
        .task {
            // 进入页面汇总一次。**刚汇总过就不重算**，但隔了一会儿再进来必须重算 ——
            // 「今日任务」的进度要跟刚才做过的事对得上，拿昨天的快照说今天的事就是撒谎。
            if snapshot.activity.isEmpty || Date().timeIntervalSince(snapshot.generatedAt) > 15 {
                await state.reloadProgress()
            }
        }
    }

    // MARK: - 今日任务推荐（PRD §7.1）

    /// 点一项 → 直接去对应的页面做。
    private func open(_ kind: DailyTask.Kind) {
        Task {
            switch kind {
            case .conversation: await state.openPractice()
            case .shadowing: await state.openShadowing()
            case .review: await state.openVocabulary()
            }
        }
    }

    private var dailyTasksCard: some View {
        DailyTasksCard(plan: state.dailyPlan, onOpen: open)
    }

    /// 消费一次「滚到某张卡」的意图：滚过去 + 把意图收掉。
    ///
    /// ⚠️ **先消费再看要不要滚**：没有跳转意图（从侧栏正常进来）就直接返回 ——
    /// 不然每次打开这一页都会莫名其妙地滚一屏。
    /// 消费后等一小会儿再滚：页面是刚切出来的，`ScrollView` 的内容这一帧还没落位，
    /// 立刻 `scrollTo` 会滚到旧的内容高度上（学习记录页那条跳转也是这么处理的）。
    private func jumpToFocus(_ proxy: ScrollViewProxy) async {
        guard let target = state.consumeProgressFocus() else { return }
        try? await Task.sleep(nanoseconds: 200_000_000)
        withAnimation(.easeOut(duration: 0.32)) {
            proxy.scrollTo(
                target == .dailyTasks ? Self.dailyTasksAnchorID : Self.annualRecapAnchorID,
                anchor: .top
            )
        }
    }

    // MARK: - 本周小结 / 月环比（#228）

    /// 一格小结数字。
    private func statChip(value: String, label: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(tint ?? theme.primaryText)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var weeklyCard: some View {
        card(title: "本周小结", systemImage: "calendar") {
            if let insight = state.weeklyInsight {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        statChip(
                            value: ProgressAggregator.durationText(insight.weekSeconds),
                            label: "本周开口"
                        )
                        statChip(
                            value: correctionChangeText(insight.correctionChange),
                            label: insight.correctionChange == 0
                                ? "批注与上周持平"
                                : (insight.correctionChange > 0 ? "批注比上周多" : "批注比上周少"),
                            tint: insight.correctionChange > 0 ? theme.warning : theme.success
                        )
                        statChip(
                            value: "\(insight.weekNewWords) 词",
                            label: "本周新增词汇"
                        )
                        statChip(
                            value: "\(snapshot.streakDays) 天",
                            label: "连续练习",
                            tint: snapshot.streakDays > 0 ? theme.accent : theme.secondaryText
                        )
                    }
                    HStack(alignment: .top, spacing: 14) {
                        statChip(
                            value: "\(insight.weekWriting) 篇",
                            label: "本周写作"
                        )
                        statChip(
                            value: "\(insight.weekReading) 篇",
                            label: "本周阅读"
                        )
                        Spacer(minLength: 0)
                    }
                    Divider().overlay(theme.divider)
                    monthChangeRow(insight)
                }
            } else {
                Text("攒一周的记录，这里就会开始说人话 —— 现在还没有足够的数据。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .lineSpacing(3)
            }
        }
    }

    /// 月环比一行：有样本给百分比，没有就说「还不够」——绝不拿 0% 冒充。
    private func monthChangeRow(_ insight: WeeklyInsight) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            if let percent = insight.monthChangePercent {
                let rounded = Int(percent.rounded())
                HStack(spacing: 4) {
                    Image(systemName: percent >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                    Text("开口时长 \(abs(rounded))%")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(percent >= 0 ? theme.success : theme.warning)
                Text("本月至今 vs 上月整月")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            } else {
                Text("开口时长环比：还不够 —— 上个月练满 5 分钟，下个月再来比")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
    }

    private func correctionChangeText(_ change: Int) -> String {
        guard change != 0 else { return "持平" }
        return change > 0 ? "+\(change) 处" : "\(change) 处"
    }

    // MARK: - 能力定位（placement，#229）

    private var placementCard: some View {
        card(title: "能力定位", systemImage: "scope") {
            let estimate = state.placementEstimate
            VStack(alignment: .leading, spacing: 10) {
                if estimate.isConfident, let level = estimate.level {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(level.code)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.accent)
                        Text("· \(level.displayName)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Spacer(minLength: 0)
                    }
                    Text(level.canDo)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .lineSpacing(3)
                } else {
                    Text("还在观察中")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("再多聊几轮、收几个词，我就能比较有把握地告诉你现在站在哪一档。")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .lineSpacing(3)
                }

                // 依据：口径透明，每条一句话。
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(estimate.signals.enumerated()), id: \.offset) { _, signal in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(theme.accent.opacity(0.7))
                                .frame(width: 4, height: 4)
                            Text(signal)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                                .monospacedDigit()
                        }
                    }
                }

                if !estimate.gaps.isEmpty, let next = estimate.nextLevel {
                    Divider().overlay(theme.divider)
                    Text("距 \(next.code)（\(next.displayName)）还差")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    ForEach(Array(estimate.gaps.enumerated()), id: \.offset) { _, gap in
                        Text("· \(gap)")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - 年度学习记录

    /// 近一年 53 周 × 7 天的分布。放在「今日任务」之后：
    /// 上面两张卡说的是今天，这张把镜头拉到一年 —— 今天的格子由上面两张卡决定。
    /// 右上角「导出图片」：把这张卡存成 PNG 分享（#210）。
    private var annualRecapCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button {
                    ReportExporter.exportAnnualRecapPanel(recap: state.annualRecap, theme: theme)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10, weight: .semibold))
                        Text("导出图片")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("把年度学习记录导出成 PNG 图片")
            }
            AnnualRecapCard(recap: state.annualRecap)
        }
    }

    // MARK: - 课程阶梯（P1-2：CEFR 课程体系）

    /// 点某一档 → 打开情景选择面板。
    ///
    /// 不做「按档筛选」：情景面板只按分组展示，没有档位筛选这个入口。
    /// 与其新造一个半成品控件，不如就把他送到情景列表 —— 少一个要维护的东西。
    /// 因此**档位本身用不上**（`_:` 标注），签名仍收一个 `CEFRLevel` 是因为
    /// 它是 `CurriculumLadderCard.onOpen` 的回调类型。
    private func openStage(_: CEFRLevel) {
        Task { await state.openScenarios() }
    }

    private var curriculumCard: some View {
        CurriculumLadderCard(stages: state.curriculumStages, onOpen: openStage)
    }

    /// 入学定级（进阶 ⑤）：自测的起点档位 + 进入摸底的入口。
    private var entrancePlacementCard: some View {
        EntrancePlacementCard(
            result: state.placementResult,
            // 样本不够时那条估计是 nil（还在观察中）—— 对照那一行据此闭嘴。
            estimateLevel: state.placementEstimate.isConfident ? state.placementEstimate.level : nil
        ) {
            Task { await state.openPlacement() }
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
                        if state.dailyGoalMode == .baseline {
                            // 保底档：判定口径就是 5 分钟（与黑板计划的量一致）。
                            Text("保底 \(snapshot.today.minutes) / 5 分钟")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                                .monospacedDigit()
                        } else {
                            Text("\(snapshot.today.minutes) / \(snapshot.goalMinutes) 分钟")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 4)
                        if state.dailyGoalMode == .advanced {
                            goalStepper
                        }
                        goalModePicker
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

    /// 目标档位切换（保底 5 分钟 / 进阶目标）。
    ///
    /// ⚠️ 不用系统 `Picker`（macOS 命中区退化），沿用两个小圆钮的自绘口径。
    private var goalModePicker: some View {
        HStack(spacing: 4) {
            ForEach(DailyGoalMode.allCases, id: \.id) { mode in
                let isSelected = state.dailyGoalMode == mode
                Button {
                    guard !isSelected else { return }
                    Task { await state.setDailyGoalMode(mode) }
                } label: {
                    Text(mode.displayName)
                        .font(.system(size: 10, weight: isSelected ? .bold : .regular, design: .rounded))
                        .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(theme.accent.opacity(isSelected ? 0.14 : 0))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                isSelected ? theme.accent.opacity(0.6) : theme.divider,
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .help(mode == .baseline
                      ? "保底档：5 分钟内做完即算今日完成，保住连续"
                      : "进阶档：按每日目标分钟数排计划")
            }
        }
    }

    /// 目标分钟数的加减（5 分钟一档，5...180）。仅进阶档显示 —— 保底档没有可调的分钟数。
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
                    // ⚠️ 标签是「待复习单词」而不是「今日待复习」：这里是**此刻**还剩多少词到期，
                    // 会随着复习变小。「今天要复习多少」是**当天定住**的另一个数（每日任务那一项，
                    // `vocabulary.dueAtDayStart`）—— 两者口径不同，别把它们说成一回事。
                    tile(icon: "clock.badge.exclamationmark", value: "\(snapshot.vocabulary.due)", label: "待复习单词")
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

    // MARK: - 写作练习 / 阅读理解（#233）

    /// 写作口径：窗口内的 activity 已经带着每天的篇数 / 平均分 / 词数（与快照同源）。
    private var writingCard: some View {
        card(title: "写作练习", systemImage: "square.and.pencil") {
            let writings = snapshot.activity.reduce(0) { $0 + $1.writings }
            if writings == 0 {
                emptyHint("这段时间还没交过作文。去写作页写几句，交给老师批改。")
            } else {
                let scores = snapshot.activity.compactMap(\.writingScore)
                let words = snapshot.activity.reduce(0) { $0 + $1.writingWords }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        tile(icon: "square.and.pencil",
                             value: "\(writings)", label: "写作篇数")
                        tile(icon: "star.leadinghalf.filled",
                             value: scores.isEmpty ? "—" : "\(Int((scores.reduce(0, +) / Double(scores.count)).rounded()))",
                             label: "平均分")
                        tile(icon: "textformat.abc",
                             value: "\(words)", label: "累计词数")
                    }
                    Text("近 \(snapshot.days) 天写了 \(writings) 篇。批改分数只记交卷的那次。")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    private var readingCard: some View {
        card(title: "阅读理解", systemImage: "book.fill") {
            let readings = snapshot.activity.reduce(0) { $0 + $1.readings }
            if readings == 0 {
                emptyHint("这段时间还没交过卷。去阅读页读一篇，答完题看看溯源讲解。")
            } else {
                let correct = snapshot.activity.reduce(0) { $0 + $1.readingCorrect }
                let questions = snapshot.activity.reduce(0) { $0 + $1.readingQuestions }
                let rate = questions > 0 ? Int((Double(correct) / Double(questions) * 100).rounded()) : 0
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        tile(icon: "book.fill",
                             value: "\(readings)", label: "阅读篇数")
                        tile(icon: "checkmark.seal.fill",
                             value: questions > 0 ? "\(rate)%" : "—", label: "答对率")
                        tile(icon: "checkmark.circle.fill",
                             value: questions > 0 ? "\(correct)/\(questions)" : "—", label: "答对题数")
                    }
                    Text("近 \(snapshot.days) 天交卷 \(readings) 篇，答对 \(correct) / \(questions) 题。只统计交过卷的阅读。")
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
        card(
            title: "最近错题",
            systemImage: "pencil.and.list.clipboard",
            trailing: { mistakesJumpButton }
        ) {
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

    /// 「前往学习记录巩固」：把这一页的结论送到**能动手的那一页**去。
    ///
    /// 卡片只列最近 5 条、且这里没有任何可操作的东西 —— 看完了只能自己去侧边栏找
    /// 「学习记录」。跳转直接落在错题本卡片上（`recordsFocus`），中间不让人再找一次。
    ///
    /// 颜色取冷紫 `accentCool`：与卡片标题的琥珀主色区分开，
    /// 与学习记录页那张「前往词汇本练习」是同一类动作、同一个颜色。
    private var mistakesJumpButton: some View {
        Button {
            Task { await state.openRecords(focus: .mistakes) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrowshape.turn.up.right.fill")
                Text("前往学习记录巩固")
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(theme.accentCool))
        }
        .buttonStyle(.plain)
        .disabled(snapshot.recentMistakes.isEmpty)
        .opacity(snapshot.recentMistakes.isEmpty ? 0.5 : 1)
        .help(snapshot.recentMistakes.isEmpty ? "还没有错题，先去说几句" : "跳到学习记录的错题本，逐条过一遍")
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
