import AIDomain
@testable import AIDomain
import Foundation
import XCTest

/// ⑤ 自适应学习路径（V2 automatic learning path）的纯函数判定。
///
/// 钉的是三件事：
/// - **样本不足一律不下结论**（宁可说「还在看」，也不给一个看着确定的错方向）；
/// - **有短板先补短板**，且顺序是 错题 → 顽固音素 → 到期词；
/// - **每条理由都带可核对的量**（数量或前后两个数），不许出现形容词式建议。
final class AdaptivePathTests: XCTestCase {

    // MARK: - 夹具

    private func trend(
        _ direction: PracticeTrend.Direction,
        recent: Double? = nil,
        earlier: Double? = nil,
        sessions: Int = 8
    ) -> PracticeTrend {
        PracticeTrend(direction: direction, recentRate: recent, earlierRate: earlier, sessionCount: sessions)
    }

    /// 发音分序列（由旧到新）：前后各 `count` 个点。
    private func points(earlier: Double, recent: Double, each: Int = 2) -> [TrendPoint] {
        let old = (0..<each).map { TrendPoint(label: "old\($0)", value: earlier) }
        let new = (0..<each).map { TrendPoint(label: "new\($0)", value: recent) }
        return old + new
    }

    private func signals(
        trend: PracticeTrend = PracticeTrend.unknown,
        errors: Int = 0,
        phonemes: Int = 0,
        due: Int = 0,
        confident: Bool = true,
        pronunciation: [TrendPoint] = []
    ) -> AdaptivePathSignals {
        AdaptivePathSignals(
            trend: trend,
            pendingErrors: errors,
            weakPhonemes: phonemes,
            dueVocabulary: due,
            isPlacementConfident: confident,
            pronunciationPoints: pronunciation
        )
    }

    // MARK: - ① 样本不足

    func testInsufficientSampleStaysObserving() {
        let path = AdaptivePathRule.evaluate(
            signals(trend: PracticeTrend.unknown, errors: 3, confident: false)
        )
        XCTAssertEqual(path.stance, .observing)
        XCTAssertEqual(path.nextActions, [.conversation], "还在观察时只该让人去多练几轮")
    }

    /// 档位不可信但**趋势有结论**时，不能装作没看见 —— 趋势本身就是样本。
    func testObservingNeedsBothSignalsMissing() {
        let path = AdaptivePathRule.evaluate(
            signals(trend: trend(.improving, recent: 0.2, earlier: 0.5), confident: false)
        )
        XCTAssertNotEqual(path.stance, .observing, "趋势已经能下结论了，就不该退回「还在看」")
    }

    // MARK: - ② 有短板先补

    func testRecurringErrorsPushToReinforce() {
        let path = AdaptivePathRule.evaluate(signals(trend: trend(.improving), errors: 3))
        XCTAssertEqual(path.stance, .reinforce)
        XCTAssertEqual(path.nextActions.first, .errorDrill)
        XCTAssertTrue(path.reasons.contains { $0.contains("3 处反复错") },
                     "理由必须带可核对的数量，实得 \(path.reasons)")
    }

    func testWeakPhonemesAlonePushToReinforce() {
        let path = AdaptivePathRule.evaluate(signals(trend: trend(.improving), phonemes: 2))
        XCTAssertEqual(path.stance, .reinforce)
        XCTAssertEqual(path.nextActions, [.phonemeDrill])
        XCTAssertTrue(path.reasons.contains { $0.contains("2 个音") }, "实得 \(path.reasons)")
    }

    /// 顺序钉死：错题排在顽固音素之前（两者都是从他自己犯的错里长出来的，但错题更直白）。
    func testBacklogActionsKeepTheAgreedOrder() {
        let path = AdaptivePathRule.evaluate(
            signals(trend: trend(.steady), errors: 1, phonemes: 1, due: 5)
        )
        XCTAssertEqual(path.nextActions, [.errorDrill, .phonemeDrill, .vocabulary])
    }

    /// 即使趋势在进步，短板也照样先补 —— 「往前推」不能盖过「改掉反复犯的错」。
    func testBacklogOutranksAnImprovingTrend() {
        let path = AdaptivePathRule.evaluate(
            signals(trend: trend(.improving, recent: 0.1, earlier: 0.6), errors: 1)
        )
        XCTAssertEqual(path.stance, .reinforce)
    }

    // MARK: - ③ 没短板看趋势

    func testImprovingTrendAdvances() {
        let path = AdaptivePathRule.evaluate(
            signals(trend: trend(.improving, recent: 0.2, earlier: 0.5))
        )
        XCTAssertEqual(path.stance, .advance)
        XCTAssertEqual(path.nextActions.first, .conversation)
        XCTAssertTrue(path.reasons.contains { $0.contains("0.20") && $0.contains("0.50") },
                     "进步的理由必须带上前后两个数，实得 \(path.reasons)")
    }

    func testSlippingTrendConsolidates() {
        let path = AdaptivePathRule.evaluate(
            signals(trend: trend(.slipping, recent: 0.7, earlier: 0.3))
        )
        XCTAssertEqual(path.stance, .consolidate)
        XCTAssertTrue(path.reasons.contains { $0.contains("比之前的 0.30 多了") },
                     "「在掉」必须说清方向，否则用户会把密度看反，实得 \(path.reasons)")
    }

    func testSteadyTrendWithoutBacklogConsolidates() {
        let path = AdaptivePathRule.evaluate(
            signals(trend: trend(.steady, recent: 0.4, earlier: 0.42))
        )
        XCTAssertEqual(path.stance, .consolidate)
        XCTAssertFalse(path.reasons.isEmpty)
    }

