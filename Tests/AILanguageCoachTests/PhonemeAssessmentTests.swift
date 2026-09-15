@testable import AIDomain
import AIInfrastructure
import XCTest

/// 音素级发音评测（推断通道）的回归测试。
///
/// 这条通道的价值只有一个：**能指出哪个音不对**。所以测试全部围绕
/// 「说对了要满分、说错了要落到对应的音上」，而不是围绕实现细节。
final class PhonemeAssessmentTests: XCTestCase {

    /// 固定词库：不依赖随包资源，测试在任何环境下结果一致。
    private let lexicon = PhonemeLexicon(words: [
        "world": ["W", "ER1", "L", "D"],
        "word": ["W", "ER1", "D"],
        "would": ["W", "UH1", "D"],
        "like": ["L", "AY1", "K"],
        "to": ["T", "UW1"],
        "make": ["M", "EY1", "K"],
        "a": ["AH0"],
        "reservation": ["R", "EH2", "Z", "ER0", "V", "EY1", "SH", "AH0", "N"],
        "i": ["AY1"],
        "think": ["TH", "IH1", "NG", "K"],
        "sink": ["S", "IH1", "NG", "K"],
        "very": ["V", "EH1", "R", "IY0"],
        "well": ["W", "EH1", "L"],
    ])

    // MARK: - 说对了

    func testFullyCorrectSentenceScoresPerfectly() throws {
        let sentence = "I would like to make a reservation"
        let words = PhonemeAssessment.assess(
            reference: sentence, recognized: sentence, lexicon: lexicon
        )

        XCTAssertEqual(words.count, 7, "七个词应各出一条音素条")
        XCTAssertTrue(words.allSatisfy { $0.status == .aligned }, "逐词都应配上对")
        let average = try XCTUnwrap(PhonemeAssessment.averageScore(words))
        XCTAssertEqual(average, 1.0, accuracy: 0.001, "同一句话读对，音素分应是满分")
        XCTAssertTrue(
            words.allSatisfy { $0.phonemes.allSatisfy { $0.score == 1 } },
            "每个音素都应是满分"
        )
    }

    // MARK: - 说错了：错音要落到具体那个音上

    func testWrongWordFlagsTheMissingPhoneme() throws {
        // world → word：差别只在中间的 /l/；评测必须指向 /l/，而不是整词判死。
        let words = PhonemeAssessment.assess(
            reference: "world", recognized: "word", lexicon: lexicon
        )
        let word = try XCTUnwrap(words.first)
        XCTAssertEqual(word.status, .aligned)
        XCTAssertEqual(word.phonemes.count, 4, "world 四个音都要有交代")

        let byPhoneme = Dictionary(
            uniqueKeysWithValues: word.phonemes.map { (PhonemeFeatures.base($0.phoneme), $0.score) }
        )
        XCTAssertEqual(try XCTUnwrap(byPhoneme["W"]), 1.0, accuracy: 0.001, "/w/ 读对了")
        XCTAssertEqual(try XCTUnwrap(byPhoneme["ER"]), 1.0, accuracy: 0.001, "/ɝ/ 读对了")
        XCTAssertEqual(try XCTUnwrap(byPhoneme["D"]), 1.0, accuracy: 0.001, "/d/ 读对了")
        XCTAssertLessThan(try XCTUnwrap(byPhoneme["L"]), 0.5, "/l/ 被吞掉，应明显偏低")
    }

    func testNearMissPhonemeScoresBetweenPerfectAndDead() throws {
        // think → sink：只差一个发音部位（齿间擦音 → 齿龈擦音），应落在「偏差」档而不是全错。
        let words = PhonemeAssessment.assess(
            reference: "think", recognized: "sink", lexicon: lexicon
        )
        let word = try XCTUnwrap(words.first)
        let theta = try XCTUnwrap(word.phonemes.first { PhonemeFeatures.base($0.phoneme) == "TH" })
        XCTAssertGreaterThan(theta.score, 0.5, "只差发音部位，不该判成完全没念")
        XCTAssertLessThan(theta.score, 0.85, "也不该当成念对了")
        XCTAssertEqual(PhonemeMark.from(score: theta.score), .fair, "应落在 △ 档")
    }

    // MARK: - 漏词与多词

    func testMissingWordIsReportedAndScoresZero() throws {
        let words = PhonemeAssessment.assess(
            reference: "very well", recognized: "very", lexicon: lexicon
        )
        XCTAssertEqual(words.count, 2)
        let missing = try XCTUnwrap(words.first { $0.word == "well" })
        XCTAssertEqual(missing.status, .missing)
        XCTAssertEqual(missing.score, 0)
        XCTAssertEqual(missing.phonemes.map(\.score), [0, 0, 0], "漏读的词每个音素都该是 0")
    }

    func testExtraWordIsReportedWithoutPhonemes() throws {
        let words = PhonemeAssessment.assess(
            reference: "very well", recognized: "very well and", lexicon: lexicon
        )
        let extra = try XCTUnwrap(words.first { $0.status == .extra })
        XCTAssertEqual(extra.word, "and")
        XCTAssertTrue(extra.phonemes.isEmpty, "多说的词不产生音素条，也不该拉低音准平均分")

        let average = try XCTUnwrap(PhonemeAssessment.averageScore(words))
        XCTAssertEqual(average, 1.0, accuracy: 0.001, "多说一个参考句里没有的词，不该扣音准分")
    }

