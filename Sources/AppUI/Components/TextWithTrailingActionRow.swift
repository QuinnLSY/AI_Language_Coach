import SwiftUI

/// 「一句话 + 紧跟其后的操作按钮」的一行（查词卡例句右侧那个朗读图标走这里）。
///
/// ⚠️ 为什么不能直接上 `HStack`：句子走 `LookupText`（AppKit `NSViewRepresentable`），
/// 而 `NSViewRepresentable` 没有 `Text` 那种「理想宽度」，它在 SwiftUI 眼里是**贪心**视图 ——
/// 只要给了可用宽度就吃满（见 `WordLookupText.sizeThatFits` 的「有限宽度」分支），
/// `HStack` 于是把后面的按钮一路顶到行尾（用户实测：朗读图标离句子隔了大半张卡）。
/// 反过来对句子整体加 `.fixedSize(horizontal: true)` 也不行：长句会被顶出卡片。
///
/// 所以这里按「先量自然宽度、够放就一行、不够才折行」两段式排：
/// 1. `自然宽度 + 间距 + 按钮宽度 ≤ 可用宽度` → 句子**钉在自然宽度**，按钮紧贴其后；
/// 2. 否则 → 句子按「可用宽度 − 按钮宽度 − 间距」折行，按钮留在右上（多行句没有「句末」可贴）。
///
/// 按钮纵向上对齐句子**首行**的中心（多行时也一样，不会跑到整块文字的中间去）。
struct TextWithTrailingActionRow: Layout {

    /// 句子与按钮之间的间距。
    var spacing: CGFloat = 6

    // MARK: - Layout

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count >= 2 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        // 不限宽（父视图没给宽度）时按内容算，别回一个 0 宽让别人量不出东西。
        let available = max(proposal.width ?? plan(available: .greatestFiniteMagnitude,
                                                   subviews: subviews).rowWidth, 1)
        let plan = plan(available: available, subviews: subviews)
        return CGSize(width: available, height: plan.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Cache) {
        guard subviews.count >= 2 else {
            subviews.first?.place(at: bounds.origin, proposal: proposal)
            return
        }
        let plan = plan(available: max(bounds.width, 1), subviews: subviews)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            proposal: ProposedViewSize(width: plan.textSize.width, height: nil)
        )
        // 按钮贴着**首行**：多行句时它仍在右上角，而不是沉到整块文字的正中间。
        let actionY = bounds.minY + max(0, (plan.firstLineHeight - plan.actionSize.height) / 2)
        subviews[1].place(
            at: CGPoint(x: bounds.minX + plan.actionX, y: actionY),
            proposal: ProposedViewSize(plan.actionSize)
        )
    }

    // MARK: - 量 / 摆 共用的同一份算式

    private struct Plan {
        var textSize: CGSize
        var actionSize: CGSize
        /// 按钮相对行左缘的 x。
        var actionX: CGFloat
        /// 句子**首行**的高度（按钮纵向居中的基准）。
        var firstLineHeight: CGFloat
        var height: CGFloat
        /// 一行排下来需要的宽度（自然宽度 + 间距 + 按钮）。
        var rowWidth: CGFloat
    }

    private func plan(available: CGFloat, subviews: Subviews) -> Plan {
        let naturalText = subviews[0].sizeThatFits(.unspecified)
        let action = subviews[1].sizeThatFits(.unspecified)
        let oneLine = naturalText.width + spacing + action.width

        if oneLine <= available {
            // 一行放得下：句子钉自然宽度，按钮紧贴其后。
            return Plan(
                textSize: CGSize(width: naturalText.width, height: naturalText.height),
                actionSize: action,
                actionX: naturalText.width + spacing,
                firstLineHeight: naturalText.height,
                height: max(naturalText.height, action.height),
                rowWidth: oneLine
            )
        }
        // 放不下：句子折行（宽度 = 可用 − 按钮 − 间距），按钮留右上。
        let textWidth = max(available - spacing - action.width, 1)
        let wrapped = subviews[0].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
        return Plan(
            textSize: CGSize(width: textWidth, height: wrapped.height),
            actionSize: action,
            actionX: max(available - action.width, 0),
            firstLineHeight: naturalText.height,
            height: max(wrapped.height, action.height),
            rowWidth: oneLine
        )
    }
}
