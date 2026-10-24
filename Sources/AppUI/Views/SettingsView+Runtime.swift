import AppCore
import SwiftUI

// #662 自 SettingsView.swift 拆出（2026-10-24）：原文件 3227 行、单结构体 22 个 MARK 段，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。

extension SettingsView {
    // MARK: - 运行环境（版本 / 配置位置 / 配置体检）

    /// 「运行环境」卡片：这一版是什么、配置从哪读、每个能力到底谁在生效。
    ///
    /// 这一整张卡都是补上来的，对应的都是「建好没接通」的实账：
    /// - 版本号只写在打包脚本里，界面上看不到（`make_app.sh` 硬编码 0.4.0 与 v1.0 不符）；
    /// - `config.json` 在哪、默认配置有没有读进来，没有任何地方告诉用户；
    /// - 在外面手改了配置**只能重启应用**（`ConfigStore.reload()` 零调用）；
    /// - 模型注册表的读侧（`listAvailable` / `getDefault` / `inconsistencies` 三条投影接口）
    ///   零消费方 —— 也就是「配置一致性体检」这件事从来没发生过。
    var runtimeCard: some View {
        card(title: "运行环境", systemImage: "stethoscope") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("版本")
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    Text(AppVersion.display)
                        .appFont(12, design: .monospaced)
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }

