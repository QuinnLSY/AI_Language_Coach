import SwiftUI

/// 考场条的数据快照。
///
/// 视图**不自己算时间**：倒计时剩余秒数由 `deadline` 与当前时刻推出来，
/// 题号、限时、期望词数都由 `AppState` 从考卷算好 —— 同一件事只有一个地方在算。
/// 考场条的数据快照。
///
/// 视图**不自己算时间**：倒计时剩余秒数由 `deadline` 与当前时刻推出来，
/// 题号、限时、期望词数都由 `AppState` 从考卷算好 —— 同一件事只有一个地方在算。
///
/// `public` 是因为它是 `AppState`（public）暴露给视图的一层数据形状，
/// 与 `ExamReport`、`DailyPlan` 同类；它不含任何行为，也没有第二份实现。
public struct ExamBarModel: Equatable, Sendable {
    public var title: String
    public var stageTitle: String
    public var instructions: String
    public var questionNumber: Int
    public var totalQuestions: Int
    public var minimumWords: Int
    public var limitSeconds: Int
    /// 当前这一问的截止时刻；nil = 考官还没把题问出来，不计时。
    public var deadline: Date?
    /// 当前这一问的唯一键（题号 + 起表时刻）：`.task(id:)` 靠它换一次计时任务。
    public var questionKey: String

    public init(
        title: String,
        stageTitle: String,
        instructions: String,
        questionNumber: Int,
        totalQuestions: Int,
        minimumWords: Int,
        limitSeconds: Int,
        deadline: Date?,
        questionKey: String
    ) {
        self.title = title
        self.stageTitle = stageTitle
        self.instructions = instructions
        self.questionNumber = questionNumber
        self.totalQuestions = totalQuestions
        self.minimumWords = minimumWords
        self.limitSeconds = limitSeconds
        self.deadline = deadline
        self.questionKey = questionKey
    }
}

/// 考场条：题号进度 + 倒计时 + 跳过 / 结束考试。
///
/// 它替代了普通练习里的「情景胶囊 + 目标条」—— 考场上学员只需要知道
/// 三件事：**现在第几题、还剩多久、怎么结束**。其余信息都是干扰。
struct ExamSessionBar: View {

    @Environment(\.forestTheme) private var theme
    let model: ExamBarModel
    /// 倒计时到点（由视图按 deadline 睡到点后回调，状态判断在 AppState 里）。
    var onTimeout: () -> Void = {}
    var onSkip: () -> Void = {}
    var onFinish: () -> Void = {}

    /// 剩余时间进入这个秒数后换成警示色。
    private let warningSeconds = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            topRow
            if !model.instructions.isEmpty {
                Text(model.instructions)
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 16)
        .appPadding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accent.opacity(0.07))
        // 一条顶边：与「普通练习」的对话区一眼区分开（考场上这点区分很重要）。
        .overlay(alignment: .top) {
            Rectangle().fill(theme.accent.opacity(0.45)).frame(height: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("考试模式：\(model.title)，第 \(model.questionNumber) 问，共 \(model.totalQuestions) 问")
        // ⚠️ 计时任务挂在**题号 + 起表时刻**上：只用题号的话，
        // 同一题起表前后（考官还在生成 → 题目出现）不会重启，
        // 学员会看到一个永远不走的倒计时。
        .task(id: model.questionKey) {
            guard let deadline = model.deadline else { return }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            onTimeout()
        }
    }

    private var topRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .appFont(12, weight: .semibold)
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    Text("第 \(model.questionNumber)/\(model.totalQuestions) 问")
                        .appFont(11, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.accent)
                    if !model.stageTitle.isEmpty {
                        Text(model.stageTitle)
                            .appFont(10, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            if model.minimumWords > 0 {
                chip("至少 \(model.minimumWords) 词")
            }
            if model.limitSeconds > 0 {
                chip("限时 \(model.limitSeconds) 秒")
            }

            countdown

            Button(action: onSkip) {
                Text("跳过")
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .appPadding(.vertical, 5)
                    .background(Capsule().fill(theme.hover))
                    .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .help("跳过这一题，直接进入下一问")
            .accessibilityLabel("跳过这一题")

            Button(action: onFinish) {
                Text("结束考试")
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.onAccentFill)
                    .padding(.horizontal, 11)
                    .appPadding(.vertical, 5)
                    .background(Capsule().fill(theme.accentFill))
                    .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .help("提前交卷并看参考分")
            .accessibilityLabel("结束考试并查看报告")
        }
    }

    /// 倒计时：没起表时给「等待考官提问」，起表后逐秒走。
    @ViewBuilder
    private var countdown: some View {
        if let deadline = model.deadline {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let remaining = max(Int(deadline.timeIntervalSince(context.date).rounded(.up)), 0)
                Text(Self.clock(remaining))
                    .appFont(13, weight: .bold, design: .rounded)
                    // ⚠️ 黄（accent）不能当实心底，但**可以当文字色** ——
                    // 这里正是文字/图标那一档的用法。
                    .foregroundStyle(tint(remaining))
                    .monospacedDigit()
                    .frame(minWidth: 46, alignment: .trailing)
                    .accessibilityLabel("剩余 \(remaining) 秒")
            }
        } else {
            Text("等待考官提问…")
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func tint(_ remaining: Int) -> Color {
        remaining <= warningSeconds ? theme.danger : theme.primaryText
    }

    /// 秒 → `0:45` / `1:20`。
    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .appFont(10, design: .rounded)
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 7)
            .appPadding(.vertical, 3)
            .background(Capsule().fill(theme.hover))
    }
}
