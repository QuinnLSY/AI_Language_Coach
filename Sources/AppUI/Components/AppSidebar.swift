import SwiftUI

/// 左侧可收拉侧边栏。App 的 logo / 名称 / 设置 / 日夜切换，以及后续所有全局功能入口都放这里。
public struct AppSidebar: View {

    @Environment(\.forestTheme) private var theme
    @Bindable var state: AppState

    @State private var isExpanded = true

    private let expandedWidth: CGFloat = 220
    private let collapsedWidth: CGFloat = 76

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider().overlay(theme.divider)
                .padding(.vertical, 8)

            VStack(spacing: 4) {
                navItem(
                    icon: "leaf.fill",
                    title: "练习",
                    isActive: !state.showingSettings
                ) {
                    state.showingSettings = false
                }

                navItem(
                    icon: "gearshape.fill",
                    title: "设置",
                    isActive: state.showingSettings
                ) {
                    state.showingSettings = true
                }

                dayNightRow
            }

            Divider().overlay(theme.divider)
                .padding(.vertical, 8)

            VStack(spacing: 4) {
                navItem(icon: "chart.bar.fill", title: "学习记录", isEnabled: false) {}
                navItem(icon: "text.book.closed.fill", title: "词汇本", isEnabled: false) {}
            }

            Spacer(minLength: 10)

            if isExpanded {
                VStack(spacing: 4) {
                    CuteAnimalView(kind: .panda, isSleeping: theme.isNight, size: 78)
                    Text(theme.isNight ? "夜深了，早点休息" : "今天也要加油")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 8)
                .transition(.opacity)
            }

            Divider().overlay(theme.divider)
                .padding(.bottom, 8)

            collapseButton
        }
        .padding(.horizontal, isExpanded ? 12 : 10)
        .padding(.vertical, 10)
        .frame(width: isExpanded ? expandedWidth : collapsedWidth)
        .background(theme.surfaceAlt.opacity(0.94))
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isExpanded)
    }

    // MARK: - 头部

    private var header: some View {
        Group {
            if isExpanded {
                HStack(spacing: 10) {
                    AppLogo(size: 38)
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
                .frame(height: 42)
            } else {
                AppLogo(size: 34)
                    .frame(height: 42)
                    .frame(maxWidth: .infinity)
            }
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

    // MARK: - 日夜切换

    private var dayNightRow: some View {
        Button {
            Task { await state.toggleDayNight() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: theme.isNight ? "moon.stars.fill" : "sun.max.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.accent)
                    .frame(width: 22, height: 22)

                if isExpanded {
                    Text(theme.isNight ? "夜晚森林" : "白天森林")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.left.right")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.horizontal, isExpanded ? 12 : 0)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.hover)
            )
        }
        .buttonStyle(.plain)
        .help(theme.isNight ? "切换到白天" : "切换到夜晚")
    }

    // MARK: - 收拉

    private var collapseButton: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { isExpanded.toggle() }
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
