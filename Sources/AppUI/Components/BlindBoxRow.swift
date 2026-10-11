import AIDomain
import SwiftUI

/// 盲盒情景（⑦-B③）：情景面板顶部那一行「不知道练什么？」。
///
/// 单独成组件的理由与 `WarmUpCard` 同款：面板是一整屏滚动内容，
/// 混在里面离屏看不出这一行到底画没画出来；单独组件才能做针对性回归。
///
/// 本视图**不做任何编排**：池子多大、开出什么、按钮叫什么都由
/// `ScenarioBlindBox` 的纯函数给（`poolCount` / `revealed`），
/// 这里只负责画。
///
/// ⚠️ 抽中之后**不替用户开始**：面板的规矩是先看清楚再开始
/// （点卡片先展开任务与重点）。所以抽中的动作是「展开那张卡并滚过去」，
/// 想一步到位再按这一行上的「就练这个」。
struct BlindBoxRow: View {

    @Environment(\.forestTheme) private var theme

    /// 池子里有几个（**真实数字**，副标上原样插出来）。
    var poolCount: Int
    /// 抽中的那条；nil = 还没抽过，或抽中那张卡已经被收起（那时副标回到「从 N 个里挑」）。
    var revealed: BlindBoxEntry?

    var onReveal: () -> Void = {}
    var onStart: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: revealed == nil ? "shuffle.circle.fill" : "gift.fill")
                .appFont(18)
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(theme.surfaceAlt)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("不知道练什么？")
                    .appFont(13, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Text(subtitle)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            // 「就练这个」只在开出来之后才出现：没开之前给一颗进不去的按钮，
            // 点了没反应，比不给更让人怀疑。
            if revealed != nil {
                Button(action: onStart) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").appFont(9, weight: .bold)
                        Text("就练这个")
                            .appFont(12, weight: .semibold, design: .rounded)
                    }
                    .foregroundStyle(theme.onAccentFill)
                    .padding(.horizontal, 14)
                    .appPadding(.vertical, 7)
                    .background(Capsule().fill(theme.accentFill))
                    .contentShape(Capsule())
                }
                // ⚠️ 不写 `.buttonStyle(.plain)`：按压反馈由 MainView 根上统一注入
                //（`MotionTokenWiringTests` 钉着这条）。
                .help("直接开练刚开出来的这个情景")
            }

            Button(action: onReveal) {
                HStack(spacing: 5) {
                    Image(systemName: "shuffle").appFont(10, weight: .semibold)
                    Text(ScenarioBlindBox.buttonTitle(hasRevealed: revealed != nil))
                        .appFont(12, weight: .semibold, design: .rounded)
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 12)
                .appPadding(.vertical, 6)
                .background(Capsule().strokeBorder(theme.accent.opacity(0.5), lineWidth: 1))
                .contentShape(Capsule())
            }
            .help(helpText)
            .accessibilityLabel(helpText)
        }
        .appPadding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    revealed == nil ? theme.divider : theme.accent.opacity(0.6),
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: - 文案

    private var subtitle: String {
        if let revealed {
            return ScenarioBlindBox.revealText(revealed)
        }
        return ScenarioBlindBox.subtitle(poolCount: poolCount)
    }

    /// 悬停与读屏说同一句：**连点一定换一个**（这是这一行唯一需要解释的规则）。
    private var helpText: String {
        revealed == nil
            ? "从 \(poolCount) 个情景里随手挑一个；连点会换一个，不会抽回刚才那个"
            : "换一个，不会抽回刚才这个"
    }
}
