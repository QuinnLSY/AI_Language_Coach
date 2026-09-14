import Foundation

/// 聊天输入框的高度规则（第 2 项需求，纯函数）。
///
/// 需求原文：**固定行宽、超宽自动换行、向上拓宽、最多 5 行，超过 5 行只显示最后 5 行并出现滚动条**。
/// 把它抽成纯函数的理由很实际 —— 高度算错的表现是「输入框抖一下」或「第 6 行被吞掉」，
/// 而这两种症状在 SwiftUI 里都很难靠肉眼定位；有纯函数就能直接钉死边界。
public enum ComposerMetrics {

    /// 最多显示几行文字。**超过就滚动**，不再继续长高。
    public static let maxLines = 5

    /// 单行高度（含行距）。1.25 是系统字体在 13–15pt 区间的稳定行高比，
    /// 比 layoutManager 的 usedRect 少一点点抖动，用于「下限」与行数换算。
    public static func lineHeight(fontSize: CGFloat) -> CGFloat {
        (fontSize * 1.25).rounded()
    }

    /// 内容高度 → 显示高度（夹在 1 行与 maxLines 行之间）。
    ///
    /// - 内容不足一行（空输入）→ 一行高：输入框不能塌成一条缝。
    /// - 内容超过 maxLines 行 → maxLines 行高：剩下的靠滚动看（而不是把窗口撑开）。
    ///
    /// - Parameter inset: 文本上下内边距（`NSTextView.textContainerInset.height`，单边值）。
    ///
    /// ⚠️ **必须把 inset 算进来**，否则封顶会差一点点：
    /// 封顶高度是「滚动的**可视区**高度」，而可视区里上下各留了 inset，
    /// 真正能放字的只有 `可视区 - inset × 2`。忽略 inset 时 5 行的封顶会少 6pt，
    /// 表现为**第 5 行被切掉一条**（很难看出是这里算错）。
    public static func clampedHeight(
        contentHeight: CGFloat,
        lineHeight: CGFloat,
        inset: CGFloat = 0
    ) -> CGFloat {
        let padding = max(inset, 0) * 2
        let oneLine = max(lineHeight, 1) + padding
        let ceiling = max(lineHeight, 1) * CGFloat(maxLines) + padding
        return min(max(contentHeight, oneLine), ceiling)
    }

    /// 内容是否已经**真的被夹掉**（UI 据此决定要不要显示下拉条）。
    ///
    /// 需求明确要求「未超过五行时不显示下拉条」——
    /// 判据必须与 `clampedHeight` **同源**：都拿「封顶高度」比较，
    /// 而不是各算一遍行数。分两处算的下场是「封顶没夹、滚动条却在闪」，
    /// 或者反过来「已经能滚了却看不见滚动条」（后者更糟：第 6 行像凭空消失了）。
    ///
    /// - Parameter inset: 文本上下内边距，与 `clampedHeight` 保持一致。
    public static func isScrollable(
        contentHeight: CGFloat,
        lineHeight: CGFloat,
        inset: CGFloat = 0
    ) -> Bool {
        contentHeight
            > clampedHeight(contentHeight: contentHeight, lineHeight: lineHeight, inset: inset) + 0.5
    }

    /// 可见行数（1...maxLines）——UI 显示「第 3/5 行」这类提示或调试时可读。
    public static func visibleLineCount(contentHeight: CGFloat, lineHeight: CGFloat) -> Int {
        let oneLine = max(lineHeight, 1)
        let raw = Int((contentHeight / oneLine).rounded(.up))
        return min(max(raw, 1), maxLines)
    }
}
