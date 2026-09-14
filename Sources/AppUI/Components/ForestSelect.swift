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
/// ⚠️ 关键实现约束（本项目踩过）：macOS **不渲染 `Menu` label 的自定义底色 / 描边 /
/// 前景色** —— 实测裸菜单只剩文字，连 `foregroundStyle` 都被忽略。
/// 所以外观层必须放在 `Menu` **之外**（ZStack 下层），`Menu` 只保留一个同尺寸的
/// **透明命中区**负责交互。与输入区「+」按钮是同一套做法。
///
/// 形状 / 高度 / 字号由 `Metrics` 决定；宽度由调用方给固定值 ——
/// 模型名长短不一，固定宽度才能让一行里多个控件对齐、不会随选中项跳来跳去。
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

    /// - Parameters:
    ///   - label: 框**左侧**的说明（渲染成「模型：」）。属于选择框的标签，不参与控件本体，
    ///            因此框里只显示**值**本身，不会和标签混在一起。
    ///   - icon: 框内的前导图标（可选）。
    ///   - width: 控件固定宽度。固定而非自适应，是为了同排多个控件对齐、且换模型时宽度不跳动。
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
            .overlay(menuLayer)
            .help(help ?? currentTitle)
    }

    /// 外观层：底色 + 描边 + 值 + 箭头。**必须**在 `Menu` 之外，理由见类型注释。
    private var appearanceLayer: some View {
        HStack(spacing: 6) {
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
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: metrics.iconSize - 1, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(shape.fill(theme.surfaceAlt))
        .overlay(shape.strokeBorder(theme.divider, lineWidth: 1))
    }

    /// 交互层：透明命中区 + 原生菜单（菜单项本身保持系统外观，选择体验不变）。
    private var menuLayer: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.id
                } label: {
                    if option.id == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            // ⚠️ 命中区必须给**明确尺寸**，不能用 `maxWidth: .infinity`：
            // `Menu` 的 label 拿到的尺寸提案不一定是外层那个固定值，自适应写法会退化成 0×0
            // —— 外观照常画出来，但鼠标点上去**毫无反应**（实测踩过：控件看得见、点不动）。
            // 与本项目输入区「+」按钮同源：那里也是写死的 `frame(width:height:)`。
            Color.clear
                .frame(width: width, height: metrics.height)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(!isEnabled)
        .accessibilityLabel(label ?? currentTitle)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    }

    private var currentTitle: String {
        options.first { $0.id == selection }?.title ?? (options.isEmpty ? "无可选项" : "未选择")
    }
}
