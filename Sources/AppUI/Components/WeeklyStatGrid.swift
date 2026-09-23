import SwiftUI

/// 「本周小结」的数字格网格（#4）。
///
/// 两行**共用同一套等宽 4 列**：第二行只有两个数，空位也必须占一格 ——
/// 否则这一行的列宽是第一行的两倍，「同列」就错位了。
/// 格内值与标签**居中**：一列里的两个数字各自贴左，看起来就是散的。
struct WeeklyStatGrid: View {
    struct Item: Sendable {
        var value: String
        var label: String
        var tint: Color? = nil
    }

    let top: [Item]
    let bottom: [Item]

    @Environment(\.forestTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(top)
            row(bottom)
        }
    }

    @ViewBuilder
    private func row(_ items: [Item]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                chip(item)
            }
            // ⚠️ 空位占格：让两行的列宽永远一致（4 列）。
            ForEach(items.count..<4, id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity)
            }
        }
    }

    private func chip(_ item: Item) -> some View {
        VStack(spacing: 2) {
            Text(item.value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(item.tint ?? theme.primaryText)
                .monospacedDigit()
            Text(item.label)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}
