import AIDomain
import SwiftUI

/// 「快捷键中心」的**卡片内容**（#281）。
///
/// 为什么从 `SettingsView` 里搬出来：设置页已经 2600 行，而这一块是自洽的
/// （只需要一个 `AppState`），搬出来就能**单独离屏渲染回归** ——
/// 「录制中键面真的变了样」「撞键真的标出来了」这两件事，留在整页图里
/// 既看不清也没法断言。外层的卡片外框（标题行 / 底色）仍由 `SettingsView.card` 提供。
///
/// 三条自己定的规矩（都是「别让界面撒谎」）：
/// 1. **撞键当场拒绝**并说清被谁占了 —— 两个动作绑同一个键时只有一个会赢，
///    另一个看着配好了却按不动，那是最难自查的一类 bug；
/// 2. **录什么都有提示**：录制中键面变成「按下新的键…」，Esc 取消；
/// 3. **每行都能单独恢复出厂**，不用「全清一遍再重配」。
struct ShortcutCenterCard: View {

    @Environment(\.forestTheme) private var theme

    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("点一个键位，再按下你想要的新组合，改完立刻生效。Esc 取消。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ShortcutGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text(group.scopeNote)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    ForEach(Self.actions(in: group)) { action in
                        row(action)
                    }
                }
            }

            if let notice = state.shortcutNotice {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.warning)
                    Text(notice)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("知道了") { state.dismissShortcutNotice() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.accent)
                }
            }

            Button {
                state.resetAllShortcutBindings()
            } label: {
                Text("全部恢复出厂")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("把每一个动作都改回它出厂时的按键")
        }
    }

    static func actions(in group: ShortcutGroup) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.group == group }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let binding = state.shortcutBinding(for: action)
        let isCapturing = state.capturingShortcutAction == action
        let conflicts = state.shortcutConflicts(for: action)
        return HStack(spacing: 8) {
            Text(action.title)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !conflicts.isEmpty {
                // 撞键：不标出来，这一行的键看着好端端的，按下去却没反应。
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.warning)
                    .help("与「\(conflicts.map(\.title).joined(separator: "、"))」撞键，其中一个不会生效")
            }
            Button {
                if isCapturing {
                    state.cancelShortcutCapture()
                } else {
                    state.beginShortcutCapture(for: action)
                }
            } label: {
                Text(isCapturing ? "按下新的键…" : binding.displayString)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isCapturing ? theme.onAccentFill : theme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(isCapturing ? theme.accentFill : theme.surfaceAlt))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(isCapturing ? "再点一次取消（或按 Esc）" : "点一下，然后按下新的组合键")
            .accessibilityLabel("\(action.title) 的按键：\(binding.displayString)")
            Button {
                state.resetShortcutBinding(action)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("恢复出厂键（\(action.defaultBinding.displayString)）")
            .accessibilityLabel("把「\(action.title)」恢复成出厂键 \(action.defaultBinding.displayString)")
        }
    }
}
