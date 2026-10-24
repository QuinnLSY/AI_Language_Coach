import AIDomain
import AppCore
import SwiftUI

// #662 自 SettingsView.swift 拆出（2026-10-24）：原文件 3227 行、单结构体 22 个 MARK 段，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。

extension SettingsView {
    // MARK: - 模型提供商（本地 / 云端并存，二选一生效）

    /// 「本地模型」入口应当停在哪个 Provider 上（配置里第一家本地的）。
    /// 没有本地 Provider 时返回 nil，调用方保持原选择 —— 绝不硬编码一个 id 兜底。
    private var localEntryTarget: String? {
        providerOptions.first { !$0.isRemote }?.id
    }

    /// 「外部模型」入口应当停在哪家：优先**当前生效**的云端 Provider，
    /// 否则配置里第一家云端。都没有时返回 nil（面板里仍可重新选）。
    private var externalEntryTarget: String? {
        if let active = state.activeProvider, active.isRemote { return active.id }
        return providerOptions.first { $0.isRemote }?.id
    }

    var modelCard: some View {
        card(title: "模型提供商", systemImage: "brain", trailing: { modelProviderStatus }) {
            VStack(alignment: .leading, spacing: 12) {
                // 固定两个入口：本地 / 外部。
                //
                // 这里原来是「一家云端厂商一个标签」，兼容格式一多就会把标签行撑爆
                // （需求 1 的原始痛点）。选哪一家属于**外部模型内部**的一步，
                // 于是整体降级成下面那张面板的第一步，卡片上永远只有两个标签。
                HStack(spacing: 8) {
                    entryTab(title: "本地模型", systemImage: "desktopcomputer", selected: !llmUsesExternal) {
                        llmUsesExternal = false
                        state.selectProviderTab(localEntryTarget ?? state.selectedProviderID)
                    }
                    entryTab(title: "外部模型", systemImage: "cloud", selected: llmUsesExternal) {
                        llmUsesExternal = true
                        if let remote = externalEntryTarget {
                            state.selectProviderTab(remote)
                        }
                    }
                    Spacer()
                }

                if providerOptions.isEmpty {
                    Text("配置文件里没有 LLM Provider。")
                        .appFont(12, design: .rounded)
                        .foregroundStyle(theme.warning)
                } else if llmUsesExternal {
                    remoteProviderSection
                } else {
                    localProviderSection
                }

                if let message = state.remoteMessage {
                    Text(message)
                        .appFont(12, design: .rounded)
                        .foregroundStyle(message.contains("成功") || message.contains("已启用") ? .green : theme.warning)
                }

                if state.activeProvider?.id == state.selectedProviderID, let bootMessage = state.bootMessage {
                    Text(bootMessage)
                        .appFont(12, design: .rounded)
                        .foregroundStyle(theme.warning)
                }
            }
        }
        // 首次打开：标签跟着**当前生效**的 Provider 走（在用云端就停在「外部模型」）。
        //
        // ⚠️ 必须用 `.task(id:)` 跟着候选清单走，不能只 `.task {}`：`providerOptions` 是在
        // 上一层的 `.task` 里异步备好的，固定 `.task` 很可能在「清单还是空」的那一帧就跑完
        // （`guard !providerOptions.isEmpty` 直接返回），标签于是永远停在默认的「本地模型」
        // —— 实测症状就是「实际在用云端，卡片却显示本地」。
        .task(id: providerOptions.map(\.id)) {
            guard !didInitLLMTab, !providerOptions.isEmpty else { return }
            didInitLLMTab = true
            llmUsesExternal = isSelectedProviderRemote
        }
        // 生效的 Provider 一变（例如刚在外部模型面板里点完「确认配置」），标签与卡片
        // 立刻跟过去。缺这一条时卡片会停在旧状态：明明已经启用云端，还显示「还没有接入外部模型」。
        .onChange(of: state.activeProvider?.id) { _, _ in
            guard !providerOptions.isEmpty else { return }
            llmUsesExternal = isSelectedProviderRemote
        }
    }

