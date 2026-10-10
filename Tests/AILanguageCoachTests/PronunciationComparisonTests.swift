import AIDomain
import XCTest

/// 发音跨次对比（④ 的纵向那一半）。
///
/// 钉住三件最容易做歪的事：
/// ① 样本不够**不下结论**（两三次的差是噪声）；② 比的是**前后两段的均值**，不是首尾两次；
/// ③ 韵律只在**量到过**的时候才出现（没数据的一行写「0%」等于谎报）。
final class PronunciationComparisonTests: XCTestCase {

    private func sample(_ overall: Double, stressed: Double? = nil, linked: Double? = nil, varied: Double? = nil) -> PronunciationSample {
        PronunciationSample(overall: overall, stressedRatio: stressed, linkedRatio: linked, variedContour: varied)
    }

    // MARK: - 样本不够就不比

    func testTooFewSamplesYieldsNothing() {
        XCTAssertNil(PronunciationComparisonRule.compare([]))
        XCTAssertNil(PronunciationComparisonRule.compare([
            sample(70), sample(75), sample(80),
        ]), "三次开口的差几乎必然是噪声 —— 拿它当『进步了』是拿噪声当结论")
        XCTAssertNotNil(PronunciationComparisonRule.compare([
            sample(70), sample(75), sample(80), sample(85),
        ]))
    }

    // MARK: - 比的是两段的均值

    /// 中间夹一次特别好的，结论不该被它翻过去（首尾比会翻）。
    func testUsesHalvesNotEndpoints() {
        let comparison = PronunciationComparisonRule.compare([
            sample(70), sample(70), sample(70), sample(100),
        ])
        // 前段均值 70、后段均值 85 —— 确实涨了，但**不是**首尾差的 30 分。
        let overall = try? XCTUnwrap(comparison?.rows.first)
        XCTAssertEqual(overall?.before, 70)
        XCTAssertEqual(overall?.after, 85)
    }

    /// 传倒序的话前后两段互换，结论正好反过来 —— 这是调用点最容易犯的错，钉死它。
    func testReversedInputFlipsTheVerdict() {
        let rising = [sample(60), sample(65), sample(90), sample(95)]
        let forward = PronunciationComparisonRule.compare(rising)
        let backward = PronunciationComparisonRule.compare(rising.reversed())
        XCTAssertTrue(forward?.rows.first?.isBetter == true)
        XCTAssertTrue(backward?.rows.first?.isWorse == true,
                      "倒序会让『进步』说成『退步』—— 调用点必须自己反序")
    }

    /// 前后两段一样 → 持平，不许标成变好或变差。
    func testFlatSeriesIsNeitherBetterNorWorse() {
        let comparison = PronunciationComparisonRule.compare([
            sample(80), sample(80), sample(80), sample(80),
        ])
        let overall = try? XCTUnwrap(comparison?.rows.first)
        XCTAssertEqual(overall?.deltaText, "没变")
        XCTAssertFalse(overall?.isBetter ?? true)
        XCTAssertFalse(overall?.isWorse ?? true)
    }

    /// 1 分以内的抖动不标色（说明不了任何事）。
    func testTinyChangesAreTreatedAsNoise() {
        let comparison = PronunciationComparisonRule.compare([
            sample(80), sample(80), sample(80.5), sample(80.5),
        ])
        XCTAssertEqual(comparison?.rows.first?.deltaText, "没变")
    }

    // MARK: - 韵律只在量到时比

    func testProsodyRowsAppearOnlyWhenMeasured() {
        let withProsody = PronunciationComparisonRule.compare([
            sample(70, stressed: 0.2, linked: 0.3, varied: 0),
            sample(72, stressed: 0.3, linked: 0.4, varied: 1),
            sample(80, stressed: 0.5, linked: 0.6, varied: 1),
            sample(82, stressed: 0.6, linked: 0.7, varied: 1),
        ])
        XCTAssertEqual(withProsody?.rows.count, 4, "总分 + 重音 + 连读 + 语调")
        XCTAssertEqual(withProsody?.rows.map(\.title), ["总分", "重音层次", "连读", "语调起伏"])

        // 一次都没量到韵律（④ 之前落的库）：只留下总分那一行。
        let legacy = PronunciationComparisonRule.compare([
            sample(70), sample(72), sample(80), sample(82),
        ])
        XCTAssertEqual(legacy?.rows.count, 1, "没量到的维度不许出现 —— 写『0%』是谎报")
    }

