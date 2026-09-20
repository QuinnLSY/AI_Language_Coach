import AIDomain
import SwiftUI

/// 首屏打卡徽章：「🔥 N 天」一颗胶囊，挂侧栏头部 —— 连续天数**提到台前**。
///
/// 两态（断签保护的核心表达，颜色全走主题令牌，不写死 hex）：
/// - 安全（今天已练）：`streak` 红 —— 常态；
/// - 危（今天还没练）：`warning` —— 连续纪录今天随时会断，悬停能看到怎么保住。
///
/// ⚠️ 09-21 改色（用户：「logo 右边的火苗及内外框改成红色」）：安全态原来是 `accent`
/// （黄/橘），现在整枚走 `streak` 红 —— **图标 + 「N 天」文字 + 描边 + 淡底一起改**，
/// 用户要的是「整枚全红」，只改图标会留下半枚橘色的徽章。
/// 风险态仍留 `warning`：它是「两态还要分得开」的唯一手段（与红 ΔE 24.1）。
///
/// ⚠️ 主题纪律：`streak`/`warning` 都只做**文字/图标/描边/淡底**（opacity ≤ 0.16），
/// 绝不当实心底；徽章不改尺寸、不加发光 —— 它嵌在头部一行里，动布局会挤歪「语林」标题。
struct StreakBadgeView: View {

    @Environment(\.forestTheme) private var theme

    let badge: TodayPanel.StreakBadge

    private var tint: Color { badge.isAtRisk ? theme.warning : theme.streak }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("\(badge.days) 天")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(badge.isAtRisk ? 0.85 : 0.4), lineWidth: 1))
        .help(TodayPanel.streakGuardLine(badge))
        .accessibilityLabel(TodayPanel.streakGuardLine(badge))
    }
}
