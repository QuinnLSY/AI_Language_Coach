import AIDomain
import XCTest

/// 聊天输入框高度规则（第 2 项需求）：固定行宽、最多 5 行、超过就滚动。
///
/// 为什么值得单独测：高度算错的症状是「输入框第 6 行被吞掉」或「打字时抖一下」——
/// 这两种在 SwiftUI 里都看不出是哪一步算错了，只能靠边界值钉死。
final class ComposerMetricsTests: XCTestCase {

    private let lineHeight: CGFloat = 18  // 14pt 字体的行高（≈17.5 取整）

    func testEmptyContentStillOccupiesOneLine() {
        // 空输入不能塌成一条缝：否则光标都放不下。
        let height = ComposerMetrics.clampedHeight(contentHeight: 0, lineHeight: lineHeight)
        XCTAssertEqual(height, lineHeight)
    }

    func testContentShorterThanOneLineClampsUpToOneLine() {
        let height = ComposerMetrics.clampedHeight(contentHeight: 7, lineHeight: lineHeight)
        XCTAssertEqual(height, lineHeight, "不足一行也按一行高显示")
    }

    func testHeightGrowsWithContentUpToMaxLines() {
        for lines in 1...ComposerMetrics.maxLines {
            let content = lineHeight * CGFloat(lines)
            XCTAssertEqual(
                ComposerMetrics.clampedHeight(contentHeight: content, lineHeight: lineHeight),
                content,
                "\(lines) 行时应当正好按内容高度显示"
            )
        }
    }

    func testHeightStopsGrowingPastMaxLines() {
        let ceiling = lineHeight * CGFloat(ComposerMetrics.maxLines)
        let height = ComposerMetrics.clampedHeight(
            contentHeight: lineHeight * CGFloat(ComposerMetrics.maxLines + 3),
            lineHeight: lineHeight
        )
        XCTAssertEqual(height, ceiling, "超过 5 行后**不再长高**，多出来的靠滚动看")
    }

    func testNotScrollableAtExactlyMaxLines() {
        // 边界：正好 5 行不该出现滚动条 —— 差 0.5pt 就闪一下滚动条是明显的观感问题。
        let exactlyFive = lineHeight * CGFloat(ComposerMetrics.maxLines)
        XCTAssertFalse(ComposerMetrics.isScrollable(contentHeight: exactlyFive, lineHeight: lineHeight))
        XCTAssertTrue(
            ComposerMetrics.isScrollable(contentHeight: exactlyFive + 1, lineHeight: lineHeight),
            "再多一点就必须能滚"
        )
    }

    func testScrollableOnlyAboveCeiling() {
        XCTAssertFalse(ComposerMetrics.isScrollable(contentHeight: lineHeight, lineHeight: lineHeight))
        XCTAssertTrue(
            ComposerMetrics.isScrollable(contentHeight: lineHeight * 6, lineHeight: lineHeight)
        )
    }

    func testVisibleLineCountIsClampedToOneThroughMax() {
        XCTAssertEqual(ComposerMetrics.visibleLineCount(contentHeight: 0, lineHeight: lineHeight), 1)
        XCTAssertEqual(
            ComposerMetrics.visibleLineCount(contentHeight: lineHeight * 3, lineHeight: lineHeight), 3
        )
        XCTAssertEqual(
            ComposerMetrics.visibleLineCount(contentHeight: lineHeight * 99, lineHeight: lineHeight),
            ComposerMetrics.maxLines,
            "再多行也只显示 maxLines"
        )
    }

    /// 零 / 负行高不能让公式除零或给出负高度（真实场景里字体测量失败会返回 0）。
    func testZeroLineHeightDoesNotProduceDegenerateValues() {
        let height = ComposerMetrics.clampedHeight(contentHeight: 40, lineHeight: 0)
        XCTAssertGreaterThanOrEqual(height, 1, "行高为 0 时也要给一个正高度")

        let count = ComposerMetrics.visibleLineCount(contentHeight: 40, lineHeight: 0)
        XCTAssertGreaterThanOrEqual(count, 1)
        XCTAssertLessThanOrEqual(count, ComposerMetrics.maxLines)
    }

    func testLineHeightIsPositiveAndScalesWithFontSize() {
        let small = ComposerMetrics.lineHeight(fontSize: 12)
        let large = ComposerMetrics.lineHeight(fontSize: 24)
        XCTAssertGreaterThan(small, 0)
        XCTAssertGreaterThan(large, small, "行高必须随字号单调增长")
    }

    // MARK: - 文本内边距（inset）必须计入封顶

    /// 封顶高度是「滚动的**可视区**高度」，而可视区上下各留了 inset。
    /// 忽略 inset 会让 5 行的封顶少 6pt —— 表现为**第 5 行被切掉一条**。
    func testCeilingReservesRoomForInset() {
        let inset: CGFloat = 3
        let ceiling = ComposerMetrics.clampedHeight(
            contentHeight: 999, lineHeight: lineHeight, inset: inset
        )
        XCTAssertEqual(
            ceiling, lineHeight * CGFloat(ComposerMetrics.maxLines) + inset * 2,
            "封顶 = maxLines 行文字 + 上下 inset"
        )
        // 去掉 inset 之后，仍然要放得下完整的 maxLines 行。
        XCTAssertGreaterThanOrEqual(
            ceiling - inset * 2, lineHeight * CGFloat(ComposerMetrics.maxLines)
        )
    }

    /// 一行高也要含 inset，否则单行输入框里光标上下贴边。
    func testOneLineFloorIncludesInset() {
        let inset: CGFloat = 3
        let floor = ComposerMetrics.clampedHeight(contentHeight: 0, lineHeight: lineHeight, inset: inset)
        XCTAssertEqual(floor, lineHeight + inset * 2)
    }

    /// **默认 inset = 0**：老调用点（不含内边距的场景）行为不变。
    func testInsetDefaultsToZeroSoExistingCallersAreUnchanged() {
        XCTAssertEqual(
            ComposerMetrics.clampedHeight(contentHeight: 0, lineHeight: lineHeight),
            ComposerMetrics.clampedHeight(contentHeight: 0, lineHeight: lineHeight, inset: 0)
        )
        XCTAssertEqual(
            ComposerMetrics.clampedHeight(contentHeight: 999, lineHeight: lineHeight),
            lineHeight * CGFloat(ComposerMetrics.maxLines)
        )
    }

    /// 负数 inset 不能让封顶低于 maxLines 行（真实场景里测量异常可能给出负值）。
    func testNegativeInsetDoesNotShrinkTheCeiling() {
        let ceiling = ComposerMetrics.clampedHeight(
            contentHeight: 999, lineHeight: lineHeight, inset: -5
        )
        XCTAssertEqual(ceiling, lineHeight * CGFloat(ComposerMetrics.maxLines))
    }
}
