import AIDomain
import XCTest

/// 聊天区「回到底部」按钮与输入框上方虚化的规则。
///
/// 为什么值得单独测：阈值算错时用户看到的是「都滚到底了按钮还赖着不走」
/// 或「翻上去半天却看不见按钮」——两种都只能靠肉眼盯着屏幕猜是哪一步错了。
final class ChatScrollMetricsTests: XCTestCase {

    // MARK: - 距底距离

    func testDistanceIsZeroWhenContentFitsViewport() {
        // 内容比视口短（无需滚动）→ 不存在「上翻」。
        let distance = ChatScrollMetrics.distanceFromBottom(
            contentHeight: 200, containerHeight: 600, contentOffsetY: 0
        )
        XCTAssertEqual(distance, 0)
    }

    func testDistanceIsZeroAtBottom() {
        // 滚到底：offset = 内容高 - 视口高。
        let distance = ChatScrollMetrics.distanceFromBottom(
            contentHeight: 2000, containerHeight: 600, contentOffsetY: 1400
        )
        XCTAssertEqual(distance, 0, accuracy: 0.001)
    }

    func testDistanceGrowsAsUserScrollsUp() {
        let small = ChatScrollMetrics.distanceFromBottom(
            contentHeight: 2000, containerHeight: 600, contentOffsetY: 1400
        )
        let large = ChatScrollMetrics.distanceFromBottom(
            contentHeight: 2000, containerHeight: 600, contentOffsetY: 200
        )
        XCTAssertGreaterThan(large, small)
        XCTAssertEqual(large, 1200, accuracy: 0.001)
    }

    /// 橡皮筋回弹会让 offset 越过边界 —— 不夹取就会得到负距离，
    /// 进而让「距底距离」在某些判断里被当成负数比较，行为不可预测。
    func testOverscrollClampsToZeroInsteadOfGoingNegative() {
        let distance = ChatScrollMetrics.distanceFromBottom(
            contentHeight: 2000, containerHeight: 600, contentOffsetY: 1700
        )
        XCTAssertEqual(distance, 0)
        XCTAssertGreaterThanOrEqual(distance, 0)
    }

    /// 底部内边距会把「到底」的 offset 推后（`offset = 内容高 - 视口高 + 内边距`），
    /// 因此同一个 offset 在有无内边距时**离底的距离并不相同**。
    /// 不把内边距补进距离，阈值实际上会往后挪一整个内边距 ——
    /// 表现为「已经往上翻了一屏，回底按钮还不出现」。
    func testBottomInsetShiftsTheThresholdBackToTheRealBottom() {
        let inset: CGFloat = 66
        let restingOffset: CGFloat = 2000 - 600 + inset
        // 从真正的底部往回翻「一个阈值再多 1pt」。
        let offset = restingOffset - (ChatScrollMetrics.jumpThreshold + 1)

        let withInset = ChatScrollMetrics.distanceFromBottom(
            contentHeight: 2000, containerHeight: 600,
            contentOffsetY: offset, bottomInset: inset
        )
        let ignoredInset = ChatScrollMetrics.distanceFromBottom(
            contentHeight: 2000, containerHeight: 600,
            contentOffsetY: offset, bottomInset: 0
        )

        XCTAssertTrue(ChatScrollMetrics.shouldOfferJumpToBottom(distanceFromBottom: withInset))
        XCTAssertEqual(withInset - ignoredInset, inset, accuracy: 0.001)
        XCTAssertFalse(
            ChatScrollMetrics.shouldOfferJumpToBottom(distanceFromBottom: ignoredInset),
            "少算 66pt 内边距 → 同一位置判成「没在上翻」"
        )
    }

    /// 内边距本身不该把「到底」判成负数（夹取后是 0，不是 -66）。
    func testDistanceAtRealBottomWithInsetIsZeroNotNegative() {
        let inset: CGFloat = 66
        let distance = ChatScrollMetrics.distanceFromBottom(
            contentHeight: 2000, containerHeight: 600, contentOffsetY: 1466, bottomInset: inset
        )
        XCTAssertEqual(distance, 0, accuracy: 0.001)
    }

    // MARK: - 按钮显隐

    func testJumpButtonHiddenAtAndBelowThreshold() {
        XCTAssertFalse(ChatScrollMetrics.shouldOfferJumpToBottom(distanceFromBottom: 0))
        XCTAssertFalse(
            ChatScrollMetrics.shouldOfferJumpToBottom(
                distanceFromBottom: ChatScrollMetrics.jumpThreshold
            ),
            "正好等于阈值时不显示：差 0.5pt 就闪一下按钮是明显的观感问题"
        )
    }

    func testJumpButtonShownAboveThreshold() {
        XCTAssertTrue(
            ChatScrollMetrics.shouldOfferJumpToBottom(
                distanceFromBottom: ChatScrollMetrics.jumpThreshold + 1
            )
        )
        XCTAssertTrue(ChatScrollMetrics.shouldOfferJumpToBottom(distanceFromBottom: 500))
    }

    // MARK: - 虚化带

    func testFadeStartFractionLeavesBottomBandOfFixedHeight() {
        // 视口 600pt、虚化带 36pt → 渐变从 94% 处开始。
        let start = ChatScrollMetrics.fadeStartFraction(containerHeight: 600, fadeHeight: 36)
        XCTAssertEqual(start, 0.94, accuracy: 0.0001)
        // 虚化带**固定高度**，不随视口等比放大（否则大半屏文字都会糊掉）。
        XCTAssertEqual((1 - start) * 600, 36, accuracy: 0.001)

        let shorter = ChatScrollMetrics.fadeStartFraction(containerHeight: 300, fadeHeight: 36)
        XCTAssertEqual(shorter, 0.88, accuracy: 0.0001)
        XCTAssertEqual((1 - shorter) * 300, 36, accuracy: 0.001, "换视口后带高不变")
    }

    func testFadeBandNeverExceedsViewport() {
        // 视口比虚化带还矮：带高夹到视口高，起点为 0（整屏渐隐），不能算出负数。
        let start = ChatScrollMetrics.fadeStartFraction(containerHeight: 20, fadeHeight: 36)
        XCTAssertEqual(start, 0, accuracy: 0.0001)
    }

    /// 视口高度非法时**不返回 NaN**：NaN 会让整个蒙版渲染成空白，
    /// 看起来就像「聊天内容全没了」——宁可整屏渐隐也不要有这种表现。
    func testInvalidViewportHeightDoesNotProduceNaN() {
        for height in [CGFloat(0), -10] {
            let start = ChatScrollMetrics.fadeStartFraction(containerHeight: height)
            XCTAssertFalse(start.isNaN, "高度 \(height) 时不能产出 NaN")
            XCTAssertEqual(start, 0)
        }
    }

    func testFadeHeightDefaultsToDocumentedValue() {
        XCTAssertGreaterThan(ChatScrollMetrics.fadeHeight, 0)
        XCTAssertEqual(
            ChatScrollMetrics.fadeStartFraction(containerHeight: 600),
            ChatScrollMetrics.fadeStartFraction(
                containerHeight: 600, fadeHeight: ChatScrollMetrics.fadeHeight
            )
        )
    }
}
