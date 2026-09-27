import AIDomain
import SwiftUI

/// 改错练习卡：把记忆里「反复犯的错」摆成一道能改的题。
///
/// 为什么单独做一张卡而不是在记忆卡里就地改：练习是**有状态的流程**
/// （第几题、刚才那道判得怎样、走完要给结算），塞进一张只负责展示的记忆卡，
/// 会把「老师记住了你什么」和「你现在在做什么」搅在一起。
///
/// ⚠️ 判分与推进分成两步：交完答案**停在这一题**给出回执，用户点「下一处」才走。
/// 一交就跳到下一题，等于没告诉他错在哪 —— 那这一题就白练了。
public struct ErrorDrillCard: View {

    @Environment(\.forestTheme) private var theme

    private let session: ErrorDrillSession
    /// 刚判的那一题（nil = 正在答题）。
    private let lastOutcome: ErrorDrillSession.Outcome?
    private let onSubmit: (String) -> Void
    private let onAdvance: () -> Void
    private let onCancel: () -> Void

    @State private var answer = ""
    @FocusState private var isFieldFocused: Bool

    public init(
        session: ErrorDrillSession,
        lastOutcome: ErrorDrillSession.Outcome?,
        onSubmit: @escaping (String) -> Void,
        onAdvance: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.session = session
        self.lastOutcome = lastOutcome
        self.onSubmit = onSubmit
        self.onAdvance = onAdvance
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let outcome = lastOutcome {
                feedback(outcome)
            } else if let error = session.current {
                prompt(error)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .appElevation(.card)
        )
        // 换题时把上一题的答案清掉 —— 留着会让人以为「这题我已经写过了」。
        .onChange(of: session.index) { answer = ""; isFieldFocused = true }
        .onAppear { isFieldFocused = true }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(theme.accent)
            Text("改错练习")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text("\(session.progress.done + 1) / \(session.progress.total)")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 8)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appPressable)
            .help("收起（已经判过的题会记进练习进度）")
        }
    }

    // MARK: - 答题

    private func prompt(_ error: RecurringError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sentence(error.original, tint: theme.danger)
            Text("把它改成正确的说法（大小写和标点不影响判定）")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.secondaryText)
            if error.count > 1 {
                Text("这处错你犯过 \(error.count) 次")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.warning)
            }
            HStack(spacing: 8) {
                TextField("", text: $answer)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.surfaceAlt)
                    )
                    .focused($isFieldFocused)
                    .onSubmit { commit() }
                actionButton("提交", isDisabled: answer.isBlank) { commit() }
            }
        }
    }

    // MARK: - 回执

    private func feedback(_ outcome: ErrorDrillSession.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = session.previous {
                sentence(error.original, tint: theme.secondaryText)
            }
            HStack(spacing: 6) {
                Image(systemName: outcome.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(outcome.isCorrect ? theme.success : theme.danger)
                Text(outcome.isCorrect ? "改对了" : "还差一点")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(outcome.isCorrect ? theme.success : theme.danger)
            }
            if !outcome.isCorrect {
                labelled("正确答案", session.previous?.corrected ?? "")
                // 只在真写错了才摆出「你写的」：空答案再展示一遍没意义，
                // 只会让人觉得界面在重复他刚刚的失败。
                if !outcome.answer.isBlank {
                    labelled("你写的", outcome.answer, tint: theme.danger)
                }
            }
            if let note = session.previous?.explanation, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            HStack {
                Spacer(minLength: 0)
                actionButton("下一处", isDisabled: false, action: onAdvance)
            }
        }
    }

    // MARK: - 零件

    private func sentence(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func labelled(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(tint ?? theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionButton(_ title: String, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isDisabled ? theme.secondaryText : .white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    Capsule().fill(isDisabled ? theme.surfaceAlt : theme.accent)
                )
        }
        .buttonStyle(.appPressable)
        .disabled(isDisabled)
    }

    private func commit() {
        guard !answer.isBlank else { return }
        onSubmit(answer)
    }
}

private extension String {
    /// 只有空白的答案不算答案（防「敲一串空格也算交了」）。
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
