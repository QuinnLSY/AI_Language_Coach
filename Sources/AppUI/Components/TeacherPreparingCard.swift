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

    let teacherKind: AnimalKind
    /// 计时起点。默认 = 本视图创建时刻；留成参数是为了离屏渲染能把它固定下来。
    var startedAt: Date = Date()

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
            // 读屏读「老师正在准备，已等待 N 秒」这一整句，而不是把跳动的点也念一遍。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TeacherWaitCopy.title(seconds: seconds))
        }
    }
}
