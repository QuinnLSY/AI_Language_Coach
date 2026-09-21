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
/// 3. **每格都能单独恢复出厂**，不用「全清一遍再重配」。
///
/// 版式（2026-09-21 用户口径）：**一行三个、文字左对齐**。
/// 13 个动作一行一个要把设置页拖出两屏多，而这里本来就是「查 / 改配置」的地方，
/// 不是正文；三列一铺，卡片高度掉到原来的三分之一。
struct ShortcutCenterCard: View {

    @Environment(\.forestTheme) private var theme

    let state: AppState

    /// 三列等宽。间距给 12：格子里是「名字 + 键面 + 复位」三样东西拼起来的，
    /// 挨太近会看成同一组的两个动作。
    ///
    /// ⚠️ 这个值是两处在用（网格本身、两列之间的竖线定 x），必须同一个来源 ——
    /// 竖线要落在间距正中间，改了间距没改首三列就会画到格子里去。
    private static let columnSpacing: CGFloat = 12
    private static let rowSpacing: CGFloat = 8

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: columnSpacing, alignment: .leading), count: 3
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("点一个键位，再按下你想要的新组合，改完立刻生效。Esc 取消。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ShortcutGroup.allCases) { group in
                let items = Self.actions(in: group)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text(group.scopeNote)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Self.rowSpacing) {
                        ForEach(items) { action in
                            cell(action)
                        }
                    }
                    // ⚠️ 挂在**这一组的网格**上，不是整个卡片：三列的分隔属于「组内的列」，
                    // 连成一条竖线贯穿上下会让人以为两组的动作是同一套。
                    .background {
                        ShortcutColumnRules(
                            itemCount: items.count,
                            columnCount: Self.columns.count,
                            spacing: Self.columnSpacing,
                            rowSpacing: Self.rowSpacing,
                            color: theme.columnDivider
                        )
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

    /// 一格 = 一个动作：名字左对齐，右边紧跟着键面与「恢复出厂」。
    ///
    /// ⚠️ 名字**必须留在格里**（不能像有些表那样把名字挪到键面上方另起一行）：
    /// 那样每格会高回去，一行三个省下的高度又没了。窄格里长名字靠 `.help` 兜底 ——
    /// 截断看得见，悬停能读全。
    private func cell(_ action: ShortcutAction) -> some View {
        let binding = state.shortcutBinding(for: action)
        let isCapturing = state.capturingShortcutAction == action
        let conflicts = state.shortcutConflicts(for: action)
        return HStack(spacing: 5) {
            Text(action.title)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(action.title)
            Spacer(minLength: 2)
            if !conflicts.isEmpty {
                // 撞键：不标出来，这一格的键看着好端端的，按下去却没反应。
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
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
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
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("恢复出厂键（\(action.defaultBinding.displayString)）")
            .accessibilityLabel("把「\(action.title)」恢复成出厂键 \(action.defaultBinding.displayString)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 「多行多列」排布里，**两列之间**那条竖线（按组各画各的：一个分组一段，组之间断开）。
///
/// 用户口径（2026-09-21）：三列之间要有竖线分一分，但**不能是一条贯穿卡片上下** ——
/// 每个分类各自分段。所以它是挂在**单个分组的网格**上的背景，而不是挂在整个卡片上。
///
/// 每一行多高不写死：从网格实际尺寸反推（`height` 已知，行数已知 → 行高）。
/// 前提是同一格里内容同构（这里每格都是「名字 + 键面 + 复位」），行高才一致。
/// ⚠️ **线的算法必须留得可单测**（所以这里不是 `private`）：这部分算术全是「差一格子」的坑，
/// 靠出图看不出来，只能靠用例锁。
struct ShortcutColumnRules: View {

    let itemCount: Int
    let columnCount: Int
    let spacing: CGFloat
    let rowSpacing: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            // ⚠️ 必须套 `ZStack(alignment: .topLeading)`：ViewBuilder 里并列的多个子视图
            // 会被各自**居中**摆放，那个 `offset` 就成了相对盒子中心的偏移 ——
            // 三段长短不一的线会歪到一起去。
            ZStack(alignment: .topLeading) {
                ForEach(rules(in: proxy.size), id: \.x) { rule in
                    Rectangle()
                        .fill(color)
                        .frame(width: 1, height: rule.height)
                        .offset(x: rule.x, y: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    /// 每条竖线跨**几行**（0 = 这一条不该画）。
    ///
    /// `index 0` 是第 1、2 列之间那条，以此类推。答案取决于**右边那一列有几行格子**：
    /// 最后一行常常只有 1、2 个格子，线要跟着短一截 —— 画到没有格子的地方
    /// 就成了悬空的一截，看着像没对齐。
    static func rows(itemCount: Int, columnCount: Int) -> [Int] {
        guard columnCount > 1, itemCount > 0 else { return Array(repeating: 0, count: max(0, columnCount - 1)) }
        return (1..<columnCount).map { column in
            // 该列的格子是 column, column+columnCount, …（按行填充，左边先满）
            guard itemCount > column else { return 0 }
            return (itemCount - 1 - column) / columnCount + 1
        }
    }

    /// 把「跨几行」换算成实际的 x 与高度。
    struct Rule: Hashable {
        let x: CGFloat
        let height: CGFloat
    }

    func rules(in size: CGSize) -> [Rule] {
        let rows = (itemCount + columnCount - 1) / columnCount
        guard rows > 0, size.height > 0 else { return [] }
        let rowHeight = max(0, size.height - rowSpacing * CGFloat(rows - 1)) / CGFloat(rows)
        let columnWidth = max(0, size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
        return Self.rows(itemCount: itemCount, columnCount: columnCount)
            .enumerated()
            .compactMap { index, occupied in
                guard occupied > 0 else { return nil }
                let height = rowHeight * CGFloat(occupied) + rowSpacing * CGFloat(occupied - 1)
                let x = columnWidth * CGFloat(index + 1) + spacing * CGFloat(index) + spacing / 2
                return Rule(x: x, height: height)
            }
    }
}
