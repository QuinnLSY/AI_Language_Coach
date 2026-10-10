import AIDomain
import SwiftUI

/// 学习计划卡的内容（① 个性化学习计划）。
///
/// 阶段层（我在哪 → 要去哪 → 这个阶段练什么）+ 今日层（今天还差几项）。
///
/// 与「能力定位」卡的分工：那张说**现状**（你现在什么水平、凭什么这么判），
/// 这张说**方向**（要往哪走、这个阶段练什么）。档位与差距**直接透传**能力定位的结果，
/// 两张卡永远不会说两套数。
///
/// ⚠️ 只拥有**内容**：卡片的标题行 / 底 / 阴影由调用方（学习进度页的 `card(…)`）提供 ——
/// 卡壳只有一份配方，在这里长出第二份就一定会与第一份漂移。
public struct LearningPlanCard: View {

    @Environment(\.forestTheme) private var theme

    private let plan: LearningPlan
    private let onFocus: (LearningPlanFocus.Action) -> Void

    public init(plan: LearningPlan, onFocus: @escaping (LearningPlanFocus.Action) -> Void) {
        self.plan = plan
        self.onFocus = onFocus
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            stageHeadline

            if !plan.stage.gaps.isEmpty {
                gapList
            }

            if plan.stage.hasFocus {
                Divider().overlay(theme.divider)
                Text("这个阶段练这些")
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                VStack(spacing: 6) {
                    ForEach(plan.stage.focus) { item in
                        focusRow(item)
                    }
                }
            }

            todayLine

            if plan.isEmpty {
                emptyHint
            }
        }
    }

    // MARK: - 阶段层

    /// 「A2 → B1」+ 靶子（练到那一档能干什么）。
    private var stageHeadline: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(plan.stage.headline)
                    .appFont(24, weight: .bold, design: .rounded)
                    .foregroundStyle(plan.stage.isConfident ? theme.accent : theme.secondaryText)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            if let canDo = plan.stage.targetCanDo {
                Text("练到这一档，就能：\(canDo)")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("样本还不够，我还在看你站在哪一档 —— 多聊几轮、多收几个词就有结论了。")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 「距下一档还差」—— 与能力定位卡同一份 `gaps`（透传，不重算）。
    private var gapList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(plan.stage.gaps.enumerated()), id: \.offset) { _, gap in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(theme.accent.opacity(0.7))
                        .frame(width: 4, height: 4)
                        .padding(.top, 5)
                    Text(gap)
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 一条重点：**整行可点**，点了直接去对应的练习（复用已有动作，不新开链路）。
    private func focusRow(_ item: LearningPlanFocus) -> some View {
        Button {
            onFocus(item.action)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: Self.focusIcon(item.action))
                    .appFont(12)
                    .foregroundStyle(theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(theme.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    Text(item.reason)
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Text(item.pendingText)
                    .appFont(12, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.accent)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .appFont(9, weight: .semibold)
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
            }
            .appPadding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.surfaceAlt.opacity(0.7))
            )
        }
        .buttonStyle(.appPressable)
        .accessibilityLabel("\(item.title)，\(item.pendingText)。\(item.reason)")
        .accessibilityHint("去练习")
    }

    // MARK: - 今日层

    /// 「今天」那张卡已经说细了，这里只报**还差几项、接着做什么**。
    private var todayLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(theme.divider)
            HStack(spacing: 6) {
                Image(systemName: "sun.max")
                    .appFont(10)
                    .foregroundStyle(theme.accent)
                if let next = plan.today.nextTask {
                    Text("今天还差 \(plan.todayRemaining) 项 · 接着做：\(next.title)")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                } else if plan.today.tasks.isEmpty {
                    Text("今天还没有安排")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                } else {
                    Text("今天的 \(plan.today.totalCount) 项都做完了")
                        .appFont(11, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.accent)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 9)
        }
    }

    // MARK: - 空态

    private var emptyHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(theme.accent)
            Text("先去练一轮，我就能给你排一个像样的阶段计划。")
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .appPadding(.vertical, 4)
    }

    /// 图标与「今日任务」/ 错题本等处保持一致，别为同一件事换第二套图标。
    private static func focusIcon(_ action: LearningPlanFocus.Action) -> String {
        switch action {
        case .errorDrill: "arrow.triangle.2.circlepath"
        case .phonemeDrill: "waveform"
        case .vocabulary: "text.book.closed.fill"
        case .shadowing: "waveform.badge.mic"
        case .conversation: "bubble.left.and.bubble.right.fill"
        }
    }
}
