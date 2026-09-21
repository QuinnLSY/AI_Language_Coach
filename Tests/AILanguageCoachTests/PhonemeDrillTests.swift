import XCTest

@testable import AIDomain

/// 第 ③ 条进阶：顽固音素聚合 + 最小对立对专项。
///
/// 全部脱机：报告由测试自己拼，不碰麦克风 / 模型 / 数据库。
final class PhonemeDrillTests: XCTestCase {

    // MARK: - 工具

    /// 造一个只含音素明细的报告（别的字段与本模块无关，一律取空）。
    private func report(
        _ words: [PhonemeWordAssessment],
        source: PhonemeSource = .inference
    ) -> PronunciationReport {
        PronunciationReport(
            referenceText: words.map(\.word).joined(separator: " "),
            recognizedText: words.map(\.word).joined(separator: " "),
            overall: 60,
            verdict: .needsWork,
            lines: [],
            metrics: SpeechMetrics(),
            weakest: nil,
            tips: [],
            phonemeWords: words,
            phonemeSource: source
        )
    }

    /// 造一个词：逐音素给分。
    private func word(
        _ text: String,
        scores: [String: Double],
        status: PhonemeWordAssessment.Status = .aligned
    ) -> PhonemeWordAssessment {
        let ratings = scores.map { PhonemeRating(phoneme: $0.key, score: $0.value) }
        let average = ratings.isEmpty ? 0 : ratings.map(\.score).reduce(0, +) / Double(ratings.count)
        return PhonemeWordAssessment(word: text, phonemes: ratings, score: average, status: status)
    }

    // MARK: - 聚合

    func testWeaknessNeedsEnoughEvidence() {
        // TH 只被评过 2 次（< minSamples 3），哪怕两次全错也不下结论：
        // 那可能只是那一次没录清楚。
        let reports = [
            report([word("think", scores: ["TH1": 0.1, "IH1": 0.9])]),
            report([word("think", scores: ["TH1": 0.1, "IH1": 0.9])]),
        ]
        XCTAssertTrue(
            PhonemeWeaknessAnalyzer.weaknesses(from: reports).isEmpty,
            "样本不足时不能给人扣「顽固」的帽子"
        )
    }

    func testOneMissIsNotStubborn() {
        // 评过 4 次只错 1 次：那是失手，不是顽固。
        let reports = [
            report([word("think", scores: ["TH1": 0.1])]),
            report([word("thank", scores: ["TH1": 0.9])]),
            report([word("thought", scores: ["TH1": 0.9])]),
            report([word("three", scores: ["TH1": 0.9])]),
        ]
        XCTAssertTrue(
            PhonemeWeaknessAnalyzer.weaknesses(from: reports).isEmpty,
            "只错一次不算顽固（minMisses 门槛）"
        )
    }

    /// 排序口径是「错得多」优先，不是「分得低」优先。
    ///
    /// ⚠️ 数据必须能**区分这两种口径**，否则这条用例在两种实现下都绿（等于没测）：
    /// 刻意让 S 的**均分更低、但错得更少** —— TH 错 3 次 / 均分 0.31，
    /// S 错 2 次 / 均分 0.30。按均分排的话 S 会跑到前面去。
    func testRepeatedMissesBecomeTheTopWeakness() {
        let reports = [
            report([word("think", scores: ["TH1": 0.1, "IH1": 0.9])]),
            report([word("thank", scores: ["TH1": 0.1, "S1": 0.0])]),
            report([word("three", scores: ["TH1": 0.1, "IH1": 0.8])]),
            report([word("sink", scores: ["S1": 0.0, "IH1": 0.9])]),
            report([word("thought", scores: ["TH1": 0.95, "S1": 0.9])]),
        ]
        let result = PhonemeWeaknessAnalyzer.weaknesses(from: reports)
        XCTAssertEqual(result.first?.phoneme, "TH", "错得多的那个该排最前")
        XCTAssertEqual(result.first?.missCount, 3)
        // 重音数字要被抹掉：TH1 与 TH0 算同一个音。
        XCTAssertEqual(result.first?.sampleCount, 4, "TH1 / TH2 都归一到 TH")
        XCTAssertEqual(result.first?.display, "θ")
        XCTAssertEqual(result.map(\.phoneme), ["TH", "S"], "S 也够格，IH 没错过不该进名单")
        // 前提自证：S 的均分确实更低 —— 否则这条用例区分不出两种排序口径。
        XCTAssertLessThan(
            result.last?.averageScore ?? 1, result.first?.averageScore ?? 0,
            "用例自身的前提：S 均分更低，靠错次才被压到第二"
        )
    }