    func testSilenceMarksEveryWordAsMissing() throws {
        let words = PhonemeAssessment.assess(
            reference: "I would like", recognized: "", lexicon: lexicon
        )
        XCTAssertEqual(words.count, 3)
        XCTAssertTrue(words.allSatisfy { $0.status == .missing })
        XCTAssertEqual(try XCTUnwrap(PhonemeAssessment.averageScore(words)), 0)
    }

    func testEmptyReferenceProducesNothing() {
        XCTAssertTrue(
            PhonemeAssessment.assess(reference: "   ", recognized: "hello", lexicon: lexicon).isEmpty,
            "没有可跟读的内容就不该编出结论"
        )
    }

    // MARK: - 词库缺失时的兜底

    func testUnknownWordFallsBackToRulesInsteadOfFailing() throws {
        let words = PhonemeAssessment.assess(
            reference: "xylophone", recognized: "xylophone", lexicon: .empty
        )
        let word = try XCTUnwrap(words.first)
        XCTAssertFalse(word.phonemes.isEmpty, "词库没有不该导致评测空转，规则 G2P 要顶上")
        XCTAssertEqual(word.score, 1.0, accuracy: 0.001, "同一个词自己跟自己比，规则结果一致即满分")
    }

    func testLexiconLookupNormalizesPunctuationAndPossessive() {
        XCTAssertEqual(lexicon.phonemes(for: "World,"), ["W", "ER1", "L", "D"])
        XCTAssertEqual(lexicon.phonemes(for: "WORLD"), ["W", "ER1", "L", "D"])
        XCTAssertEqual(lexicon.phonemes(for: "would's"), ["W", "UH1", "D", "Z"])
        XCTAssertNil(lexicon.phonemes(for: "zzz"))
    }

    // MARK: - 报告层：音准维度与音素条必须同源

    func testReportCarriesPhonemeWordsAndHonestSource() throws {
        let words = PhonemeAssessment.assess(
            reference: "world", recognized: "word", lexicon: lexicon
        )
        let report = PronunciationScorer.report(
            reference: "world", recognized: "word",
            metrics: .empty, phonemeWords: words, phonemeSource: .inference
        )

        XCTAssertEqual(report.phonemeSource, .inference)
        XCTAssertEqual(report.phonemeWords.count, 1)
        XCTAssertTrue(report.hasPhonemeBreakdown)

        let line = try XCTUnwrap(report.line(.phonemeAccuracy))
        XCTAssertTrue(line.isEstimated, "规则推断必须自报家门，否则用户会当成录音实测")
        XCTAssertTrue(line.detail.contains("规则推断"), "明细里也要写明来源：\(line.detail)")

        // 音准维度的分数必须是音素条的加权结果（同源，不是各算各的）。
        let average = try XCTUnwrap(PhonemeAssessment.averageScore(words)) * 100
        XCTAssertEqual(line.score, average, accuracy: 0.001)
    }

    func testReportWithoutPhonemesOmitsTheDimension() {
        let report = PronunciationScorer.report(
            reference: "hello", recognized: "hello", metrics: .empty
        )
        XCTAssertNil(report.line(.phonemeAccuracy), "拿不到音素就不显示这一维，不拿别的维度冒充")
        XCTAssertEqual(report.phonemeSource, .none)
        XCTAssertFalse(report.hasPhonemeBreakdown)
    }

    // MARK: - 老记录兼容

    func testReportDecodesLegacyJSONWithoutPhonemeFields() throws {
        // 造一份「旧版本落库的报告」：拿真实报告编码后**摘掉新字段**，
        // 而不是手写 JSON —— 手写的夹具验证不到真实结构，还会因少列字段假失败。
        let fresh = PronunciationScorer.report(
            reference: "hello", recognized: "hello", metrics: .empty
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any]
        )
        object.removeValue(forKey: "phonemeWords")
        object.removeValue(forKey: "phonemeSource")

        let data = try JSONSerialization.data(withJSONObject: object)
        let report = try JSONDecoder().decode(PronunciationReport.self, from: data)
        XCTAssertTrue(report.phonemeWords.isEmpty, "旧记录没有音素字段，应降级为「无音素」而不是解码失败")
        XCTAssertEqual(report.phonemeSource, .none)
        XCTAssertEqual(report.recognizedText, "hello")
    }

    // MARK: - 随包词库

    func testBundledLexiconIsUsableAndCoversMaterials() {
        let bundled = PhonemeLexiconStore.shared()
        XCTAssertGreaterThan(bundled.count, 1000, "随包词库应覆盖素材里的常用词")
        XCTAssertEqual(bundled.phonemes(for: "world"), ["W", "ER1", "L", "D"])
        XCTAssertEqual(bundled.phonemes(for: "reservation")?.isEmpty, false)
        XCTAssertEqual(bundled.phonemes(for: "pronunciation")?.isEmpty, false)
    }
}
