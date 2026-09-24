@testable import AppUI
import XCTest

/// 年度记录悬停浮卡的落点钳制（#5，纯函数）。
///
/// 要求：浮卡出现在鼠标旁、**不超出边界**。优先右下；右边放不下翻左边、
/// 下面放不下翻上面；贴边的极端情形最后钳进边界。
///
/// 三轮（2026-09-24 报障「浮卡挡住了要看的那一天的方格，以及同列上下其他格子」）：
/// 再加一条**禁入区** —— 浮卡与「被查看那一列」的条带纵向有交集时必须整体让开。
final class AnnualTooltipPlacementTests: XCTestCase {

    private let container = CGSize(width: 700, height: 200)
    /// 浮卡尺寸（宽固定 216、约 6 行高）。
    private let tooltip = CGSize(width: 216, height: 110)

    private func origin(_ mouse: CGPoint) -> CGPoint {
        AnnualTooltipPlacement.origin(mouse: mouse, containerSize: container, tooltipSize: tooltip)
    }

    /// 钳制后的矩形必须完整落在容器内（margin=12）。
    private func assertInside(_ result: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(result.x, 12, file: file, line: line)
        XCTAssertGreaterThanOrEqual(result.y, 12, file: file, line: line)
        XCTAssertLessThanOrEqual(result.x + tooltip.width, container.width - 12, file: file, line: line)
        XCTAssertLessThanOrEqual(result.y + tooltip.height, container.height - 12, file: file, line: line)
    }

    // MARK: 自由空间 → 右下

    func testPrefersBelowRightOfTheMouse() {
        let result = origin(CGPoint(x: 100, y: 40))
        XCTAssertEqual(result.x, 112)
        XCTAssertEqual(result.y, 52)
    }

    // MARK: 右缘 → 翻左；下缘 → 翻上

    func testFlipsToLeftNearTheRightEdge() {
        let result = origin(CGPoint(x: 660, y: 40))
        assertInside(result)
        // 翻到鼠标左侧：浮卡右缘在鼠标左边的 margin 处。
        XCTAssertEqual(result.x, 660 - 12 - tooltip.width, accuracy: 0.5)
    }

    func testFlipsToAboveNearTheBottomEdge() {
        let result = origin(CGPoint(x: 100, y: 190))
        assertInside(result)
        XCTAssertEqual(result.y, 190 - 12 - tooltip.height, accuracy: 0.5)
    }

    // MARK: 右下角 → 双向翻 + 兜底钳制

    func testClampsAtTheBottomRightCorner() {
        let result = origin(CGPoint(x: 690, y: 195))
        assertInside(result)
    }

    // MARK: 鼠标贴着左缘 → 不会翻出左边界

    func testNeverLeavesTheLeftEdge() {
        let result = origin(CGPoint(x: 2, y: 40))
        assertInside(result)
    }

    // MARK: 容器比浮卡还小 → 钳进边界（这道守护只有这种极端情形才可达）

    func testPinsInsideWhenTheContainerIsSmallerThanTheCard() {
        // 年历在窄窗口上可能比浮卡 216pt 还窄：翻转逻辑会翻过头（x 算出 -168），
        // 最终钳制把它钉在左上 margin —— 装不下是物理事实，能做的只有贴边可见。
        let size = AnnualTooltipPlacement.origin(
            mouse: CGPoint(x: 60, y: 30),
            containerSize: CGSize(width: 180, height: 80),
            tooltipSize: CGSize(width: 216, height: 110)
        )
        XCTAssertEqual(size.x, 12, "x 要被钳到左 margin（没有钳制会算出 -168）")
        XCTAssertEqual(size.y, 12, "y 要被钳到上 margin（没有钳制会算出 -92）")
    }

    // MARK: 禁入区：被查看的那一列（2026-09-24 报障）

    /// 鼠标停在那一列的**任何横向位置**（含贴着左右边缘），浮卡都不许压住它。
    ///
    /// 报障本体：老落点 = 鼠标 + margin，鼠标落在格子偏左时浮卡的左缘正好切在
    /// 同一格里 —— 那一列上下别的格子也被整条盖住，「沿列比对」完全没法做。
    /// 反证：把 `avoiding:` 传成 nil（或删掉让开那一段）→ 本用例红。
    func testTooltipStaysClearOfTheFocusedColumn() {
        let strip = CGRect(x: 190, y: 30, width: 22, height: 150)
        for mouseX in stride(from: 191.0, through: 211.0, by: 2.0) {
            let result = AnnualTooltipPlacement.origin(
                mouse: CGPoint(x: mouseX, y: 80),
                containerSize: container,
                tooltipSize: tooltip,
                avoiding: strip
            )
            assertInside(result)
            let rect = CGRect(origin: result, size: tooltip)
            XCTAssertFalse(
                rect.intersects(strip),
                "鼠标 x=\(mouseX) 时浮卡 \(rect) 压住了被查看的那一列 \(strip)"
            )
            // 空档要够一个 margin：浮卡有半径 6 的阴影，贴着边放还是会糊到格子上。
            XCTAssertTrue(
                rect.maxX <= strip.minX - 12 || rect.minX >= strip.maxX + 12,
                "鼠标 x=\(mouseX) 时浮卡 \(rect) 离那一列太近（阴影会盖住格子）"
            )
        }
    }

    /// 列右侧装不下就翻到**列左侧**（仍然是整条让开，不是压一半）。
    func testFlipsToTheLeftSideWhenTheRightSideHasNoRoom() {
        let strip = CGRect(x: 480, y: 30, width: 22, height: 150)
        let result = AnnualTooltipPlacement.origin(
            mouse: CGPoint(x: 490, y: 80),
            containerSize: container,
            tooltipSize: tooltip,
            avoiding: strip
        )
        assertInside(result)
        XCTAssertEqual(result.x, 480 - 12 - tooltip.width, accuracy: 0.5, "应贴在列的左侧")
    }

    /// 列在最左边 → 浮卡只能往右让。
    func testGoesToTheRightSideWhenTheColumnIsAtTheLeftEdge() {
        let strip = CGRect(x: 12, y: 30, width: 22, height: 150)
        let result = AnnualTooltipPlacement.origin(
            mouse: CGPoint(x: 20, y: 60),
            containerSize: container,
            tooltipSize: tooltip,
            avoiding: strip
        )
        assertInside(result)
        XCTAssertEqual(result.x, 34 + 12, accuracy: 0.5, "应贴在列的右侧")
    }

    /// 纵向根本不挨着那一列（例如浮卡已经在网格下方）→ 不许为它横着挪。
    ///
    /// 少了这个上界判断，浮卡会为了一个自己根本碰不到的矩形乱跳。
    func testDoesNotShiftHorizontallyWhenVerticallyClearOfTheColumn() {
        let strip = CGRect(x: 190, y: 30, width: 22, height: 130)
        let result = AnnualTooltipPlacement.origin(
            mouse: CGPoint(x: 200, y: 300),
            containerSize: CGSize(width: 700, height: 400),
            tooltipSize: tooltip,
            avoiding: strip
        )
        XCTAssertEqual(result.x, 212, "纵向不重叠时落点应与无禁入区时一致（鼠标 x + margin）")
        XCTAssertGreaterThan(result.y, strip.maxY, "夹具自检：浮卡确实落在那一列下方")
    }
}