    // MARK: - 发音走势（第二条通道）

    func testFallingPronunciationPushesToConsolidateEvenWhenErrorRateIsSteady() {
        let path = AdaptivePathRule.evaluate(
            signals(trend: trend(.steady, recent: 0.4, earlier: 0.4),
                    pronunciation: points(earlier: 82, recent: 74))
        )
        XCTAssertEqual(path.stance, .consolidate, "纠错密度平稳但发音在掉，也该稳住")
        XCTAssertTrue(path.reasons.contains { $0.contains("发音分在往下走") }, "实得 \(path.reasons)")
    }

    /// 发音在掉必须**压过**「纠错密度在变好」这条结论。
    ///
    /// ⚠️ 这条是本通道唯一的真判据：其余用例里「稳态 + 掉」两种走法都会落到
    /// `consolidate`，撤掉发音通道照样绿（实测假绿过一次）。
    /// 只有「进步 + 掉」这个组合能分出高下：不摘通道 = 稳住，摘掉 = 往前推。
    func testFallingPronunciationOutranksAnImprovingTrend() {
        let path = AdaptivePathRule.evaluate(
            signals(trend: trend(.improving, recent: 0.2, earlier: 0.5),
                    pronunciation: points(earlier: 84, recent: 72))
        )
        XCTAssertEqual(path.stance, .consolidate,
                       "纠错密度在变好、但发音在往下走 —— 两个信号打架时先稳住")
        XCTAssertTrue(path.reasons.contains { $0.contains("发音分在往下走") }, "实得 \(path.reasons)")
    }

    func testRisingPronunciationIsReportedWhenAdvancing() {
        let path = AdaptivePathRule.evaluate(
            signals(trend: trend(.improving, recent: 0.2, earlier: 0.5),
                    pronunciation: points(earlier: 70, recent: 80))
        )
        XCTAssertEqual(path.stance, .advance)
        XCTAssertTrue(path.reasons.contains { $0.contains("发音分在往上走") }, "实得 \(path.reasons)")
    }

    /// 少于 4 个点**不下结论**：两点定不了一条趋势（某天一次走音就能翻盘）。
    func testPronunciationSlopeRefusesThinSamples() {
        XCTAssertNil(AdaptivePathRule.pronunciationSlope([TrendPoint(label: "a", value: 90),
                                                          TrendPoint(label: "b", value: 60)]))
        XCTAssertNil(AdaptivePathRule.pronunciationSlope([]))
    }

    func testPronunciationSlopeToleratesTwoPointsPerHalf() {
        XCTAssertEqual(AdaptivePathRule.pronunciationSlope(points(earlier: 70, recent: 80)), .up)
        XCTAssertEqual(AdaptivePathRule.pronunciationSlope(points(earlier: 80, recent: 70)), .down)
        XCTAssertEqual(AdaptivePathRule.pronunciationSlope(points(earlier: 75, recent: 76)), .flat)
    }

    /// 判据是**前后两半的均值**，不是首尾两点。
    /// 反例：首尾都是 70（首尾法会判「没变」），但前半被一个 100 抬高了 → 实为下滑。
    func testPronunciationSlopeUsesHalvesNotEndpoints() {
        XCTAssertEqual(
            AdaptivePathRule.pronunciationSlope([
                TrendPoint(label: "1", value: 70),
                TrendPoint(label: "2", value: 100),
                TrendPoint(label: "3", value: 70),
                TrendPoint(label: "4", value: 70),
            ]),
            .down,
            "首尾都是 70，但前半均值 85、后半 70 —— 按首尾会误判成「没变」"
        )
        XCTAssertEqual(
            AdaptivePathRule.pronunciationSlope([
                TrendPoint(label: "1", value: 70),
                TrendPoint(label: "2", value: 70),
                TrendPoint(label: "3", value: 90),
                TrendPoint(label: "4", value: 90),
            ]),
            .up
        )
    }

    // MARK: - 边界

    /// 负数是调用方算错的信号：夹到 0，绝不能说出「-1 处错没练掉」。
    func testNegativeCountsAreClamped() {
        let input = signals(trend: trend(.steady), errors: -3)
        XCTAssertEqual(input.pendingErrors, 0)
        let path = AdaptivePathRule.evaluate(input)
        XCTAssertEqual(path.stance, .consolidate, "夹成 0 之后就没有短板了")
        XCTAssertFalse(path.reasons.contains { $0.contains("-") }, "实得 \(path.reasons)")
    }

    /// 有短板时**不可能**没有下一步（三样都清完不属于这个分支，这里兜跟读）。
    func testBacklogBranchAlwaysHasAnAction() {
        let actions = AdaptivePathRule.backlogActions(signals())
        XCTAssertEqual(actions, [.shadowing])
    }

    /// 每种档位都要说得出来由（空数组会让卡片只剩一句结论，看着像凭感觉）。
    func testEveryStanceComesWithAtLeastOneReason() {
        let cases: [AdaptivePathSignals] = [
            signals(trend: PracticeTrend.unknown, confident: false),
            signals(trend: trend(.improving, recent: 0.2, earlier: 0.5), errors: 2),
            signals(trend: trend(.slipping, recent: 0.6, earlier: 0.3)),
            signals(trend: trend(.improving, recent: 0.2, earlier: 0.5)),
            signals(trend: trend(.steady, recent: 0.4, earlier: 0.4)),
        ]
        for item in cases {
            let path = AdaptivePathRule.evaluate(item)
            XCTAssertFalse(path.reasons.isEmpty, "\(path.stance) 必须有理由")
            XCTAssertTrue(path.hasNextAction, "\(path.stance) 必须有下一步")
        }
    }
}
