import AppCore
import SwiftUI

// #662 自 SettingsView.swift 拆出（2026-10-24）：原文件 3227 行、单结构体 22 个 MARK 段，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。

extension SettingsView {
    // MARK: - 模型管理中心（ASR/TTS/VAD/Embedding/Pronunciation，本地检测 + 外部模型）

    var voiceModelCenterCard: some View {
        card(title: "模型管理中心", systemImage: "shippingbox.fill") {
            VStack(alignment: .leading, spacing: 14) {
                // 历史坏配置修复提示：本地模型名曾经被写进云端供应商（云端没有这个模型），
                // 已在启动时清掉——必须告诉用户为什么他的模型选择变空了。
                if let notice = state.modelHealNotice {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .appFont(11)
                            .foregroundStyle(theme.warning)
                        Text(notice)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .appPadding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.warning.opacity(0.12)))
                }
                // ⚠️ 说话检测（vad）刻意不列：它没有 runtime（配置了也不会被任何
                // 功能消费），列出来只会让用户对着一张「内置模拟」的假卡片配置半天。
                // 配置模型仍保留（mock.vad 在默认配置里），只是不展示。
                let kinds: [AIProviderKind] = [.asr, .tts, .embedding, .pronunciation]
                ForEach(kinds) { kind in
                    if let info = state.capabilityInfos[kind] {
                        capabilitySection(info)
                        if kind != .pronunciation { Divider().overlay(theme.divider.opacity(0.6)) }
                    }
                }

                // 语音服务在线状态（原「语音」卡片头部，卡片已并入本板块）
                voiceServiceStatus

                remoteCallAuditCard

                deploymentTips
            }
        }
        .task { await state.refreshCapabilityInfos() }
    }

    /// 对外调用记录（费用护栏留痕）。
    ///
    /// 为什么必须放在设置页：用户的诉求是「我只点了一下朗读，别把我的账号跑一遍」。
    /// 与其让他去猜，不如把应用**实际发出的每一次云端调用**摆出来——能力、模型、时间、结果，
    /// 逐条能与服务商账单对上。异常扇出会被红色告警提示，超限调用则直接被打断（不会发出）。
    private var remoteCallAuditCard: some View {
        let summary = state.remoteCallSummary
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: summary.blockedTotal > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .appFont(12)
                    .foregroundStyle(summary.blockedTotal > 0 ? theme.warning : Color.green)
                Text("对外调用记录")
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Button("刷新") { Task { await state.refreshRemoteCalls() } }
                    .appFont(11, design: .rounded)
                    .buttonStyle(.appPressable)
                    .foregroundStyle(theme.accent)
                Button("清空") { Task { await state.clearRemoteCalls() } }
                    .appFont(11, design: .rounded)
                    .buttonStyle(.appPressable)
                    .foregroundStyle(theme.secondaryText)
            }

            Text(summary.headline)
                .appFont(11, weight: .medium, design: .rounded)
                .foregroundStyle(theme.primaryText)

            Text("本次运行涉及模型：\(summary.models.isEmpty ? "无" : summary.models.joined(separator: "、"))")
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = summary.fanOutWarning {
                Text(warning)
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.remoteCallRecords.isEmpty {
                Text("暂无记录。应用每次调用云端模型都会记在这里（只记能力 / 模型 / 结果，不记内容）。")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(state.remoteCallRecords) { record in
                        HStack(spacing: 8) {
                            Text(Self.auditTimeFormatter.string(from: record.at))
                                .appFont(10, design: .monospaced)
                                .foregroundStyle(theme.secondaryText)
                            Text(record.operation.displayName)
                                .appFont(10, design: .rounded)
                                .foregroundStyle(theme.secondaryText)
                            // 端点写出来：用户拿着这条记录就能与服务商账单里的计费项逐条对上
                            // （`/v1/audio/speech` 是语音合成、`/v1/chat/completions` 是语言模型）。
                            Text(record.endpoint)
                                .appFont(10, design: .monospaced)
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                            // 公共服务（天气预报）没有模型 → 显示服务名；
                            // 显示一串「—」等于让用户猜这条到底是什么请求。
                            Text(record.targetName)
                                .appFont(10, design: .monospaced)
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(record.outcome.displayName)
                                .appFont(10, weight: .semibold, design: .rounded)
                                .foregroundStyle(record.outcome == .ok ? Color.green : (record.outcome == .blocked ? theme.warning : Color.red))
                        }
                    }
                }
            }

            Text("完整留痕：\(state.remoteCallLogPath)")
                .appFont(10, design: .monospaced)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(state.remoteCallLogPath)
        }
        .appPadding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceAlt.opacity(0.6)))
    }

    private static let auditTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// 「本地 / 云端」小徽章：云端走 API Key 与外部网络，本地跑在本机 runtime 上。
    private func sourceBadge(info: CapabilityModelInfo) -> some View {
        let title = info.isRemote ? "云端" : "本地"
        return HStack(spacing: 3) {
            Image(systemName: info.isRemote ? "cloud.fill" : "desktopcomputer")
                .appFont(8)
            Text(title)
                .appFont(10, weight: .semibold, design: .rounded)
        }
        .foregroundStyle(info.isRemote ? theme.accent : theme.secondaryText)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(
            Capsule().fill(theme.surfaceAlt)
        )
        .overlay(
            Capsule().strokeBorder(
                (info.isRemote ? theme.accent : theme.divider).opacity(0.5), lineWidth: 1
            )
        )
        .help(info.isRemote
              ? "云端模型：由 \(info.providerName ?? "外部供应商") 通过 API Key 提供"
              : "本地模型：运行在本机，不需要外部网络")
    }

    /// 单个能力的模型区块：当前模型/来源 → 本地检测选择 → 手动填写 → 外部模型。
    @ViewBuilder
    private func capabilitySection(_ info: CapabilityModelInfo) -> some View {
        let kind = info.kind
        VStack(alignment: .leading, spacing: 9) {
            // ① 当前模型 + 来源 + 状态（状态右边是共用的「启动 / 关闭」按钮）
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(info.healthOK ? Color.green : (info.currentModel == nil ? Color.gray : theme.warning))
                    .frame(width: 8, height: 8)
                Text(kind.displayName)
                    .appFont(13, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                // 本地 / 云端一眼可辨（云端必带 API Key，走外部网络）
                sourceBadge(info: info)
                Spacer()
                Text(info.healthText)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                modelRunButton(kind, healthOK: info.healthOK, hasModel: info.currentModel != nil)
            }
            Text("当前：\(info.currentModel ?? "未配置")")
                .appFont(12, weight: .medium, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Text(info.sourceDescription)
                .appFont(11, design: .monospaced)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(info.sourceDescription)

            // ② 本地检测模型选择
            if !info.localModels.isEmpty {
                HStack(spacing: 8) {
                    ForestSelect(
                        "本地模型",
                        icon: "folder.badge.gearshape",
                        selection: Binding(
                            get: { info.currentModel ?? info.localModels[0].name },
                            set: { name in Task { await state.selectLocalModel(kind, name: name) } }
                        ),
                        options: info.localModels.map {
                            ForestSelectOption(value: $0.name, title: $0.name)
                        },
                        width: 200
                    )
                    Spacer()
                    Button {
                        Task { await state.refreshCapabilityInfos() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.appPressable)
                    .help("重新检测可用模型（本地 Ollama / 目录）")
                    .accessibilityLabel("重新检测可用模型")
                }
            }

            // ③ 手动填写
            HStack(spacing: 8) {
                TextField("手动填写模型名", text: Binding(
                    get: { state.customModelDrafts[kind.rawValue] ?? "" },
                    set: { state.customModelDrafts[kind.rawValue] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .appFont(12, design: .rounded)
                Button("应用") {
                    Task { await state.applyCustomModel(kind, name: state.customModelDrafts[kind.rawValue] ?? "") }
                }
                .appFont(12, weight: .semibold, design: .rounded)
                .disabled((state.customModelDrafts[kind.rawValue] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // ④ 外部模型（各厂商统一入口：填 Key → 拉取 → 选择）
            externalModelSection(kind: kind)

            // ⑤ 教师语音专有：音色 / 语速 / 自动朗读（原独立「语音」卡片，
            //    并入本板块后「配模型」与「怎么读」在同一处完成）
            if kind == .tts {
                teacherVoiceControls
                clonedVoiceControls
            }
        }
    }

    /// 外部模型入口（与「AI 大脑」那张卡片**同一个面板**）。
    ///
    /// 这里原来是「一家厂商一个标签 + 各自的 Key/模型控件」的折叠区，
    /// 兼容格式一多就把这一块撑成一片按钮墙。现在收成一行：
    /// 当前接的是哪家 + 一个按钮，点开才做选择。
    @ViewBuilder
    private func externalModelSection(kind: AIProviderKind) -> some View {
        let info = state.capabilityInfos[kind]
        let usingRemote = info?.isRemote ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "cloud")
                    .appFont(11)
                    .foregroundStyle(usingRemote ? theme.accent : theme.secondaryText)
                Text(usingRemote
                     ? "外部模型：\(info?.providerName ?? "已接入")\(info?.currentModel.map { " · \($0)" } ?? "")"
                     : "外部模型：未接入")
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Button {
                    externalSheetKind = kind
                } label: {
                    Text(usingRemote ? "更换" : "配置")
                        .appFont(11, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(theme.surfaceAlt))
                        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.appPressable)
                .help("接入这一能力的外部模型")
            }
            if !usingRemote, kind == .pronunciation {
                // 发音评测有两条通道：没有云端配置也能用（规则推断），配了就是声学实测。
                Text("当前按本地规则推断打分；接入云端发音评测后改为逐音素声学实测。")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .task {
            // 面板需要供应商清单，这里先把缓存备好（面板打开时就能直接列出来）。
            if state.externalProviderCache[kind.rawValue] == nil {
                state.externalProviderCache[kind.rawValue] = await state.remoteProviderOptions(for: kind)
            }
        }
    }

    /// 本地模型部署指导。
    private var deploymentTips: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "lightbulb.fill")
                    .appFont(11)
                    .foregroundStyle(Color(hex: 0xF7B32B))
                Text("如何让应用自动识别新的本地模型")
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
            }
            Text("把模型统一放在 ~/AI_Models/ 对应模块目录下即可：\n• 语音识别 (asr)：模型文件放入 ~/AI_Models/asr/models/（如 ggml-*.bin）\n• 教师语音 (tts)：每个模型一个文件夹放入 ~/AI_Models/tts/\n• 发音评测 (pronunciation)：每个模型一个文件夹放入对应目录\n• 记忆索引 (embedding)：本机由 Ollama 提供——在 Ollama 安装 nomic-embed-text 等嵌入模型后，刷新即可列出；也可在「外部模型」接入云端嵌入\n放好后点击各能力区块的刷新按钮（↻），应用会自动检测并列出可选。云端模型请展开「外部模型」填写 API Key 接入。")
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(3)
        }
        .appPadding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceAlt.opacity(0.6)))
    }
}
