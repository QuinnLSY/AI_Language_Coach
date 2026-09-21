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
///
/// ⚠️ 2026-09-21（用户口径「徽章可以点击跳转到学习记录的年度记录卡片处」）：整枚做成按钮。
/// 「连续 N 天」这个数字的上下文全在**年度学习记录卡**上（整年的练习热力图 + 达成天数），
/// 点它就该直接看到那一年。做法上只是外面套一层 `Button`，**尺寸与配色一律不动**：
/// 它跟「语林」标题同处一行，多一个内边距就会把标题挤歪。
struct StreakBadgeView: View {

    @Environment(\.forestTheme) private var theme

    let badge: TodayPanel.StreakBadge
    /// 点一下去哪儿（侧栏传 `AppState.openAnnualRecapInProgress`）。
    var onTap: () -> Void = {}

    private var tint: Color { badge.isAtRisk ? theme.warning : theme.streak }

    var body: some View {
        Button(action: onTap) {
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
            // ⚠️ 命中区必须是整枚胶囊：胶囊里的文字有墨、周围那圈淡底没有 ——
            // 少了这一句就变成「点在边上没反应」。
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // 提示里两件事都要说：断签保护那句（悬停给的是「怎么保住 N 天」）+ 点它能去哪。
        .help(TodayPanel.streakGuardLine(badge) + "\n点一下看整年的学习记录")
        .accessibilityLabel(
            "\(TodayPanel.streakGuardLine(badge))，点按查看年度学习记录"
        )
    }
}
