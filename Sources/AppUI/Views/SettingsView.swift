import AIDomain
import AIInterfaces
import AIServices
import AppCore
import AppKit
import SwiftUI

/// 设置里的伙伴角色：老师（侧边栏/聊天区 AI）、小学员（聊天区学员位/树上攀爬者）、
/// 小伙伴（陪着小学员一起爬树的那一只）。
enum PartnerRole: String, CaseIterable, Identifiable {
    case teacher
    case student
    case companion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teacher: "老师"
        case .student: "小学员"
        case .companion: "小伙伴"
        }
    }

    var caption: String {
        switch self {
        case .teacher: "显示在左侧边栏与聊天区"
        case .student: "显示在聊天区与成长之树攀爬者"
        case .companion: "陪小学员一起爬树，配饰跟着一起换"
        }
    }

    var icon: String {
        switch self {
        case .teacher: "graduationcap.fill"
        case .student: "figure.child"
        case .companion: "heart.fill"
        }
    }
}

public struct SettingsView: View {

    @Environment(\.forestTheme) var theme
    @Bindable var state: AppState

    @State var partnerRole: PartnerRole = .teacher
    @State var endpointDraft: String = ""
    /// 输入框的占位提示：**取自当前供应商的端点**，不在 UI 里写死任何地址/端口。
    @State var endpointPlaceholder: String = ""
    @State var temperatureDraft: Double = 0.7
    @State var logs: [LogEntry] = []
    /// 当前日志级别（`LogOptions` 的界面副本；改它即落 UserDefaults）。
    @State var logLevel: LogLevel = .debug
    @State var showAdvanced = false
    @State var isRefreshing = false
    @State var isClearingCache = false
    @State var showClearConfirm = false
    /// 备份导入确认框（#209）。
    @State var showImportConfirm = false
    /// 重置每日推荐学习进度的二次确认。
    @State var showVocabularyResetConfirm = false
    /// 重置闯关进度（全新起点）的二次确认。
    @State var showQuestResetConfirm = false
    // 使用说明（#413）是**全局**浮层（`state.showingHelp`）：菜单栏「帮助」也能开它，
    // 所以这里不再持有自己的一份 `@State`（两份就会各开各的）。
    /// 配置里的 LLM Provider 标签（本地 / 云端）。
    @State var providerOptions: [(id: String, name: String, isRemote: Bool)] = []
    /// 「外部模型」面板（统一接入入口）：
    /// 打开时记录是给哪个能力接的 —— 一份面板服务所有能力，卡片上因此永远只有一个按钮。
    @State var externalSheetKind: AIProviderKind?
    /// 「AI 大脑」卡片当前看的是本地模型还是外部模型（**固定两个标签，永不增长**）。
    @State var llmUsesExternal = false
    /// 是否已按当前生效 Provider 初始化过上面的标签（避免每次重绘都把它掰回来）。
    @State var didInitLLMTab = false
    // 克隆音色（第 24 步）：选中的参考音频 + 新建表单的两个输入。
    @State var pendingReferenceURL: URL?
    @State var pendingVoiceName: String = ""
    @State var pendingConsent: String = ""

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    helpCenterCard
                    displayCard
                    themeCard
                    motionCard
                    soundCard
                    partnerCard
                    forestCompanionsCard
                    modelCard
                    voiceModelCenterCard
                    learningCard
                    practiceReminderCard
                    dailyGoalCard
                    vocabularyCard
                    scenarioCard
                    privacyCard
                    cacheCard
                    runtimeCard
                    localSpeedCard
                    performanceCard
                    shortcutCenterCard
                    advancedCard
                    logsCard
                }
                .appPadding(20)
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
        // ⚠️ 本机服务启停命令的首次确认框（#S2-6）**不在这里**：2026-10-14 挪到
        // MainView 根上做全局唯一挂点 —— 开屏自启的提示条（#546）在对话区也要能弹它，
        // 挂在设置页里的话，用户不在设置页时框永远不出现。设置页点「启动」弹出的
        // 还是同一个框（MainView 是这棵树的根，窗口级呈现）。
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
            await state.refreshSemanticMemory()
            await state.refreshMemoryPressure()
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
        .confirmationDialog("确定重置闯关进度吗？", isPresented: $showQuestResetConfirm, titleVisibility: .visible) {
            Button("重置进度", role: .destructive) {
                Task { await state.resetQuestProgress() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有关卡归零、只开放第一关，情景任务的完成记录一并清空，无法恢复。词汇本、对话记录与学习记忆不受影响。")
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

    // MARK: - 通用

    func card<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        card(title: title, systemImage: systemImage, trailing: { EmptyView() }, content: content)
    }

    /// 带「卡片右上角内容」的卡片：模型状态与「启动 / 关闭」按钮都放这里，
    /// 与模型管理中心各能力区块的布局保持一致。
    func card<Content: View, Trailing: View>(
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
                    .appFont(14, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    // 卡片标题就是标题：报成 header，VoiceOver 的「标题」转轮才能逐卡跳。
                    // 这里是设置页**所有**卡片的唯一标题出口，改一处即全覆盖。
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing()
            }
            content()
        }
        .appPadding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .appElevation(.card)
        )
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
