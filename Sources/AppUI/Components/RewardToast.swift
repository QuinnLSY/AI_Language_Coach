import AIDomain
import SwiftUI

/// 情景结算提示条：浮在界面顶部，显示「+N 星 / 通关」与一句话反馈。
/// 纯展示组件——数据来自 `ScenarioReward`，点击叉可直接收起。
struct RewardToast: View {

    @Environment(\.forestTheme) private var theme
    let reward: ScenarioReward
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: reward.didCompleteLevel ? "flag.checkered" : "star.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                if let levelTitle = reward.levelTitle {
                    Text("\(levelTitle)\(reward.didCompleteLevel ? " · 已通关" : "")")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                Text(reward.message)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            }

            if reward.stars > 0 {
                Text(String(repeating: "⭐️", count: reward.stars))
                    .font(.system(size: 12))
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.appPressable)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(theme.panel)
                .shadow(color: theme.shadow, radius: 14, x: 0, y: 6)
        )
        .overlay(Capsule().strokeBorder(theme.divider, lineWidth: 1))
    }
}