                if let failure = state.configLoadFailure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("配置文件")
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    Text(state.configLocationPath.isEmpty ? "（尚未取到）" : state.configLocationPath)
                        .appFont(10, design: .monospaced)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await state.reloadConfigurationFromDisk() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .appFont(11)
                            Text("重新载入配置")
                                .appFont(12, weight: .semibold, design: .rounded)
                        }
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 9)
                        .appPadding(.vertical, 5)
                        .background(Capsule().fill(theme.surfaceAlt))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.appPressable)
                    .help("按磁盘上的 config.json 重新载入，并把各能力的模型重接一遍（不必重启）")

                    if !state.configLocationPath.isEmpty {
                        FinderRevealButton(path: state.configLocationPath, title: "打开配置所在目录")
                    }
                    Spacer(minLength: 0)
                }

                if let notice = state.configReloadNotice {
                    HStack(alignment: .top, spacing: 6) {
                        Label(notice, systemImage: "arrow.clockwise.circle.fill")
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Button {
                            state.dismissConfigReloadNotice()
                        } label: {
                            Image(systemName: "xmark")
                                .appFont(9, weight: .semibold)
                                .foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.appPressable)
                        .help("收起回执")
                        .accessibilityLabel("收起配置重载回执")
                    }
                }

                Divider().overlay(theme.divider)

                Text("配置体检")
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.registryCheckRows) { row in
                        registryCheckRow(row)
                    }
                }

                Text("体检只看**配置层**：谁被选中、有没有缺 Key、有没有指向已停用的供应商。服务真的通不通，看上面各能力区块的状态点。")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(theme.divider)

                Text("语义记忆索引")
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)

                semanticMemoryRow

                if !state.availableMemoryText.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "memorychip")
                            .appFont(11)
                            .foregroundStyle(theme.secondaryText)
                        Text(state.availableMemoryText)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// 语义记忆索引这一行：通没通 + 多少维 + 没接通时下一步去哪儿。
    private var semanticMemoryRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.semanticMemoryStatus.isEnabled
                  ? "checkmark.circle.fill" : "circle.dashed")
                .appFont(11)
                .foregroundStyle(state.semanticMemoryStatus.isEnabled ? Color.green : theme.secondaryText)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.semanticMemoryStatus.headline)
                    .appFont(11, weight: .medium, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Text(state.semanticMemoryStatus.detail)
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// 「每日目标」卡片。
    ///
    /// 目标值一直只在**学习进度页**的「今天」卡里能改，而用户想改目标时第一反应是翻设置页
    /// ——翻不到就以为这应用不能调。这里补一份入口，控件与进度页同源（`DailyGoalControls`），
    /// 不另写一份（两边各写一份必然漂移：一边改了口径、另一边不跟）。
    var dailyGoalCard: some View {
        card(title: "每日目标", systemImage: "target") {
            VStack(alignment: .leading, spacing: 10) {
                Text("决定「今日任务」排多少量，也决定今天算不算完成。忙的日子切到保底档：5 分钟内做完同样保住连续。")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                DailyGoalControls(state: state)
            }
        }
    }

    // MARK: - 本地模型测速

    /// 「本地模型测速」卡片。
    ///
    /// 这条链路以前只有 `alc-bench` 命令行在用（`LocalLLMBenchmark` 界面零引用），
    /// 「我的机器跑这个模型到底快不快」只能靠体感。搬进界面后仍然只打本地 runtime，
    /// **不产生任何云端费用**——所以这里不走计费闸门，但也不提供云端选项。
    var localSpeedCard: some View {
        card(title: "本地模型测速", systemImage: "speedometer") {
            VStack(alignment: .leading, spacing: 12) {
                Text("用固定的三句提示词跑几轮，量出本机模型的生成速度。只打本地 runtime，不产生云端费用。")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        Task { await state.runLocalBenchmark() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .appFont(11)
                            Text(state.isRunningBenchmark ? "测速中…" : "跑一次测速")
                                .appFont(12, weight: .semibold, design: .rounded)
                        }
                        .foregroundStyle(state.isRunningBenchmark ? theme.secondaryText : theme.accent)
                        .padding(.horizontal, 9)
                        .appPadding(.vertical, 5)
                        .background(Capsule().fill(theme.surfaceAlt))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.appPressable)
                    .disabled(state.isRunningBenchmark)
                    .help("跑完约需半分钟到一分钟，期间别关应用")

                    if state.isRunningBenchmark {
                        ProgressView()
                            .controlSize(.small)
                        Text("约 30–60 秒")
                            .appFont(10, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }

                if let error = state.benchmarkError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let snapshot = state.benchmarkSnapshot {
                    VStack(alignment: .leading, spacing: 6) {
                        speedRow(label: "被测模型", value: snapshot.model)
                        speedRow(label: "整段生成（中位）", value: snapshot.generateText)
                        speedRow(label: "首个字出来（中位）", value: snapshot.firstTokenText)
                        speedRow(label: "吐字速度（中位）", value: snapshot.throughputText)
                        Text(snapshot.sampleText)
                            .appFont(10, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
        }
    }

    private func speedRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 4)
            Text(value)
                .appFont(11, weight: .medium, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    /// 一行体检结果：能力 → 谁在生效 / 为什么不生效。
    private func registryCheckRow(_ row: RegistryCheckRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .appFont(11)
                .foregroundStyle(row.isHealthy ? Color.green : theme.warning)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.kind.displayName)
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    if let effective = row.effective {
                        Text(effective.provider + (effective.model.map { " · \($0)" } ?? ""))
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        // 不生效的原因分两种，指向的动作完全不同：
                        // 一个都没配 → 去「模型管理中心」加一个；
                        // 配了但没启用 → 去把开关打开。含混一句「没有生效的供应商」等于让用户自己猜。
                        Text(row.providerCount == 0
                             ? "没有配置任何供应商"
                             : (row.enabledCount == 0
                                ? "配了 \(row.providerCount) 个供应商，但都处于停用状态"
                                : "有启用中的供应商，但没能解析出生效项"))
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.warning)
                    }
                }
                ForEach(row.issues, id: \.self) { issue in
                    Text(issue)
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let health = row.healthDescription {
                    Text(health)
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 「一个都没配」和「配了但全停用」在用户眼里都表现为「用不了」，
                // 但要做的事完全不同。不把这两个数摆出来，这一行就只能说
                // 「没有生效的供应商」，等于什么都没说。
                if row.providerCount > 0 {
                    Text("共 \(row.providerCount) 个供应商 · 启用 \(row.enabledCount) 个")
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText.opacity(0.85))
                }
            }
            Spacer(minLength: 0)
        }
    }
}
