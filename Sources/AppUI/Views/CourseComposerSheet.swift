import AIDomain
import SwiftUI

/// 「排一条课」浮层：学员状态 → 一次请求排出一条**有序**的课（③）。
///
/// 与「描述场景」的分工：那个是**用户说练什么就练什么**（一句描述 → 一个情景），
/// 这个是**老师按你的水平与错处安排顺序**（状态 → 几节，由易到难）。
/// 两者共用同一套键值行约定与「一次操作 = 一次请求」的纪律。
///
/// ⚠️ 这一屏最重要的不是输入框，是**「照着什么排」**：四项依据全部摊开给用户看。
/// 排课是自动的，不透明就会变成「不知道它凭什么这么排」—— 学员一旦不认这条依据，
/// 这条课就白排了。
struct CourseComposerSheet: View {

    @Bindable var state: AppState
    var onClose: () -> Void
    @Environment(\.forestTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("老师按你现在的水平、常犯的错和念不准的音，排一条由易到难的课：几节情景，每节都带开场白、几句你要真说出口的话（练完逐句核对）、一批该用上的词（自动收进词汇本）。")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    basisSection
                    topicEditor
                    examples
                    actionRow
                    continuations

                    if let notice = state.courseResult {
                        resultBanner(notice)
                    }
                }
                .appPadding(20)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: CourseBlueprintRule.icon)
                .appFont(18)
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(theme.surfaceAlt)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("排一条课")
                    .appFont(16, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Text("按你的状态排出几节 · 由易到难")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .appFont(11, weight: .semibold)
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

    // MARK: - 照着什么排（可核对）

    private var basisSection: some View {
        let request = state.courseRequest
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("照着什么排")
                    .appFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                if request.level == nil && request.recurringErrors.isEmpty && request.weakPhonemes.isEmpty {
                    Text("还没攒下可参考的记录")
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.warning)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                basisRow(
                    icon: "chart.bar.fill",
                    title: "当前档位",
                    text: request.level.map { "\($0.code)（\($0.displayName)）" } ?? "还没定位出来"
                )
                basisRow(
                    icon: "exclamationmark.bubble.fill",
                    title: "反复犯的错",
                    text: request.recurringErrors.isEmpty
                        ? "暂无"
                        : request.recurringErrors.prefix(3).joined(separator: "；")
                            + (request.recurringErrors.count > 3 ? " 等 \(request.recurringErrors.count) 处" : "")
                )
                basisRow(
                    icon: "mouth.fill",
                    title: "顽固音素",
                    text: request.weakPhonemes.isEmpty
                        ? "暂无"
                        : request.weakPhonemes.joined(separator: "、")
                )
                basisRow(
                    icon: "tag.fill",
                    title: "你想练的",
                    text: request.topics.isEmpty ? "（没写就只按状态排）" : request.topics.joined(separator: "、")
                )
            }
        }
    }

    private func basisRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .appFont(10)
                .foregroundStyle(theme.accent)
                .frame(width: 14)
                .appPadding(.top, 1)
            Text(title)
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .frame(width: 62, alignment: .leading)
            Text(text)
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(text)")
    }

    // MARK: - 主题输入

    private var topicEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { state.courseTopicDraft },
                set: { state.courseTopicDraft = $0 }
            ))
            .appFont(12, design: .rounded)
            .scrollContentBackground(.hidden)
            .foregroundStyle(theme.primaryText)
            .frame(height: 76)
            .appPadding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.surfaceAlt.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.divider, lineWidth: 1)
            )
            .accessibilityLabel("想练的主题输入框")

            if state.courseTopicDraft.isEmpty {
                Text("可留空。最多 \(CourseBlueprintRule.maximumTopics) 个，顿号或逗号分隔")
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
                    .padding(.horizontal, 16)
                    .appPadding(.top, 16)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 示例 chip：点一下填进输入框（用户可以直接改，不用从零想）。
    private var examples: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("试试这些")
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.secondaryText)
            FlowRow(spacing: 6, lineSpacing: 6, wrapsLongItems: true) {
                ForEach(CourseBlueprintRule.examples, id: \.self) { example in
                    Button {
                        state.courseTopicDraft = example
                    } label: {
                        Text(example)
                            .appFont(11, weight: .medium, design: .rounded)
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 8)
                            .appPadding(.vertical, 3)
                            .background(Capsule().fill(theme.accent.opacity(0.10)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.appPressable)
                    .help("用这个主题")
                }
            }
        }
    }

    // MARK: - 动作

    private var actionRow: some View {
        HStack(spacing: 10) {
            if !state.canComposeCourse {
                Text(CourseBlueprintRule.inputIssue(for: state.courseRequest)?.message ?? "")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)

            Button {
                Task { await state.generateCourseFromState() }
            } label: {
                HStack(spacing: 5) {
                    if state.isGeneratingCourse {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars").appFont(10, weight: .bold)
                    }
                    Text(state.isGeneratingCourse ? "排课中…" : "开始排课")
                        .appFont(12, weight: .semibold, design: .rounded)
                }
                .foregroundStyle(theme.onAccentFill)
                .padding(.horizontal, 16)
                .appPadding(.vertical, 7)
                .background(Capsule().fill(theme.accentFill))
                .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .disabled(state.isGeneratingCourse || !state.canComposeCourse)
            .help("一次排课 = 一次模型请求，排出整条")
        }
    }

    // MARK: - 接着往下排（课随进度接，不是重排）

    /// 已经练完 / 卡住的课，在这里再接一批。
    ///
    /// ⚠️ 与「开始排课」是两件事：那个排**一条新课**，这个是在一条**已有课后面接**，
    /// 已有那几节连同它们的星星一个都不动。按钮上的字因此也不同（`decision.title`）。
    @ViewBuilder
    private var continuations: some View {
        let waiting = state.coursesAwaitingContinuation
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("接着往下排")
                    .appFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                ForEach(waiting) { course in
                    continuationRow(course)
                }
            }
        }
    }

    private func continuationRow(_ course: CourseBlueprint) -> some View {
        let decision = state.continuationDecision(for: course)
        return HStack(spacing: 8) {
            Image(systemName: CourseBlueprintRule.icon)
                .appFont(10)
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(course.displayTitle)
                    .appFont(11, weight: .medium, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(state.continuationSummary(for: course))
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer(minLength: 8)

            Button {
                Task { await state.continueCourse(id: course.id) }
            } label: {
                HStack(spacing: 4) {
                    if state.isContinuingCourse {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: decision == .easier ? "arrow.down.right" : "plus")
                            .appFont(9, weight: .bold)
                    }
                    Text(decision.title)
                        .appFont(11, weight: .semibold, design: .rounded)
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 10)
                .appPadding(.vertical, 5)
                .background(Capsule().fill(theme.accent.opacity(0.10)))
                .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .disabled(state.isContinuingCourse)
            .help(decision == .easier
                  ? "卡住了：接着排一批，难度降一档（已有那几节不动）"
                  : "都闯完了：接着往后排一批新的")
        }
        .appPadding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.6))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(course.displayTitle)：\(state.continuationSummary(for: course))，\(decision.title)")
    }

    private func resultBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.lastGeneratedCourse != nil
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .appFont(12)
                .foregroundStyle(state.lastGeneratedCourse != nil ? theme.accent : theme.warning)
            Text(notice)
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                state.dismissCourseResult()
            } label: {
                Image(systemName: "xmark")
                    .appFont(9, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.appPressable)
            .accessibilityLabel("关闭提示")
        }
        .appPadding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.6))
        )
    }
}
