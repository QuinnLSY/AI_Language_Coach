import SwiftUI

/// 一行「朗读档位」选择器 —— **语速与调门共用同一份配方**。
///
/// 为什么要抽成组件（两条理由都很实际）：
/// 1. **能离屏渲染**。它原来是设置页里的内联 `HStack`，属于某个 `private var` 的中间部分 ——
///    离屏渲染用例碰不到页面内部，于是「档位选中态对不对、标签会不会被截成省略号」
///    只能靠人眼看截图。抽成独立组件后可以把它单独渲染出来做逐像素差分。
/// 2. **一份配方**。语速与调门的排版逐项相同（标题 + 胶囊档位 + 悬停提示），
///    抄两遍必然在其中一处漏改样式 —— 那种不一致只有肉眼能看出来。
///
/// 档位取值统一是 `Double`：语速是倍速、调门是半音，两者本来就是同类档位，
/// 所以组件不需要泛型（也就不会让调用点被类型推断绕住）。
struct SpeechToneRow: View {

    struct Option: Identifiable, Equatable {
        /// 档位取值（语速倍速 / 调门半音）。
        let value: Double
        /// 档位文案（如「1.5×」「原声」）。
        let label: String
        /// 悬停提示（如「以 1.5× 语速朗读」）。
        let help: String
        var isSelected: Bool

        var id: Double { value }
    }

    let title: String
    let options: [Option]
    let onSelect: (Option) -> Void

    @Environment(\.forestTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .appFont(13, design: .rounded)
                .foregroundStyle(theme.primaryText)

            HStack(spacing: 6) {
                ForEach(options) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        Text(option.label)
                            .appFont(12, weight: .semibold, design: .rounded)
                            .foregroundStyle(option.isSelected ? Color.white : theme.primaryText)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(
                                Capsule().fill(option.isSelected ? theme.accent : theme.surfaceAlt)
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    option.isSelected ? theme.accent : theme.divider,
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(.appPressable)
                    .help(option.help)
                    // 读屏用户看不到「哪一档是选中的」——胶囊底色对读屏是不存在的，
                    // 所以选中态必须另外说出来（无障碍标签 + isSelected 特征）。
                    .accessibilityLabel("\(title) \(option.label)")
                    .accessibilityAddTraits(option.isSelected ? [.isSelected] : [])
                }
            }

            Spacer(minLength: 0)
        }
    }
}
