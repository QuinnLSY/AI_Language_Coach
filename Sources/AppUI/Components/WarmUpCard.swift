import AIDomain
import SwiftUI

/// 碎片热身卡（⑦-B②）：空态里「不知道从哪儿开始」的那一答。
///
/// 三种样子，由入参决定、本视图不做任何判断之外的编排：
/// - `progress == nil` 且 `plan` 非空 → **入口卡**（「来一轮热身 · 3 个到期词 · 约 1 分 29 秒」）；
/// - `progress` 在走 → **流程卡**（一步一屏，每步只给这一步用得上的按钮）；
/// - `progress` 走完 → **结算卡**（「记得 2/3 · 用时 1 分 12 秒」）。
///
/// 为什么单独成组件（与 `KickoffRow` 同款理由）：空态那一屏里已经叠了问候与话题卡，
/// 再塞一整段流程进去，整页离屏看不出它到底画没画出来；单独组件才能做针对性回归。
///
/// ⚠️ 卡片上的每个数字都**来自入参**，这里不做任何「差不多」的兜底：
/// 步骤构成、预计用时、记得几个、用时多久，全在 `AIDomain/WarmUp` 算好。
struct WarmUpCard: View {

    @Environment(\.forestTheme) private var theme

    /// 没在跑时展示的那一轮（nil = 一步都排不出来，整块不画、不留空壳）。
    var plan: WarmUpPlan? = nil
    /// 正在跑 / 已跑完的那一轮。
    var progress: WarmUpProgress? = nil
    /// 这一步的提示（麦克风打不开 / 没听清这类），带「重试」。
    var notice: AppNotice? = nil
    /// 这一步刚读出来的发音分（按「继续」之前先摆出来给人看一眼）。
    var stepScore: Double? = nil
    /// 这一步听到的原话。
    var heardText: String? = nil
    var isRecording = false
    /// 识别 / 评分在跑（这段窗口里不给再按录音）。
    var isBusy = false

    var onStart: () -> Void = {}
    var onGrade: (Bool) -> Void = { _ in }
    var onPlaySentence: () -> Void = {}
    var onToggleRecording: () -> Void = {}
    var onContinue: () -> Void = {}
    var onSkip: () -> Void = {}
    var onSendSpoken: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onDismissNotice: () -> Void = {}

    /// 与话题卡同宽：两摞卡在空态里对齐，鼠标不用横穿半屏。
    ///
    /// ⚠️ 同上限不是定宽：聊天区最窄 340，定宽 360 会溢出。
    /// 宽容器里仍是 360，窄容器里收起来贴边。
    static let width: CGFloat = 360

    var body: some View {
        if let progress {
            if progress.isFinished {
                settlement(progress.summary(now: Date()))
            } else if let step = progress.currentStep {
                running(progress: progress, step: step)
            } else {
                EmptyView()
            }
        } else if let plan, !plan.isEmpty {
            entry(plan)
        } else {
            EmptyView()
        }
    }

    // MARK: - ① 入口卡

