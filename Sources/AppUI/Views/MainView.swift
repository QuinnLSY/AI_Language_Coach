import AIDomain
import SwiftUI

/// 主界面：**左侧可收拉侧边栏 / 中间对话 / 右侧成长之树闯关画布**。
public struct MainView: View {

    @Bindable var state: AppState
    @Environment(\.colorScheme) private var colorScheme

    public init(state: AppState) { self.state = state }

    public var body: some View {
        ZStack {
            ForestSky(theme: state.theme)

            HStack(spacing: 0) {
                AppSidebar(state: state)

                Divider().overlay(state.theme.divider)

                chatArea

                Divider().overlay(state.theme.divider)

                levelPanel
            }

            if state.showingSettings {
                settingsOverlay
            }
        }
        .frame(minWidth: 1180, minHeight: 720)
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
        }
        .onChange(of: colorScheme) { _, newValue in
            state.systemIsDark = (newValue == .dark)
        }
    }

    // MARK: - 中间：对话

    private var chatArea: some View {
        ChatView(chat: state.chat, modelName: state.currentModelName, health: state.health)
            .background(state.theme.surfaceAlt.opacity(0.55))
    }

    // MARK: - 右侧：成长之树

    private var levelPanel: some View {
        VStack(spacing: 0) {
            levelHeader
            Divider().overlay(state.theme.divider)
            ScrollView(.vertical, showsIndicators: false) {
                TreeCanvas(theme: state.theme, progress: state.progress) { level in
                    Task { await open(level) }
                }
                .padding(.top, 8)
            }
        }
        .frame(width: 340)
        .background(state.theme.surface.opacity(0.62))
    }

    private var levelHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "tree.fill")
                    .foregroundStyle(state.theme.accent)
                    .font(.system(size: 14))
                Text("成长之树")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(state.theme.primaryText)
                Spacer()
                Text("已爬升 \(Int(state.progress.climbFraction * 100))%")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(state.theme.secondaryText)
            }

            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .foregroundStyle(state.theme.accent)
                    .font(.system(size: 12))
                Text("\(state.progress.totalStars) 颗星星")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(state.theme.primaryText)
                Spacer()
                Text("\(state.progress.levels.filter { $0.state == .completed }.count)/\(state.progress.levels.count) 关")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(state.theme.secondaryText)
            }

            if state.isBooting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在唤醒本地模型…")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(state.theme.secondaryText)
                }
            } else if let bootMessage = state.bootMessage {
                Text(bootMessage)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - 设置浮层（全局响应日夜，可关闭）

    private var settingsOverlay: some View {
        ZStack {
            state.theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { state.showingSettings = false }

            SettingsView(state: state)
                .frame(width: 680)
                .frame(maxHeight: 740)
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

    private func open(_ level: TreeLevel) async {
        guard level.state != .locked else { return }
        state.chat.send("Let's practice: \(level.title)")
    }
}
