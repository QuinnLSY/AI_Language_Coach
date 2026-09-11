import AIDomain
import AppCore
import AppKit
import SwiftUI

/// 主界面：**左侧可收拉侧边栏 / 中间对话 / 右侧成长之树闯关画布**。
/// - 三栏顶栏统一 64pt 高，顶部分界线对齐；
/// - 对话与成长之树之间是可拖动分割线（拖动调整两栏宽度，内容自适应居中）；
/// - 整页弹性布局：窗口变化时按可用宽度重新分配，不再需要手动拉大窗口。
public struct MainView: View {

    @Bindable var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.forestTheme) private var theme

    /// 成长之树面板宽度（可拖动），由窗口宽度约束夹取。
    @State private var treePanelWidth: CGFloat = 380
    @State private var treeDragStart: CGFloat?

    private let sideDividerWidth: CGFloat = 1
    private let resizeHandleWidth: CGFloat = 14
    private let chatMinWidth: CGFloat = 400
    private let treeMinWidth: CGFloat = 300

    public init(state: AppState) { self.state = state }

    public var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let sidebarW = state.isSidebarExpanded ? AppSidebar.expandedWidth : AppSidebar.collapsedWidth
            let fixedW = sidebarW + sideDividerWidth + resizeHandleWidth
            let treeW = treeWidth(available: total - fixedW)
            let chatW = max(chatMinWidth, total - fixedW - treeW)

            ZStack {
                // 天空不再自己画天体：右上角的太阳/月亮由 CelestialToggle 画在内容层之上，
                // 这样它才是「看得见、点得到」的日夜切换控件（点击即切换）。
                ForestSky(theme: state.theme, showsCelestial: false)

                HStack(spacing: 0) {
                    AppSidebar(state: state)
                        .frame(width: sidebarW)

                    Divider().overlay(state.theme.divider)
                        .frame(width: sideDividerWidth)

                    chatArea
                        .frame(width: chatW)

                    resizeHandle
                        .frame(width: resizeHandleWidth)

                    levelPanel
                        .frame(width: treeW)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 右上角：太阳 / 月亮 = 日夜切换（位置与原先天空装饰完全一致）
                CelestialToggle {
                    Task { await state.toggleDayNight() }
                }
                .frame(width: 130, height: 130)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 64)
                .padding(.top, 44)
                .zIndex(2)

                if state.showingSettings {
                    settingsOverlay
                }

                if state.showingScenarios {
                    scenariosOverlay
                }

                // 模型启停结果：顶部最前方，向下弹入 → 数秒后向上收起
                if let toast = state.modelToast {
                    ModelToastView(toast: toast) { state.dismissModelToast() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 18)
                        .zIndex(50)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // 情景结算提示（星星入账 / 通关）——浮在最上层，数秒后自动消失
                if let reward = state.lastReward {
                    RewardToast(reward: reward) { state.dismissReward() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 78)
                        .zIndex(30)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 720)
        .forestTheme(state.theme)
        // 日夜切换作用于全局：原生控件（TextField / Picker / 滚动条）也一起跟随。
        .preferredColorScheme(state.theme.isNight ? .dark : .light)
        .animation(.easeInOut(duration: 0.5), value: state.theme.palette)
        .animation(.easeOut(duration: 0.22), value: state.showingSettings)
        .animation(.easeOut(duration: 0.22), value: state.showingScenarios)
        .task {
            state.systemIsDark = (colorScheme == .dark)
            await state.start()
            await state.loadScenarios()
            // 截图/验证辅助：--theme day|night|system 临时切换主题（**不写入配置**）
            if let index = CommandLine.arguments.firstIndex(of: "--theme"),
               index + 1 < CommandLine.arguments.count,
               let mode = ThemeMode(rawValue: CommandLine.arguments[index + 1]) {
                state.themeMode = mode
            }
            // 截图/验证辅助：--open-settings 启动时直接打开设置面板
            if CommandLine.arguments.contains("--open-settings") {
                state.showingSettings = true
            }
            // 截图/验证辅助：--open-scenarios 启动时直接打开情景选择面板
            if CommandLine.arguments.contains("--open-scenarios") {
                state.showingScenarios = true
            }
            // 截图/验证辅助：--open-records 启动时直接进入学习记录页
            if CommandLine.arguments.contains("--open-records") {
                Task { await state.openRecords() }
            }
            // 截图/验证辅助：--open-shadowing 启动时直接进入跟读页
            if CommandLine.arguments.contains("--open-shadowing") {
                await state.openShadowing()
            }
            // 截图/验证辅助：--open-vocabulary 启动时直接进入词汇本页
            // （--daily-flip / --vocabulary-tail 自带进页，见 VocabularyView 的验证钩子）
            if CommandLine.arguments.contains("--open-vocabulary")
                || CommandLine.arguments.contains("--daily-flip")
                || CommandLine.arguments.contains("--vocabulary-tail") {
                await state.openVocabulary()
            }
            // 截图/验证辅助：--vocabulary-draft "sign" 进词汇本 + 往添加框塞一段输入，
            // 直接看「添加」按钮与悬浮联想浮层（本机 UI 自动化打字不可靠）。
            if let index = CommandLine.arguments.firstIndex(of: "--vocabulary-draft"),
               index + 1 < CommandLine.arguments.count {
                await state.openVocabulary()
                state.vocabularyDraft = CommandLine.arguments[index + 1]
                state.vocabularyDraftChanged()
            }
            // 截图/验证辅助：--define-vocabulary 进词汇本 + 给第一个每日推荐词查释义、
            // 给最新一条词条重新释义，并朗读「单词 + 例句」。
            // 一次跑完「提示词 → 解析 → 卡片排版 → 朗读」整条链路，
            // 不需要模拟点击（本机 UI 自动化对 SwiftUI 不可靠）。
            if CommandLine.arguments.contains("--define-vocabulary") {
                await state.openVocabulary()
                await state.loadDailyWordsIfNeeded()
                if let first = state.dailyWords.first {
                    await state.toggleDailyDefinition(word: first.word)
                    let example = state.dailyDefinitions[first.word]?.example ?? ""
                    let spoken = example.isEmpty ? first.word : "\(first.word). \(example)"
                    Task { await state.speak(spoken) }
                }
                if let newest = state.vocabularyEntries.first {
                    await state.redefineVocabulary(id: newest.id)
                }
            }
            // 截图/验证辅助：--shadowing-sample "识别文本" 用**同一条评测链路**预览反馈界面
            // （本机无法合成点击、也无法自动对麦克风说话；它不录音、不落库，
            //   发音卡用合成的演示波形驱动 —— 真实录音时走的是同一段纯函数）
            if let index = CommandLine.arguments.firstIndex(of: "--shadowing-sample"),
               index + 1 < CommandLine.arguments.count {
                await state.openShadowing()
                await state.previewShadowingResult(CommandLine.arguments[index + 1])
            }
            // 端到端验证辅助：--scenario <id> 启动后直接进入某个情景
            if let index = CommandLine.arguments.firstIndex(of: "--scenario"),
               index + 1 < CommandLine.arguments.count,
               let scenario = state.scenarios.first(where: { $0.id == CommandLine.arguments[index + 1] }) {
                await state.startScenario(scenario)
            }
            // 端到端验证辅助：--send "文本" 启动后自动发送一条消息
            if let index = CommandLine.arguments.firstIndex(of: "--send"),
               index + 1 < CommandLine.arguments.count {
                let text = CommandLine.arguments[index + 1]
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    state.chat.send(text)
                }
            }
            // 端到端验证辅助：--auto-speak 启动即打开自动朗读（观察分句流水线时序）
            if CommandLine.arguments.contains("--auto-speak") {
                await state.setAutoSpeak(true)
            }
            // 端到端验证辅助：--auto-end-scenario 启动 12 秒后自动结束情景（观察星星结算）
            if CommandLine.arguments.contains("--auto-end-scenario") {
                Task {
                    try? await Task.sleep(for: .seconds(12))
                    await state.endScenario()
                }
            }
        }
        .onChange(of: colorScheme) { _, newValue in
            state.systemIsDark = (newValue == .dark)
        }
        // 截图/验证辅助：--translate-last 等老师开口后，自动翻译最后一条消息（验证气泡翻译）
        .task {
            guard CommandLine.arguments.contains("--translate-last") else { return }
            // 等首条消息出现且生成结束（老师主动打招呼需要几秒到几十秒）。
            for _ in 0..<60 where state.chat.messages.isEmpty || state.chat.isGenerating {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !state.chat.messages.isEmpty else { return }
            // 学员与老师各翻一条：一个开关就能同时验两种译文对齐（学员右 / 老师左）。
            if let teacher = state.chat.messages.last(where: { $0.role == .assistant }) {
                await state.translateMessage(teacher.id)
            }
            if let learner = state.chat.messages.last(where: { $0.role == .user }) {
                await state.translateMessage(learner.id)
            }
        }
    }

    // MARK: - 宽度分配

    /// 树宽夹取在 [min, 可用宽 - 聊天最小宽]；保证聊天区永远不小于下限。
    private func treeWidth(available: CGFloat) -> CGFloat {
        let upper = max(treeMinWidth, available - chatMinWidth)
        return min(max(treePanelWidth, treeMinWidth), upper)
    }

    // MARK: - 中间：对话 / 学习记录

    @ViewBuilder
    private var chatArea: some View {
        Group {
            if state.showingShadowing {
                ShadowingView(state: state)
            } else if state.showingVocabulary {
                VocabularyView(state: state)
            } else if state.showingRecords {
                RecordsView(state: state)
            } else {
                ChatView(
                    chat: state.chat,
                    modelName: state.currentModelName,
                    health: state.health,
                    providerLabel: state.activeProviderName,
                    contextLimit: state.contextLimit,
                    reasoningLabel: Self.reasoningDisplay(state.activeReasoningEffort),
                    teacherKind: state.teacherAnimalKind,
                    studentKind: state.studentAnimalKind,
                    isRecording: state.isRecording,
                    isTranscribing: state.isTranscribing,
                    autoSpeak: state.autoSpeak,
                    onMicStart: { await state.startVoiceInput() },
                    onMicStop: { await state.finishVoiceInput() },
                    voiceError: state.voiceError,
                    onDismissVoiceError: { state.clearVoiceError() },
                    onSpeakTap: { text in Task { await state.speak(text) } },
                    onStopSpeak: { Task { await state.stopSpeaking() } },
                    speechPhase: state.speechPhase,
                    speakingText: state.speakingText,
                    speechRate: state.speechRate,
                    onSpeechRateChange: { rate in Task { await state.setSpeechRate(rate) } },
                    scenario: state.activeScenario,
                    onOpenScenarios: { Task { await state.openScenarios() } },
                    onEndScenario: { Task { await state.endScenario() } },
                    voiceTranscript: state.voiceTranscript,
                    modelStoppedNotice: state.llmStoppedNotice,
                    starterQuestions: state.starterQuestions,
                    onTranslate: { id in await state.translateMessage(id) },
                    translationError: state.translationNotice,
                    onDismissTranslationError: { state.clearTranslationNotice() }
                )
            }
        }
        .background(state.theme.surfaceAlt.opacity(0.55))
    }

    // MARK: - 可拖动分割线（聊天 / 成长之树之间）

    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(theme.divider)
                .frame(width: 1)

            Capsule()
                .fill(theme.divider.opacity(0.9))
                .frame(width: 5, height: 44)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle().inset(by: -2))
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if treeDragStart == nil { treeDragStart = treePanelWidth }
                    // 拖动越靠左（translation < 0），树越宽。
                    treePanelWidth = (treeDragStart ?? treePanelWidth) - value.translation.width
                }
                .onEnded { _ in
                    treeDragStart = nil
                }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("拖动调整对话与成长之树的宽度")
    }

    // MARK: - 右侧：成长之树

    private var levelPanel: some View {
        VStack(spacing: 0) {
            levelHeader
                .frame(height: 64)
            Divider().overlay(state.theme.divider)
            // 树可上下滚动；林间地面带固定吸附在底部（小动物始终可见、可点击说话）
            ZStack(alignment: .bottom) {
                ScrollView(.vertical, showsIndicators: false) {
                    TreeCanvas(
                        theme: state.theme,
                        progress: state.progress,
                        studentAnimal: state.studentAnimalKind,
                        bubblesAllowed: state.animalBubblesEnabled
                    ) { level in
                        Task { await open(level) }
                    }
                    .padding(.top, 6)
                }

                ForestGroundBand(
                    theme: state.theme,
                    bubblesAllowed: state.animalBubblesEnabled,
                    activityAllowed: state.animalActivityEffective,
                    activityFrequency: state.animalActivityFrequency,
                    onActivityToggle: {
                        Task { await state.setAnimalActivity(!state.animalActivityEnabled) }
                    },
                    previewSleepBubble: CommandLine.arguments.contains("--sleep-bubble")
                )
                .frame(height: 150)
                .allowsHitTesting(true)
            }
        }
        .background(state.theme.surface.opacity(0.62))
    }

    private var levelHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "tree.fill")
                    .foregroundStyle(state.theme.accent)
                    .font(.system(size: 14))
                Text("成长之树")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(state.theme.primaryText)
                Spacer()
                if state.isBooting {
                    ProgressView().controlSize(.mini)
                }
                Text("已爬升 \(Int(state.progress.climbFraction * 100))%")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(state.theme.secondaryText)
            }

            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .foregroundStyle(state.theme.accent)
                    .font(.system(size: 11))
                Text("\(state.progress.totalStars) 颗星星")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(state.theme.primaryText)
                Spacer()
                Text("\(state.progress.levels.filter { $0.state == .completed }.count)/\(state.progress.levels.count) 关")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(state.theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }

    // MARK: - 设置浮层（全局响应日夜，可关闭）

    private var settingsOverlay: some View {
        ZStack {
            state.theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { state.showingSettings = false }

            SettingsView(state: state)
                .frame(width: 720)
                .frame(maxHeight: 780)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(state.theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(state.theme.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: state.theme.shadow, radius: 30, x: 0, y: 14)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        }
        .zIndex(20)
    }

    // MARK: - 情景选择浮层（数据驱动，随日夜主题）

    private var scenariosOverlay: some View {
        ZStack {
            state.theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { state.closeScenarios() }

            ScenarioPickerView(state: state) { state.closeScenarios() }
                .frame(width: 720)
                .frame(maxHeight: 720)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(state.theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(state.theme.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: state.theme.shadow, radius: 30, x: 0, y: 14)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        }
        .zIndex(18)
    }

    // MARK: -

    /// 推理强度展示文案（low/medium/high → 低/中/高）。
    public static func reasoningDisplay(_ effort: String?) -> String? {
        switch effort {
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        default: nil
        }
    }

    private func open(_ level: TreeLevel) async {
        guard level.state != .locked else { return }
        // 绑定情景的关卡：点它就直接进入该情景（老师按角色开场，结算也记在这一关）
        if let scenario = state.scenario(for: level.scenarioID) {
            await state.startScenario(scenario)
            return
        }
        state.chat.send("Let's practice: \(level.title)")
    }
}
