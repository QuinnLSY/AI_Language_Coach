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
    /// 配置里的 LLM Provider 标签（本地 / 云端）。
    @State private var providerOptions: [(id: String, name: String, isRemote: Bool)] = []

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
                    voiceCard
                    learningCard
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
            await state.refreshCacheInfo()
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
                    get: { state.animalActivityEnabled },
                    set: { enabled in Task { await state.setAnimalActivity(enabled) } }
                ))
                .font(.system(size: 13, design: .rounded))

                Text("关闭活动时，小动物们会回到初始位置排排站好（成长之树右下角有同步的表情开关）。夜晚它们会自动安静下来。以上开关全局记忆，下次打开应用自动延续。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: - 模型提供商（本地 / 云端并存，二选一生效）

    private var modelCard: some View {
        card(title: "模型提供商", systemImage: "brain") {
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

    private var isSelectedProviderRemote: Bool {
        providerOptions.first { $0.id == state.selectedProviderID }?.isRemote ?? false
    }

    /// 本地模型（Ollama）：状态 + 模型选择。
    private var localProviderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.health.isUsable ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(state.health.userFacingDescription)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
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
            // ① API Key
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

            // ③ 推理强度
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

    // MARK: - 语音（说话 + 教师朗读）

    private var voiceCard: some View {
        card(title: "语音", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 12) {
                // 两个能力的在线状态
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

                // 本地语音模型（runtime 自报：模型 + 运行设备）
                if let runtimeInfo = state.ttsRuntimeInfo {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.accent)
                        Text("本地语音模型：\(runtimeInfo)")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }
                }

                // 教师音色
                Picker("老师的声音", selection: Binding(
                    get: { state.teacherVoice },
                    set: { voice in Task { await state.setVoice(voice) } }
                )) {
                    ForEach(state.availableVoices, id: \.self) { voice in
                        Text(voice.capitalized).tag(voice)
                    }
                }

                // 自动朗读
                Toggle("老师回复后自动朗读", isOn: Binding(
                    get: { state.autoSpeak },
                    set: { enabled in Task { await state.setAutoSpeak(enabled) } }
                ))
                .font(.system(size: 13, design: .rounded))

                Text("在聊天框点 🎤 说话，松开后文字会填进输入框；每条老师回复下方可点「听老师读」。语音完全在本地处理。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
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
