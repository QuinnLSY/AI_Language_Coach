import AIDomain
import SwiftUI

/// 入学定级浮层：出卷 → 逐题作答 → 出结果。
///
/// 三个状态共用一层壳（与「上传材料」浮层同一套版式），内部只切内容：
/// 还没出卷（说明页）/ 正在答题 / 已出结果。
///
/// 三条刻意的界面规则：
/// 1. **答题中不给对错**，也不显示这道题属于哪一档 —— 中途给反馈，量到的就是
///    「看了提示之后的水平」；显示档位则会让人按「这题简单 / 这题难」调心态。
/// 2. **不能回退**，一选即过：能退回去改答案，结果一定偏高。
/// 3. **结果页必须能核对**：逐档摆出「几分之几」，并说清定级停在哪一档 ——
///    只丢一个字母（「你是 B1」）等于让人无条件相信它。
struct PlacementSheet: View {

    @Bindable var state: AppState
    var onClose: () -> Void
    @Environment(\.forestTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    if let outcome = state.placementOutcome {
                        resultView(outcome)
                    } else if state.placementPaper.isEmpty {
                        introView
                    } else {
                        questionView
                    }
                    if let notice = state.placementNotice {
                        noticeBanner(notice)
                    }
                }
                .appPadding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 头

    /// 头部那行小字：说明 / 答题 / 结果三种状态各说各的。
    ///
    /// ⚠️ 结果页**不许**再报「第 N / M 题」：卷子已经判完了，还挂着题号等于
    /// 告诉用户「还有题没做」。这条口径单列成属性，好让测试直接钉住
    ///（像素上量不出文案，`monospacedDigit` 换个字也不会变高度）。
    var headerSubtitle: String {
        if state.placementOutcome != nil {
            return "摸底完成 · 共 \(state.placementPaper.questionCount) 题"
        }
        if state.placementProgressText.isEmpty {
            return "几分钟摸个底，我按你的水平出题"
        }
        return state.placementProgressText
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "figure.walk.arrival")
                .appFont(14)
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("入学定级")
                    .appFont(15, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Text(headerSubtitle)
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .appFont(11, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appPressable)
            .help(state.placementPaper.isEmpty ? "关掉" : "先放一放（进度留着，回来接着答）")
            .accessibilityLabel("关闭入学定级")
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    // MARK: - 说明页

    private var introView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ⚠️ 别用 `**` 想显示粗体：这里的 `Text` 不会把星号当 markdown 解析，
            // 屏幕上会**原样打出两个星号**（离屏出图抓到过一次）。要强调就改 weight。
            Text("这一轮是摸底，不是考试：")
                .appFont(12, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            bullet("一共十来道选择题：认词 + 语法，从入门到自如四档各抽几道")
            bullet("选中就进入下一题，中途不给对错、也不能回头改 —— 那样量出来才准")
            bullet("全在本地判分，不联网、不上传，做完马上给结果")
            bullet("结果只影响「从哪一档开始」，随时可以重测")

            HStack(spacing: 10) {
                Button {
                    Task { await state.startPlacement() }
                } label: {
                    Text("开始摸底")
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.onAccentFill)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(theme.accentFill)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.appPressable)
                .disabled(state.isPlacementLoading)
                .opacity(state.isPlacementLoading ? 0.6 : 1)
                .accessibilityLabel("开始摸底")

                if let level = state.placementLevel {
                    Text("上次定级：\(level.code) \(level.displayName)")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "circle.fill")
                .appFont(4)
                .foregroundStyle(theme.accent)
                .appPadding(.top, 5)
            Text(text)
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 答题

    private var questionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            progressBar
            if let question = state.currentPlacementQuestion {
                Text(question.kind.displayName)
                    .appFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.accentCool)
                    .padding(.horizontal, 7)
                    .appPadding(.vertical, 2)
                    .background(Capsule().fill(theme.accentCool.opacity(0.14)))

                Text(question.prompt)
                    .appFont(question.kind == .vocabulary ? 30 : 17,
                             weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, question.kind == .vocabulary ? 8 : 0)

                VStack(spacing: 8) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        optionRow(index: index, option: option)
                    }
                }
            }
        }
    }

    private var progressBar: some View {
        let total = max(state.placementPaper.questionCount, 1)
        let done = min(state.placementIndex, total)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.divider)
                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(6, proxy.size.width * Double(done) / Double(total)))
            }
        }
        .frame(height: 6)
    }

    private func optionRow(index: Int, option: String) -> some View {
        Button {
            state.choosePlacementOption(index)
        } label: {
            HStack(spacing: 10) {
                Text(letter(index))
                    .appFont(11, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(theme.hover))
                Text(option)
                    .appFont(13, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .appPadding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.surfaceAlt.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.secondaryText.opacity(0.28), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.appPressable)
        .accessibilityLabel("\(letter(index)). \(option)")
        // 词汇题是「词 → 义」，语法题是「句子 → 形式」，两个题型都只有一个正确答案。
        .help("选它进入下一题")
    }

    private func letter(_ index: Int) -> String {
        guard let scalar = UnicodeScalar(65 + index) else { return "\(index + 1)" }
        return String(Character(scalar))
    }

    // MARK: - 结果

    private func resultView(_ result: PlacementResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text(result.level.code)
                    .appFont(40, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("你的起点：\(result.level.displayName)")
                        .appFont(14, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    Text("\(result.headline) · 正确率 \(result.accuracyPercent)%")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            Text(result.level.canDo)
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(result.perLevel, id: \.level) { score in
                    HStack(spacing: 8) {
                        Image(systemName: score.isPassed ? "checkmark.circle.fill" : "xmark.circle")
                            .appFont(10)
                            .foregroundStyle(score.isPassed ? theme.success : theme.warning)
                        Text("\(score.level.code) · \(score.level.displayName)")
                            .appFont(11, weight: .medium, design: .rounded)
                            .foregroundStyle(theme.primaryText)
                        Text("\(score.correct) / \(score.total)")
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        Text(score.isPassed ? "过了" : "没过")
                            .appFont(10, weight: .semibold, design: .rounded)
                            .foregroundStyle(score.isPassed ? theme.success : theme.warning)
                    }
                }
            }
            .appPadding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.surfaceAlt.opacity(0.7))
            )

            Text(conclusion(result))
                .appFont(12, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task { await state.openScenarios() }
                    state.dismissPlacementOutcome()
                } label: {
                    Text("去练这一档的情景")
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.onAccentFill)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(theme.accentFill)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.appPressable)

                Button {
                    Task { await state.startPlacement() }
                } label: {
                    Text("重测一轮")
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(theme.accent.opacity(0.14))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.appPressable)
                .help("换一批题再摸一次底")

                Button {
                    state.dismissPlacementOutcome()
                } label: {
                    Text("知道了")
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(theme.surfaceAlt.opacity(0.8))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(theme.secondaryText.opacity(0.35), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.appPressable)

                Spacer(minLength: 0)
            }
        }
    }

    private func conclusion(_ result: PlacementResult) -> String {
        guard let failed = result.firstFailedLevel else {
            return "四档都过了。\(result.level.placementAdvice)"
        }
        return "\(failed.code) 这一档还差点，所以起点定在 \(result.level.code)。\(result.level.placementAdvice)"
    }

    // MARK: - 提示条

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .appFont(10)
                .foregroundStyle(theme.warning)
            Text(text)
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                state.dismissPlacementNotice()
            } label: {
                Image(systemName: "xmark")
                    .appFont(9, weight: .semibold)
                    .foregroundStyle(theme.warning)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appPressable)
        }
        .appPadding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.warning.opacity(0.14))
        )
    }
}
