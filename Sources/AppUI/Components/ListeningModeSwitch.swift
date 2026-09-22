import AIDomain
import SwiftUI

/// 听力板块的三种形式切换条。
///
/// ⚠️ 三个**兄弟按钮**，绝不用系统 `Picker` / `Menu`：macOS 上两者都不渲染 label，
/// 命中区还会退化（见项目里那条「别用系统 Picker」的教训）。
///
/// ⚠️ 换形式**不清进度**：三种形式本来练的就是同一批句子，把进度清零等于
/// 逼人「想换个练法就得从头再来」—— 那正是最容易让人放弃的地方。
struct ListeningModeSwitch: View {

    @Environment(\.forestTheme) private var theme

    let current: ListeningMode
    let onSelect: (ListeningMode) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ListeningMode.allCases) { mode in
                segment(mode)
            }
            Spacer(minLength: 0)
        }
    }

    private func segment(_ mode: ListeningMode) -> some View {
        let isOn = mode == current
        return Button {
            onSelect(mode)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.title)
                    .font(.system(size: 12, weight: isOn ? .semibold : .regular, design: .rounded))
            }
            .foregroundStyle(isOn ? theme.accent : theme.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(isOn ? theme.accent.opacity(0.14) : theme.surfaceAlt.opacity(0.6))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isOn ? theme.accent.opacity(0.55) : theme.divider, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(mode.blurb)
        .accessibilityLabel(mode.title)
    }
}