    private func entry(_ plan: WarmUpPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("碎片热身")
                .appFont(11, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.secondaryText)

            Button { onStart() } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "flame.fill")
                        .appFont(12)
                        .foregroundStyle(theme.accent)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("来一轮热身")
                            .appFont(12, weight: .semibold, design: .rounded)
                            .foregroundStyle(theme.primaryText)
                        Text(plan.compositionText)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 6)

                    Text("约 \(plan.estimateText)")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }
                .appPadding(.horizontal, 12)
                .appPadding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .warmUpSurface(theme)
            }
            // ⚠️ 不写 `.buttonStyle(.plain)`：按压反馈由 MainView 根上那一行统一注入，
            // 自己包一层 `.plain` 会把它盖掉（`MotionTokenWiringTests` 钉着这条）。
        }
        .frame(maxWidth: Self.width)
        .accessibilityElement(children: .contain)
    }

    // MARK: - ② 流程卡

    private func running(progress: WarmUpProgress, step: WarmUpStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("碎片热身")
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                Text("第 \(progress.stepNumber) / \(progress.plan.total) 步")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                Button {
                    onSkip()
                } label: {
                    Text("跳过")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .appFont(11, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                    Text(step.text)
                        .appFont(14, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                controls(for: step)
            }
            .appPadding(.horizontal, 12)
            .appPadding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .warmUpSurface(theme)

            if let notice {
                NoticeBanner(notice: notice) { onDismissNotice() }
            }
        }
        .frame(maxWidth: Self.width)
        .accessibilityElement(children: .contain)
    }

    /// 每一步只给这一步用得上的按钮 —— 认词就两个判分键，
    /// 读句子才有听示范与录音。
    @ViewBuilder
    private func controls(for step: WarmUpStep) -> some View {
        switch step.kind {
        case .word:
            HStack(spacing: 8) {
                pill("记得", systemImage: "checkmark", tint: theme.success) { onGrade(true) }
                pill("忘了", systemImage: "xmark", tint: theme.danger) { onGrade(false) }
            }

        case .shadow:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    pill("听示范", systemImage: "speaker.wave.2", tint: theme.accent) { onPlaySentence() }
                    pill(
                        isRecording ? "说完了" : "读一遍",
                        systemImage: isRecording ? "stop.fill" : "mic.fill",
                        tint: theme.accent
                    ) { onToggleRecording() }
                    .disabled(isBusy)
                }
                if isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在听你刚才那遍…")
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                if let score = stepScore {
                    resultRow("这一遍 \(Int(score.rounded())) 分")
                }
            }

        case .speak:
            VStack(alignment: .leading, spacing: 8) {
                pill(
                    isRecording ? "说完了" : "说这句",
                    systemImage: isRecording ? "stop.fill" : "mic.fill",
                    tint: theme.accent
                ) { onToggleRecording() }
                .disabled(isBusy)
                if isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在听你刚才那遍…")
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                if let heardText, !heardText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("听到的是：\(heardText)")
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(2)
                        pill("就这句，继续", systemImage: "arrow.right", tint: theme.accent) { onContinue() }
                    }
                }
            }
        }
    }

    /// 跟读读完那一遍的分数 + 「继续」。分数得先摆出来看一眼，不给自动跳。
    private func resultRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .appFont(11, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 0)
            pill("继续", systemImage: "arrow.right", tint: theme.accent) { onContinue() }
        }
    }

    // MARK: - ③ 结算卡

    private func settlement(_ summary: WarmUpSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .appFont(12)
                    .foregroundStyle(theme.success)
                Text("热身完成")
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(summary.headline)
                    .appFont(14, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Text(summary.detail)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                if let spoken = summary.spokenText, !spoken.isEmpty {
                    Text("你说的是：\(spoken)")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let spoken = summary.spokenText, !spoken.isEmpty {
                        pill("发给老师", systemImage: "paperplane.fill", tint: theme.accent) { onSendSpoken() }
                    }
                    pill("完成", systemImage: nil, tint: theme.secondaryText) { onDismiss() }
                }
            }
            .appPadding(.horizontal, 12)
            .appPadding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .warmUpSurface(theme)
        }
        .frame(maxWidth: Self.width)
        .accessibilityElement(children: .contain)
    }

    // MARK: - 按钮

    /// 一颗胶囊按钮。
    ///
    /// ⚠️ 刻意**不写** `.buttonStyle(.plain)`：按压反馈由 MainView 根上的
    /// `.buttonStyle(.appPressable)` 统一注入（见 `AppButtonStyle` 的说明）。
    private func pill(
        _ title: String,
        systemImage: String?,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .appFont(10)
                }
                Text(title)
                    .appFont(11, weight: .semibold, design: .rounded)
            }
            .appPadding(.horizontal, 10)
            .appPadding(.vertical, 6)
            .foregroundStyle(tint)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(tint.opacity(0.35), lineWidth: 0.5)
                    )
            )
        }
    }
}

// MARK: - 卡面

/// 三张卡共用的一张卡面（圆角 + 表面色 + 半像素描边）。
///
/// 抽出来只为「改配色只改一处」：三处各写一份的话，改描边时一定会漏掉其中一个，
/// 症状是「入口卡换了描边，结算卡还是旧的」—— 看着像两张不同的卡。
private extension View {
    func warmUpSurface(_ theme: ForestTheme) -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.divider, lineWidth: 0.5)
                )
        )
    }
}
