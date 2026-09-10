import SwiftUI

/// 左侧可收拉侧边栏。App 的 logo / 名称 / 设置 等全局功能入口都放这里。
/// 日夜切换按用户要求收进设置页，不再单独拎出。
public struct AppSidebar: View {

    @Environment(\.forestTheme) private var theme
    @Bindable var state: AppState

    public static let expandedWidth: CGFloat = 220
    public static let collapsedWidth: CGFloat = 76

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            // 头部：与其他两栏同高的 64pt 顶栏，保证顶部分界线对齐
            header
                .frame(height: 64)

            Divider().overlay(theme.divider)

            navList

            Spacer(minLength: 8)

            teacherSeat

            Divider().overlay(theme.divider)

            collapseButton
        }
        .padding(.horizontal, isExpanded ? 12 : 10)
        .frame(width: isExpanded ? Self.expandedWidth : Self.collapsedWidth)
        .background(theme.surfaceAlt.opacity(0.94))
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isExpanded)
        // 每次老师回复后刷新黑板上的今日 token 用量
        .onChange(of: state.chat.messages.count) { _, _ in
            state.refreshTodayTokens()
        }
    }

    private var isExpanded: Bool { state.isSidebarExpanded }

    // MARK: - 头部（与其他两栏 64pt 顶栏对齐）

    private var header: some View {
        Group {
            if isExpanded {
                HStack(spacing: 10) {
                    AppLogo(size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("语林")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("AI 语言私教")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
            } else {
                AppLogo(size: 34)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 导航

    private var navList: some View {
        VStack(spacing: 4) {
            navItem(
                icon: "leaf.fill",
                title: "练习",
                isActive: !state.showingSettings && !state.showingRecords && !state.showingScenarios
            ) {
                Task { await state.openPractice() }
            }

            navItem(
                icon: "map.fill",
                title: "情景对话",
                isActive: state.showingScenarios
            ) {
                Task { await state.openScenarios() }
            }

            navItem(
                icon: "chart.bar.fill",
                title: "学习记录",
                isActive: state.showingRecords
            ) {
                Task { await state.openRecords() }
            }

            navItem(
                icon: "gearshape.fill",
                title: "设置",
                isActive: state.showingSettings
            ) {
                state.showingSettings = true
            }

            Divider().overlay(theme.divider)
                .padding(.vertical, 6)

            VStack(spacing: 4) {
                navItem(icon: "text.book.closed.fill", title: "词汇本", isEnabled: false) {}
            }
        }
        .padding(.top, 10)
    }

    // MARK: - 老师座位（黑板 + 教棍老师 + 督促气泡；白天夜晚文案随主题）

    @ViewBuilder
    private var teacherSeat: some View {
        if isExpanded {
            TeacherCorner(
                kind: state.teacherAnimalKind,
                isSleeping: theme.isNight,
                todayTokens: state.todayTokens,
                bubblesAllowed: state.teacherBubblesEnabled
            )
            .help("AI 老师 · \(state.teacherAnimalKind.displayName)（可在设置中更换）")
            .transition(.opacity)
        } else {
            CuteAnimalView(kind: state.teacherAnimalKind, isSleeping: theme.isNight, size: 46, accessory: .teacher)
                .frame(height: 96)
        }
    }

    // MARK: - 条目

    private func navItem(
        icon: String,
        title: String,
        isActive: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(isActive ? theme.accent : (isEnabled ? theme.primaryText : theme.secondaryText))
                    .frame(width: 22, height: 22)

                if isExpanded {
                    Text(title)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(isEnabled ? theme.primaryText : theme.secondaryText)
                    Spacer(minLength: 0)
                    if !isEnabled {
                        Text("soon")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(theme.secondaryText.opacity(0.8))
                    }
                }
            }
            .padding(.horizontal, isExpanded ? 12 : 0)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? theme.selection : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isEnabled ? title : "\(title)（即将推出）")
    }

    // MARK: - 收拉

    private var collapseButton: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                state.isSidebarExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.left" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                if isExpanded {
                    Text("收起")
                        .font(.system(size: 12, design: .rounded))
                }
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, isExpanded ? 12 : 0)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.hover)
            )
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "收起侧边栏" : "展开侧边栏")
    }
}
