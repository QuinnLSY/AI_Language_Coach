import AIDomain
import AIInterfaces
import AIServices
import AppCore
import AppKit
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
    /// 输入框的占位提示：**取自当前供应商的端点**，不在 UI 里写死任何地址/端口。
    @State private var endpointPlaceholder: String = ""
    @State private var temperatureDraft: Double = 0.7
    @State private var logs: [LogEntry] = []
    /// 当前日志级别（`LogOptions` 的界面副本；改它即落 UserDefaults）。
    @State private var logLevel: LogLevel = .debug
    @State private var showAdvanced = false
    @State private var isRefreshing = false
    @State private var isClearingCache = false
    @State private var showClearConfirm = false
    /// 备份导入确认框（#209）。
    @State private var showImportConfirm = false
    /// 重置每日推荐学习进度的二次确认。
    @State private var showVocabularyResetConfirm = false
    /// 配置里的 LLM Provider 标签（本地 / 云端）。
    @State private var providerOptions: [(id: String, name: String, isRemote: Bool)] = []
    /// 「外部模型」面板（统一接入入口）：
    /// 打开时记录是给哪个能力接的 —— 一份面板服务所有能力，卡片上因此永远只有一个按钮。
    @State private var externalSheetKind: AIProviderKind?
    /// 「AI 大脑」卡片当前看的是本地模型还是外部模型（**固定两个标签，永不增长**）。
    @State private var llmUsesExternal = false
    /// 是否已按当前生效 Provider 初始化过上面的标签（避免每次重绘都把它掰回来）。
    @State private var didInitLLMTab = false
    // 克隆音色（第 24 步）：选中的参考音频 + 新建表单的两个输入。
    @State private var pendingReferenceURL: URL?
    @State private var pendingVoiceName: String = ""
    @State private var pendingConsent: String = ""

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    themeCard
                    motionCard
                    partnerCard
                    forestCompanionsCard
                    modelCard
                    voiceModelCenterCard
                    learningCard
                    practiceReminderCard
                    vocabularyCard
                    privacyCard
                    cacheCard
                    runtimeCard
                    shortcutCenterCard
                    advancedCard
                    logsCard
                }
                .padding(20)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // 内容不足一屏时不硬弹（#360，同聊天区）。
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(theme.panel)
        // 设置页里散落着好几个文本输入（学习语言 / 母语 / 教师音色 / 手动模型名…）：
        // 点它们之外的地方就该交出焦点，否则快捷键会一直被输入框吃掉。
        .releaseKeyboardFocusOnOutsideClick()
        .task {
            await loadRuntimeValues()
            // 用已保存的配置回填外部模型草稿：Key、模型列表、选中的供应商。
            // 必须在 loadRuntimeValues 之后（后者决定 selectedProviderID）。
            await state.prefillExternalDrafts()
            await state.refreshCacheInfo()
            await state.refreshPrivacy()
            await state.refreshBackups()
            await state.refreshRuntimeLocations()
            // 「运行环境」卡的体检区（#275 接通）：打开设置页时刷一次；此后
            // 「重新载入配置」按钮会自带重刷（见 reloadConfigurationFromDisk）。
            await state.refreshRegistryCheck()
            await state.refreshRegistryCheck()
            await state.loadVocabularyBankIfNeeded()
        }
        // 外部模型统一面板：一份面板服务所有能力，卡片上因此只有一个按钮。
        .sheet(item: $externalSheetKind) { kind in
            ExternalModelSheet(
                kind: kind,
                vendors: state.externalProviderCache[kind.rawValue] ?? [],
                state: state,
                onClose: { externalSheetKind = nil }
            )
            .task {
                // 面板用到的供应商清单可能还没备好（例如从「AI 大脑」进来时）。
                if state.externalProviderCache[kind.rawValue] == nil {
                    state.externalProviderCache[kind.rawValue] = await state.remoteProviderOptions(for: kind)
                }
            }
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
            .buttonStyle(.appPressable)
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

    // MARK: - 动画效果（应用内动效开关，三态）

    private var motionCard: some View {
        card(title: "动画效果", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: Binding(
                    get: { state.motionMode },
                    set: { mode in Task { await state.setMotionMode(mode) } }
                )) {
                    ForEach(MotionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(motionHint)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// 三态的说明文案（抽成纯函数便于钉住措辞）。
    private var motionHint: String {
        switch state.motionMode {
        case .followSystem:
            "跟着系统的「减弱动态效果」设置走 —— 系统安静，语林也安静。"
        case .reduced:
            "星星、树叶都停下来，动画退成轻轻的淡入淡出。"
        case .full:
            "所有动画都开，与系统的「减弱动态效果」设置无关。"
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
                            withAnimation(.app(.reveal)) { partnerRole = role }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: role.icon)
                                    .font(.system(size: 12))
                                Text(role.title)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(partnerRole == role ? theme.onAccentFill : theme.primaryText)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(partnerRole == role ? theme.accentFill : theme.surfaceAlt)
                            )
                        }
                        .buttonStyle(.appPressable)
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
                        .foregroundStyle(theme.onAccentFill)
                        .padding(4)
                        .background(Circle().fill(theme.accentFill))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.appPressable)
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

    private var modelCard: some View {
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
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.warning)
                } else if llmUsesExternal {
                    remoteProviderSection
                } else {
                    localProviderSection
                }

                if let message = state.remoteMessage {
                    Text(message)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(message.contains("成功") || message.contains("已启用") ? .green : theme.warning)
                }

                if state.activeProvider?.id == state.selectedProviderID, let bootMessage = state.bootMessage {
                    Text(bootMessage)
                        .font(.system(size: 12, design: .rounded))
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
                Image(systemName: systemImage).font(.system(size: 10))
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
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
                .buttonStyle(.appPressable)
                .disabled(isRefreshing)
                .help("重新检测本地模型")
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
    private var teacherVoiceOptions: [ForestSelectOption<String>] {
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
                    .font(.system(size: 12, design: .rounded))
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
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(isRemoteActive
                         ? "模型：\(state.modelDraft.isEmpty ? "未选择" : state.modelDraft)\(state.activeReasoningEffort.map { " · 推理强度\(reasoningText($0))" } ?? "")"
                         : "点右边的按钮选一家厂商、填入该厂商的 API Key 即可接入。")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    externalSheetKind = .llm
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cloud.badge.plus").font(.system(size: 11))
                        Text(isRemoteActive ? "更换外部模型" : "配置外部模型")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
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
                .font(.system(size: 11, design: .rounded))
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

    // MARK: - 模型管理中心（ASR/TTS/VAD/Embedding/Pronunciation，本地检测 + 外部模型）

    private var voiceModelCenterCard: some View {
        card(title: "模型管理中心", systemImage: "shippingbox.fill") {
            VStack(alignment: .leading, spacing: 14) {
                // 历史坏配置修复提示：本地模型名曾经被写进云端供应商（云端没有这个模型），
                // 已在启动时清掉——必须告诉用户为什么他的模型选择变空了。
                if let notice = state.modelHealNotice {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.warning)
                        Text(notice)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.warning.opacity(0.12)))
                }
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
                    .foregroundStyle(summary.blockedTotal > 0 ? theme.warning : Color.green)
                Text("对外调用记录")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Button("刷新") { Task { await state.refreshRemoteCalls() } }
                    .font(.system(size: 11, design: .rounded))
                    .buttonStyle(.appPressable)
                    .foregroundStyle(theme.accent)
                Button("清空") { Task { await state.clearRemoteCalls() } }
                    .font(.system(size: 11, design: .rounded))
                    .buttonStyle(.appPressable)
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
                            // 端点写出来：用户拿着这条记录就能与服务商账单里的计费项逐条对上
                            // （`/v1/audio/speech` 是语音合成、`/v1/chat/completions` 是语言模型）。
                            Text(record.endpoint)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                            Text(record.model.isEmpty ? "—" : record.model)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(record.outcome.displayName)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(record.outcome == .ok ? Color.green : (record.outcome == .blocked ? theme.warning : Color.red))
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
                    .fill(info.healthOK ? Color.green : (info.currentModel == nil ? Color.gray : theme.warning))
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
                    .font(.system(size: 11))
                    .foregroundStyle(usingRemote ? theme.accent : theme.secondaryText)
                Text(usingRemote
                     ? "外部模型：\(info?.providerName ?? "已接入")\(info?.currentModel.map { " · \($0)" } ?? "")"
                     : "外部模型：未接入")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Button {
                    externalSheetKind = kind
                } label: {
                    Text(usingRemote ? "更换" : "配置")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(theme.surfaceAlt))
                        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.appPressable)
                .help("接入这一能力的外部模型")
            }
            if !usingRemote, kind == .vad {
                // 说话检测依赖逐帧音频，云端没有通用接口，明确说出来好过让用户对着空列表找原因。
                Text("该能力基于逐帧音频在本地计算，暂无云端接口。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            if !usingRemote, kind == .pronunciation {
                // 发音评测有两条通道：没有云端配置也能用（规则推断），配了就是声学实测。
                Text("当前按本地规则推断打分；接入云端发音评测后改为逐音素声学实测。")
                    .font(.system(size: 10, design: .rounded))
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
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0xF7B32B))
                Text("如何让应用自动识别新的本地模型")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            }
            Text("把模型统一放在 ~/AI_Models/ 对应模块目录下即可：\n• 语音识别 (asr)：模型文件放入 ~/AI_Models/asr/models/（如 ggml-*.bin）\n• 教师语音 (tts)：每个模型一个文件夹放入 ~/AI_Models/tts/\n• 说话检测 (vad) / 发音评测 (pronunciation)：每个模型一个文件夹放入对应目录\n• 记忆索引 (embedding)：本机由 Ollama 提供——在 Ollama 安装 nomic-embed-text 等嵌入模型后，刷新即可列出；也可在「外部模型」接入云端嵌入\n放好后点击各能力区块的刷新按钮（↻），应用会自动检测并列出可选。云端模型请展开「外部模型」填写 API Key 接入。")
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
                .buttonStyle(.appPressable)
                .help("重新检测语音服务")
            }

            if let error = state.voiceError {
                Text(error)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.warning)
            }

            // 语音链路的费用口径：拼写纠正在说完一句话后自动发生，用户看不见，
            // 所以必须写出来——云端语言模型下一律跳过，语音输入不会产生 token 费用。
            if !state.spellingNote.isEmpty {
                Text(state.spellingNote)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceAlt.opacity(0.6)))
    }

    // MARK: - 克隆音色（第 24 步：音色定制与克隆）

    /// 音色克隆：显式授权 + 本地参考音频 + 启用时可见提示。
    ///
    /// 需求原文（Phase 24）就是这几条，界面上一步都不能省：
    /// 授权说明必填、参考音频只能从本机选、启用后必须看得见正在用哪个克隆音色。
    /// 至于「怎么拿参考音频做克隆」属于 runtime 的实现 —— 应用只交给它一个通用音色标识。
    @ViewBuilder
    private var clonedVoiceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(theme.divider.opacity(0.6))

            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accent)
                Text("克隆音色")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 4)
                Text(state.voiceCloningSupported ? "当前供应商支持克隆" : "当前供应商未声明支持克隆")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(state.voiceCloningSupported ? theme.accent : theme.secondaryText)
            }

            Text("只用本人或已获授权的声音。参考音频会复制进本机应用目录，不上传；启用后老师就用它朗读。")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let indicator = state.activeVoiceIndicator {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.accent)
                    Text(indicator)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: 4)
                    Button("切回内置") { Task { await state.deactivateClonedVoice() } }
                        .buttonStyle(.appPressable)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.accent)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.accent.opacity(0.10)))
            }

            let cloned = state.voiceProfiles.filter(\.isCloned)
            if cloned.isEmpty, pendingReferenceURL == nil {
                Text("还没有克隆音色。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(cloned) { profile in
                clonedVoiceRow(profile)
            }

            if let url = pendingReferenceURL {
                pendingVoiceForm(referenceURL: url)
            } else {
                Button {
                    pickReferenceAudio()
                } label: {
                    Label("从本地音频新建…", systemImage: "plus.circle")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.appPressable)
                .foregroundStyle(theme.accent)
            }

            if let notice = state.voiceProfileNotice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.accent)
                    Text(notice)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        state.clearVoiceProfileNotice()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.appPressable)
                    .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    /// 一条克隆音色档案：启用 / 停用 / 删除。
    @ViewBuilder
    private func clonedVoiceRow(_ profile: VoiceProfile) -> some View {
        let isActive = state.activeClonedVoice?.id == profile.id
        HStack(spacing: 8) {
            Image(systemName: isActive ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? theme.accent : theme.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text(profile.consent?.statement ?? "")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(isActive ? "停用" : "启用") {
                Task {
                    if isActive {
                        await state.deactivateClonedVoice()
                    } else {
                        await state.activateClonedVoice(id: profile.id)
                    }
                }
            }
            .buttonStyle(.appPressable)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(isActive ? theme.secondaryText : theme.accent)

            Button {
                Task { await state.deleteClonedVoice(id: profile.id) }
            } label: {
                Image(systemName: "trash").font(.system(size: 10))
            }
            .buttonStyle(.appPressable)
            .foregroundStyle(theme.secondaryText)
            .help("删除这个音色档案")
        }
    }

    /// 新建表单：音频已选定，等用户填名字与授权说明。
    @ViewBuilder
    private func pendingVoiceForm(referenceURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(referenceURL.lastPathComponent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("音色名字（如「我的声音」）", text: $pendingVoiceName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .rounded))
            TextField("授权说明：声音来源与使用范围（必填）", text: $pendingConsent)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .rounded))
            HStack(spacing: 10) {
                Button("保存") {
                    let url = referenceURL
                    Task {
                        await state.createClonedVoice(
                            name: pendingVoiceName,
                            referenceURL: url,
                            consentStatement: pendingConsent
                        )
                        pendingReferenceURL = nil
                        pendingVoiceName = ""
                        pendingConsent = ""
                    }
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .disabled(pendingVoiceName.trimmingCharacters(in: .whitespaces).isEmpty
                          || pendingConsent.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("取消") {
                    pendingReferenceURL = nil
                    pendingVoiceName = ""
                    pendingConsent = ""
                }
                .buttonStyle(.appPressable)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.surfaceAlt))
    }

    /// 选择参考音频：只认本机文件 —— 面板给不出 URL 之外的来源，
    /// 从入口上就堵死了「填一个远端地址做克隆」这条路。
    private func pickReferenceAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择一段本地录音作为参考音频（仅使用本人或已获授权的声音）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingVoiceName = ""
        pendingConsent = ""
        pendingReferenceURL = url
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
                ForestSelect(
                    "老师的声音",
                    icon: "waveform",
                    selection: Binding(
                        get: { state.teacherVoice },
                        set: { voice in Task { await state.setVoice(voice) } }
                    ),
                    options: teacherVoiceOptions,
                    width: 170,
                    help: "教师朗读时使用的声音；云端音色由供应商决定，切换后会自动重读。"
                )

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
                .buttonStyle(.appPressable)
                .help(state.voicePreviewEnabled ? "自动试听已开启：切换音色即朗读示例（点此关闭）" : "自动试听已关闭（点此开启，切换音色即朗读示例）")

                // 立即试听
                Button {
                    Task { await state.speak("Nice to meet you!") }
                } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.appPressable)
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
                        .buttonStyle(.appPressable)
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
                .fill(health.isUsable ? Color.green : theme.warning)
                .frame(width: 8, height: 8)
            Text("\(title) · \(health.userFacingDescription)")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
    }

    // MARK: - 语言候选（学习语言 / 母语的唯一下拉数据源）

    /// 学习语言下拉的选项。
    ///
    /// ⚠️ 走 `includingCurrent` 而不是直接用 `LanguageOptions.learning`：
    /// 老配置里可能存着清单外的标识，不补进候选就会显示「未选择」，
    /// 用户看着像设置丢了，一碰下拉还会被无声改掉。
    private var learningLanguageOptions: [ForestSelectOption<String>] {
        LanguageOptions.includingCurrent(state.learningLanguage, in: LanguageOptions.learning)
            .map { ForestSelectOption(value: $0.tag, title: $0.title) }
    }

    /// 母语下拉的选项，规则同学习语言。
    private var nativeLanguageOptions: [ForestSelectOption<String>] {
        LanguageOptions.includingCurrent(state.nativeLanguage, in: LanguageOptions.native)
            .map { ForestSelectOption(value: $0.tag, title: $0.title) }
    }

    /// 两个下拉共用同一个宽度：同排控件宽度不一致会显得没对齐。
    ///
    /// ⚠️ 宽度必须**量**出来（`widthFitting`），不能凭感觉写数字 ——
    /// 写小的表现是值被截成省略号，而几何空档上看不出来（2026-09-14 的「语速不显示」就是这样来的）。
    private var languageSelectWidth: CGFloat {
        ForestSelect<String>.Metrics.regular.widthFitting(
            (learningLanguageOptions + nativeLanguageOptions).map(\.title)
        )
    }

    /// 老师性格下拉的宽度：同样**量**出来（「温和鼓励」是四个字，拍数字最容易把它截掉）。
    private var personaSelectWidth: CGFloat {
        ForestSelect<TeacherPersona>.Metrics.regular.widthFitting(
            TeacherPersona.allCases.map(\.displayName)
        )
    }

    // MARK: - 学习

    private var learningCard: some View {
        card(title: "学习设置", systemImage: "leaf.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForestSelect(
                        "练习模式",
                        icon: "leaf",
                        selection: Binding(
                            get: { state.productPracticeMode },
                            set: { mode in Task { await state.setPracticeMode(mode) } }
                        ),
                        options: PracticeMode.allCases.map {
                            ForestSelectOption(value: $0, title: $0.displayName)
                        },
                        width: 170
                    )
                    Spacer()
                }

                ForestSelect(
                    "学习语言",
                    icon: "globe",
                    selection: Binding(
                        get: { state.learningLanguage },
                        set: { value in Task { await state.setLearningLanguage(value) } }
                    ),
                    options: learningLanguageOptions,
                    width: languageSelectWidth,
                    help: "当前版本只支持英语；变体决定语音识别与发音评测用哪一套英语模型。"
                )

                ForestSelect(
                    "母        语",
                    icon: "character.bubble",
                    selection: Binding(
                        get: { state.nativeLanguage },
                        set: { value in Task { await state.setNativeLanguage(value) } }
                    ),
                    options: nativeLanguageOptions,
                    width: languageSelectWidth,
                    help: "释义、翻译与讲解使用的语言。"
                )

                ForestSelect(
                    "老师性格",
                    icon: "person.wave.2",
                    selection: Binding(
                        get: { state.teacherPersona },
                        set: { persona in Task { await state.setTeacherPersona(persona) } }
                    ),
                    options: TeacherPersona.allCases.map {
                        ForestSelectOption(value: $0, title: $0.displayName)
                    },
                    width: personaSelectWidth,
                    help: state.teacherPersona.summary
                )

                // 教师音色原来在这里还有一个手填框，与上方「模型管理中心 → 老师怎么读」里的下拉
                // 指向同一个值、却**绕过了** `setVoice`（不会停用克隆音色）——
                // 一个设置两处入口、行为还不一致。这里只留一条指路，避免两处各说各的。
                Text("教师音色已并入上方「模型管理中心 → 老师怎么读」，在那里切换会立即试听。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .lineSpacing(3)
            }
            .font(.system(size: 13, design: .rounded))
        }
    }

    // MARK: - 提醒我练习（#226 本地定时通知）

    private var practiceReminderCard: some View {
        card(title: "提醒我练习", systemImage: "bell.badge.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("每天定时提醒我练一会儿", isOn: Binding(
                    get: { state.practiceReminderEnabled },
                    set: { enabled in Task { await state.setPracticeReminderEnabled(enabled) } }
                ))
                .font(.system(size: 13, design: .rounded))

                if state.practiceReminderEnabled {
                    HStack(spacing: 10) {
                        Text("提醒时刻")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(theme.primaryText)

                        // 时刻用自绘步进（系统 DatePicker 样式与整体口径不符，且命中区退化）。
                        HStack(spacing: 4) {
                            reminderButton(systemImage: "minus") {
                                let total = state.practiceReminderHour * 60 + state.practiceReminderMinute
                                let shifted = (total - 30 + 24 * 60) % (24 * 60)
                                Task {
                                    await state.setPracticeReminderTime(hour: shifted / 60, minute: shifted % 60)
                                }
                            }
                            Text(String(format: "%02d:%02d", state.practiceReminderHour, state.practiceReminderMinute))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                                .monospacedDigit()
                                .frame(width: 46)
                            reminderButton(systemImage: "plus") {
                                let total = state.practiceReminderHour * 60 + state.practiceReminderMinute
                                let shifted = (total + 30) % (24 * 60)
                                Task {
                                    await state.setPracticeReminderTime(hour: shifted / 60, minute: shifted % 60)
                                }
                            }
                        }
                        Text("每 30 分钟一档")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 20)
                }

                if state.reminderAuthorizationDenied {
                    Text("通知权限被系统拒绝了：请到「系统设置 → 通知 → 语林」里允许通知，之后开关一次提醒即可生效。")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.warning)
                        .lineSpacing(3)
                } else if state.practiceReminderEnabled {
                    Text(TodayPanel.practiceReminderCopy(streakDays: 0).body)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .lineSpacing(3)
                } else {
                    Text("到点小鹅子会来敲门 🐧 —— 应用没开着也能收到（走系统通知）。点击通知直接回到今天的作业。")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .lineSpacing(3)
                }
            }
        }
    }

    private func reminderButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // ⚠️ 必须是 Image(systemName:) —— 写成 Image(systemImage) 会匹配到
            // Image(_ name:)（按资源名找图片），"minus"/"plus" 不是资源名 → 图标空白。
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .frame(width: 20, height: 20)
                .background(Circle().fill(theme.hover))
        }
        .buttonStyle(.appPressable)
    }

    // MARK: - 词汇本（每日推荐学习进度）

    private var vocabularyCard: some View {
        card(title: "词汇本", systemImage: "text.book.closed.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("每日推荐按「简单 → 中等 → 困难 → 词组」的节奏出词。某个等级全部认识后该等级不再出现，空缺由还没学完的最低等级补上。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                // 词库规模：**去重后**的词数（跨词典同名词只算一个），与词典页页头同一个数。
                // ⚠️ 不是「学员自己收录了几词」——那个在下面那行「本机已收录」里。
                if state.dictionaryUniqueWordCount > 0 {
                    Text("词库共 \(state.dictionaryUniqueWordCount) 词 · \(state.dictionaryBooks.count) 本")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .monospacedDigit()
                }

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
                .buttonStyle(.appPressable)
                .help("清空「认识」记录，每日推荐重新从简单档开始")

                Text(vocabularyResetSummary)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
            // 卡片一出现就把两个数刷新到最新（幂等、便宜）：
            // 词库规模只在词典页被读过，本机收录数只在词汇本页被读过 ——
            // 这一轮启动若那两个页面都没进过，卡片会少一行 / 显示旧值。
            .task {
                await state.reloadDictionaryLibrary()
                await state.reloadVocabulary()
            }
        }
    }

    /// 「上次重置时间 + 上次已学词数」+「本机已收录（去重）词数」。
    ///
    /// ⚠️ 三个数各是各的，文案必须写清是谁的，否则一眼看去像自相矛盾：
    /// - 卡片上「词库共 N 词」= **去重后的词典规模**（`dictionaryUniqueWordCount`，与词典页同源，含全部可见词典）；
    /// - 本行分母 = `dailyBankTotal` = **每日推荐词源**去重后的词数 —— 只算被勾成词源的那几本，
    ///   勾得比可见词典少时它就是个小一点的数，所以这里必须标「推荐词源」；
    /// - 「本机已收录 M 词」= `vocabularyUniqueWordCount`，学员自己收进词汇本的词（按词去重）。
    private var vocabularyResetSummary: String {
        let collected = state.vocabularyUniqueWordCount
        let collectedText = collected > 0 ? "本机已收录 \(collected) 词" : "还没有收录单词"
        let total = state.dailyBankTotal
        guard let date = state.dailyProgressResetAt else {
            return "还没有重置过 · \(collectedText)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let learned = total > 0
            ? "上次已学 \(state.dailyProgressResetLearned) / \(total) 词（推荐词源）"
            : "上次已学 \(state.dailyProgressResetLearned) 词"
        return "上次重置：\(formatter.string(from: date)) · \(learned) · \(collectedText)"
    }

    // MARK: - 隐私与安全（本地优先 + 外发披露）

    private var privacyCard: some View {
        card(title: "隐私与安全", systemImage: "lock.shield.fill") {
            VStack(alignment: .leading, spacing: 10) {
                let report = state.privacyReport
                let disclosure = report.disclosure

                HStack(spacing: 6) {
                    Image(systemName: disclosure.isLocalOnly ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(disclosure.isLocalOnly ? .green : theme.warning)
                    Text(disclosure.summary)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                }

                // 有外发就得把「谁、发到哪、发了什么」摊开给用户看——
                // 这是 §33 的硬要求：云端功能必须显式启用并明确披露。
                if !disclosure.flows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(disclosure.flows) { flow in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(flow.kind.displayName)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(theme.accent)
                                Text(flow.displayName)
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(theme.primaryText)
                                Text(flow.host)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(theme.secondaryText)
                                Spacer(minLength: 4)
                                Text(flow.categories.map(\.displayName).joined(separator: "、"))
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                    }
                }

                Divider().overlay(theme.divider)

                Text("数据存放位置")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                ForEach(report.locations) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: item.isSensitive ? "lock.fill" : "doc")
                                .font(.system(size: 9))
                                .foregroundStyle(item.isSensitive ? theme.accent : theme.secondaryText)
                            Text(item.title)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                            Spacer(minLength: 6)
                            if let reveal = item.revealPath {
                                FinderRevealButton(path: reveal, compact: true)
                            }
                        }
                        Text(item.detail)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                        Text(item.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                if !report.dataDirectory.isEmpty {
                    FinderRevealButton(path: report.dataDirectory)
                }

                Text("默认全部在本机处理：录音、转写、学习记忆与配置都不上传。只有你在「模型管理中心」启用了云端供应商，对应能力的数据才会发往上面列出的域名；日志与留痕只记录元数据，不记录你说的话。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// 「在 Finder 中打开」按钮。
    ///
    /// 打开目录这件事在 App 内部是**零副作用的**——界面哪里都不会变。
    /// 不给即时反馈，用户会以为自己没点上（Finder 窗口也可能藏在其它窗口后面）。
    /// 所以：按住缩一下 + 松开回弹，打开后短暂显示「已在 Finder 中打开」。
    private struct FinderRevealButton: View {
        @Environment(\.forestTheme) private var theme
        @State private var isPressing = false
        @State private var didOpen = false
        @State private var revertTask: Task<Void, Never>?

        let path: String
        /// 按钮文案（默认是数据根目录那句）。
        var title: String = "在 Finder 中打开数据目录"
        /// 紧凑模式：只画一个图标。
        ///
        /// 「数据存放位置」列表里每一行都自带落点，六行各配一句完整文案会把卡片撑爆，
        /// 于是列表内只留图标（提示走 `.help`），卡片底部那颗才是完整按钮。
        var compact: Bool = false

        var body: some View {
            Button(action: reveal) {
                HStack(spacing: 5) {
                    Image(systemName: didOpen ? "checkmark.circle.fill" : (isPressing ? "folder.fill" : "folder"))
                        .font(.system(size: 11))
                    if !compact {
                        Text(didOpen ? "已在 Finder 中打开" : title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundStyle(didOpen ? .green : theme.accent)
                .padding(.horizontal, compact ? 6 : 9)
                .padding(.vertical, compact ? 3 : 5)
                .background(Capsule().fill(theme.surfaceAlt))
                .scaleEffect(isPressing ? 0.94 : 1)
                .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .help(path)
            // simultaneous 而非 gesture：保留 Button 自身的点击语义。
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in withAnimation(.app(.press)) { isPressing = true } }
                    .onEnded { _ in
                        withAnimation(.app(.press)) { isPressing = false }
                    }
            )
            .appAnimation(.reveal, value: didOpen)
        }

        private func reveal() {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            didOpen = true
            revertTask?.cancel()
            revertTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.app(.reveal)) { didOpen = false }
            }
        }
    }

    // MARK: - 运行环境（版本 / 配置位置 / 配置体检）

    /// 「运行环境」卡片：这一版是什么、配置从哪读、每个能力到底谁在生效。
    ///
    /// 这一整张卡都是补上来的，对应的都是「建好没接通」的实账：
    /// - 版本号只写在打包脚本里，界面上看不到（`make_app.sh` 硬编码 0.4.0 与 v1.0 不符）；
    /// - `config.json` 在哪、默认配置有没有读进来，没有任何地方告诉用户；
    /// - 在外面手改了配置**只能重启应用**（`ConfigStore.reload()` 零调用）；
    /// - 模型注册表的读侧（`listAvailable` / `getDefault` / `inconsistencies` 三条投影接口）
    ///   零消费方 —— 也就是「配置一致性体检」这件事从来没发生过。
    private var runtimeCard: some View {
        card(title: "运行环境", systemImage: "stethoscope") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("版本")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(AppVersion.display)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }

                if let failure = state.configLoadFailure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("配置文件")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(state.configLocationPath.isEmpty ? "（尚未取到）" : state.configLocationPath)
                        .font(.system(size: 10, design: .monospaced))
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
                                .font(.system(size: 11))
                            Text("重新载入配置")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
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
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Button {
                            state.dismissConfigReloadNotice()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.appPressable)
                        .help("收起回执")
                    }
                }

                Divider().overlay(theme.divider)

                Text("配置体检")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.registryCheckRows) { row in
                        registryCheckRow(row)
                    }
                }

                Text("体检只看**配置层**：谁被选中、有没有缺 Key、有没有指向已停用的供应商。服务真的通不通，看上面各能力区块的状态点。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 一行体检结果：能力 → 谁在生效 / 为什么不生效。
    private func registryCheckRow(_ row: RegistryCheckRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(row.isHealthy ? Color.green : theme.warning)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.kind.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    if let effective = row.effective {
                        Text(effective.provider + (effective.model.map { " · \($0)" } ?? ""))
                            .font(.system(size: 11, design: .rounded))
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
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.warning)
                    }
                }
                ForEach(row.issues, id: \.self) { issue in
                    Text(issue)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let health = row.healthDescription {
                    Text(health)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 「一个都没配」和「配了但全停用」在用户眼里都表现为「用不了」，
                // 但要做的事完全不同。不把这两个数摆出来，这一行就只能说
                // 「没有生效的供应商」，等于什么都没说。
                if row.providerCount > 0 {
                    Text("共 \(row.providerCount) 个供应商 · 启用 \(row.enabledCount) 个")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText.opacity(0.85))
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 快捷键中心（#281：所有可设的键都在这里改）

    /// 内容整个在 `ShortcutCenterCard` 里（搬出去是为了能单独离屏渲染回归）。
    /// 这里只负责套上设置页统一的卡片外框。
    private var shortcutCenterCard: some View {
        card(title: "快捷键中心", systemImage: "keyboard") {
            ShortcutCenterCard(state: state)
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
                    .buttonStyle(.appPressable)
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
                        .foregroundStyle(theme.onAccentFill)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accentFill))
                    }
                    .buttonStyle(.appPressable)
                    .disabled(isClearingCache || snapshot.items.isEmpty)
                    .help("清理过期对话流水并回收磁盘空间")
                }

                Text("清除只影响可再生的对话流水与数据库碎片；学习记忆（错题本、进度）和配置始终保留。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)

                Divider().overlay(theme.divider)

                // 学习库被隔离重建必须让用户看见：不说，用户会以为旧记录还在。
                if let note = state.databaseRecoveryNote {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.warning)
                        Text(note)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }
                    Divider().overlay(theme.divider)
                }

                // 本轮启动应用了备份恢复：替换了什么要说清楚。
                if let note = state.restoreNote {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.accent)
                        Text(note)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                    }
                    Divider().overlay(theme.divider)
                }

                Text("数据备份")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                HStack(spacing: 10) {
                    Button {
                        Task { await state.exportBackup() }
                    } label: {
                        HStack(spacing: 5) {
                            if state.isExportingBackup {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.down.fill").font(.system(size: 11))
                            }
                            Text("导出备份")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(theme.onAccentFill)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accentFill))
                    }
                    .buttonStyle(.appPressable)
                    .disabled(state.isExportingBackup)
                    .help("把学习库、配置和调用留痕打包成一个带时间戳的 zip")

                    Button {
                        chooseBackupToImport()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.up.fill").font(.system(size: 11))
                            Text("导入备份")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(theme.divider, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.appPressable)
                    .disabled(state.isExportingBackup)
                    .help("从备份 zip 恢复学习库与配置（重启后生效，恢复前会自动留底当前数据）")

                    if let first = state.backupSnapshots.first {
                        Text("最近备份：\(first.fileName)")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                // 导入确认框：替换范围、自动留底、重启生效，三件事都要说清楚。
                .alert(
                    "用这份备份恢复？",
                    isPresented: $showImportConfirm,
                    presenting: state.backupImportPlan
                ) { plan in
                    Button("恢复并重启后生效", role: .destructive) {
                        Task { await state.confirmBackupImport() }
                    }
                    Button("取消", role: .cancel) {
                        state.cancelBackupImport()
                    }
                } message: { plan in
                    Text(
                        "将替换：\(plan.scopeDescription)\(plan.includesCallLog ? "、调用留痕" : "")。\n"
                        + "替换前会自动把当前数据再备份一份；恢复在重启应用时生效。"
                    )
                }

                ForEach(state.backupSnapshots.prefix(3)) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.secondaryText)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Spacer()
                        Text(item.sizeDisplay)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .monospacedDigit()
                    }
                }

                // 已安排恢复：如实说明何时生效、替换了什么。
                if let notice = state.backupImportNotice {
                    HStack(alignment: .top, spacing: 6) {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Button {
                            state.dismissBackupImportNotice()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.appPressable)
                        .help("知道了，收起这条回执")
                    }
                }

                if let error = state.backupError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.warning)
                }

                Text("备份包含学习库（含 -wal）、配置与调用留痕，存在本机，不上传任何地方。导入坏包会被校验拦下，不会动现有数据。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// 选备份文件 → 校验 → 弹确认框（校验失败的原因会出现在下方错误区）。
    private func chooseBackupToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.message = "选择要恢复的备份压缩包（AI_Language_Coach_备份_….zip）"
        guard panel.runModal() == .OK, let url = panel.url else {
            state.cancelBackupImport()
            return
        }
        Task {
            await state.inspectBackup(at: url.path)
            if state.backupImportPlan != nil {
                showImportConfirm = true
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
            VStack(alignment: .leading, spacing: 8) {
                // 级别与清空：这两颗原本没有界面 —— `LogBus.setMinimumLevel` / `clear()`
                // 写好了却零调用，日志永远是最低门槛全收、也只进不出。
                HStack(spacing: 8) {
                    Text("级别")
                        .font(.system(size: 12, design: .rounded))
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
                                .font(.system(size: 10))
                            Text("清空")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.surfaceAlt))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.appPressable)
                    .help("清空设置页展示的日志（系统日志里的历史清不掉）")
                }

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
                    // 卡片标题就是标题：报成 header，VoiceOver 的「标题」转轮才能逐卡跳。
                    // 这里是设置页**所有**卡片的唯一标题出口，改一处即全覆盖。
                    .accessibilityAddTraits(.isHeader)
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
                .appElevation(.card)
        )
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
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
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

    private func loadRuntimeValues() async {
        let configuration = await state.services.configuration
        endpointDraft = configuration.resolvedProvider(for: .llm)?.endpoint ?? ""
        endpointPlaceholder = configuration.resolvedProvider(for: .llm)?.endpoint ?? ""
        temperatureDraft = configuration.resolvedProvider(for: .llm)?.temperature ?? 0.7
        providerOptions = await state.llmProviderOptions()
        if state.selectedProviderID.isEmpty, let first = providerOptions.first {
            state.selectProviderTab(first.id)
        }
        logLevel = LogOptions.minimumLevel
        logs = await LogBus.shared.recent(limit: 60)
    }
}
