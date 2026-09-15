import AIDomain
import AppCore
import SwiftUI

/// 情景对话选择面板（Implementation Plan §21）。
///
/// **完全数据驱动**：本视图只渲染 `AppState.scenarios`，不内置任何场景内容，
/// 也不判断场景语义（分组、难度、词汇都由数据决定）。
public struct ScenarioPickerView: View {

    @Environment(\.forestTheme) private var theme
    @Bindable var state: AppState
    var onClose: () -> Void

    public init(state: AppState, onClose: @escaping () -> Void) {
        self.state = state
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)

            if state.scenarios.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Scenario.groups(state.scenarios), id: \.category) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.category)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(theme.secondaryText)
                                ForEach(group.items) { scenario in
                                    card(scenario)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "map.fill")
                .font(.system(size: 18))
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(theme.surfaceAlt)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("情景对话")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("选一个场景，老师会扮演角色陪你练")
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
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
    }

    // MARK: - 空态（资源缺失时给可操作提示，不静默空白）

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 30))
                .foregroundStyle(theme.secondaryText)
            Text("没有找到情景资源")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text("请确认 App 资源中的 Scenarios 目录存在且包含 JSON 场景文件。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - 场景卡片

    private func card(_ scenario: Scenario) -> some View {
        let isActive = state.activeScenario?.scenario.id == scenario.id
        return Button {
            Task { await state.startScenario(scenario) }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: scenario.icon)
                    .font(.system(size: 17))
                    .foregroundStyle(theme.accent)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.surfaceAlt)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(scenario.titleZh)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text(scenario.title)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                        if isActive {
                            Text("进行中")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.selection))
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        chip(scenario.level)
                        chip("难度 \(scenario.difficultyDots)")
                        chip("\(scenario.maxTurns) 轮")
                        chip("纠错 · \(scenario.correctionMode.displayName)")
                    }

                    if !scenario.objective.isEmpty {
                        Text(scenario.objective)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }

                    if !scenario.targetVocabulary.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(scenario.targetVocabulary.prefix(6), id: \.self) { word in
                                Text(word)
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(theme.secondaryText)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(theme.hover))
                            }
                        }
                    }

                    // 本关目标句（P1-2 课程体系）：**练之前就要看得见**。
                    // 只在练完之后才告诉学员「你只说到 2 句」是耍赖 —— 他事先并不知道要说这几句。
                    if !scenario.targetSentences.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("本关要说出的句子")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.secondaryText.opacity(0.9))
                            ForEach(scenario.targetSentences, id: \.self) { sentence in
                                HStack(alignment: .top, spacing: 5) {
                                    Circle()
                                        .fill(theme.accent.opacity(0.7))
                                        .frame(width: 3, height: 3)
                                        .padding(.top, 5)
                                    Text(sentence)
                                        .font(.system(size: 10, design: .rounded))
                                        .foregroundStyle(theme.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.surfaceAlt.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isActive ? theme.accent.opacity(0.7) : theme.divider, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("进入「\(scenario.titleZh)」")
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.hover))
    }
}
