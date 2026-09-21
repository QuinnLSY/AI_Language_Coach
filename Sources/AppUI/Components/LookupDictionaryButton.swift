import SwiftUI

/// 「去词典里查这个词」—— 划词气泡卡右上角与复习卡词条行**共用同一颗按钮**。
///
/// 为什么抽成一个组件，而不是两处各写一遍 `Image(systemName:)`：
/// 这是**同一个动作**（把这个词送去词典查），两处长得不一样，用户就只能靠位置去猜
/// 哪个是「读」哪个是「查」。早先复习卡那边用的是 `character.book.closed`（一本合着的书），
/// 与气泡这边完全不同形；当时在注释里写了一句「保持一致」—— 但注释拦不住下一次改动。
/// 图标、字号、字重、颜色现在只写在这一个文件里，「一致」由构造保证。
///
/// ⚠️ **命中区边长是参数、不是常量**：那由两处的布局定（气泡卡 22×22、复习卡词条行 16×16），
/// 是布局约束而不是图标口径。把它也钉成一个值，必然有一处要么被挤变形、要么点不中。
struct LookupDictionaryButton: View {

    @Environment(\.forestTheme) private var theme

    /// 图标口径 —— 两处共用的**唯一真源**（改这里就是改两处）。
    ///
    /// `magnifyingglass.circle` 而不是 `magnifyingglass`：词条行里它要与喇叭、
    /// 加号这些**成圈的**图标并排，光秃秃一个放大镜在视觉重量上压不住那一排。
    static let symbol = "magnifyingglass.circle"
    static let pointSize: CGFloat = 13
    static let weight: Font.Weight = .semibold

    /// 命中区边长（布局约束，见类型注释）。
    var side: CGFloat = 22
    /// 悬停提示。
    let help: String
    /// 读屏文案（不传就用 `help`）。
    var accessibilityLabel: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: Self.symbol)
                .font(.system(size: Self.pointSize, weight: Self.weight))
                // ⚠️ 冷紫而不是喇叭那个橘：同一行里两个按钮抢同一个颜色时，
                // 用户分不出哪个是「读」哪个是「查」。冷紫是主题里留给
                // 「跳去别处」这类次要动作的那一支。
                .foregroundStyle(theme.accentCool)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel ?? help)
    }
}
