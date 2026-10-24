import SwiftUI
import AIDomain

// #661 自 TreeCanvas.swift 拆出（2026-10-24）：原文件 2812 行、21 个类型混居，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。

// MARK: - 正文 / 课程关卡之间的云带（③）

/// 云带：三片大小不一的云，标示「往上走进入了更高的闯关」。
///
/// ⚠️ 为什么是云而不是一道横线或一条虚线：树本身就是一根垂直的枝干，
/// 横向的线会被读成「又一棵树干的分界」；云是**天空**的东西，
/// 它说的是「过了这层就是另一片天」—— 正好是「树冠之上还有一层」这件事。
struct CourseCloudBand: View {

    let theme: ForestTheme

    /// 云带占多高（只影响留白与摆位，不影响云的大小）。
    static let bandHeight: CGFloat = 96

    /// 三片云：横向位置（0…1 相对面板宽）、大小、浓淡。
    /// ⚠️ 浓淡要**不均匀**：三朵一样浓会读成一条横杠，读不出「云」。
    /// ⚠️ 颜色跟随 `primaryText` 的淡色，**不能用白色**：树面板在日间是接近白的底，
    /// 白云画上去等于没画（实测：只有压在树干上的那一小块露出来，成了一团灰影）。
    /// 跟随文字色则日夜两套底色下都自带对比 —— 日间是淡墨、夜间是淡光。
    private let puffs: [(x: CGFloat, scale: CGFloat, opacity: Double)] = [
        (0.17, 0.78, 0.10),
        (0.38, 1.00, 0.15),
        (0.63, 0.86, 0.11),
        (0.84, 0.68, 0.09),
    ]

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(puffs.enumerated()), id: \.offset) { _, puff in
                Image(systemName: "cloud.fill")
                    .appFont(52 * puff.scale, weight: .regular)
                    .foregroundStyle(theme.primaryText.opacity(puff.opacity))
                    .position(x: proxy.size.width * puff.x, y: proxy.size.height / 2)
            }
        }
    }
}

// MARK: - 关卡节点

struct LevelNode: View {
    let level: TreeLevel
    let theme: ForestTheme
    let isCurrent: Bool
    /// 对应情景与主线任务进度（没绑定情景时为 nil）。
    let note: TreeLevelNote?

    var body: some View {
        ZStack {
            if isCurrent {
                Circle()
                    .stroke(theme.accent, lineWidth: 3)
                    .frame(width: 76, height: 76)
                    .scaleEffect(isCurrent ? 1.0 : 0.9)
            }

            Circle()
                .fill(fill)
                .frame(width: 58, height: 58)
                .overlay(
                    Circle()
                        .strokeBorder(
                            border,
                            // ③ 课程关卡用虚线圈：颜色之外再加一道形状差，
                            // 色弱用户与深浅两套主题下都分得出来。
                            style: StrokeStyle(
                                lineWidth: 2.5,
                                dash: level.isAboveCurriculum ? [5, 4] : []
                            )
                        )
                )
                .shadow(color: theme.shadow, radius: 6, x: 0, y: 3)

            VStack(spacing: 2) {
                if level.state == .locked {
                    Image(systemName: "lock.fill")
                        .appFont(15, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Image(systemName: iconName)
                        .appFont(15, weight: .semibold)
                        .foregroundStyle(iconColor)
                }
                Text("\(level.earnedStars)/\(level.requiredStars)")
                    .appFont(9, weight: .bold, design: .rounded)
                    .foregroundStyle(iconColor.opacity(0.9))
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 1) {
                Text(level.title)
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Text(level.subtitle)
                    .appFont(9, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                // 需求 2：这一格对应哪个情景、主线任务做到哪 —— 一句话说清两者的关系。
                if let note {
                    Text(note.summaryLine)
                        .appFont(9, weight: .medium, design: .rounded)
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .fixedSize()
            .offset(y: 46)
        }
        // 绑定了情景的关卡：挂一个小对话标，提示「点它就是进情景练」
        .overlay(alignment: .topTrailing) {
            if level.scenarioID != nil {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .appFont(8, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(theme.accentAlt))
                    .offset(x: 4, y: -4)
            }
        }
        // 批次七 · G：关卡点是 onTapGesture，默认不在 VoiceOver 树里 ——
        // 不补这一段，读屏用户既看不见关卡也进不了练习。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.voiceOverLine(level: level, note: note))
        .accessibilityAddTraits(level.state == .locked ? [] : [.isButton])
        .accessibilityHint(Self.voiceOverHint(isLocked: level.state == .locked))
    }

    /// 关卡节点的读屏提示（文案唯一出处见 `AccessibilityLines.levelHint`）。
    static func voiceOverHint(isLocked: Bool) -> String {
        AccessibilityLines.levelHint(isLocked: isLocked)
    }

    /// 关卡节点的读屏一句话（文案唯一出处见 `AccessibilityLines.levelLine`，可单测）。
    ///
    /// ③ 课程关卡补一句「AI 排的课」：读屏用户看不到虚线圈与冷色描边，
    /// 不说就与正文关卡完全一样 —— 视觉上的区分对读屏用户不存在。
    static func voiceOverLine(level: TreeLevel, note: TreeLevelNote?) -> String {
        let base = AccessibilityLines.levelLine(level: level, note: note)
        guard level.isAboveCurriculum else { return base }
        return "AI 排的课 · " + base
    }

    private var fill: Color {
        switch level.state {
        case .locked: theme.surfaceAlt
        case .unlocked: theme.surface
        case .inProgress: theme.accent.opacity(0.9)
        case .completed: Color(hex: 0x8FD694)
        }
    }

    private var border: Color {
        // ③ AI 排的课里的一节：**描边换成冷色 + 虚线**，一眼与正文关卡分开。
        // 判据是 `isAboveCurriculum`（高度 > 1 这个**数据**），不是 id 前缀。
        if level.isAboveCurriculum { return theme.accentCool }
        return level.state == .locked ? theme.divider : theme.accentAlt
    }

    private var iconName: String {
        // 课程关卡用「路线」图标，与课卡、情景卡（对话气泡 / sparkles）同一套来源识别。
        if level.isAboveCurriculum { return CourseBlueprintRule.icon }
        switch level.state {
        case .completed: return "star.fill"
        case .inProgress: return "flame.fill"
        default: return "leaf.fill"
        }
    }

    private var iconColor: Color {
        level.state == .inProgress ? .white : theme.primaryText
    }
}

