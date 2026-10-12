import XCTest

@testable import AIDomain

/// ⑦-D 通勤连播队列的**编排规则**（纯函数）。
///
/// 钉的是几句会悄悄说谎的话：预估时长、第几句、放完的收尾，
/// 以及「下标越界时队列不许空转」。
final class CommuteQueueTests: XCTestCase {

    // MARK: - ① 排队

    func testNoDrillsMeansNoQueue() {
        XCTAssertNil(CommuteQueue.build(drills: []), "今天没有句子就不该有那张卡")
    }

    func testQueueStartsFromTheGivenSentence() {
        let queue = CommuteQueue.build(drills: Self.drills, from: 2)
        XCTAssertEqual(queue?.index, 2)
        XCTAssertEqual(queue?.progressText, "第 3 / 6 句")
        XCTAssertEqual(queue?.currentDrill?.text, "Nice to meet you.")
    }

    /// ⚠️ 素材重生成之后句数会变少，存下来的「练到第几句」可能已经越界 ——
    /// 不夹取就会出现「连播按下去什么都不放」。
    func testOutOfRangeIndexIsClamped() {
        XCTAssertEqual(CommuteQueue.build(drills: Self.drills, from: 99)?.index, 5)
        XCTAssertEqual(CommuteQueue.build(drills: Self.drills, from: -3)?.index, 0)
    }

    // MARK: - ② 推进

    func testAdvanceReturnsFalseAtTheEnd() {
        var queue = CommuteQueue.build(drills: Self.drills, from: 4)!
        XCTAssertTrue(queue.advance(), "第 5 句之后还有一句")
        XCTAssertFalse(queue.advance(), "放完最后一句要返回 false，调用方据此收尾")
        XCTAssertTrue(queue.isFinished)
        XCTAssertNil(queue.currentDrill)
    }

    func testRemainingText() {
        let queue = CommuteQueue.build(drills: Self.drills, from: 3)!
        XCTAssertEqual(queue.remainingText, "还剩 2 句")
    }

    // MARK: - ③ 时长估算

    func testSpeakingSecondsGrowsWithTheSentence() {
        let short = CommuteQueue.speakingSeconds("Hi.")
        let long = CommuteQueue.speakingSeconds("Could you tell me where the nearest station is please?")
        XCTAssertGreaterThan(long, short, "长句自然要念更久")
        XCTAssertGreaterThanOrEqual(short, 1, "再短的句子也要占一位，不能算出 0")
    }

    /// 从中间接着放时，已经放过的那几句**不计入**预估（报总数会虚高）。
    func testEstimateCountsOnlyTheRest() {
        let full = CommuteQueue.build(drills: Self.drills, from: 0)!
        let tail = CommuteQueue.build(drills: Self.drills, from: 3)!
        XCTAssertLessThan(tail.estimatedSeconds, full.estimatedSeconds)
        XCTAssertEqual(full.estimatedSeconds - tail.estimatedSeconds, Self.estimateOfFirstThree)
    }

    func testSummaryTextCarriesBothNumbers() {
        let queue = CommuteQueue.build(drills: Self.drills)!
        XCTAssertEqual(queue.summaryText, "共 6 句 · 约 \(queue.estimateText)")
    }

    /// 留白更长 → 总时长更长（连播的正文是那段留白，不是示范）。
    func testWiderGapMeansLongerEstimate() {
        let tight = CommuteQueue.build(drills: Self.drills, gapSeconds: 2)!
        let loose = CommuteQueue.build(drills: Self.drills, gapSeconds: 8)!
        XCTAssertGreaterThan(loose.estimatedSeconds, tight.estimatedSeconds)
    }

    func testNegativeGapIsClamped() {
        let queue = CommuteQueue.build(drills: Self.drills, gapSeconds: -5)
        XCTAssertEqual(queue?.gapSeconds, 0, "负的留白会算出负数时长并让 sleep 直接抛错")
    }

    // MARK: - 工装

    private static let drills: [ShadowingDrill] = [
        ShadowingDrill(id: "d1", text: "Hi.", translation: "你好。", topic: "问候", difficulty: 1, focus: ""),
        ShadowingDrill(id: "d2", text: "How are you?", translation: "你好吗？", topic: "问候", difficulty: 1, focus: ""),
        ShadowingDrill(id: "d3", text: "Nice to meet you.", translation: "很高兴认识你。", topic: "问候", difficulty: 2, focus: ""),
        ShadowingDrill(id: "d4", text: "I would like a coffee please.", translation: "我要一杯咖啡。", topic: "点单", difficulty: 2, focus: ""),
        ShadowingDrill(id: "d5", text: "Could you tell me where the nearest station is?", translation: "请问最近的车站在哪？", topic: "问路", difficulty: 3, focus: ""),
        ShadowingDrill(id: "d6", text: "See you tomorrow.", translation: "明天见。", topic: "告别", difficulty: 1, focus: "")
    ]

    /// 前三句各自的「朗读 + 留白」之和（与 `estimatedSeconds` 同一把尺）。
    private static var estimateOfFirstThree: Int {
        drills.prefix(3).reduce(0) { $0 + Int((CommuteQueue.speakingSeconds($1.text) + CommuteQueue.defaultGapSeconds).rounded()) }
    }
}
