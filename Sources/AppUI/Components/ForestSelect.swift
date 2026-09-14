import AppKit
import SwiftUI

/// 下拉选项：`id` 就是选中值本身。
struct ForestSelectOption<Value: Hashable>: Identifiable {
    let id: Value
    let title: String

    init(value: Value, title: String) {
        self.id = value
        self.title = title
    }
}

/// 应用统一风格的「下拉选择」控件。
///
/// 为什么不用系统 `Picker`：它的外观（灰底、系统箭头、系统高亮）与本应用的
/// 圆角 + 浅色描边 + 强调色体系不一致，而且**改不动** —— `.pickerStyle` 只有那几种，
/// `Menu` 的 `menuStyle` 也改不了配色。用户明确要求「不要用系统默认选择框」。
///
/// ⚠️ 关键实现约束（本项目踩过两次，见 `MenuPopUpHitArea`）：
/// 1. macOS **不渲染 `Menu` label 的自定义底色 / 描边 / 前景色** —— 实测裸菜单只剩文字，
///    连 `foregroundStyle` 都被忽略，所以外观层必须自己画。
/// 2. 但重画外观之后**不能**让 `Menu` 去当命中区：它的 label 是空视图时，
///    系统只给到 6×14 的命中范围（无障碍实测），控件看着正常却「点不动」。
/// 于是命中区改成 AppKit 的 `MenuPopUpHitArea`——范围就是外层给的尺寸，且自己弹菜单。
///
/// 形状 / 高度 / 字号由 `Metrics` 决定；宽度由调用方给固定值 ——
/// 选中项长短不一，固定宽度才能让一行里多个控件对齐、不会随选中项跳来跳去。
/// ⚠️ 这个「固定值」要用 `Metrics.widthFitting(_:)` **量**出来，不能凭感觉写：
/// 写小了的表现是值被截成一个省略号（控件的几何空档看不出来，只有渲染像素才露馅）。
struct ForestSelect<Value: Hashable>: View {

    /// 尺寸档位。
    enum Metrics {
        /// 设置页 / 面板里的字段：高 30、圆角 9、字号 12。
        case regular
        /// 行内小控件（如对话区「语速」）：高 20、近似胶囊、字号 10。
        case compact

        var height: CGFloat { self == .regular ? 30 : 20 }
        var fontSize: CGFloat { self == .regular ? 12 : 10 }
        /// 胶囊就是「圆角 = 高度的一半」——不需要另一套形状代码。
        var cornerRadius: CGFloat { self == .regular ? 9 : height / 2 }
        var horizontalPadding: CGFloat { self == .regular ? 10 : 7 }
        var iconSize: CGFloat { self == .regular ? 9 : 8 }
        /// 控件内部横向间距：小档位要抠出空间留给「值」，否则图标+箭头会把它挤没。
        var spacing: CGFloat { self == .regular ? 6 : 4 }
        /// 值右侧为「箭头 + 间隙」预留的宽度。
        /// 箭头是 overlay（不参与布局），所以这段空间必须靠内边距显式让出。
        var chevronReserve: CGFloat { self == .regular ? 18 : 14 }

        /// 装下「宽度为 `textWidth` 的值」所需的最小控件宽度（含图标、箭头、内边距与间隙）。
        ///
        /// 用途：调用方给的宽度如果比它小，值就会被压成「…」——
        /// 2026-09-14 反馈「老师朗读的速率未正常显示」正是如此。
        /// 这个函数把「够不够」变成可计算、可断言的事。
        ///
        /// 系数由**像素实测**校准，不是按图标尺寸估算的：
        /// 实测方式是把控件渲染两次（标题置空 / 用真实标题）再逐像素差分出「文字块」，
        /// 扫宽度找到「文字块宽度不再变小」的临界点（见 `TempRenderRateChip` 的历史输出）。
        /// 估算法会偏小，而偏小的表现恰好就是「值被截成省略号」。
        public func minimumWidth(forValueWidth textWidth: CGFloat) -> CGFloat {
            horizontalPadding * 2 + iconSize + 2 + spacing + textWidth + chevronReserve
        }

        /// 按**实际字体**量出 `titles` 里最宽的一个，返回刚好装下它的控件宽度。
        ///
        /// 为什么不直接拍一个数字：可用文字宽度 = 控件宽 − 图标 − 内边距 − 间隙 − 箭头，
        /// 任何一项调整都会让「拍」出来的数字失效，而失效表现就是**值被截成 `2…`**——
        /// 正是 2026-09-14 这次 bug。量一次就长期免疫字体 / 档位变化。
        public func widthFitting(_ titles: [String]) -> CGFloat {
            let font = Metrics.roundedFont(size: fontSize, weight: .medium)
            let widest = titles
                .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
                .max() ?? 0
            // 向上取整再留 2pt：字形的排版推进宽度比像素墨迹宽约 2pt，
            // 且实测「临界宽度」正好压在整数附近（见测试里的扫描结论），需要一点余量。
            return minimumWidth(forValueWidth: ceil(widest) + 2)
        }