    /// 卡片上的固定入口标签（本地 / 外部）。样式与模型管理中心的区块标题一致。
    private func entryTab(
        title: String,
        systemImage: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).appFont(10)
                Text(title).appFont(13, weight: .semibold, design: .rounded)
            }
            .foregroundStyle(selected ? theme.onAccentFill : theme.primaryText)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? theme.accentFill : theme.surfaceAlt)
            )
        }
        .buttonStyle(.appPressable)
    }

    /// 卡片右上角：`local.llm · qwen3:8b 已就绪 【关闭】`。
    ///
    /// 与模型管理中心各能力区块一致 —— 状态与「启动 / 关闭」按钮都在右上角，
    /// 前缀 `local` / `cloud` 直接说明模型跑在本机还是云端。
    private var modelProviderStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.health.isUsable ? Color.green : theme.warning)
                .frame(width: 8, height: 8)
            Text(state.llmProviderStatusLine)
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)
            modelRunButton(.llm, healthOK: state.health.isUsable)
            if !isSelectedProviderRemote {
                Button {
                    isRefreshing = true
                    Task {
                        await state.refreshStatus()
                        isRefreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.appPressable)
                .disabled(isRefreshing)
                .help("重新检测本地模型")
                .accessibilityLabel("重新检测本地模型")
            }
        }
    }

    // MARK: - 模型启动 / 关闭（所有模型组件共用同一个按钮）

    /// 「启动 / 关闭」按钮：两种状态共用一个位置。
    ///
    /// - 模型处于**启动**状态 → 显示红色外框的「关闭」，点击后让模型下线。
    /// - 模型处于**关闭**状态 → 显示绿色外框的「启动」，点击后让模型上线。
    ///
    /// 本地模型会真正启停后台服务；云端 / 内置模型只做应用层面的开关。
    @ViewBuilder
    /// 模型「启动 / 关闭」按钮。
    ///
    /// 语义是「这个模型**现在真的能用**吗」，不是「用户有没有点过关闭」：
    /// 只有「用户没关掉 **且** 健康检查通过」才显示红色的「关闭」；
    /// 服务没启动 / 没填 API Key / 连不上时显示绿色的「启动」（本地点它真的会拉起后台服务，
    /// 云端点它会重新校验连接）。否则会出现「明明写着服务未启动，却只有一个关闭按钮」的死角。
    func modelRunButton(_ kind: AIProviderKind, healthOK: Bool, hasModel: Bool = true) -> some View {
        let running = state.isModelRunning(kind)
        let active = ModelRunControl.isActive(running: running, healthOK: healthOK)
        let switching = state.modelSwitching.contains(kind)
        let tint: Color = active ? .red : .green

        Button {
            Task {
                await state.setModelRunning(
                    kind,
                    running: ModelRunControl.nextRunningState(running: running, healthOK: healthOK)
                )
            }
        } label: {
            HStack(spacing: 4) {
                if switching {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                        .tint(tint)
                } else {
                    Image(systemName: ModelRunControl.systemImage(running: running, healthOK: healthOK))
                        .appFont(10, weight: .semibold)
                }
                Text(ModelRunControl.title(running: running, healthOK: healthOK))
                    .appFont(11, weight: .semibold, design: .rounded)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(tint.opacity(0.10)))
            .overlay(Capsule().strokeBorder(tint, lineWidth: 1.2))
        }
        .buttonStyle(.appPressable)
        .disabled(switching)
        .help(active
              ? "关闭该模型：本地模型会真正停掉后台服务"
              : (hasModel
                 ? "启动该模型：本地模型会在本机后台拉起服务，云端会重新校验连接"
                 : "启动该模型：先在下方选择模型（本地或云端）"))
    }

    /// 当前**生效**的是不是云端 Provider。
    ///
    /// 优先看生效的 Provider，而不是「标签停在哪家」：后者在打开设置时可能还停在候选第一家
    /// （本地），于是「实际在用云端、卡片却显示本地」—— 界面与真实调用对不上。
    private var isSelectedProviderRemote: Bool {
        if let active = state.activeProvider { return active.isRemote }
        return providerOptions.first { $0.id == state.selectedProviderID }?.isRemote ?? false
    }

    /// 本地模型下拉的选项：把当前模型补进去。
    ///
    /// 不补的话，当 `modelDraft` 不在扫描结果里（模型被删了 / 还没扫到）下拉会显示成
    /// 「未选择」，用户看到的是「我明明选过」。修的是显示，不改配置。
    private var localModelOptions: [ForestSelectOption<String>] {
        var options = state.availableModels.map {
            ForestSelectOption(value: $0.id, title: $0.name)
        }
        let current = state.modelDraft
        if !current.isEmpty, !options.contains(where: { $0.id == current }) {
            options.insert(ForestSelectOption(value: current, title: current), at: 0)
        }
        return options
    }

    /// 教师音色下拉的选项：当前音色可能不在静态清单里（云端拉回来的音色），同样补进去。
    var teacherVoiceOptions: [ForestSelectOption<String>] {
        var options = state.availableVoices.map {
            ForestSelectOption(value: $0, title: $0.capitalized)
        }
        let current = state.teacherVoice
        if !current.isEmpty, !options.contains(where: { $0.id == current }) {
            options.insert(ForestSelectOption(value: current, title: current.capitalized), at: 0)
        }
        return options
    }

    /// 本地模型（Ollama）：状态 + 模型选择。
    private var localProviderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.availableModels.isEmpty {
                Text("没有检测到本地模型。请确认本地模型服务已启动后点击刷新。")
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.warning)
            } else {
                ForestSelect(
                    "模型",
                    icon: "cpu",
                    selection: Binding(
                        get: { state.modelDraft },
                        set: { name in Task { await state.applyModel(name) } }
                    ),
                    options: localModelOptions,
                    width: 240
                )
            }

            HStack(spacing: 8) {
                TextField("或手动填写模型名", text: $state.modelDraft)
                    .textFieldStyle(.roundedBorder)
                    .appFont(13, design: .rounded)
                Button("应用") {
                    Task { await state.applyModel(state.modelDraft) }
                }
                .disabled(state.modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if state.activeProvider?.id != state.selectedProviderID {
                Button("启用本地模型") {
                    Task { await state.activateProvider(state.selectedProviderID) }
                }
                .appFont(13, weight: .semibold, design: .rounded)
            }

            Text("模型完全在本地运行，不上传任何对话内容。")
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
        }
    }

    /// 外部模型：**当前接入的是哪一家 + 一个统一的配置入口**。
    ///
    /// 选厂商 / 填 Key / 拉模型 / 选模型与推理强度全在那张面板里完成，
    /// 卡片上因此永远只有这一个按钮 —— 兼容格式再多也不会把界面挤爆。
    private var remoteProviderSection: some View {
        let active = state.activeProvider
        let isRemoteActive = active?.isRemote ?? false
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isRemoteActive
                         ? "当前接入：\(active?.userFacingName ?? "外部供应商")"
                         : "还没有接入外部模型")
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    Text(isRemoteActive
                         ? "模型：\(state.modelDraft.isEmpty ? "未选择" : state.modelDraft)\(state.activeReasoningEffort.map { " · 推理强度\(reasoningText($0))" } ?? "")"
                         : "点右边的按钮选一家厂商、填入该厂商的 API Key 即可接入。")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    externalSheetKind = .llm
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cloud.badge.plus").appFont(11)
                        Text(isRemoteActive ? "更换外部模型" : "配置外部模型")
                            .appFont(12, weight: .semibold, design: .rounded)
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(theme.surfaceAlt)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(theme.accent.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.appPressable)
                .help("接入 OpenAI / AgnesAI / DeepSeek 等外部模型")
            }

            Text("对话内容会发送到你选定的服务商云端处理。支持任何 OpenAI 兼容协议的供应商，内置 OpenAI、AgnesAI、DeepSeek、OpenRouter 等。")
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 推理强度的展示文案（面板里是下拉选择，这里只是回显）。
    private func reasoningText(_ effort: String) -> String {
        switch effort {
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        default: effort
        }
    }
}
