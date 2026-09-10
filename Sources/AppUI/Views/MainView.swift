import AIDomain
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
                ForestSky(theme: state.theme)

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

                if state.showingSettings {
                    settingsOverlay
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 720)
        .forestTheme(state.theme)
        // 日夜切换作用于全局：原生控件（TextField / Picker / 滚动条）也一起跟随。
        .preferredColorScheme(state.theme.isNight ? .dark : .light)
        .animation(.easeInOut(duration: 0.5), value: state.theme.palette)
        .animation(.easeOut(duration: 0.22), value: state.showingSettings)
        .task {
            state.systemIsDark = (colorScheme == .dark)
            await state.start()
            // 截图/验证辅助：--open-settings 启动时直接打开设置面板
            if CommandLine.arguments.contains("--open-settings") {
                state.showingSettings = true
            }
            // 截图/验证辅助：--open-records 启动时直接进入学习记录页
            if CommandLine.arguments.contains("--open-records") {
                Task { await state.openRecords() }
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
        }
        .onChange(of: colorScheme) { _, newValue in
            state.systemIsDark = (newValue == .dark)
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
            if state.showingRecords {
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
                    onSpeakTap: { text in Task { await state.speak(text) } }
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
                    onActivityToggle: {
                        Task { await state.setAnimalActivity(!state.animalActivityEnabled) }
                    }
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
        state.chat.send("Let's practice: \(level.title)")
    }
}
