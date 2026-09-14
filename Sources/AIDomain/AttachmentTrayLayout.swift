import Foundation

/// 附件托盘「放不下就换行」的规则（纯函数）。
///
/// 为什么抽成纯函数：换行算错的表现是「最后一个 chip 被切掉半截」或
/// 「明明放得下却提前换行」——两种都只能靠肉眼盯着截图猜。写成纯函数就能把
/// 边界值（恰好放得下 / 差 1pt / 单个 chip 比整行还宽）直接钉死。
///
/// 规则只负责**行划分**，真正的排版由 `AppUI/Components/FlowLayout` 完成 ——
/// 它把这个结果翻译成位置，规则本身不掺 UI。
public enum AttachmentTrayLayout {

    /// 把每个 chip 的**自然宽度**按「每行累计不超过 `maxWidth`」切成若干行。
    ///
    /// 返回每一行内 chip 的下标（保持原有顺序）。
    /// - 单个 chip 比整行还宽时**独占一行** —— 不这样做就会陷入「永远放不下」的
    ///   死循环（或让它被无限裁切）。
    /// - `maxWidth` 不是有限正数（首次布局还没量到宽度）时一律并成一行，
    ///   交给下一次布局修正；绝不能返回 `infinity` 之类的坏值。
    public static func rows(
        itemWidths: [CGFloat],
        maxWidth: CGFloat,
        spacing: CGFloat
    ) -> [[Int]] {
        guard !itemWidths.isEmpty else { return [] }
        guard maxWidth.isFinite, maxWidth > 0 else {
            return [Array(itemWidths.indices)]
        }
        let gap = max(spacing, 0)
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, width) in itemWidths.enumerated() {
            let natural = max(width, 0)
            if current.isEmpty {
                current = [index]
                used = natural
                continue
            }
            // 只有「加上间距后仍在行宽内」才归入本行；否则开新行。
            if used + gap + natural <= maxWidth {
                current.append(index)
                used += gap + natural
            } else {
                rows.append(current)
                current = [index]
                used = natural
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// 内容需要几行放置（供「有无超出可视行数」这类判断复用）。
    public static func lineCount(
        itemWidths: [CGFloat],
        maxWidth: CGFloat,
        spacing: CGFloat
    ) -> Int {
        rows(itemWidths: itemWidths, maxWidth: maxWidth, spacing: spacing).count
    }
}
