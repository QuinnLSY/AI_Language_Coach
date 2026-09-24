import AIDomain
import SwiftUI

/// 「描述场景」浮层：一句话 → 一次请求生成一个能直接开练的情景（⑦）。
///
/// 与「上传材料」的分工：那个是**有原文**（把一篇课文拆成情景 + 跟读句 + 生词表），
/// 这个是**没原文**（描述一句你想要的场景，让老师替你把它搭出来）。
/// 两者共用同一套键值行约定与「一次操作 = 一次请求」的纪律。
struct ScenarioComposerSheet: View {

    @Bindable var state: AppState
    var onClose: () -> Void
    @Environment(\.forestTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("用一句话说说你想练什么。老师会把它变成一个能直接开练的情景：一句开场白、几句你要说的话（练完逐句核对说没说到）、一批这个场景该用上的词（自动收进词汇本）。")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    editor
                    examples
                    actionRow

                    if let notice = state.scenarioResult {
                        resultBanner(notice)
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(theme.surfaceAlt)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("描述场景")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("一句话 → 一个能开练的情景")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.hover))
            }
            .buttonStyle(.appPressable)
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
    }

    // MARK: - 输入区

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { state.scenarioPromptText },
                set: { state.scenarioPromptText = $0 }
            ))
            .font(.system(size: 12, design: .rounded))
            .scrollContentBackground(.hidden)
            .foregroundStyle(theme.primaryText)
            .frame(height: 104)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.surfaceAlt.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.divider, lineWidth: 1)
            )
            .accessibilityLabel("情景描述输入框")

            if state.scenarioPromptText.isEmpty {
                Text("比如：在咖啡店点一杯拿铁，想换成燕麦奶")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 示例 chip：点一下填进输入框（用户可以直接改，不用从零想）。
    private var examples: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("试试这些")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
            FlowRow(spacing: 6, lineSpacing: 6, wrapsLongItems: true) {
                ForEach(ScenarioDraftRule.examples, id: \.self) { example in
                    Button {
                        state.scenarioPromptText = example
                    } label: {
                        Text(example)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(theme.accent.opacity(0.10)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.appPressable)
                    .help("用这个描述")
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            if let issue = ScenarioDraftRule.inputIssue(for: state.scenarioPromptText) {
                Text(issueText(issue))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }

            Button {
                Task { await state.generateScenarioFromPrompt() }
            } label: {
                HStack(spacing: 5) {
                    if state.isGeneratingScenario {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars").font(.system(size: 10, weight: .bold))
                    }
                    Text(state.isGeneratingScenario ? "生成中…" : "生成情景")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(theme.onAccentFill)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(theme.accentFill))
                .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .disabled(
                state.isGeneratingScenario
                    || ScenarioDraftRule.inputIssue(for: state.scenarioPromptText) != nil
            )
            .help("一次生成 = 一次模型请求")
        }
    }

    private func resultBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.lastGeneratedScenarioDraft != nil
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(state.lastGeneratedScenarioDraft != nil ? theme.accent : theme.warning)
            Text(notice)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                state.dismissScenarioResult()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.appPressable)
            .accessibilityLabel("关闭提示")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.6))
        )
    }

    private func issueText(_ issue: ScenarioDraftRule.InputIssue) -> String {
        switch issue {
        case .empty:
            "还没有写描述"
        case .tooShort(let actual):
            "再写具体一点（\(actual)/\(ScenarioDraftRule.minimumLength) 字）"
        case .tooLong(let actual):
            "太长了（\(actual)/\(ScenarioDraftRule.maximumLength) 字）"
        }
    }
}
