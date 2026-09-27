import AIDomain
import SwiftUI

/// 情景对话选择面板（Implementation Plan §21）。
///
/// **完全数据驱动**：本视图只渲染 `AppState.scenarios`，不内置任何场景内容，
/// 也不判断场景语义（分组、难度、词汇都由数据决定）。
///
/// ⚠️ 需求 3：**点卡片不再直接进练习**。第一次点只展开「主线任务 + 教学重点 + 挂在大树的哪一关」，
/// 再点收起；真正开始要按展开区右侧的「开始任务」。这样学员在开口之前就清清楚楚知道
/// 「这一关要做什么、做到什么算完成、它在树上对应哪一格」。
///
/// 考试模式（雅思口语 / 面试问答）与情景**同面板、不同分区**：两者都是「开始一段练习」的入口，
/// 但评价体系完全分开（考试给参考分，情景给星星与判定卡）。放在一起是为了让学员
/// 在选择的那一刻就看见差别，而不是进了考场才发现「怎么没有星星」。
public struct ScenarioPickerView: View {

    @Environment(\.forestTheme) private var theme
    @Bindable var state: AppState
    var onClose: () -> Void

    /// 展开的考卷 id（与情景卡片的展开状态分开存：两者是两种东西，
    /// 共用一份状态会让「展开一套考卷」把展开的情景卡也收起来）。
    @State private var expandedExamID: String?

    /// 待确认删除的自建情景 id（两步确认的第一下）。
    ///
    /// 删除自建情景是**一点就没、且无法恢复**的：情景连同它的目标句一起消失，
    /// 重新生成要再花一次模型请求。所以不能像「开始任务」那样点了就走 ——
    /// 第一下只进确认态，第二下才真删，并且随时有「取消」可退。
    /// 存的是 id 而不是 Bool：一屏多个自建情景，Bool 会让点其中一个把其它几个也点亮。
    @State private var pendingDeleteScenarioID: String?

    public init(state: AppState, onClose: @escaping () -> Void) {
        self.state = state
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)

