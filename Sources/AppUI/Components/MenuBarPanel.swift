import AIDomain
import SwiftUI

/// 菜单栏里弹出的那一张小人：一眼今日进度 + 一颗「现在该按」。
///
/// 单独成组件的理由与 `BlindBoxRow` 同款：它活在 `NSPopover` 里，UI 验证只能靠离屏渲染，
/// 混在系统视图树里看不出它到底画没画出来。
///
/// ⚠️ 本视图不认识 `AppState`、不认识 `NSStatusBar`：内容由纯函数
/// `MenuBarAssistant.snapshot(...)` 给，动作由四个闭包带上（`MenuBarPanelHost` 负责接 AppState）。
/// 这样这张卡才能进渲染回归，也不会把 AppKit 生命周期拖进来。
struct MenuBarPanel: View {

    @Environment(\.forestTheme) private var theme

    var snapshot: MenuBarAssistant.Snapshot
    /// Dock 图标是否已收起（决定底下那一行显示「已收起」还是没收）。
    var dockIconHidden: Bool

    var onGo: (AppSection) -> Void = { _ in }
    var onOpenMainWindow: () -> Void = {}
    var onToggleDockIcon: () -> Void = {}
    var onQuit: () -> Void = {}

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)

            if let primary = snapshot.primary {
                primaryButton(primary)
            }

            if !snapshot.secondary.isEmpty {
                VStack(spacing: 2) {
                    ForEach(snapshot.secondary) { row($0) }
                }
                .padding(.top, 10)
            }

            Divider().overlay(theme.divider)
                .padding(.vertical, 12)

            VStack(spacing: 2) {
                footerRow("打开语林窗口", systemImage: "macwindow", action: onOpenMainWindow)
                footerRow(dockRowTitle, systemImage: "dock.rectangle", checked: dockIconHidden,
                          action: onToggleDockIcon)
                footerRow("退出", systemImage: "power", tint: theme.secondaryText, action: onQuit)
            }
        }
        .appPadding(16)
        .frame(width: Self.width)
        .background(theme.panel)
    }

    // MARK: - 头

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: snapshot.isAllDone ? "checkmark.seal.fill" : "leaf.fill")
                .appFont(16)
                .foregroundStyle(snapshot.isAllDone ? theme.success : theme.accent)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(theme.surfaceAlt)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("语林")
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                Text(snapshot.headline)
                    .appFont(15, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                if !snapshot.detail.isEmpty {
                    Text(snapshot.detail)
                        .appFont(11, design: .rounded)
                        // 今天就到头的连续纪录要看得出来 —— 这是菜单栏唯一一处警示色。
                        .foregroundStyle(snapshot.isStreakAtRisk ? theme.warning : theme.secondaryText)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 「现在该按」那颗

    private func primaryButton(_ action: MenuBarAssistant.Action) -> some View {
        Button { onGo(action.section) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "play.fill")
                    .appFont(10, weight: .bold)
                    .foregroundStyle(theme.onAccentFill)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .appFont(13, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.onAccentFill)
                        .fixedSize(horizontal: false, vertical: true)
                    if !action.detail.isEmpty {
                        Text(action.detail)
                            .appFont(10.5, design: .rounded)
                            .foregroundStyle(theme.onAccentFill.opacity(0.78))
                    }
                }
                Spacer(minLength: 0)
            }
            .appPadding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(theme.accentFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        // ⚠️ 不写 `.buttonStyle(.plain)`：按压反馈由 Host 统一注入
        //（`MotionTokenWiringTests` 钉着这条）。
        .help("接着做今天还没做完的这一件")
    }

    // MARK: - 其余几条

    private func row(_ action: MenuBarAssistant.Action) -> some View {
        Button { onGo(action.section) } label: {
            HStack(spacing: 9) {
                Image(systemName: action.section.systemImage)
                    .appFont(11)
                    .foregroundStyle(theme.accent)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .appFont(12.5, weight: .medium, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        // 任务标题是排出来的（「跟读 3 句，逐音素纠音」），窄面板里要能折行。
                        .fixedSize(horizontal: false, vertical: true)
                    if !action.detail.isEmpty {
                        Text(action.detail)
                            .appFont(10.5, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .appFont(9, weight: .bold)
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .appPadding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.surfaceAlt.opacity(0.6))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .help("打开「\(action.section.title)」")
    }

    // MARK: - 底栏

    private func footerRow(
        _ title: String,
        systemImage: String,
        tint: Color? = nil,
        checked: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .appFont(11)
                    .foregroundStyle(tint ?? theme.primaryText)
                    .frame(width: 16)
                Text(title)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(tint ?? theme.primaryText)
                Spacer(minLength: 0)
                if let checked {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .appFont(11)
                        .foregroundStyle(checked ? theme.accent : theme.secondaryText)
                }
            }
            .padding(.horizontal, 10)
            .appPadding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    /// Dock 那一行：**状态写进标题里**，而不是两侧各放一个含义难猜的图标。
    private var dockRowTitle: String {
        dockIconHidden ? "显示 Dock 图标" : "收起 Dock 图标"
    }
}
