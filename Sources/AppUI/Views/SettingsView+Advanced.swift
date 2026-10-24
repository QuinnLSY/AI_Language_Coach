import AppCore
import SwiftUI

// #662 自 SettingsView.swift 拆出（2026-10-24）：原文件 3227 行、单结构体 22 个 MARK 段，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。

extension SettingsView {
    // MARK: - 快捷键中心（#281：所有可设的键都在这里改）

    /// 内容整个在 `ShortcutCenterCard` 里（搬出去是为了能单独离屏渲染回归）。
    /// 这里只负责套上设置页统一的卡片外框。
    var shortcutCenterCard: some View {
        card(title: "快捷键中心", systemImage: "keyboard") {
            ShortcutCenterCard(state: state)
        }
    }

    // MARK: - 高级

    var advancedCard: some View {
        card(title: "高级", systemImage: "slider.horizontal.3") {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("服务端点").frame(width: 88, alignment: .leading)
                        TextField(endpointPlaceholder, text: $endpointDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("应用") {
                            Task { await state.setLLMEndpoint(endpointDraft) }
                        }
                    }

                    HStack {
                        Text("创意度").frame(width: 88, alignment: .leading)
                        Slider(value: $temperatureDraft, in: 0...1.4, step: 0.05)
                        Text(String(format: "%.2f", temperatureDraft))
                            .frame(width: 44, alignment: .trailing)
                            .monospacedDigit()
                        Button("应用") {
                            Task { await state.setLLMTemperature(temperatureDraft) }
                        }
                    }

                    Text("普通用户不需要修改这些。默认值已针对本机优化。")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }
                .appPadding(.top, 8)
                .appFont(13, design: .rounded)
            } label: {
                Text("显示高级选项")
                    .appFont(13, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: - 日志

    var logsCard: some View {
        card(title: "运行日志", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 8) {
                // 级别与清空：这两颗原本没有界面 —— `LogBus.setMinimumLevel` / `clear()`
                // 写好了却零调用，日志永远是最低门槛全收、也只进不出。
                HStack(spacing: 8) {
                    Text("级别")
                        .appFont(12, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    // ⚠️ 项目约束：不用系统 Picker。这里改用分段按钮，四个档位一眼看全。
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        logLevelButton(level)
                    }
                    Spacer(minLength: 8)
                    Button {
                        LogOptions.clear()
                        logs = []
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .appFont(10)
                            Text("清空")
                                .appFont(11, weight: .semibold, design: .rounded)
                        }
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8)
                        .appPadding(.vertical, 4)
                        .background(Capsule().fill(theme.surfaceAlt))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.appPressable)
                    .help("清空设置页展示的日志（系统日志里的历史清不掉）")
                }

                if logs.isEmpty {
                    Text("暂无日志")
                        .appFont(12, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                } else {
                    ForEach(logs.suffix(30)) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.level.rawValue.uppercased())
                                .appFont(9, weight: .bold, design: .rounded)
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 48, alignment: .leading)
                            Text(entry.message)
                                .appFont(11, design: .rounded)
                                .foregroundStyle(theme.secondaryText)
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 日志级别档位按钮（选中态走黄底胶囊 + `onAccentFill`，与伙伴形象切换同一套）。
    private func logLevelButton(_ level: LogLevel) -> some View {
        let selected = logLevel == level
        return Button {
            logLevel = level
            LogOptions.minimumLevel = level
            Task { logs = await LogBus.shared.recent(limit: 60) }
        } label: {
            Text(level.rawValue.uppercased())
                .appFont(10, weight: .semibold, design: .monospaced)
                .foregroundStyle(selected ? theme.onAccentFill : theme.primaryText)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? theme.accentFill : theme.surfaceAlt)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.appPressable)
        .help(level == .debug ? "全收（默认）：连调试信息一起留着" : "只看 \(level.rawValue) 及以上")
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: .gray
        case .info: .blue
        case .warning: theme.warning
        case .error: .red
        }
    }
}
