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
///
/// ⚠️ 2026-09-24（用户报障「点了徽章之后悬浮气泡不显示了」）：原生 `.help` 的气泡
/// 由 AppKit 的悬浮状态机管理 —— **点击之后鼠标不移出再移回，气泡就不再弹出**。
/// 自绘悬浮卡不依赖那台状态机：鼠标在就显示、离开就收，点击前后行为一致。
/// 面板底走 `panel`、描边走 `columnDivider`（浮层语义色，日夜切换不漏）。
struct StreakBadgeView: View {

    @Environment(\.forestTheme) private var theme

    let badge: TodayPanel.StreakBadge
    /// 点一下去哪儿（侧栏传 `AppState.openAnnualRecapInProgress`）。
    var onTap: () -> Void = {}

    /// 自绘悬浮卡开关。`.onHover` 直接驱动 —— 不经过 AppKit 的 tooltip 状态机。
    @State private var showsTip = false
    /// 测试钩子（**只在离屏渲染用例里置 true**）：hover 路径离屏搭不出来，
    /// 出图要直接把悬浮卡点亮，量它的墨。
    var previewShowsTip = false

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
        .onHover { hovering in
            showsTip = hovering
        }
        // 悬浮卡挂在胶囊**下方**（徽章在侧栏最顶上，往上放会出窗）。
        // overlay 允许画出自身边界之外，压在导航列表上；不参与命中，不抢点击。
        .overlay(alignment: .bottom) {
            if showsTip || previewShowsTip {
                tipCard
                    .fixedSize()
                    .offset(y: tipCardEstimatedHeight)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .accessibilityLabel(
            "\(TodayPanel.streakGuardLine(badge))，点按查看年度学习记录"
        )
    }

    /// 悬浮卡说两件事：断签保护那句 + 点它能去哪（与旧 `.help` 文案一致）。
    private var tipCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(TodayPanel.streakGuardLine(badge))
                .foregroundStyle(theme.primaryText)
            Text("点一下看整年的学习记录")
                .foregroundStyle(theme.secondaryText)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.panel)
                .shadow(color: .black.opacity(theme.isNight ? 0.4 : 0.14), radius: 5, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.columnDivider, lineWidth: 1)
        )
    }

    /// 徽章胶囊高（约 21）+ 间隙：把悬浮卡从胶囊底边挪下去一点。
    private var tipCardEstimatedHeight: CGFloat { 27 }
}
