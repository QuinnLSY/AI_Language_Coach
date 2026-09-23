import XCTest
@testable import AppUI

/// 气泡宽度口径的回归（用户 2026-09-24 报障：学员说了一句短的，
/// 气泡却拉满整行，右侧留一大片空白）。
///
/// 根因在 `WordLookupText.sizeThatFits`：它当年是「有可用宽度就**用满**」——
/// 把自己当成贪心视图（`NSViewRepresentable` 在 SwiftUI 眼里本来也是），
/// 于是任何短句都被撑到列宽。现在改成「自然宽度与可用宽度的较小者」。
///
/// ⚠️ 为什么钉纯函数而不是渲染出图：宽度是**布局前**算出来的数，
/// 它同时决定渲染与「气泡是不是贴内容」，把它单独抽出来就能直接断言；
/// 渲染出图另有一条（`ChatBubbleWidthRenderTests`）钉「离屏看到的右缘」。
final class BubbleWidthRuleTests: XCTestCase {

    /// 短句：贴着内容排（这就是这次修的那一格）。
    func testShortSentenceKeepsItsNaturalWidth() {
        let width = WordLookupText.layoutWidth(natural: 120, requested: 420, minimum: 1)
        XCTAssertEqual(width, 120, "一行放得下就该贴着内容，不许拉满可用宽度")
    }

    /// 长句：放不下才用可用宽度折行。
    func testLongSentenceWrapsAtTheAvailableWidth() {
        let width = WordLookupText.layoutWidth(natural: 900, requested: 420, minimum: 1)
        XCTAssertEqual(width, 420, "自然宽度超过可用宽度时，按可用宽度折行")
    }

    /// 父视图不限宽（`fixedSize(horizontal: true)` / 查词卡那处）：就是内容宽度。
    func testUnboundedProposalFallsBackToTheNaturalWidth() {
        XCTAssertEqual(WordLookupText.layoutWidth(natural: 180, requested: nil, minimum: 1), 180)
        XCTAssertEqual(
            WordLookupText.layoutWidth(
                natural: 180, requested: WordLookupText.unboundedWidth, minimum: 1
            ),
            180,
            "天文数字级的「可用宽度」等于没给，不能拿它去拉满"
        )
    }

    /// 极短内容（"Ok."）也要有地板 —— 否则文字会被压成一条缝。
    func testExtremelyShortContentKeepsTheFloor() {
        XCTAssertEqual(WordLookupText.layoutWidth(natural: 8, requested: 420, minimum: 36), 36)
        XCTAssertEqual(WordLookupText.layoutWidth(natural: 0, requested: nil, minimum: 36), 36)
    }

    /// 反证对照：老口径（用满可用宽度）会把这条短句算成 420。
    ///
    /// 它同时是「这条断言不是恒等式」的自检 —— 两个算式在同一输入上必须给出不同答案，
    /// 否则说明 `layoutWidth` 根本没改。
    func testOldGreedyRuleWouldHaveBeenWrongHere() {
        let oldRule = max(CGFloat(420), CGFloat(1))
        let newRule = WordLookupText.layoutWidth(natural: 120, requested: 420, minimum: 1)
        XCTAssertNotEqual(newRule, oldRule, "新旧口径在这条输入上必须不同")
        XCTAssertEqual(oldRule, 420)
    }

    // MARK: - 气泡的最小宽度 = 三颗图标的整宽（用户口径）

    func testLearnerBubbleFloorMatchesItsActionRow() {
        XCTAssertEqual(LearnerBubbleActionRow.totalWidth, 64, "三颗 20pt 图标 + 两个 2pt 间距")
        XCTAssertEqual(
            LearnerBubbleActionRow.minimumBubbleContentWidth,
            LearnerBubbleActionRow.totalWidth - 28,
            "气泡左右各 14 的内边距要从地板里扣掉"
        )
    }
}
