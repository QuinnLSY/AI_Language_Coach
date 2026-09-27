import AIDomain
import SwiftUI

/// 「课程阶梯」卡片（P1-2：CEFR 课程体系）。
///
/// 这一块回答一个问题：**我现在练的东西，在整条路上排第几？**
/// 所以它只显示三样东西，不显示别的：
/// 1. 每一档**能做到什么**（can-do，人话，不是教学术语）；
/// 2. 这一档有哪些情景、其中几关挂在成长之树上、攒了几颗星；
/// 3. 整条阶梯走完了多少。
///
/// 单独成组件的原因与 `DailyTasksCard` / `PhonemeBreakdownCard` 相同 ——
/// 整页离屏渲染看不出它到底画没画出来，独立组件才能单独回归。
struct CurriculumLadderCard: View {

    @Environment(\.forestTheme) private var theme

    /// 阶梯内容（`AppState.curriculumStages`，纯函数算出来的）。
    let stages: [CurriculumStage]
    /// 点某一档 → 去看那一档的情景（nil = 只读展示）。
    var onOpen: ((CEFRLevel) -> Void)? = nil
    /// 离屏渲染测试用：关掉底色才不会让整宽背景糊住墨迹边界。
    var showsContainer: Bool = true

    /// 已练完用的绿：与「今天」卡片、「今日任务」同一个色。
    private let doneGreen = Color(hex: 0x8FD694)
    /// 还锁着的那一档用的灰调。
    private var lockedTint: Color { theme.secondaryText.opacity(0.55) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if stages.isEmpty {
                emptyHint
            } else {
                Text(subtitle)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    ForEach(stages, id: \.level) { stage in
                        stageRow(stage)
                    }
                }
            }
        }
        .padding(showsContainer ? 18 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if showsContainer {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.surface)
                    .appElevation(.card)
            }
        }
    }

    // MARK: - 头

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "stairs")
                .font(.system(size: 12))
                .foregroundStyle(theme.accent)
            Text("课程阶梯")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 8)
            if !stages.isEmpty {
                Text("整体 \(Int((overallProgress * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
        }
    }

    private var emptyHint: some View {
        Text("还没有可显示的分级 —— 情景素材里必须写清 `level`（如 `B1`）才会出现在阶梯上。")
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 「A1 → B2 · 10 个情景 · 挂在 8 关成长树上」。
    private var subtitle: String {
        let first = stages.first?.level.code ?? "A1"
        let last = stages.last?.level.code ?? "B2"
        let scenarioCount = scenarioCount
        let levelCount = levelCount
        return "\(first) → \(last) · \(scenarioCount) 个情景 · 挂在 \(levelCount) 关成长树上"
    }

    private var overallProgress: Double {
        CurriculumLadder.overallProgress(stages)
    }

    /// 情景总数：**按 id 去重** —— 区间场景（`A1-A2`）会同时出现在两档里。
    private var scenarioCount: Int {
        var seen = Set<String>()
        return stages.reduce(0) { total, stage in
            total + stage.scenarios.filter { seen.insert($0.id).inserted }.count
        }
    }

    /// 挂在阶梯上的关卡总数（同样按 id 去重）。
    private var levelCount: Int {
        var seen = Set<String>()
        return stages.reduce(0) { total, stage in
            total + stage.levels.filter { seen.insert($0.id).inserted }.count
        }
    }

    // MARK: - 一档

    private func stageRow(_ stage: CurriculumStage) -> some View {
        let unlocked = stage.isUnlocked
        let completed = stage.isCompleted
        let tint = completed ? doneGreen : (unlocked ? theme.accent : lockedTint)
        return Button {
            onOpen?(stage.level)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    levelChip(stage.level, tint: tint, filled: unlocked)
                    Text(stage.level.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(unlocked ? theme.primaryText : theme.secondaryText)
                    Spacer(minLength: 6)
                    Text(starsText(stage))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                        .monospacedDigit()
                }

                Text(stage.level.canDo)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                // 细进度条：星星攒够多少。
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.divider.opacity(0.6))
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, proxy.size.width * stage.progress))
                    }
                }
                .frame(height: 4)

                HStack(spacing: 6) {
                    Text(scenarioListText(stage))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if completed {
                        Label("已练完", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(doneGreen)
                            .labelStyle(.titleAndIcon)
                    } else if !unlocked {
                        Label("未解锁", systemImage: "lock.fill")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(lockedTint)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(completed ? doneGreen.opacity(0.10) : theme.surfaceAlt.opacity(0.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.appPressable)
        .disabled(onOpen == nil)
        .help(stageA11yHint(stage))
    }

    private func levelChip(_ level: CEFRLevel, tint: Color, filled: Bool) -> some View {
        Text(level.code)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(filled ? .white : theme.secondaryText)
            .padding(.horizontal, 7)
            .frame(height: 17)
            .background(Capsule().fill(filled ? tint : theme.hover))
            .overlay(Capsule().strokeBorder(filled ? .clear : theme.divider, lineWidth: 1))
    }

    /// 「5/6 星」；没有挂关卡时说明「未挂关」—— 不让它显示成 0/0 星那种看不出问题的样子。
    private func starsText(_ stage: CurriculumStage) -> String {
        guard !stage.levels.isEmpty else { return "未挂关" }
        return "\(stage.earnedStars)/\(stage.requiredStars) 星"
    }

    /// 「点咖啡、点单」——情景的中文名，用顿号连起来。
    private func scenarioListText(_ stage: CurriculumStage) -> String {
        guard !stage.scenarios.isEmpty else { return "这一档还没有情景" }
        return stage.scenarios.map(\.titleZh).joined(separator: "、")
    }

    private func stageA11yHint(_ stage: CurriculumStage) -> String {
        let base = "\(stage.level.code) \(stage.level.displayName)：\(stage.level.canDo)"
        guard !stage.scenarios.isEmpty else { return base }
        return base + " · 情景：" + stage.scenarios.map(\.titleZh).joined(separator: "、")
    }
}
