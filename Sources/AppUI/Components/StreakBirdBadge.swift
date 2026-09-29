import AIDomain
import SwiftUI

/// 中间栏的连胜飞鸟（批次三）：连胜天数 ≥1 时停在对话区顶栏，点击跳年度学习记录。
///
/// 动效预算**全场最低**（设计拍板）：平时**完全静止**——没有循环动画、没有呼吸感，
/// 只在「连胜 +1」的那一刻扑一次翅膀（一次性的 spring 回落，走 `.app(.panel)` token）。
/// 断签风险态（今天还没练）不庆祝：颜色换警示档、也不扑翅——催促的时候别蹦跶。
struct StreakBirdBadge: View {

    @Environment(\.forestTheme) private var theme
    let badge: TodayPanel.StreakBadge
    var onTap: (() -> Void)? = nil

    /// 扑翅触发器：连胜天数变化且**变大**时置 true，spring 回落后自动收回。
    @State private var isFlapping = false

    private var tint: Color { badge.isAtRisk ? theme.warning : theme.streak }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 5) {
                bird
                Text("\(badge.days) 天")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.appPressable)
        .help(badge.isAtRisk ? TodayPanel.streakGuardLine(badge) : "已连续学习 \(badge.days) 天，点按查看年度学习记录")
        // 批次七 · G：读屏听到的要是有语义的一句话，不是孤零零「7 天」。
        .accessibilityLabel(Self.voiceOverLine(badge: badge))
        .accessibilityHint("查看年度学习记录")
        // 连胜 +1：扑一次翅膀庆祝（一次性，平时静止——动效预算最低）
        .onChange(of: badge.days) { oldValue, newValue in
            guard newValue > oldValue, !badge.isAtRisk else { return }
            withAnimation(.app(.panel)) { isFlapping = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.6))
                withAnimation(.app(.panel)) { isFlapping = false }
            }
        }
    }

    /// 连胜徽章的读屏一句话（文案唯一出处见 `AccessibilityLines.streakLine`，可单测）。
    static func voiceOverLine(badge: TodayPanel.StreakBadge) -> String {
        AccessibilityLines.streakLine(badge: badge)
    }

    // MARK: - 小鸟（纯矢量，随徽章缩放）

    private var bird: some View {
        ZStack {
            // 身体（飞行姿态的椭圆）
            Ellipse()
                .fill(tint)
                .frame(width: 14, height: 9)
            // 尾羽
            Triangle()
                .fill(tint)
                .frame(width: 7, height: 6)
                .rotationEffect(.degrees(-140))
                .offset(x: -9, y: 0)
            // 喙（品牌橘——不新增 hex，从主题取）
            Triangle()
                .fill(theme.accent)
                .frame(width: 5, height: 4)
                .rotationEffect(.degrees(90))
                .offset(x: 8.5, y: -1)
            // 眼睛
            Circle()
                .fill(.white)
                .frame(width: 2.6, height: 2.6)
                .offset(x: 4.5, y: -1.5)
            // 翅膀（扑翅时向上抬起）
            Ellipse()
                .fill(tint)
                .frame(width: 9, height: 4.5)
                .rotationEffect(.degrees(isFlapping ? -38 : 12), anchor: .trailing)
                .offset(x: -1, y: isFlapping ? -5 : -2)
        }
        .frame(width: 22, height: 16)
        .offset(y: isFlapping ? -1.5 : 0)
    }
}
