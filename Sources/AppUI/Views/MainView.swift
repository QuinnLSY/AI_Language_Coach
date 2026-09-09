import AIDomain
import SwiftUI

/// 主界面：左侧「参天大树」闯关画布，右侧与 AI 教师的对话。
public struct MainView: View {

    @Bindable var state: AppState
    @Environment(\.colorScheme) private var colorScheme

    public init(state: AppState) { self.state = state }

    public var body: some View {
        ZStack {
            ForestSky(theme: state.theme)

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 340)
                Divider().overlay(state.theme.divider)
                chatArea
            }
        }
        .frame(minWidth: 1020, minHeight: 680)
        .forestTheme(state.theme)
        .animation(.easeInOut(duration: 0.6), value: state.theme.palette)
        .task {
            state.systemIsDark = (colorScheme == .dark)
            await state.start()
        }
        .onChange(of: colorScheme) { _, newValue in
            state.systemIsDark = (newValue == .dark)
        }
        .sheet(isPresented: $state.showingSettings) {
            SettingsView(state: state)
                .frame(width: 640, height: 720)
        }
    }

    // MARK: - 侧边栏：大树

    private var sidebar: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(state.theme.divider)
            ScrollView(.vertical, showsIndicators: false) {
                TreeCanvas(theme: state.theme, progress: state.progress) { level in
                    Task { await open(level) }
                }
                .padding(.top, 8)
            }
        }
        .background(state.theme.surface.opacity(0.62))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("森林语言树")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(state.theme.primaryText)
                    Text("和小动物们一起向上爬")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(state.theme.secondaryText)
                }
                Spacer()
                Button {
                    Task { await state.toggleDayNight() }
                } label: {
                    Image(systemName: state.theme.isNight ? "sun.max.fill" : "moon.stars.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(state.theme.accent)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(state.theme.surface))
                        .overlay(Circle().strokeBorder(state.theme.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(state.theme.isNight ? "切换到白天" : "切换到夜晚")
            }

            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .foregroundStyle(state.theme.accent)
                    .font(.system(size: 12))
                Text("\(state.progress.totalStars) 颗星星")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(state.theme.primaryText)
                Spacer()
                Text("已爬升 \(Int(state.progress.climbFraction * 100))%")
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

    // MARK: - 对话区

    private var chatArea: some View {
        ChatView(
            chat: state.chat,
            modelName: state.currentModelName,
            health: state.health
        ) {
            state.showingSettings = true
        }
        .background(state.theme.surface.opacity(0.78))
    }

    private func open(_ level: TreeLevel) async {
        guard level.state != .locked else { return }
        let title = level.title
        state.chat.send("Let's practice: \(title)")
    }
}