        /// 与 `appearanceLayer` 里 `Text` 所用字体**同源**：`.rounded` + `.medium`。
        /// 不共用就会量出偏窄的宽度 —— 那时控件看着够宽，字却仍被截。
        static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded),
                  let rounded = NSFont(descriptor: descriptor, size: size)
            else { return base }
            return rounded
        }
    }

    @Environment(\.forestTheme) private var theme

    private let label: String?
    private let icon: String?
    @Binding private var selection: Value
    private let options: [ForestSelectOption<Value>]
    private let metrics: Metrics
    private let width: CGFloat
    private let help: String?
    private let isEnabled: Bool
    /// 悬停高亮：让「可以点」这件事在按下去之前就看得见。
    @State private var isHovering = false

    /// - Parameters:
    ///   - label: 框**左侧**的说明（渲染成「模型：」）。属于选择框的标签，不参与控件本体，
    ///            因此框里只显示**值**本身，不会和标签混在一起。
    ///   - icon: 框内的前导图标（可选）。
    ///   - width: 控件固定宽度。固定而非自适应，是为了同排多个控件对齐、且换选中项时宽度不跳动。
    ///            ⚠️ 调用方**不要凭感觉写数字**：用 `Metrics.widthFitting(_:)` 按实际字体量出来，
    ///            否则容易写小、值被截成省略号（2026-09-14 的「语速不显示」就是这样来的）。
    init(
        _ label: String? = nil,
        icon: String? = nil,
        selection: Binding<Value>,
        options: [ForestSelectOption<Value>],
        metrics: Metrics = .regular,
        width: CGFloat = 200,
        help: String? = nil,
        isEnabled: Bool = true
    ) {
        self.label = label
        self.icon = icon
        self._selection = selection
        self.options = options
        self.metrics = metrics
        self.width = width
        self.help = help
        self.isEnabled = isEnabled && !options.isEmpty
    }

    var body: some View {
        HStack(spacing: 6) {
            if let label {
                Text("\(label)：")
                    .font(.system(size: metrics.fontSize, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize()
            }
            field
        }
    }

    private var field: some View {
        appearanceLayer
            .frame(width: width, height: metrics.height)
            .opacity(isEnabled ? 1 : 0.55)
            .overlay(hitArea)
            .onHover { hovering in
                isHovering = hovering && isEnabled
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .help(help ?? currentTitle)
    }

    /// 外观层：底色 + 描边 + 值 + 箭头。**必须**在命中区之外，理由见类型注释。
    ///
    /// ⚠️ 结构上刻意**不让「值」和任何弹性视图同排**（2026-09-14 修「语速不显示」时定稿）：
    /// 原先把 `Spacer` 放在「值」与箭头之间，`Spacer` 会参与 HStack 的宽度分配，
    /// 实测把 `Text` 压到只剩 7pt 的省略号 —— 即便控件宽 68pt、几何上还剩 33pt 空档。
    /// 现在箭头改为 `.overlay(alignment: .trailing)`：overlay 不参与布局，
    /// 「值」因此拿得到自己的理想宽度；箭头的位置由 `trailing` 内边距预留，不会互相抢。
    private var appearanceLayer: some View {
        HStack(spacing: metrics.spacing) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: metrics.iconSize))
                    .foregroundStyle(theme.accent)
            }
            Text(currentTitle)
                .font(.system(size: metrics.fontSize, weight: .medium, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                // 模型名往往前半段相同（`agnes-2.5-flash` / `agnes-2.5-pro`），
                // 从中间截断才能同时留住前缀与尾部的区分度。
                .truncationMode(.middle)
        }
        .padding(.leading, metrics.horizontalPadding)
        // 右侧留出「箭头 + 间隙」的位置：overlay 不占布局，要靠内边距把空间让出来。
        .padding(.trailing, metrics.horizontalPadding + metrics.chevronReserve)
        // 只需填满外层给的固定尺寸；宽度不由这里决定（由调用方的 `width` 决定）。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(shape.fill(theme.surfaceAlt))
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.down")
                .font(.system(size: metrics.iconSize - 1, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .padding(.trailing, metrics.horizontalPadding)
        }
        .overlay(
            // 悬停时描边转为强调色：在与用户「按下」之前就说明这里可以点。
            shape.strokeBorder(isHovering ? theme.accent : theme.divider, lineWidth: 1)
        )
    }

    /// 交互层：AppKit 命中区，按下即弹原生菜单。
    ///
    /// 尺寸用「填满外层」而不是另写一个数值：命中区必须与外观层严丝合缝，
    /// 否则四角或右侧会出现一段点不动的空白。外层 `field` 已钉死尺寸，这里只需填满。
    private var hitArea: some View {
        MenuPopUpHitArea(
            titles: options.map(\.title),
            selectedIndex: options.firstIndex { $0.id == selection },
            isEnabled: isEnabled,
            accessibilityTitle: label ?? currentTitle,
            tooltip: help ?? currentTitle,
            onSelect: { index in
                guard options.indices.contains(index) else { return }
                let picked = options[index].id
                if picked != selection { selection = picked }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    }

    private var currentTitle: String {
        options.first { $0.id == selection }?.title ?? (options.isEmpty ? "无可选项" : "未选择")
    }
}
