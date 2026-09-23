@testable import AppUI
import XCTest

/// 年度记录悬停浮卡的落点钳制（#5，纯函数）。
///
/// 要求：浮卡出现在鼠标旁、**不超出边界**。优先右下；右边放不下翻左边、
/// 下面放不下翻上面；贴边的极端情形最后钳进边界。
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
}