            if state.scenarios.isEmpty && state.examBlueprints.isEmpty && state.materialKits.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 18) {
                        if !state.materialKits.isEmpty {
                            materialSection
                        }
                        if !state.examBlueprints.isEmpty {
                            examSection
                        }
                        ForEach(Scenario.groups(state.scenarios), id: \.category) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.category)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(theme.secondaryText)
                                ForEach(group.items) { scenario in
                                    card(scenario)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        // 收起卡片就把确认态一起清掉：否则下次展开同一张卡，按钮还停在「确认删除」，
        // 人以为自己刚点的那下没生效，再点一下就真删了。
        .onChange(of: state.expandedScenarioID) { _, _ in
            pendingDeleteScenarioID = nil
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "map.fill")
                .font(.system(size: 18))
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(theme.surfaceAlt)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("情景对话")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("点卡片看任务与重点；想练的没有，就自己描述一个")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            // 描述场景（⑦）：与「上传材料」同为头部常驻入口，且排在它前面 ——
            // 「一句话生成」是零素材门槛的入口，比「先找一篇文章」用得多。
            Button {
                Task { await state.openScenarioComposer() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                    Text("描述场景")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().strokeBorder(theme.accent.opacity(0.5), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .help("用一句话描述你想练的场景，让老师把它搭出来")
            .accessibilityLabel("描述场景，一句话生成一个情景对话")

            // 上传材料（#208）：与关闭按钮同为头部常驻入口。
            Button {
                Task { await state.openMaterialUpload() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.badge.plus").font(.system(size: 10, weight: .semibold))
                    Text("上传材料")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().strokeBorder(theme.accent.opacity(0.5), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .help("把一篇文章拆成情景 + 跟读句 + 生词表")
            .accessibilityLabel("上传材料，自动生成情景对话、跟读句和生词表")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.hover))
            }
            .buttonStyle(.appPressable)
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
    }

    // MARK: - 空态（资源缺失时给可操作提示，不静默空白）

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 30))
                .foregroundStyle(theme.secondaryText)
            Text("没有找到情景与考卷资源")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text("请确认 App 资源中的 Scenarios 与 Exams 目录存在且包含 JSON 文件。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - 我的材料（上传材料自动出题，#208）

    private var materialSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text("我的材料")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Text("从你上传的文章拆出来：情景 + 跟读句 + 生词表")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.85))
            }
            ForEach(state.materialKits) { kit in
                MaterialKitCard(kit: kit, state: state)
            }
        }
    }

    // MARK: - 考试模式（雅思口语 / 面试问答）

    private var examSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text("考试模式")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Text("按考官流程一题一题走，考完给参考分（不记星星）")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.85))
            }
            ForEach(state.examBlueprints) { blueprint in
                examCard(blueprint)
            }
        }
    }

    private func examCard(_ blueprint: ExamBlueprint) -> some View {
        let isExpanded = expandedExamID == blueprint.id
        let isActive = state.examRunner?.blueprint.id == blueprint.id
        return VStack(alignment: .leading, spacing: 0) {
            // ⚠️ 与情景卡片同款：展开只能用真 `Button`（`.onTapGesture` 键盘与读屏都走不到，
            //    而「开始考试」正长在展开区里）。
            Button {
                withAnimation(.app(.reveal)) {
                    expandedExamID = isExpanded ? nil : blueprint.id
                }
            } label: {
                examHeader(blueprint, isActive: isActive, isExpanded: isExpanded)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appPressable)
            .help(isExpanded ? "收起这套考卷的环节" : "展开看考哪些环节")
            .accessibilityHint(isExpanded ? "收起考卷详情" : "展开考卷详情")

            if isExpanded {
                Divider().overlay(theme.divider).padding(.vertical, 12)
                examDetail(blueprint)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isActive || isExpanded ? theme.accent.opacity(0.7) : theme.divider,
                    lineWidth: 1
                )
        )
    }

    private func examHeader(_ blueprint: ExamBlueprint, isActive: Bool, isExpanded: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: blueprint.format.icon)
                .font(.system(size: 17))
                .foregroundStyle(theme.accent)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.surfaceAlt)
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(blueprint.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    if isActive {
                        badge("进行中", tint: theme.accent)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                HStack(spacing: 8) {
                    chip("\(blueprint.stages.count) 个环节")
                    chip("\(blueprint.questionCount) 问")
                    chip("约 \(Self.minutes(blueprint.totalTimeLimitSeconds)) 分钟")
                }
                if !blueprint.summary.isEmpty {
                    Text(blueprint.summary)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }

    private func examDetail(_ blueprint: ExamBlueprint) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blueprint.stages) { stage in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(stage.title)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Spacer(minLength: 0)
                        Text("\(stage.prompts.count) 问 · 每题 \(stage.timeLimitSeconds) 秒 · 至少 \(stage.minimumWords) 词")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Text(stage.instructions)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            HStack(spacing: 10) {
                Text("题目来自考卷文件，答完自动进下一题；中途可跳过或提前交卷。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                Button {
                    Task { await state.startExam(blueprint) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "flag.checkered").font(.system(size: 9, weight: .bold))
                        Text("开始考试")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.onAccentFill)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(theme.accentFill))
                    .contentShape(Capsule())
                }
                .buttonStyle(.appPressable)
                .help("开始「\(blueprint.title)」")
            }
        }
    }

    /// 总时长写成「约 N 分钟」（各环节限时之和；不足一分钟按 1 分钟算，别显示 0）。
    static func minutes(_ seconds: Int) -> Int {
        max(Int((Double(seconds) / 60).rounded()), 1)
    }

    // MARK: - 场景卡片

    private func card(_ scenario: Scenario) -> some View {
        let isActive = state.activeScenario?.scenario.id == scenario.id
        let isExpanded = state.expandedScenarioID == scenario.id
        return VStack(alignment: .leading, spacing: 0) {
            // 头部：**只有这一块响应「展开 / 收起」**，展开区里的按钮才不会被外层吞掉。
            //
            // ⚠️ 必须是 `Button` 而不是 `.onTapGesture`：「开始任务」长在展开区里，
            // 而手势只有鼠标能用 —— 键盘与 VoiceOver 用户压根走不到开始那一步
            // （旧版就是手势，读屏读不出这一块能按，也不给焦点）。
            Button {
                state.toggleScenarioExpansion(scenario.id)
            } label: {
                cardHeader(scenario, isActive: isActive, isExpanded: isExpanded)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appPressable)
            .help(isExpanded ? "收起这一关的详情" : "展开看主线任务与教学重点")
            .accessibilityHint(isExpanded ? "收起详情" : "展开详情")

            if isExpanded {
                Divider().overlay(theme.divider).padding(.vertical, 12)
                detail(scenario)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isActive || isExpanded ? theme.accent.opacity(0.7) : theme.divider,
                    lineWidth: 1
                )
        )
        .appAnimation(.reveal, value: isExpanded)
    }

    private func cardHeader(_ scenario: Scenario, isActive: Bool, isExpanded: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: scenario.icon)
                .font(.system(size: 17))
                .foregroundStyle(theme.accent)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.surfaceAlt)
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(scenario.titleZh)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(scenario.title)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                    if isActive {
                        badge("进行中", tint: theme.accent)
                    }
                    if let level = state.boundLevel(for: scenario), level.state == .completed {
                        badge("已过关", tint: theme.accentCool)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }

                HStack(spacing: 8) {
                    chip(scenario.level)
                    chip("难度 \(scenario.difficultyDots)")
                    chip("\(scenario.maxTurns) 轮")
                    chip("纠错 · \(scenario.correctionMode.displayName)")
                }

                if !scenario.objective.isEmpty {
                    Text(scenario.objective)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                // 收起态也给一行主线任务进度：一眼看出「这一关做到哪了」。
                let progress = state.questProgress(for: scenario)
                if progress.total > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "flag.checkered")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.accent)
                        Text("\(progress.summary) · \(progress.isComplete ? "已完成" : progress.currentText)")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    // MARK: - 展开区：主线任务 / 教学重点 / 大树联动 / 开始任务

    private func detail(_ scenario: Scenario) -> some View {
        let progress = state.questProgress(for: scenario)
        let level = state.boundLevel(for: scenario)
        return VStack(alignment: .leading, spacing: 14) {
            questSection(scenario, progress: progress)
            focusSection(scenario)
            levelSection(scenario, level: level)
            HStack(spacing: 10) {
                // 自建情景才给删除入口（内置素材删不掉，它们随包发布）。
                // 判断走 `origin` 这个**数据**，不拿分组名或 id 前缀比较 ——
                // 那两样一改字，「这是不是用户自建的」就会静默失效，而它决定的是删除入口。
                if scenario.origin == .custom {
                    let confirming = pendingDeleteScenarioID == scenario.id
                    Button {
                        if confirming {
                            pendingDeleteScenarioID = nil
                            Task { await state.deleteCustomScenario(id: scenario.id) }
                        } else {
                            pendingDeleteScenarioID = scenario.id
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: confirming ? "trash.fill" : "trash")
                                .font(.system(size: 9, weight: .semibold))
                            Text(confirming ? "确认删除" : "删除")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        // 常态描边、确认态红底：两级视觉强度，让人一眼看出「这一步不一样」。
                        .foregroundStyle(confirming ? .white : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(confirming ? theme.danger : Color.clear))
                        .overlay(
                            Capsule().strokeBorder(
                                confirming ? Color.clear : theme.divider,
                                lineWidth: 1
                            )
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.appPressable)
                    .help(confirming
                        ? "再点一次就真的删掉「\(scenario.titleZh)」，无法恢复"
                        : "删掉这个自建情景；已经收进词汇本的词不回收")
                }
                Text(scenario.origin == .custom
                    ? "删除只影响这个情景，词汇本里的词留着。"
                    : "展开只是先看清楚；准备好就按右边开始。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                Button {
                    Task { await state.startScenario(scenario) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                        Text(progress.doneCount > 0 && !progress.isComplete ? "继续任务" : "开始任务")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.onAccentFill)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(theme.accentFill))
                    .contentShape(Capsule())
                }
                .buttonStyle(.appPressable)
                .help("进入「\(scenario.titleZh)」")
            }
            if pendingDeleteScenarioID == scenario.id {
                deleteConfirmBanner(scenario)
            }
        }
    }

    /// 删除确认条：**必须自带「取消」**。
    ///
    /// 只有「再点一次」没有退路的话，确认态一旦进入，唯一的出口就是硬着头皮点下去
    /// （学习记忆卡上这条是被实测反馈过的）。所以警告条里就地给一个「取消」，
    /// 点了什么都不删、退回原来的样子。
    private func deleteConfirmBanner(_ scenario: Scenario) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.danger)
            Text("再点一次「确认删除」就会删掉「\(scenario.titleZh)」和它的目标句，无法恢复。已经收进词汇本的词会保留。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                pendingDeleteScenarioID = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("取消")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Capsule().fill(theme.surface))
                .overlay(Capsule().strokeBorder(theme.divider, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .help("什么都不删，退回原来的样子")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.danger.opacity(0.10))
        )
    }

    /// 主线任务：当前节点 + 完成情况（需求 3 的核心展示）。
    ///
    /// 整个面板一次只画一个情景，`Scenario` 用不上（内容全在 `progress` 里）；
    /// 保留位置参数是为了区分「情景分区」与「结果分区」之外的其它分区函数。
    private func questSection(_: Scenario, progress: QuestProgress) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("主线任务", trailing: progress.total > 0 ? progress.summary : "")
            if !progress.title.isEmpty {
                Text(progress.title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            if progress.steps.isEmpty {
                Text("这一关没有分步任务，练完按「教学重点」判定。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            } else {
                ForEach(progress.steps) { step in
                    questStepRow(step)
                }
            }
        }
    }

    private func questStepRow(_ step: QuestStepState) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: step.isDone ? "checkmark.circle.fill" : (step.isCurrent ? "circle.dotted" : "circle"))
                .font(.system(size: 11))
                .foregroundStyle(step.isDone ? theme.accent : (step.isCurrent ? theme.accentCool : theme.secondaryText.opacity(0.6)))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(step.marker) \(step.text)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(step.isDone ? theme.secondaryText : theme.primaryText)
                    .strikethrough(step.isDone, color: theme.secondaryText.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if step.isCurrent, !step.hint.isEmpty {
                    Text(step.hint)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
            if step.isCurrent {
                Text("当前")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accentCool)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.hover))
            }
        }
    }

    /// 教学重点：目标句 + 目标词（练之前就看得见）。
    /// 「教学重点」右侧的两个数：素材**总量** + **达标门槛**，两个都要给。
    ///
    /// ⚠️ 只写总量会误导：卡片上写「目标句 4 句」，进到对话里提要条却写「目标句 0/2」，
    /// 学员第一反应是「另外那 2 句哪去了 / 我是不是漏了」。门槛数必须提前说清。
    /// 门槛走 `CurriculumScorer.focusThreshold`（与判定同源），**不在这里重算** ——
    /// 各算一遍迟早算出两个数。
    private func focusTrailing(_ scenario: Scenario) -> String {
        let threshold = CurriculumScorer.focusThreshold(for: scenario)
        var parts: [String] = []
        if !scenario.targetSentences.isEmpty {
            parts.append("目标句 \(scenario.targetSentences.count) 句（说到 \(threshold.sentences) 句）")
        }
        if !scenario.targetVocabulary.isEmpty {
            parts.append("目标词 \(scenario.targetVocabulary.count) 个（用到 \(threshold.words) 个）")
        }
        return parts.joined(separator: " · ")
    }

    private func focusSection(_ scenario: Scenario) -> some View {
        let sentences = scenario.targetSentences
        let words = scenario.targetVocabulary
        return VStack(alignment: .leading, spacing: 7) {
            sectionTitle(
                "教学重点",
                trailing: focusTrailing(scenario)
            )
            if sentences.isEmpty && words.isEmpty {
                Text("这一关没有设定重点，自由发挥就好。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(sentences, id: \.self) { sentence in
                bullet(sentence)
            }
            if !words.isEmpty {
                HStack(spacing: 6) {
                    ForEach(words.prefix(8), id: \.self) { word in
                        Text(word)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(theme.hover))
                    }
                }
                .padding(.top, 1)
            }
            if !scenario.targetGrammar.isEmpty {
                Text("语法点（提示，不参与判定）：\(scenario.targetGrammar.joined(separator: "、"))")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    /// 大树联动：这一关在大树上对应哪一格、什么状态（需求 2）。
    private func levelSection(_: Scenario, level: TreeLevel?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("成长之树", trailing: level?.state.displayName ?? "")
            if let level {
                HStack(spacing: 8) {
                    Image(systemName: "tree.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accent)
                    Text(level.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(level.subtitle)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                    Spacer(minLength: 0)
                    Text("★ \(level.earnedStars)/\(level.requiredStars)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                Text("过关条件：完成主线任务 + 教学重点达标（星星只记开口量）")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.9))
            } else {
                Text("这个情景还没挂到大树上，练完只给判定、不加关卡进度。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: - 零件

    private func sectionTitle(_ text: String, trailing: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 0)
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Circle()
                .fill(theme.accent.opacity(0.7))
                .frame(width: 3, height: 3)
                .padding(.top, 5)
            Text(text)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.selection))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.hover))
    }
}
