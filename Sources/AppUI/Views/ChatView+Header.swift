import SwiftUI

// #663 自 ChatView.swift 拆出（2026-10-24）：原文件 2896 行、单结构体 + 5 个尾部类型，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ChatView {

    // MARK: - 头部

    var header: some View {
        HStack(spacing: 12) {
            // 老师平时不跳（只眨眼）——与侧栏座位同一条规矩。
            CuteAnimalView(kind: teacherKind, isSleeping: theme.isNight, size: 44, bobbing: false)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(teacherKind.displayName)老师")
                    .appFont(16, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                HStack(spacing: 5) {
                    // 「老师正在准备」时状态行跟着转：顶栏与对话区必须说同一件事，
                    // 不能底下在等、上面看着像闲着。
                    if isTeacherPreparing {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                    }
                    Text(statusLine)
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Spacer()

            // 连胜飞鸟（批次三）：连胜 ≥1 天才出现，扑翅动效只在 +1 那一刻；
            // 点按去处与侧栏火苗徽章一致（年度学习记录）。
            if let streakBadge {
                StreakBirdBadge(badge: streakBadge, onTap: { onOpenStreak?() })
            }

            // 克隆音色生效提示：与情景胶囊并列，位置显眼但不抢戏。
            if let voiceIndicator {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.badge.mic")
                        .appFont(9, weight: .semibold)
                    Text(voiceIndicator)
                        .appFont(10, weight: .semibold, design: .rounded)
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 8)
                .appPadding(.vertical, 4)
                .background(Capsule().fill(theme.accent.opacity(0.14)))
                .help("当前使用的是克隆音色，不是内置音色")
            }

            if let scenario {
                HStack(spacing: 6) {
                    Image(systemName: scenario.scenario.icon)
                        .appFont(10, weight: .semibold)
                    Text("\(scenario.scenario.titleZh) · \(scenario.turnsText)")
                        .appFont(10, weight: .semibold, design: .rounded)
                    if scenario.isFinalTurn {
                        Text("收尾")
                            .appFont(9, weight: .semibold, design: .rounded)
                            .padding(.horizontal, 5)
                            .appPadding(.vertical, 1)
                            .background(Capsule().fill(theme.accent.opacity(0.22)))
                    }
                    Button {
                        onEndScenario?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .appFont(11)
                    }
                    .buttonStyle(.appPressable)
                    .help("结束情景对话")
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 9)
                .appPadding(.vertical, 4)
                .background(Capsule().fill(theme.selection))
            } else {
                Button {
                    onOpenScenarios?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "map.fill")
                            .appFont(10, weight: .semibold)
                        Text("情景")
                            .appFont(10, weight: .semibold, design: .rounded)
                    }
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 9)
                    .appPadding(.vertical, 4)
                    .background(Capsule().fill(theme.hover))
                }
                .buttonStyle(.appPressable)
                .help("选择情景对话场景")
            }

            if let modelName, !modelName.isEmpty {
                Text(headerModelCaption(modelName))
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .appPadding(.vertical, 4)
                    .background(Capsule().fill(theme.surfaceAlt))
            }

            // 「开启新练习」（需求 4）：结束当前这一段（自动复盘）并进随口练。
            // 与情景对话的区别写在按钮的 hover 提示里 —— 学员按下之前就该知道两件事不一样。
            Button {
                // 双击防线（S4-4）：AppState 里还有一道，这里只负责「别白起一个 Task」。
                guard let onStartFreeTalk, !isStartingFreeTalk else { return }
                Task { await onStartFreeTalk() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .appFont(10, weight: .semibold)
                    Text(isStartingFreeTalk
                         ? "正在开始…"
                         : (practiceMode == .freeTalk ? "重开随口练" : "开启新练习"))
                        .appFont(10, weight: .semibold, design: .rounded)
                }
                .foregroundStyle(theme.onAccentFill)
                .padding(.horizontal, 10)
                .appPadding(.vertical, 4)
                .background(Capsule().fill(theme.accentFill))
                .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .disabled(onStartFreeTalk == nil || isStartingFreeTalk)
            .opacity(isStartingFreeTalk ? 0.6 : 1)
            .help("换一段自由练习：你定话题、老师跟着你聊，多给建议与纠错（上一段会自动复盘收进学习记录）")
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

}
