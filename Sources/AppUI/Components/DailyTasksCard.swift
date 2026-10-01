import AIDomain
import SwiftUI

/// 「今日任务」卡片（PRD §7 今日学习状态 / §7.1 Today's Focus）。
///
/// 三条硬规矩：
/// 1. **完成度来自真实记录**，不是让用户自己打勾 —— 打勾的清单只会变成自我安慰；
/// 2. **推荐理由必须可核对**（「有 8 个词到期」），不是形容词；
/// 3. 点每一项都能**直接去做**（跳到对应的页面），不做「看得到走不到」的清单。
///
/// 单独成组件的原因：与 `PhonemeBreakdownCard` 同理 ——
/// 整页离屏渲染看不出它到底有没有画出来，独立组件才能单独回归。
struct DailyTasksCard: View {

    @Environment(\.forestTheme) private var theme

    let plan: DailyPlan
    /// 点某一项 → 跳到对应页面（nil = 只读展示）。
    var onOpen: ((DailyTask.Kind) -> Void)? = nil

    /// 完成态用的绿：与「今天」卡片里的目标达成同一个色。
    private let doneGreen = Color(hex: 0x8FD694)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if plan.tasks.isEmpty {
                emptyHint
            } else {
                VStack(spacing: 8) {
                    ForEach(plan.tasks) { task in
                        taskRow(task)
                    }
                }
            }
            if let focus = plan.focus {
                focusRow(focus)
            }
        }
        .appPadding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .appElevation(.card)
        )
    }

    // MARK: - 头

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: plan.isAllDone ? "checkmark.seal.fill" : "list.bullet.clipboard.fill")
                .appFont(12)
                .foregroundStyle(plan.isAllDone ? doneGreen : theme.accent)
            Text("今日任务")
                .appFont(13, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 8)
            if !plan.tasks.isEmpty {
                Text(plan.isAllDone ? "今天都做完了" : plan.progressText)
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(plan.isAllDone ? doneGreen : theme.secondaryText)
                    .monospacedDigit()
            }
        }
    }

    private var emptyHint: some View {
        Text("今天没有安排 —— 要么该做的都做完了，要么还没有足够的记录可以推荐。")
            .appFont(11, design: .rounded)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 一项

    private func taskRow(_ task: DailyTask) -> some View {
        let tint = task.isDone ? doneGreen : theme.accent
        return Button {
            onOpen?(task.kind)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .appFont(13)
                    .foregroundStyle(tint)
                    .appPadding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: task.kind.systemImage)
                            .appFont(10)
                            .foregroundStyle(theme.secondaryText)
                        Text(task.title)
                            .appFont(12, weight: .medium, design: .rounded)
                            .foregroundStyle(theme.primaryText)
                            .strikethrough(task.isDone, color: theme.secondaryText)
                        Spacer(minLength: 6)
                        Text(task.progressText)
                            .appFont(10, weight: .semibold, design: .rounded)
                            .foregroundStyle(tint)
                            .monospacedDigit()
                    }

                    // 细进度条：超额算满。
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.divider.opacity(0.6))
                            Capsule()
                                .fill(tint)
                                .frame(width: max(4, proxy.size.width * task.progressRatio))
                        }
                    }
                    .frame(height: 4)

                    Text(task.reason)
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if onOpen != nil {
                    Image(systemName: "chevron.right")
                        .appFont(9, weight: .semibold)
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                        .appPadding(.top, 3)
                }
            }
            .appPadding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(task.isDone ? doneGreen.opacity(0.10) : theme.surfaceAlt.opacity(0.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.appPressable)
        .disabled(onOpen == nil)
        .help(task.isDone ? "已经完成：\(task.reason)" : "去做：\(task.title)")
    }

    // MARK: - 今日重点

    private func focusRow(_ focus: DailyPlan.Focus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .appFont(10)
                    .foregroundStyle(theme.accentCool)
                Text(focus.title)
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
            }
            Text(focus.reason)
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appPadding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accentCool.opacity(0.12))
        )
    }
}