    func testEquallyFrequentMissesRankByScore() {
        // 两个音各错 2 次：平均分低的那个更该先练。
        let reports = [
            report([word("a", scores: ["TH1": 0.3, "S1": 0.45])]),
            report([word("b", scores: ["TH1": 0.3, "S1": 0.0])]),
            report([word("c", scores: ["TH1": 0.9, "S1": 0.9])]),
        ]
        let result = PhonemeWeaknessAnalyzer.weaknesses(from: reports)
        XCTAssertEqual(result.map(\.phoneme), ["S", "TH"], "同错次时按平均分升序")
    }

    func testMissingWordsAreNotBlamedAsPhonemeErrors() {
        // 漏读（missing）是「没读出来」，不是「这个音没发对」。
        // 算进来会把「没开口」诬陷成「发音差」—— 那会让名单整个失真。
        let reports = [
            report([word("think", scores: ["TH1": 0.1], status: .missing)]),
            report([word("think", scores: ["TH1": 0.1], status: .missing)]),
            report([word("think", scores: ["TH1": 0.1], status: .missing)]),
        ]
        XCTAssertTrue(
            PhonemeWeaknessAnalyzer.weaknesses(from: reports).isEmpty,
            "漏读的词不进音素统计"
        )
    }

    func testEstimatedReportsCanBeExcluded() {
        let reports = [
            report([word("a", scores: ["TH1": 0.1])]),
            report([word("b", scores: ["TH1": 0.1])]),
            report([word("c", scores: ["TH1": 0.1])]),
        ]
        XCTAssertFalse(
            PhonemeWeaknessAnalyzer.weaknesses(from: reports).isEmpty,
            "默认采纳推断音素（多数用户只有这一条通道）"
        )
        XCTAssertTrue(
            PhonemeWeaknessAnalyzer.weaknesses(from: reports, includeEstimated: false).isEmpty,
            "只要实测时，推断报告必须整份排除"
        )
    }

    // MARK: - 词表

    /// 词表的音素标注是人工标的 —— 这里用特征距离把它兜住。
    ///
    /// 判据两条：
    /// ① 左右两个音**不能是同一个**（写反 / 写重了会让这一对根本没在比什么）；
    /// ② 必须是**近音**（distance ≤ 0.35）—— 把 TH 和 NG 标成一对也算「不同音」，
    ///    但那不是最小对立对，练它没意义。
    ///
    /// ⚠️ 已知局限：`PhonemeFeatures` 的表里 R 与 L 同为 place 4 / manner 5，
    ///    两者距离是 **0**（r 念成 l 目前不扣分）。这条测试因此**不**断言
    ///    distance > 0，只断言「不是同一个音」。修特征表是另一件事，别在这里夹带。
    func testCatalogPairsContrastNearButDistinctSounds() {
        for pair in MinimalPairCatalog.pairs {
            XCTAssertNotEqual(
                pair.leftPhoneme, pair.rightPhoneme,
                "\(pair.id) 两边标了同一个音，这一对没有在比任何东西"
            )
            let distance = PhonemeFeatures.distance(pair.leftPhoneme, pair.rightPhoneme)
            XCTAssertLessThanOrEqual(
                distance, 0.35,
                "\(pair.id) 比的两个音差太远（\(distance)），不是最小对立对"
            )
            XCTAssertFalse(
                pair.contrastDisplay.isEmpty, "\(pair.id) 应当有可展示的对比说明"
            )
        }
    }

    func testCatalogCoversTheUsualChineseSpeakerTraps() {
        // 中文母语者最典型的几处，词表里都得有得练。
        for phoneme in ["TH", "R", "L", "V", "W", "N", "NG", "IY", "IH"] {
            XCTAssertFalse(
                MinimalPairCatalog.pairs(for: phoneme).isEmpty,
                "\(phoneme) 没有对应的最小对立对"
            )
        }
    }

    // MARK: - 出题

    func testDrillsCoverBothSidesOfTheContrast() {
        let weakness = PhonemeWeakness(phoneme: "TH", missCount: 4, sampleCount: 6, averageScore: 0.2)
        let drills = MinimalPairDrill.drills(for: weakness)
        XCTAssertEqual(drills.count, 4, "2 个词对 × 两边各一句")
        XCTAssertEqual(drills.map(\.text), ["Think", "Sink", "Three", "Tree"])

        // 两边都得说清「留意哪个音」—— 只给词不说重点，学员不知道在练什么。
        XCTAssertTrue(drills[0].focus.contains("θ"))
        XCTAssertTrue(drills[1].focus.contains("s"))
        XCTAssertTrue(drills[0].topic.contains("θ"), "标题要写明这一对在比什么")
        XCTAssertFalse(drills[0].translation.isEmpty, "给中文释义，否则只是鹦鹉学舌")
    }

    func testUnknownPhonemeYieldsNoDrills() {
        let weakness = PhonemeWeakness(phoneme: "HH", missCount: 9, sampleCount: 9, averageScore: 0.1)
        XCTAssertTrue(
            MinimalPairDrill.drills(for: weakness).isEmpty,
            "没有词对的音素不硬凑练习 —— 凑出来的就不是最小对立对了"
        )
    }
}
