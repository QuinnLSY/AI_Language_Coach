import AIDomain
import SwiftUI

/// 「老师正在准备」等待卡：开场白生成 / 启动装配期间对话区里的**明确等待态**。
///
/// 为什么单独一张卡：这段时间里 `streamingText` 一直是空的（开场白不流式），
/// 原来只能落在「三个跳动的点」那个兜底分支上 —— 与普通回复的思考态长得一模一样，
/// 而它偏偏是最长的一次等待（冷启动 30–60s）。等这么久却看不出在等谁、等了多久，
/// 用户只会以为应用死了。
///
/// 纯展示：只收 `teacherKind` 与计时起点，不读全局状态 —— 与 `VocabularyReviewCard`
/// 同款理由，能单独离屏渲染回归，也测得动。
///
/// 计时用 `TimelineView` 而不是 `@State + Timer`：秒数只在**这张卡内部**滚动，
/// 不会每秒把整个 `ChatView`（含整段消息列表）重画一遍。
struct TeacherPreparingCard: View {

    @Environment(\.forestTheme) private var theme
    @Environment(\.appMotion) private var motion

    let teacherKind: AnimalKind
    /// 计时起点。默认 = 本视图创建时刻；留成参数是为了离屏渲染能把它固定下来。
    var startedAt: Date = Date()
    /// 当前真实的等待阶段（装配 → 生成开场白）。**不是按秒数编的**：
    /// `ChatView` 手里有真实信号（`isBooting` / `chat.isGreeting`），分界线不是猜的。
    var stage: TeacherWaitStage = .greeting

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let seconds = max(Int(context.date.timeIntervalSince(startedAt)), 0)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    CuteAnimalView(kind: teacherKind, isSleeping: false, size: 30)
                    Text(TeacherWaitCopy.title(seconds: seconds))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        // 秒数每秒变化：等宽数字，否则整行会随位数抖动。
                        .monospacedDigit()
                    TypingDots(color: theme.secondaryText)
                }
                stageRow
                if let detail = TeacherWaitCopy.detail(seconds: seconds) {
                    Text(detail)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        // 与上一行的文字左边缘对齐（头像宽 30 + 间距 8）。
                        .padding(.leading, 38)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 读屏读「老师正在准备，已等待 N 秒」这一整句 + 当前阶段，而不是把跳动的东西也念一遍。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TeacherWaitCopy.title(seconds: seconds) + "，\(stage.displayName)")
        }
    }

    /// 阶段条：两个真实阶段的点 + 标签，走到哪一步哪个点亮。
    ///
    /// ⚠️ 这一行**常驻**（两个阶段都要显示）：如果只在某个阶段才画，
    /// 阶段切换那一秒卡片会凭空长高/缩短一行 —— 等待 30 秒的人会以为界面又闪了一下。
    private var stageRow: some View {
        HStack(spacing: 14) {
            ForEach(TeacherWaitStage.allCases, id: \.self) { step in
                let reached = step <= stage
                let current = step == stage
                HStack(spacing: 4) {
                    Image(systemName: reached ? "circle.inset.filled" : "circle")
                        .font(.system(size: 7))
                        .foregroundStyle(current ? theme.accent : reached ? theme.secondaryText.opacity(0.6) : theme.secondaryText.opacity(0.3))
                    Text(step.displayName)
                        .font(.system(size: 9, weight: current ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(current ? theme.accent : theme.secondaryText.opacity(current ? 1 : 0.6))
                }
            }
        }
        // 与文字左边缘对齐（头像宽 30 + 间距 8）。
        .padding(.leading, 38)
        .appAnimation(.press, value: stage)
    }
}
