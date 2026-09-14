import AIDomain
import SwiftUI

/// 自动换行的流式布局：一行放不下就换到下一行，行内左对齐、行间等距。
///
/// 为什么不用 `LazyVGrid(columns: .adaptive)`：附件 chip 的宽度由**内容**决定
/// （图片 chip 带缩略图、文件 chip 只有文件名），grid 会把它们拉成统一的列宽 ——
/// 结果是图片被压扁、长文件名被截断。流式布局保留每个 chip 的自然宽度，
/// 只在放不下时换行，正是需求要的「展示不全时自动换行」。
///
/// 行划分规则在 `AIDomain/AttachmentTrayLayout`（纯函数，可单测）里；
/// 这里只把「哪些下标在同一行」翻译成实际位置，不重复实现规则。
struct FlowLayout: Layout {

    /// 同一行内相邻元素之间的水平间距。
    var spacing: CGFloat = 8
    /// 行与行之间的垂直间距。
    var lineSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rowIndices(subviews: subviews, maxWidth: maxWidth)
        var height: CGFloat = 0
        var width: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            var rowWidth: CGFloat = 0
            var rowHeight: CGFloat = 0
            for (position, index) in row.enumerated() {
                let size = subviews[index].sizeThatFits(.unspecified)
                rowWidth += size.width + (position == 0 ? 0 : spacing)
                rowHeight = max(rowHeight, size.height)
            }
            width = max(width, rowWidth)
            height += rowHeight + (rowIndex == 0 ? 0 : lineSpacing)
        }
        // 宽度未知时给出内容自然宽（`min(width, .infinity)` 即 width），
        // 绝不把 `infinity` 交回去 —— 那会让上层布局直接崩掉。
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let rows = rowIndices(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 { y += lineSpacing }
            var x = bounds.minX
            var rowHeight: CGFloat = 0
            for (position, index) in row.enumerated() {
                let size = subviews[index].sizeThatFits(.unspecified)
                if position > 0 { x += spacing }
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width
                rowHeight = max(rowHeight, size.height)
            }
            y += rowHeight
        }
    }

    private func rowIndices(subviews: Subviews, maxWidth: CGFloat) -> [[Int]] {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        return AttachmentTrayLayout.rows(
            itemWidths: widths, maxWidth: maxWidth, spacing: spacing
        )
    }
}
