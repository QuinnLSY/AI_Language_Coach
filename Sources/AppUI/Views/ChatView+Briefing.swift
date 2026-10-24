import AIDomain
import SwiftUI

// #663 自 ChatView.swift 拆出（2026-10-24）：原文件 2896 行、单结构体 + 5 个尾部类型，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ChatView {

    // MARK: - 前情提要条（需求 3：进任务先讲清「上次练到哪」）

    /// 老师进任务前先交代的内容。与 `scenarioStrip`（角色 / 轮次）分工不同：
    /// 那条说「你在演谁」，这条说「我们上次做到哪、这次先做什么」。
    func briefingStrip(_ briefing: ScenarioBriefing) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .appFont(10, weight: .semibold)
                    .foregroundStyle(theme.accent)
                Text(briefing.isFirstTime ? "今天的任务" : "前情提要")
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                if briefing.quest.total > 0 {
                    Text(briefing.quest.summary)
                        .appFont(10, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.accentCool)
                        .padding(.horizontal, 6)
                        .appPadding(.vertical, 1)
                        .background(Capsule().fill(theme.hover))
                }
                Spacer(minLength: 0)
            }
            ForEach(briefing.lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 5) {
                    Circle()
                        .fill(theme.accent.opacity(0.7))
                        .frame(width: 3, height: 3)
                        .appPadding(.top, 5)
                    Text(line)
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(.horizontal, 18)
        .appPadding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.selection.opacity(0.5))
    }

    /// 上一段练习自动复盘的结果（需求 5：复盘变成自动，所以必须给一句回执）。
    ///
    /// 复盘的正文在学习记录页里，学员看到「已收进学习记录」之后**第一件想做的事就是去看它** ——
    /// 所以这条回执自带一个「去看复盘」：跳过去、并顺手展开**那一条**的复盘。
    /// 目标会话跟着 `AppNotice` 的值一起走，界面上没有第二处需要同步的状态。
    @ViewBuilder
    var practiceNoticeBanner: some View {
        if let practiceNotice {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .appFont(11)
                    .foregroundStyle(theme.accent)
                Text(practiceNotice.text)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                if let action = practiceNotice.action {
                    NoticeActionButton(
                        action: action,
                        helpText: "\(action.title)：到学习记录里看这一段的复盘内容",
                        context: practiceNotice.text
                    )
                }
                Button { onDismissPracticeNotice?() } label: {
                    Image(systemName: "xmark")
                        .appFont(9, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.appPressable)
            }
            .padding(.horizontal, 18)
            .appPadding(.vertical, 6)
            .background(theme.surfaceAlt.opacity(0.9))
            .overlay(alignment: .top) { Divider().overlay(theme.divider) }
            .overlay(alignment: .bottom) { Divider().overlay(theme.divider) }
        }
    }

    // MARK: - 情景目标条（数据来自场景本体，UI 不解释语义）

    func scenarioStrip(_ progress: ScenarioProgress) -> some View {
        let scenario = progress.scenario
        // #598 常驻进度的两个实时真源：主线进度是 `briefing.quest`（每轮发言重算，
        // 与落库、Prompt 注入同一份），教学重点是 `chat.liveFocus`（与结算同一条
        // 纯函数链）。⚠️ 不读 `briefing.focusItems` —— 那是进入时 turnsUsed:0
        // 算的占位，练习中永远是「全未达成」。
        let quest = briefing?.quest
        let focus = chat.liveFocus
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "target")
                .appFont(11)
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("你是 \(scenario.learnerRole)")
                        .appFont(10, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    Text("· \(scenario.level) · 纠错\(scenario.correctionMode.displayName)")
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }
                if !scenario.objective.isEmpty {
                    Text(scenario.objective)
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 「这关还差什么」扫一眼就有（#598）。两者皆空时不渲染：
                // 极简素材（无主线也无重点）不配拥有一个空进度条。
                if (quest?.total ?? 0) > 0 || !focus.isEmpty {
                    liveProgressRow(quest: quest, focus: focus)
                }
                if !scenario.targetVocabulary.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(scenario.targetVocabulary.prefix(6), id: \.self) { word in
                            targetWordChip(word, focus: focus)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .appPadding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.selection.opacity(0.35))
    }

    /// #598 常驻进度行：主线几步 / 教学重点覆盖 / 还差哪一步。
    ///
    /// 形态取「一行扫完」：左边汇总 pill（未达标 = 冷色，达标 = 主题色），
    /// 右边是当前节点。轮次不在这里重复 —— 右上胶囊已经有「第 3/12 轮」。
    private func liveProgressRow(quest: QuestProgress?, focus: TeachingFocus) -> some View {
        HStack(spacing: 6) {
            if let quest, quest.total > 0 {
                progressPill("主线 \(quest.doneCount)/\(quest.total)", done: quest.isComplete)
                if quest.isComplete {
                    Text("主线已全部完成")
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                } else if let current = quest.currentStep {
                    // 当前节点可能很长（锚点就是目标句本身）：截断而不是换行，
                    // 这一行的高度是常驻成本，多一行全聊天区都得让位。
                    Text("还差：\(current.text)")
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if !focus.isEmpty {
                if focus.requiredSentences > 0 {
                    progressPill(
                        "目标句 \(focus.matchedSentences)/\(focus.requiredSentences)",
                        done: focus.matchedSentences >= focus.requiredSentences
                    )
                }
                if focus.requiredWords > 0 {
                    progressPill(
                        "目标词 \(focus.matchedWords)/\(focus.requiredWords)",
                        done: focus.matchedWords >= focus.requiredWords
                    )
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 进度行里的小胶囊（未达标 = 冷色，达标 = 主题色）。
    private func progressPill(_ text: String, done: Bool) -> some View {
        Text(text)
            .appFont(9, weight: .semibold, design: .rounded)
            .foregroundStyle(done ? theme.accent : theme.accentCool)
            .padding(.horizontal, 6)
            .appPadding(.vertical, 2)
            .background(Capsule().fill(theme.hover))
    }

    /// 目标词 chip：#598 起按「说到没说到」着色 —— 命中 = 主题色，没命中 = 原样灰。
    /// 这是「这关还差什么」最直观的那一半：一眼扫出哪个词还没出口。
    private func targetWordChip(_ word: String, focus: TeachingFocus) -> some View {
        let hit = focus.wordItems.contains { $0.text == word && $0.isHit }
        return Text(word)
            .appFont(9, design: .rounded)
            .foregroundStyle(hit ? theme.accent : theme.secondaryText)
            .padding(.horizontal, 6)
            .appPadding(.vertical, 2)
            .background(Capsule().fill(hit ? theme.hover : theme.surfaceAlt))
    }

    /// 右上角胶囊：模型名 · 推理强度（如「qwen3:8b · 高」）。
    func headerModelCaption(_ model: String) -> String {
        if let reasoningLabel, !reasoningLabel.isEmpty {
            return "\(model) · \(reasoningLabel)"
        }
        return model
    }

    var statusLine: String {
        var parts: [String] = []
        if let modelName, !modelName.isEmpty { parts.append(modelName) }
        parts.append(health.userFacingDescription)
        return parts.joined(separator: " · ")
    }

}
