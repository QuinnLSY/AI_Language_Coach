import AIDomain
import XCTest

/// 附件托盘「放不下就换行」规则：上传项展示不全时自动换行（本轮需求）。
///
/// 为什么值得单独测：换行算错的症状是「最后一个 chip 被切掉半截」或
/// 「明明还放得下却提早换行」——在 SwiftUI 里只能靠肉眼盯截图猜是哪一步错了，
/// 有纯函数就能把边界值（恰好放得下 / 差 1pt / 单个比整行还宽）直接钉死。
final class AttachmentTrayLayoutTests: XCTestCase {

    func testEmptyInputYieldsNoRows() {
        XCTAssertTrue(
            AttachmentTrayLayout.rows(itemWidths: [], maxWidth: 400, spacing: 8).isEmpty
        )
    }

    func testSingleRowWhenEverythingFits() {
        // 三个 100pt 的 chip + 两个 8pt 间距 = 316 ≤ 400 → 一行。
        let widths: [CGFloat] = [100, 100, 100]
        XCTAssertEqual(
            AttachmentTrayLayout.rows(itemWidths: widths, maxWidth: 400, spacing: 8),
            [[0, 1, 2]]
        )
    }

    func testExactlyFitsDoesNotWrap() {
        // 边界：100 + 8 + 100 = 208，恰好等于行宽 → **不换行**（不能用 `<` 判定）。
        XCTAssertEqual(
            AttachmentTrayLayout.rows(itemWidths: [100, 100], maxWidth: 208, spacing: 8),
            [[0, 1]]
        )
        // 窄 1pt 就必须换行。
        XCTAssertEqual(
            AttachmentTrayLayout.rows(itemWidths: [100, 100], maxWidth: 207, spacing: 8),
            [[0], [1]]
        )
    }

    func testWrapsInOriginalOrder() {
        let widths: [CGFloat] = [120, 120, 120, 120]
        let rows = AttachmentTrayLayout.rows(itemWidths: widths, maxWidth: 260, spacing: 8)
        // 每行最多两个（120 + 8 + 120 = 248 ≤ 260），顺序不被打乱。
        XCTAssertEqual(rows, [[0, 1], [2, 3]])
    }

    func testOversizedChipOccupiesItsOwnRow() {
        // 单个 chip 比整行还宽：独占一行，且**不能**陷入死循环或把后续项吞掉。
        let rows = AttachmentTrayLayout.rows(
            itemWidths: [500, 60, 60], maxWidth: 200, spacing: 8
        )
        XCTAssertEqual(rows, [[0], [1, 2]])
    }

    func testUnknownWidthCollapsesToSingleRow() {
        // 首次布局拿不到宽度（`proposal.width == nil` → 传 `.infinity`）：
        // 并成一行等下一次布局修正，绝不返回坏值。
        XCTAssertEqual(
            AttachmentTrayLayout.rows(itemWidths: [80, 80, 80], maxWidth: .infinity, spacing: 8),
            [[0, 1, 2]]
        )
        XCTAssertEqual(
            AttachmentTrayLayout.rows(itemWidths: [80, 80], maxWidth: 0, spacing: 8),
            [[0, 1]]
        )
    }

    func testLineCountMatchesRows() {
        let widths: [CGFloat] = [120, 120, 120, 120]
        XCTAssertEqual(
            AttachmentTrayLayout.lineCount(itemWidths: widths, maxWidth: 260, spacing: 8),
            2
        )
    }

    func testNegativeSpacingIsTreatedAsZero() {
        // 间距传负数不应把两个 chip 叠在一起（也算一种越界容错）。
        let rows = AttachmentTrayLayout.rows(
            itemWidths: [100, 100], maxWidth: 200, spacing: -50
        )
        XCTAssertEqual(rows, [[0, 1]])
    }
}
