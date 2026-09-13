import AIDomain
import AIInterfaces
import AppCore
import SwiftUI

/// 设置里的伙伴角色：老师（侧边栏/聊天区 AI）与 小学员（聊天区学员位/树上攀爬者）。
private enum PartnerRole: String, CaseIterable, Identifiable {
    case teacher
    case student

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teacher: "老师"
        case .student: "小学员"
        }
    }

    var caption: String {
        switch self {
        case .teacher: "显示在左侧边栏与聊天区"
        case .student: "显示在聊天区与成长之树攀爬者"
        }
    }

    var icon: String {
        switch self {
        case .teacher: "graduationcap.fill"
        case .student: "figure.child"
        }
    }
}

public struct SettingsView: View {

    @Environment(\.forestTheme) private var theme
    @Bindable var state: AppState

    @State private var partnerRole: PartnerRole = .teacher
    @State private var endpointDraft: String = ""
    @State private var temperatureDraft: Double = 0.7
    @State private var logs: [LogEntry] = []
    @State private var showAdvanced = false
    @State private var isRefreshing = false
    @State private var isClearingCache = false
    @State private var showClearConfirm = false
    /// 重置每日推荐学习进度的二次确认。
    @State private var showVocabularyResetConfirm = false
    /// 配置里的 LLM Provider 标签（本地 / 云端）。
    @State private var providerOptions: [(id: String, name: String, isRemote: Bool)] = []
    /// 「外部模型」折叠区的展开状态（kind.rawValue -> 是否展开）。
    /// 没记过时按「该能力当前是否走云端」决定默认值。
    @State private var expandedExternal: [String: Bool] = [:]

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    themeCard
                    partnerCard
                    forestCompanionsCard
                    modelCard
                    voiceModelCenterCard
                    learningCard
                    vocabularyCard
                    cacheCard
                    advancedCard
                    logsCard
                }
                .padding(20)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(theme.panel)
        .task {
            await loadRuntimeValues()
            // 用已保存的配置回填外部模型草稿：Key、模型列表、选中的供应商。
            // 必须在 loadRuntimeValues 之后（后者决定 selectedProviderID）。
            await state.prefillExternalDrafts()
            await state.refreshCacheInfo()
            await state.loadVocabularyBankIfNeeded()
        }
        .confirmationDialog("确定重置每日推荐学习进度吗？", isPresented: $showVocabularyResetConfirm, titleVisibility: .visible) {
            Button("重置进度", role: .destructive) {
                Task { await state.resetDailyProgress() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「认识」次数会清零，词库重新从简单档开始推荐。词汇本里的词条与复习进度不受影响。")
        }
        .confirmationDialog("确定清理缓存吗？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清理缓存", role: .destructive) {
                isClearingCache = true
                Task {
                    await state.clearCache()
                    isClearingCache = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理过期的对话流水并回收磁盘空间。学习记忆与应用配置会完整保留。")
        }
    }

    // MARK: - 顶部栏（含关闭按钮；日夜切换收在下方「森林时刻」卡片里）

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15))
                .foregroundStyle(theme.accent)
            Text("设置")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)

            Spacer()

            Button {
                state.showingSettings = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(theme.surfaceAlt))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("关闭设置 (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 森林时刻（日夜切换在此，不再单独拎出）

    private var themeCard: some View {
        card(title: "森林时刻", systemImage: theme.isNight ? "moon.stars.fill" : "sun.max.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: Binding(
                    get: { state.themeMode },
                    set: { mode in Task { await state.setThemeMode(mode) } }
                )) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(theme.isNight ? "夜晚的森林很安静，星星陪着小动物们睡觉，也陪你练习。" : "阳光正好，小动物们都醒着，一起爬树学英语吧！")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: - 我的伙伴（老师 / 小学员形象切换）

    private var partnerCard: some View {
        card(title: "我的伙伴", systemImage: "pawprint.fill") {
            VStack(alignment: .leading, spacing: 12) {
                // 角色选择：老师与小学员共用下方的小动物展示区
                HStack(spacing: 8) {
                    ForEach(PartnerRole.allCases) { role in
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { partnerRole = role }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: role.icon)
                                    .font(.system(size: 12))
                                Text(role.title)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(partnerRole == role ? Color.white : theme.primaryText)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(partnerRole == role ? theme.accent : theme.surfaceAlt)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                // 当前角色说明
                HStack(spacing: 8) {
                    Image(systemName: partnerRole == .teacher ? "graduationcap.fill" : "figure.child")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accent)
                    Text(partnerRole.caption)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }

                // 小动物展示区：当前角色已选中的动物带身份配件 + 高亮圈
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                    ForEach(AnimalKind.allCases) { kind in
                        partnerCell(kind)
                    }
                }
                .padding(.top, 2)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accent)
                    Text("老师持教棍，小学员戴红领巾。点选即可分别更换两个形象。")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    private func partnerCell(_ kind: AnimalKind) -> some View {
        let isSelected = partnerRole == .teacher
            ? kind == state.teacherAnimalKind
            : kind == state.studentAnimalKind
        let accessory: AnimalAccessory = isSelected
            ? (partnerRole == .teacher ? .teacher : .student)
            : .none

        return Button {
            Task {
                if partnerRole == .teacher {
                    await state.setTeacherAnimal(kind)
                } else {
                    await state.setStudentAnimal(kind)
                }
            }
        } label: {
            VStack(spacing: 4) {
                CuteAnimalView(kind: kind, isSleeping: theme.isNight, size: 58, accessory: accessory)
                Text(kind.displayName)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? theme.selection.opacity(0.7) : theme.surfaceAlt.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? theme.accent : Color.clear, lineWidth: 2)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: partnerRole == .teacher ? "graduationcap.fill" : "figure.child")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(theme.accent))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .help("设为\(partnerRole.title)：\(kind.displayName)")
    }

    // MARK: - 森林伙伴（气泡 / 活动开关，全部全局记忆）

    private var forestCompanionsCard: some View {
        card(title: "森林伙伴", systemImage: "pawprint") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("老师激励气泡", isOn: Binding(
                    get: { state.teacherBubblesEnabled },
                    set: { enabled in Task { await state.setTeacherBubbles(enabled) } }
                ))
                .font(.system(size: 13, design: .rounded))

                Toggle("小动物气泡（点击/自发冒泡）", isOn: Binding(
                    get: { state.animalBubblesEnabled },
                    set: { enabled in Task { await state.setAnimalBubbles(enabled) } }
                ))
                .font(.system(size: 13, design: .rounded))

                Toggle("小动物自由活动", isOn: Binding(
                    // 夜晚：显示为未勾选且不可点击（白天的小动物都睡了），
                    // 但**不改动用户白天的配置**，切回白天即恢复原选择。
                    get: { AppState.animalActivityToggleValue(enabled: state.animalActivityEnabled, isNight: theme.isNight) },
                    set: { enabled in Task { await state.setAnimalActivity(enabled) } }
                ))
                .font(.system(size: 13, design: .rounded))
                .disabled(theme.isNight)
                .help(theme.isNight ? "夜晚小动物们都在睡觉，白天才能开启活动" : "开启后小动物会在林间自由活动")

                // 活动频率滑条：关闭活动（或夜晚）时置灰不可拖
                HStack(spacing: 10) {
                    Text("移动频率")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(activityControlsActive ? theme.primaryText : theme.secondaryText)
                    Slider(
                        value: Binding(
                            get: { state.animalActivityFrequency },
                            set: { value in Task { await state.setAnimalActivityFrequency(value) } }
                        ),
                        in: 0...1
                    )
                    .disabled(!activityControlsActive)
                    Text(activityControlsActive ? frequencyLabel : "—")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 52, alignment: .trailing)
                        .monospacedDigit()
                }
                .padding(.leading, 20)
                .opacity(activityControlsActive ? 1 : 0.45)

                Text(theme.isNight
                     ? "现在是夜晚，小动物们都在睡觉，活动开关已暂时锁定；切回白天即可重新调整。"
                     : "关闭活动时，小动物们会回到初始位置排排站好（成长之树右下角有同步的表情开关）。夜晚它们会自动安静下来。小动物们还会不定时告别离开、换新邻居进场。以上开关全局记忆，下次打开应用自动延续。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// 小动物活动相关控件是否可用（夜晚一律锁定）。
    private var activityControlsActive: Bool {
        state.animalActivityEnabled && !theme.isNight
    }

    /// 频率滑条的展示文案。
    private var frequencyLabel: String {
        let value = state.animalActivityFrequency
        if value < 0.25 { return "悠闲" }
        if value < 0.55 { return "正常" }
        if value < 0.8 { return "活泼" }
        return "撒欢"
    }

    // MARK: - 模型提供商（本地 / 云端并存，二选一生效）

    private var modelCard: some View {
        card(title: "模型提供商", systemImage: "brain", trailing: { modelProviderStatus }) {
            VStack(alignment: .leading, spacing: 12) {
                // 提供商标签行：本地模型 / DeepSeek / OpenRouter…
                HStack(spacing: 8) {
                    ForEach(providerOptions, id: \.id) { option in
                        providerTab(option)
                    }
                    Spacer()
                }

                if providerOptions.isEmpty {
                    Text("配置文件里没有 LLM Provider。")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.orange)
                } else if isSelectedProviderRemote {
                    remoteProviderSection
                } else {
                    localProviderSection
                }

                if let message = state.remoteMessage {
                    Text(message)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(message.contains("成功") || message.contains("已启用") ? .green : .orange)
                }

                if state.activeProvider?.id == state.selectedProviderID, let bootMessage = state.bootMessage {
                    Text(bootMessage)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// 卡片右上角：`local.llm · qwen3:8b 已就绪 【关闭】`。
    ///
    /// 与模型管理中心各能力区块一致 —— 状态与「启动 / 关闭」按钮都在右上角，
    /// 前缀 `local` / `cloud` 直接说明模型跑在本机还是云端。
    private var modelProviderStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.health.isUsable ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(state.llmProviderStatusLine)
                .font(.system(size: 11, design: .rounded))
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
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help("重新检测本地模型")
            }
        }
    }

    private func providerTab(_ option: (id: String, name: String, isRemote: Bool)) -> some View {
        let isActive = state.activeProvider?.id == option.id
        return Button {
            state.selectProviderTab(option.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: option.isRemote ? "cloud.fill" : "desktopcomputer")
                    .font(.system(size: 10))
                Text(option.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(state.selectedProviderID == option.id ? Color.white : theme.primaryText)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(state.selectedProviderID == option.id ? theme.accent : theme.surfaceAlt)
            )
            .overlay(alignment: .topTrailing) {
                if isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isActive ? "当前生效" : "切换到\(option.name)")
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
    private func modelRunButton(_ kind: AIProviderKind, healthOK: Bool, hasModel: Bool = true) -> some View {
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
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(ModelRunControl.title(running: running, healthOK: healthOK))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(tint.opacity(0.10)))
            .overlay(Capsule().strokeBorder(tint, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .disabled(switching)
        .help(active
              ? "关闭该模型：本地模型会真正停掉后台服务"
              : (hasModel
                 ? "启动该模型：本地模型会在本机后台拉起服务，云端会重新校验连接"
                 : "启动该模型：先在下方选择模型（本地或云端）"))
    }

    private var isSelectedProviderRemote: Bool {
        providerOptions.first { $0.id == state.selectedProviderID }?.isRemote ?? false
    }

    /// 本地模型（Ollama）：状态 + 模型选择。
    private var localProviderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.availableModels.isEmpty {
                Text("没有检测到本地模型。请确认本地模型服务已启动后点击刷新。")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.orange)
            } else {
                Picker("选择模型", selection: Binding(
                    get: { state.modelDraft },
                    set: { name in Task { await state.applyModel(name) } }
                )) {
                    ForEach(state.availableModels) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .labelsHidden()
            }

            HStack(spacing: 8) {
                TextField("或手动填写模型名", text: $state.modelDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .rounded))
                Button("应用") {
                    Task { await state.applyModel(state.modelDraft) }
                }
                .disabled(state.modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if state.activeProvider?.id != state.selectedProviderID {
                Button("启用本地模型") {
                    Task { await state.activateProvider(state.selectedProviderID) }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            }

            Text("模型完全在本地运行，不上传任何对话内容。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
    }

    /// 云端 Provider：API Key → 验证并获取模型 → 选模型 / 推理强度 → 启用。
    private var remoteProviderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ① API Key（状态与「启动 / 关闭」在卡片右上角；云端模型无法被终止，开关只作用于应用层）
            HStack(spacing: 8) {
                SecureField("API Key", text: Binding(
                    get: { state.apiKeyDrafts[state.selectedProviderID] ?? "" },
                    set: { state.apiKeyDrafts[state.selectedProviderID] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .rounded))

                Button {
                    Task { await state.fetchRemoteModels() }
                } label: {
                    HStack(spacing: 5) {
                        if state.isFetchingRemoteModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "key.horizontal")
                        }
                        Text("验证并获取模型")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.plain)
                .disabled(state.isFetchingRemoteModels)
            }

            // ② 模型列表（验证成功后自动出现）
            let models = state.remoteModels[state.selectedProviderID] ?? []
            if !models.isEmpty {
                Picker("选择模型", selection: Binding(
                    get: { remoteModelDraft(models: models) },
                    set: { model in Task { await state.applyRemoteProvider(model: model) } }
                )) {
                    ForEach(models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .labelsHidden()
            }

            // ④ 推理强度
            Picker("推理强度", selection: Binding(
                get: { state.reasoningEffortDraft },
                set: { state.reasoningEffortDraft = $0 }
            )) {
                Text("标准").tag(String?.none)
                Text("低").tag(String?.some("low"))
                Text("中").tag(String?.some("medium"))
                Text("高").tag(String?.some("high"))
            }

            Text("对话内容会发送到该服务商的云端处理。填写正确的 API Key 后点击「验证并获取模型」，选择模型即可自动启用。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
    }

    /// 云端模型草稿：当前生效模型优先，否则列表第一个。
    private func remoteModelDraft(models: [DiscoveredModel]) -> String {
        if state.activeProvider?.id == state.selectedProviderID, !state.modelDraft.isEmpty {
            return state.modelDraft
        }
        return models.first?.id ?? ""
    }

    // MARK: - 模型管理中心（ASR/TTS/VAD/Embedding/Pronunciation，本地检测 + 外部模型）

    private var voiceModelCenterCard: some View {
        card(title: "模型管理中心", systemImage: "shippingbox.fill") {
            VStack(alignment: .leading, spacing: 14) {
                let kinds: [AIProviderKind] = [.asr, .tts, .vad, .embedding, .pronunciation]
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
                    .font(.system(size: 12))
                    .foregroundStyle(summary.blockedTotal > 0 ? Color.orange : Color.green)
                Text("对外调用记录")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Button("刷新") { Task { await state.refreshRemoteCalls() } }
                    .font(.system(size: 11, design: .rounded))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                Button("清空") { Task { await state.clearRemoteCalls() } }
                    .font(.system(size: 11, design: .rounded))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryText)
            }

            Text(summary.headline)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.primaryText)

            Text("本次运行涉及模型：\(summary.models.isEmpty ? "无" : summary.models.joined(separator: "、"))")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = summary.fanOutWarning {
                Text(warning)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.remoteCallRecords.isEmpty {
                Text("暂无记录。应用每次调用云端模型都会记在这里（只记能力 / 模型 / 结果，不记内容）。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(state.remoteCallRecords) { record in
                        HStack(spacing: 8) {
                            Text(Self.auditTimeFormatter.string(from: record.at))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                            Text(record.operation.displayName)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                            Text(record.model.isEmpty ? "—" : record.model)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(record.outcome.displayName)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(record.outcome == .ok ? Color.green : (record.outcome == .blocked ? Color.orange : Color.red))
                        }
                    }
                }
            }

            Text("完整留痕：\(state.remoteCallLogPath)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(state.remoteCallLogPath)
        }
        .padding(12)
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
                .font(.system(size: 8))
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
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
                    .fill(info.healthOK ? Color.green : (info.currentModel == nil ? Color.gray : Color.orange))
                    .frame(width: 8, height: 8)
                Text(kind.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                // 本地 / 云端一眼可辨（云端必带 API Key，走外部网络）
                sourceBadge(info: info)
                Spacer()
                Text(info.healthText)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                modelRunButton(kind, healthOK: info.healthOK, hasModel: info.currentModel != nil)
            }
            Text("当前：\(info.currentModel ?? "未配置")")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text(info.sourceDescription)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(info.sourceDescription)

            // ② 本地检测模型选择
            if !info.localModels.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accent)
                    Picker("本地模型", selection: Binding(
                        get: { info.currentModel ?? info.localModels[0].name },
                        set: { name in Task { await state.selectLocalModel(kind, name: name) } }
                    )) {
                        ForEach(info.localModels) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                    .labelsHidden()
                    Spacer()
                    Button {
                        Task { await state.refreshCapabilityInfos() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("重新扫描 ~/AI_Models")
                }
            }

            // ③ 手动填写
            HStack(spacing: 8) {
                TextField("手动填写模型名", text: Binding(
                    get: { state.customModelDrafts[kind.rawValue] ?? "" },
                    set: { state.customModelDrafts[kind.rawValue] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .rounded))
                Button("应用") {
                    Task { await state.applyCustomModel(kind, name: state.customModelDrafts[kind.rawValue] ?? "") }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .disabled((state.customModelDrafts[kind.rawValue] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // ④ 外部模型（各厂商统一入口：填 Key → 拉取 → 选择）
            externalModelSection(kind: kind)

            // ⑤ 教师语音专有：音色 / 语速 / 自动朗读（原独立「语音」卡片，
            //    并入本板块后「配模型」与「怎么读」在同一处完成）
            if kind == .tts {
                teacherVoiceControls
            }
        }
    }

    /// 外部模型折叠区（与 LLM 云端一致的流程）。
    ///
    /// 默认展开状态跟着**当前生效的 Provider**走：这个能力正在用云端模型时，
    /// 一打开设置就应当看到那家供应商、已保存的 Key 与可选模型，
    /// 而不是一个折叠着的「外部模型」，还得再点一下才知道自己配过什么。
    @ViewBuilder
    private func externalModelSection(kind: AIProviderKind) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedExternal[kind.rawValue] ?? (state.capabilityInfos[kind]?.isRemote ?? false) },
            set: { expandedExternal[kind.rawValue] = $0 }
        )) {
            VStack(alignment: .leading, spacing: 9) {
                let options = state.externalProviderCache[kind.rawValue] ?? []
                if options.isEmpty {
                    // 说话检测 / 发音评测依赖逐帧音频与声学特征，云端没有通用接口，
                    // 因此不提供外部供应商——明确说出来，好过让用户对着空列表找原因。
                    Text(kind == .vad || kind == .pronunciation
                         ? "该能力基于逐帧音频在本地计算，暂无云端接口。"
                         : "该能力暂未配置外部供应商。")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                } else {
                    // 供应商标签
                    HStack(spacing: 8) {
                        ForEach(options, id: \.id) { option in
                            let selected = state.externalSelectedProvider[kind.rawValue] == option.id
                            // 已经存过 API Key 的供应商：右上角点一颗小绿点，
                            // 一眼看出「这家配好了，不用重新填」，不必逐个点开确认。
                            let configured = state.externalKeyConfigured.contains(option.id)
                            Button {
                                state.externalSelectedProvider[kind.rawValue] = option.id
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "cloud.fill").font(.system(size: 9))
                                    Text(option.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                                }
                                .foregroundStyle(selected ? Color.white : theme.primaryText)
                                .padding(.horizontal, 11)
                                .frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selected ? theme.accent : theme.surfaceAlt))
                                .overlay(alignment: .topTrailing) {
                                    if configured {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 7, height: 7)
                                            .overlay(Circle().strokeBorder(theme.panel, lineWidth: 1))
                                            .offset(x: 3, y: -3)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .help(configured
                                  ? "\(option.name)：API Key 已保存，可直接选择模型"
                                  : "\(option.name)：尚未填写 API Key")
                        }
                        Spacer()
                    }

                    if let providerID = state.externalSelectedProvider[kind.rawValue] {
                        // Key + 验证
                        HStack(spacing: 8) {
                            SecureField("API Key", text: Binding(
                                get: { state.externalKeyDrafts[providerID] ?? "" },
                                set: { state.externalKeyDrafts[providerID] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .rounded))
                            Button {
                                Task { await state.fetchExternalModels(kind: kind, providerID: providerID) }
                            } label: {
                                HStack(spacing: 4) {
                                    if state.isFetchingExternal {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "key.horizontal")
                                    }
                                    Text("验证并获取模型")
                                }
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .buttonStyle(.plain)
                            .disabled(state.isFetchingExternal)
                        }

                        // 当前已保存的密钥指纹（只露末 4 位）：换 Key 后一眼确认是否生效。
                        if let fingerprint = state.externalKeyFingerprints[providerID] {
                            Text("当前使用的密钥：\(fingerprint)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                        }

                        // 模型列表
                        let models = state.externalModels[providerID] ?? []
                        if !models.isEmpty {
                            Picker("选择模型", selection: Binding(
                                get: { state.capabilityInfos[kind]?.currentModel ?? models[0].id },
                                set: { model in Task { await state.applyExternalModel(kind, providerID: providerID, model: model) } }
                            )) {
                                ForEach(models) { model in
                                    Text(model.name).tag(model.id)
                                }
                            }
                            .labelsHidden()
                        }

                        if let message = state.externalMessages[providerID] {
                            Text(message)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(message.contains("成功") || message.contains("已启用") ? .green : .orange)
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cloud")
                    .font(.system(size: 11))
                Text("外部模型")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(theme.secondaryText)
        }
        .task {
            if state.externalProviderCache[kind.rawValue] == nil {
                state.externalProviderCache[kind.rawValue] = await state.remoteProviderOptions(for: kind)
                if state.externalSelectedProvider[kind.rawValue] == nil {
                    state.externalSelectedProvider[kind.rawValue] = state.externalProviderCache[kind.rawValue]?.first?.id
                }
            }
        }
    }

    /// 本地模型部署指导。
    private var deploymentTips: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0xF7B32B))
                Text("如何让应用自动识别新的本地模型")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            }
            Text("把模型统一放在 ~/AI_Models/ 对应模块目录下即可：\n• 语音识别 (asr)：模型文件放入 ~/AI_Models/asr/models/（如 ggml-*.bin）\n• 教师语音 (tts)：每个模型一个文件夹放入 ~/AI_Models/tts/\n• 说话检测 (vad) / 记忆索引 (embedding) / 发音评测 (pronunciation)：每个模型一个文件夹放入对应目录\n放好后点击各能力区块的刷新按钮（↻），应用会自动检测并列出可选。云端模型请展开「外部模型」填写 API Key 接入。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceAlt.opacity(0.6)))
    }

    // MARK: - 教师朗读（已并入模型管理中心的教师语音板块）

    /// 语音服务的在线状态 + 重新检测 + 最近错误。
    ///
    /// 原来是独立「语音」卡片的头部。卡片合并进模型管理中心后，这段仍然要有：
    /// 它是唯一能一眼看到「识别 / 教师朗读 现在通不通」的地方。
    private var voiceServiceStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                voiceStatusDot("识别", state.asrHealth)
                voiceStatusDot("教师朗读", state.ttsHealth)
                Spacer()
                Button {
                    Task { await state.bootstrapVoice() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("重新检测语音服务")
            }

            if let error = state.voiceError {
                Text(error)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceAlt.opacity(0.6)))
    }

    /// 老师朗读的行为设置：音色 / 语速 / 自动朗读。
    ///
    /// 从原独立「语音」卡片整体搬进**教师语音**能力区块——模型与朗读行为放在一起，
    /// 配完模型顺手就能调「怎么读」，不用在两个卡片之间来回找。
    @ViewBuilder
    private var teacherVoiceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(theme.divider.opacity(0.6))

            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accent)
                Text("老师怎么读")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            }

            // 教师音色 + 自动试听小喇叭
            HStack(spacing: 10) {
                Picker("老师的声音", selection: Binding(
                    get: { state.teacherVoice },
                    set: { voice in Task { await state.setVoice(voice) } }
                )) {
                    ForEach(state.availableVoices, id: \.self) { voice in
                        Text(voice.capitalized).tag(voice)
                    }
                }

                // 小喇叭：开启后切换音色自动试听
                Button {
                    Task { await state.setVoicePreview(!state.voicePreviewEnabled) }
                } label: {
                    Image(systemName: state.voicePreviewEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state.voicePreviewEnabled ? theme.accent : theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.surfaceAlt))
                        .overlay(Circle().strokeBorder(state.voicePreviewEnabled ? theme.accent.opacity(0.4) : theme.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(state.voicePreviewEnabled ? "自动试听已开启：切换音色即朗读示例（点此关闭）" : "自动试听已关闭（点此开启，切换音色即朗读示例）")

                // 立即试听
                Button {
                    Task { await state.speak("Nice to meet you!") }
                } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .help("立即试听当前音色")
            }

            // 朗读语速：与对话区「听老师读」右侧的选择器共用同一份配置
            HStack(spacing: 10) {
                Text("朗读语速")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                HStack(spacing: 6) {
                    ForEach(SpeechRate.allCases) { option in
                        Button {
                            Task { await state.setSpeechRate(option.rawValue) }
                        } label: {
                            Text(option.label)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(isSelected(rate: option) ? Color.white : theme.primaryText)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(
                                    Capsule().fill(isSelected(rate: option) ? theme.accent : theme.surfaceAlt)
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        isSelected(rate: option) ? theme.accent : theme.divider,
                                        lineWidth: 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .help("以 \(option.label) 语速朗读")
                    }
                }
                Spacer(minLength: 0)
            }

            Toggle("老师回复后自动朗读", isOn: Binding(
                get: { state.autoSpeak },
                set: { enabled in Task { await state.setAutoSpeak(enabled) } }
            ))
            .font(.system(size: 13, design: .rounded))

            // 朗读方式随当前生效的语音模型自动切换，在这里说清楚，免得用户以为是 bug。
            Text("\(state.speechDelivery.explanation)在聊天框点 🎤 说话，松开后文字会填进输入框；每条老师回复下方可点「听老师读」，右侧小胶囊可切换朗读语速（只改快慢、不变音调）。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(3)
        }
    }

    /// 语速档位是否当前选中（浮点比较留容差）。
    private func isSelected(rate: SpeechRate) -> Bool {
        abs(rate.rawValue - state.speechRate) < 0.01
    }

    private func voiceStatusDot(_ title: String, _ health: ProviderHealth) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(health.isUsable ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text("\(title) · \(health.userFacingDescription)")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
    }

    // MARK: - 学习

    private var learningCard: some View {
        card(title: "学习设置", systemImage: "leaf.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("练习模式", selection: Binding(
                    get: { state.productPracticeMode },
                    set: { mode in Task { await state.setPracticeMode(mode) } }
                )) {
                    ForEach(PracticeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                HStack {
                    Text("学习语言").frame(width: 88, alignment: .leading)
                    TextField("如 en-US", text: Binding(
                        get: { state.learningLanguage },
                        set: { value in Task { await state.setLearningLanguage(value) } }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("母语").frame(width: 88, alignment: .leading)
                    TextField("如 zh-CN", text: Binding(
                        get: { state.nativeLanguage },
                        set: { value in Task { await state.setNativeLanguage(value) } }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("教师音色").frame(width: 88, alignment: .leading)
                    TextField("音色名称", text: Binding(
                        get: { state.teacherVoice },
                        set: { value in Task { await state.setTeacherVoice(value) } }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
            .font(.system(size: 13, design: .rounded))
        }
    }

    // MARK: - 词汇本（每日推荐学习进度）

    private var vocabularyCard: some View {
        card(title: "词汇本", systemImage: "text.book.closed.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("每日推荐按「简单 → 中等 → 困难 → 词组」的节奏出词。某个等级全部认识后该等级不再出现，空缺由还没学完的最低等级补上。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showVocabularyResetConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("词汇本每日推荐学习进度重置")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.8), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("清空「认识」记录，每日推荐重新从简单档开始")

                Text(vocabularyResetSummary)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
        }
    }

    /// 「上次重置时间 + 上次已学词数 / 词库总词数」。
    private var vocabularyResetSummary: String {
        let total = state.dailyBankTotal
        guard let date = state.dailyProgressResetAt else {
            return total > 0 ? "还没有重置过 · 词库共 \(total) 词" : "还没有重置过"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "上次重置：\(formatter.string(from: date)) · 上次已学 \(state.dailyProgressResetLearned) / \(total) 词"
    }

    // MARK: - 缓存管理（大小 / 目录显示 + 清除）

    private var cacheCard: some View {
        card(title: "存储与缓存", systemImage: "externaldrive.fill") {
            VStack(alignment: .leading, spacing: 10) {
                let snapshot = state.cacheSnapshot

                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accent)
                    Text(snapshot.directory.isEmpty ? "—" : snapshot.directory)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .help(snapshot.directory)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("合计占用")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                    Text(snapshot.totalDisplay)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .monospacedDigit()
                    Spacer()
                    Button {
                        Task { await state.refreshCacheInfo() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("重新统计")
                }

                // 明细：学习记忆加锁标记（清理时保留）
                ForEach(snapshot.items) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isLearningData ? "lock.fill" : "doc")
                            .font(.system(size: 9))
                            .foregroundStyle(item.isLearningData ? theme.accent : theme.secondaryText)
                        Text(item.name)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        if item.isLearningData {
                            Text("学习记忆")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.accent.opacity(0.12)))
                        }
                        Spacer()
                        Text(CacheSnapshot.byteCount(item.bytes))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .monospacedDigit()
                    }
                }

                HStack(spacing: 10) {
                    if state.cacheFreedBytes > 0 {
                        Label("已释放 \(CacheSnapshot.byteCount(state.cacheFreedBytes))", systemImage: "trash.slash")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.green)
                    }
                    if let cleared = snapshot.lastClearedAt {
                        Text("上次清理：\(cleared.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    Button {
                        showClearConfirm = true
                    } label: {
                        HStack(spacing: 5) {
                            if isClearingCache {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "paintbrush.fill").font(.system(size: 11))
                            }
                            Text("清除缓存")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(isClearingCache || snapshot.items.isEmpty)
                    .help("清理过期对话流水并回收磁盘空间")
                }

                Text("清除只影响可再生的对话流水与数据库碎片；学习记忆（错题本、进度）和配置始终保留。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: - 高级

    private var advancedCard: some View {
        card(title: "高级", systemImage: "slider.horizontal.3") {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("服务端点").frame(width: 88, alignment: .leading)
                        TextField("http://127.0.0.1:11434", text: $endpointDraft)
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
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(.top, 8)
                .font(.system(size: 13, design: .rounded))
            } label: {
                Text("显示高级选项")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: - 日志

    private var logsCard: some View {
        card(title: "运行日志", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 6) {
                if logs.isEmpty {
                    Text("暂无日志")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                } else {
                    ForEach(logs.suffix(30)) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.level.rawValue.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 48, alignment: .leading)
                            Text(entry.message)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 通用

    private func card<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        card(title: title, systemImage: systemImage, trailing: { EmptyView() }, content: content)
    }

    /// 带「卡片右上角内容」的卡片：模型状态与「启动 / 关闭」按钮都放这里，
    /// 与模型管理中心各能力区块的布局保持一致。
    private func card<Content: View, Trailing: View>(
        title: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 8)
                trailing()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 8, x: 0, y: 3)
        )
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: .gray
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    private func loadRuntimeValues() async {
        let configuration = await state.services.configuration
        endpointDraft = configuration.resolvedProvider(for: .llm)?.endpoint ?? ""
        temperatureDraft = configuration.resolvedProvider(for: .llm)?.temperature ?? 0.7
        providerOptions = await state.llmProviderOptions()
        if state.selectedProviderID.isEmpty, let first = providerOptions.first {
            state.selectProviderTab(first.id)
        }
        logs = await LogBus.shared.recent(limit: 60)
    }
}