    /// 只有一段量到了韵律 → 那一行也不出现（拿一段和另一段比没有意义）。
    func testProsodyRowNeedsBothHalves() {
        let comparison = PronunciationComparisonRule.compare([
            sample(70, stressed: 0.2),
            sample(72, stressed: 0.3),
            sample(80),
            sample(82),
        ])
        XCTAssertEqual(comparison?.rows.count, 1)
    }

    /// 只算量到过的那几次：混着老记录时，分母不许把没量到的次算进去。
    func testMeansOnlyCountMeasuredSamples() {
        let comparison = PronunciationComparisonRule.compare([
            sample(70, stressed: 0.0),
            sample(72),
            sample(80, stressed: 1.0),
            sample(82),
        ])
        // 前段只有第 1 次量到（0%），后段只有第 3 次量到（100%）—— 两段都有，行才出现。
        let stressed = comparison?.rows.first { $0.title == "重音层次" }
        XCTAssertEqual(stressed?.before, 0)
        XCTAssertEqual(stressed?.after, 1)
        XCTAssertEqual(stressed?.afterText, "100%")
    }

    // MARK: - 文案

    func testHeadlineCarriesBothCountsAndTheScoreMove() {
        let comparison = PronunciationComparisonRule.compare([
            sample(70), sample(70), sample(85), sample(85),
        ])
        let headline = try? XCTUnwrap(comparison?.headline)
        XCTAssertEqual(headline, "最近 2 次 vs 之前 2 次：总分 70 → 85（+15 分）")
        XCTAssertEqual(comparison?.sampleCount, 4)
        XCTAssertEqual(comparison?.recentCount, 2)
    }

    /// 「首尾两次」与「前后两半均值」在这组数据上会给出**相反的结论**：
    /// 首尾都是 80（看着没变），但后两次是 100 和 90（均值 95，明显在进步）。
    /// 这条判据能分辨两种实现 —— 只钉「样本数 / 文案」的用例在两种实现下结果完全一样，是假闸。
    func testAnOutlierInTheMiddleCannotFlipTheConclusion() {
        let comparison = PronunciationComparisonRule.compare([
            sample(80), sample(80), sample(100), sample(90),
        ])
        let overall = comparison?.rows.first
        // 首尾：80 → 80（持平）；两半均值：80 → 95（进步）
        XCTAssertEqual(overall?.delta, 15, "后两次均值应是 95，不是最后一次的 90 也不是首尾持平")
        XCTAssertEqual(overall?.beforeText, "80")
        XCTAssertEqual(overall?.afterText, "95")
    }

    func testHeadlineSaysFlatWhenNothingMoved() {
        let comparison = PronunciationComparisonRule.compare([
            sample(80), sample(80), sample(80), sample(80),
        ])
        XCTAssertTrue(comparison?.headline?.contains("基本持平") == true)
    }

    /// 百分比行的变化量按百分点算（0.2 → 0.5 是 +30，不是 +0.3），
    /// **而且必须写出单位** —— `0% → 100%` 旁边光写 `+100` 会被读成「翻了一倍」。
    func testPercentDeltaIsInPointsAndCarriesItsUnit() {
        let comparison = PronunciationComparisonRule.compare([
            sample(70, stressed: 0.2),
            sample(70, stressed: 0.2),
            sample(80, stressed: 0.5),
            sample(80, stressed: 0.5),
        ])
        let stressed = comparison?.rows.first { $0.title == "重音层次" }
        XCTAssertEqual(stressed?.deltaText, "+30 个百分点")
        XCTAssertEqual(stressed?.beforeText, "20%")
        XCTAssertEqual(stressed?.afterText, "50%")

        // 总分行是「分」，不带「个百分点」—— 别让同一个属性对两种单位说同一句话。
        XCTAssertEqual(comparison?.rows.first?.deltaText, "+10")
    }
}
