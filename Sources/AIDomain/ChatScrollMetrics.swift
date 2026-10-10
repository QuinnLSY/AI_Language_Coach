import Foundation

/// 聊天区「回到底部」按钮与输入框上方虚化的规则（纯函数）。
///
/// 抽成纯函数的理由和 `ComposerMetrics` 一样实际：这类阈值算错的表现是
/// 「都滚到底了按钮还赖着不走」或「明明在上翻却看不见按钮」——
/// 两种症状都只能靠肉眼盯着屏幕猜，而有纯函数就能把边界值直接钉死。
public enum ChatScrollMetrics {

    /// 距底部超过这个距离（pt）就认为「用户正在往回翻」。
    ///
    /// 96 是权衡值：太小（如 20）会让触控板回弹的几像素就把按钮闪出来；
    /// 太大（如 400）则要翻过一整屏才给按钮，用户那时已经找不到回来的路了。
    public static let jumpThreshold: CGFloat = 96

    /// 输入框上方那层虚化带的高度（pt）。
    ///
    /// **不按视口比例缩放**：一条固定高度的窄带就足以表达「下面还有内容」，
    /// 按比例放大反而会让大半屏文字都糊掉 —— 需求要的是「轻微可见」。
    public static let fadeHeight: CGFloat = 36

    /// 视口底边与内容底边之间的距离；负值（橡皮筋回弹 / 内容不足一屏）一律夹到 0。
    ///
    /// - 内容比视口短：本来就没有可滚动的量，不存在「上翻」。
    /// - 越过边界回弹：`contentOffset` 会跑到区间外，不夹取就会得到负距离。
    public static func distanceFromBottom(
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        contentOffsetY: CGFloat,
        bottomInset: CGFloat = 0
    ) -> CGFloat {
        max(contentHeight - contentOffsetY - containerHeight + bottomInset, 0)
    }

    /// 是否该显示「回到底部」按钮。
    public static func shouldOfferJumpToBottom(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom > jumpThreshold
    }

    /// 内容变化时该不该自动滚到底（S4-1）。
    ///
    /// 口径（2026-10-10 拍板）：**用户一上翻就暂停跟随**。
    /// 生成回复时往上翻看历史，不该每来一个 token 就被拽回底部；
    /// 要继续跟随就自己滚回底部，或者点「回到底部」。
    ///
    /// - Parameter userSentMessage: 这次变化是不是**用户刚发出一条**。
    ///   自己发的话即使之前在上翻也要拉到底 —— 那条消息就是他发出去要看的东西，
    ///   留在屏幕外会让人以为「没发出去」。老师的流式输出 / 追加历史一律尊重上翻。
    public static func shouldAutoScrollOnContentChange(
        isScrolledUp: Bool,
        userSentMessage: Bool
    ) -> Bool {
        userSentMessage || !isScrolledUp
    }

    /// 虚化带在视口中的起点比例（0…1），供渐变蒙版用。
    ///
    /// 视口高度非法（0 / 负）时返回 0：宁可整屏渐隐，也不要因为除零算出 NaN
    /// 让整个蒙版变成一片空白（那看起来像「聊天内容全没了」）。
    public static func fadeStartFraction(
        containerHeight: CGFloat,
        fadeHeight: CGFloat = ChatScrollMetrics.fadeHeight
    ) -> CGFloat {
        guard containerHeight > 0 else { return 0 }
        let band = min(max(fadeHeight, 0), containerHeight)
        return 1 - band / containerHeight
    }
}
