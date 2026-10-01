import AppCore
import SwiftUI

/// 每日目标的两个控件：档位（保底 5 分钟 / 进阶目标）+ 进阶档下的分钟步进器。
///
/// 抽成组件的理由：这组控件原本只住在**学习进度页**的「今天」卡里，
/// 而用户找目标设置时第一反应是去**设置页**——两处各写一份必然漂移
/// （一边改了显示口径、另一边没跟）。现在两页共用同一个组件、同一组 setter。
///
/// ⚠️ 不用系统 `Picker`（macOS 命中区退化，见 MEMORY），沿用两个小圆钮的自绘口径。
public struct DailyGoalControls: View {

    @Environment(\.forestTheme) private var theme
    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 8) {
            modePicker
            // 保底档的口径固定 5 分钟（与保底计划的量一致），给它步进器等于骗人。
            if state.dailyGoalMode == .advanced {
                stepper
            }
            Spacer(minLength: 0)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(DailyGoalMode.allCases, id: \.id) { mode in
                let isSelected = state.dailyGoalMode == mode
                Button {
                    guard !isSelected else { return }
                    Task { await state.setDailyGoalMode(mode) }
                } label: {
                    Text(mode.displayName)
                        .appFont(10, weight: isSelected ? .bold : .regular, design: .rounded)
                        .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                        .padding(.horizontal, 7)
                        .appPadding(.vertical, 3)
                        .background(
                            Capsule().fill(theme.accent.opacity(isSelected ? 0.14 : 0))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                isSelected ? theme.accent.opacity(0.6) : theme.divider,
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.appPressable)
                .help(mode == .baseline
                      ? "保底档：5 分钟内做完即算今日完成，保住连续"
                      : "进阶档：按每日目标分钟数排计划")
            }
        }
    }

    /// 分钟步进器（±5，范围 5...180 —— 与 `ProductConfig` 的钳位同源）。
    private var stepper: some View {
        HStack(spacing: 6) {
            stepperButton(systemImage: "minus", enabled: currentMinutes > 5) {
                Task { await state.setDailyGoalMinutes(currentMinutes - 5) }
            }
            Text("\(currentMinutes) 分钟")
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
            stepperButton(systemImage: "plus", enabled: currentMinutes < 180) {
                Task { await state.setDailyGoalMinutes(currentMinutes + 5) }
            }
        }
    }

    /// 当前分钟数取**生效口径**（`effectiveGoalMinutes`）：保底档下就是 5，
    /// 不读它就会出现「界面显示 15 分钟、判定按 5 分钟」这种自己打自己的嘴。
    private var currentMinutes: Int {
        state.effectiveGoalMinutes
    }

    private func stepperButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .appFont(9, weight: .bold)
                .foregroundStyle(enabled ? theme.primaryText : theme.secondaryText.opacity(0.5))
                .frame(width: 20, height: 20)
                .background(Circle().fill(theme.hover))
        }
        .buttonStyle(.appPressable)
        .disabled(!enabled)
        .help(systemImage == "plus" ? "调高每日目标 5 分钟" : "调低每日目标 5 分钟")
    }
}
