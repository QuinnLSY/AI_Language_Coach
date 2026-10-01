import SwiftUI

/// 小喇叭按钮（词汇本 / 每日推荐 / 词典**共用同一个**）。
///
/// 为什么单独拎出来：同一个按钮在三个页面各写一遍，改一次样式要改三处，
/// 而且必然出现「这页转圈、那页不转圈」的不一致。这里只做**展示**，
/// 朗读链路仍由调用方（`AppState`）负责 —— 组件不读全局状态，才测得动。
///
/// 朗读中是**声波逐层点亮**的动效（不是静音图标 —— 那看着像「已经静音」）；
/// 首句还在合成（preparing）时转圈，告诉用户「点了，正在准备」。
public struct SpeakButton: View {

    @Environment(\.forestTheme) private var theme
    private let isActive: Bool
    private let isPreparing: Bool
    private let size: CGFloat
    private let accessibilityLabel: String
    private let action: () -> Void

    public init(
        isActive: Bool,
        isPreparing: Bool,
        size: CGFloat = 16,
        accessibilityLabel: String = "朗读",
        action: @escaping () -> Void
    ) {
        self.isActive = isActive
        self.isPreparing = isPreparing
        self.size = size
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                if isPreparing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .frame(width: size, height: size)
                } else {
                    Image(systemName: isActive ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                        .appFont(size * 0.75)
                        // 走主题令牌，别用 `Color.yellow`：纯黄在白天卡片上只有 1.07:1，
                        // 等于没画；夜晚又亮得扎眼。`accent` 两档都是同一支压暗的琥珀。
                        .foregroundStyle(theme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: isActive)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.appPressable)
        .help(isActive ? "停止朗读" : accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}
