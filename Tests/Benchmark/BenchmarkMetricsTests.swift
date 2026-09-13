import AIDomain
import XCTest

/// 基准口径的单元测试：WER / RTF / TTFT / 吞吐 / 百分位 / 评分一致性。
///
/// 这些数字是「基准的尺子」——尺子歪了，所有报告都没意义，因此全部用纯函数 + 固定输入断言。
final class BenchmarkMetricsTests: XCTestCase {

    // MARK: - WER

    func testIdenticalTextHasZeroErrorRate() {
        let wer = BenchmarkMetrics.WordErrorRate(
            reference: "I would like a window seat",
            hypothesis: "I would like a window seat"
        )
        XCTAssertEqual(wer.rate, 0, accuracy: 1e-9)
        XCTAssertEqual(wer.editDistance, 0)
        XCTAssertEqual(wer.referenceWords, 6)
    }

    func testPunctuationAndCaseAreIgnored() {
        let wer = BenchmarkMetrics.WordErrorRate(
            reference: "I would like a window seat, please!",
            hypothesis: "i would like a window seat please"
        )
        XCTAssertEqual(wer.rate, 0, accuracy: 1e-9)
    }

    func testOneSubstitutionInThreeWords() {
        let wer = BenchmarkMetrics.WordErrorRate(
            reference: "I like cats",
            hypothesis: "I like dogs"
        )
        XCTAssertEqual(wer.editDistance, 1)
        XCTAssertEqual(wer.substitutions, 1)
        XCTAssertEqual(wer.insertions, 0)
        XCTAssertEqual(wer.deletions, 0)
        XCTAssertEqual(wer.rate, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testInsertionAndDeletionAreCounted() {
        let insertion = BenchmarkMetrics.WordErrorRate(
            reference: "I like cats",
            hypothesis: "I really like cats"
        )
        XCTAssertEqual(insertion.insertions, 1)
        XCTAssertEqual(insertion.deletions, 0)
        XCTAssertEqual(insertion.rate, 1.0 / 3.0, accuracy: 1e-9)

        let deletion = BenchmarkMetrics.WordErrorRate(
            reference: "I really like cats",
            hypothesis: "I like cats"
        )
        XCTAssertEqual(deletion.deletions, 1)
        XCTAssertEqual(deletion.insertions, 0)
        XCTAssertEqual(deletion.rate, 1.0 / 4.0, accuracy: 1e-9)
    }

    func testChineseIsSplitByCharacter() {
        let wer = BenchmarkMetrics.WordErrorRate(
            reference: "我喜欢这只猫",
            hypothesis: "我喜欢那只猫"
        )
        XCTAssertEqual(wer.referenceWords, 6)
        XCTAssertEqual(wer.editDistance, 1)
    }

    func testEmptyReferenceIsNotSilentlyPassed() {
        let bothEmpty = BenchmarkMetrics.WordErrorRate(reference: "", hypothesis: "")
        XCTAssertEqual(bothEmpty.rate, 0)

        let hallucination = BenchmarkMetrics.WordErrorRate(reference: "", hypothesis: "hello")
        XCTAssertEqual(hallucination.rate, 1.0)
    }

    // MARK: - 时延与吞吐

    func testRealTimeFactorAndGuards() {
        XCTAssertEqual(BenchmarkMetrics.realTimeFactor(processingSeconds: 2, audioSeconds: 4), 0.5)
        XCTAssertNil(BenchmarkMetrics.realTimeFactor(processingSeconds: 2, audioSeconds: 0))
        XCTAssertNil(BenchmarkMetrics.realTimeFactor(processingSeconds: -1, audioSeconds: 4))
    }

    func testTimeToFirstTokenNeverNegative() {
        let start = Date()
        let earlier = start.addingTimeInterval(-3)
        XCTAssertEqual(BenchmarkMetrics.timeToFirstTokenSeconds(start: start, first: earlier), 0)
        XCTAssertEqual(
            BenchmarkMetrics.timeToFirstTokenSeconds(start: start, first: start.addingTimeInterval(0.25)),
            0.25,
            accuracy: 1e-6
        )
    }

    func testTokensPerSecond() {
        XCTAssertEqual(BenchmarkMetrics.tokensPerSecond(tokens: 120, seconds: 4), 30)
        XCTAssertNil(BenchmarkMetrics.tokensPerSecond(tokens: 120, seconds: 0))
    }

    // MARK: - 分布与稳定性

    func testPercentileUsesLinearInterpolation() throws {
        let values = [1.0, 2.0, 3.0, 4.0]
        XCTAssertEqual(try XCTUnwrap(BenchmarkMetrics.percentile(values, fraction: 0.5)), 2.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(BenchmarkMetrics.percentile(values, fraction: 0)), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(BenchmarkMetrics.percentile(values, fraction: 1)), 4.0, accuracy: 1e-9)
        XCTAssertNil(BenchmarkMetrics.percentile([], fraction: 0.5))
    }

    func testLatencySummary() throws {
        let values = [0.2, 0.4, 0.6, 0.8, 10.0]
        let summary = try XCTUnwrap(BenchmarkMetrics.latencySummary(values))
        XCTAssertEqual(summary.count, 5)
        XCTAssertEqual(summary.min, 0.2)
        XCTAssertEqual(summary.max, 10.0)
        XCTAssertEqual(summary.p50, 0.6, accuracy: 1e-9)
        // p95 应当暴露长尾，而不是被均值抹平。
        XCTAssertGreaterThan(summary.p95, 5)
        XCTAssertNil(BenchmarkMetrics.latencySummary([]))
    }

    func testScoreConsistency() throws {
        let stable = try XCTUnwrap(BenchmarkMetrics.scoreConsistency([80, 81, 79, 80]))
        XCTAssertEqual(stable.mean, 80, accuracy: 1e-9)
        XCTAssertTrue(stable.isStable(within: 2))
        XCTAssertFalse(stable.isStable(within: 0.5))

        let jittery = try XCTUnwrap(BenchmarkMetrics.scoreConsistency([60, 95, 72]))
        XCTAssertGreaterThan(jittery.maxDeviation, 10)

        let single = try XCTUnwrap(BenchmarkMetrics.scoreConsistency([88]))
        XCTAssertEqual(single.standardDeviation, 0)
        XCTAssertNil(BenchmarkMetrics.scoreConsistency([]))
    }
}
