import AIDomain
@testable import AIDomain
import Foundation
import XCTest

/// ④ 韵律 / 连读 / 词级重音：领域层纯函数。
///
/// 最要紧的一条是 `WordTimelineTrust`：词级分析的**全部质量**都押在词时间戳是不是真对齐上，
/// 而 `ASRWord` 的注释明说 runtime 可能只给「按字符均摊」的估计值。
/// 拿均摊值当真对齐会给出**错的结论**（把重音位置指错），所以宁可退化。
final class ProsodyAnalysisTests: XCTestCase {

    // MARK: - 夹具

    /// 真对齐的样本：时长长短不一（`duration / 字符数` 离散度大）。
    private func realSamples() -> [ProsodyWordSample] {
        [
            ProsodyWordSample(word: "I", start: 0.00, end: 0.09, energy: 0.30, pitch: 210),
            ProsodyWordSample(word: "want", start: 0.12, end: 0.38, energy: 0.52, pitch: 205),
            ProsodyWordSample(word: "to", start: 0.40, end: 0.50, energy: 0.28, pitch: 198),
            ProsodyWordSample(word: "order", start: 0.52, end: 1.08, energy: 0.86, pitch: 232),
            ProsodyWordSample(word: "a", start: 1.10, end: 1.16, energy: 0.26, pitch: nil),
            ProsodyWordSample(word: "latte", start: 1.18, end: 1.55, energy: 0.55, pitch: 168),
        ]
    }

    /// 均摊估计：时长**严格正比于字符数**（这才是「按字符摊」的形态）。
    ///
    /// ⚠️ 第一版把每个词都写成 0.2 秒 —— 那样时长与字符数**无关**，
    /// 判据立刻正确地判成 `trusted`（离散度很大）。可见这条判据认的是
    /// 「比值是否恒定」，不是「时长是否一样」。
    private func estimatedSamples() -> [ProsodyWordSample] {
        let words = ["I", "want", "to", "order", "a", "latte"]
        let perCharacter = 1.2 / Double(words.reduce(0) { $0 + $1.count })
        var cursor = 0.0
        return words.map { word in
            let duration = perCharacter * Double(word.count)
            defer { cursor += duration }
            return ProsodyWordSample(
                word: word, start: cursor, end: cursor + duration,
                energy: 0.4, pitch: 200
            )
        }
    }

    // MARK: - 词时间戳可信度

    func testRealAlignmentIsTrusted() {
        XCTAssertEqual(WordTimelineTrust.assess(realSamples()), .trusted)
        XCTAssertTrue(WordTimelineTrust.canAnalyze(realSamples()))
    }

    /// 反证：把真对齐的数据换成「按字符均摊」→ 必须判定为不可信。
    func testCharacterAveragedEstimateIsRejected() {
        XCTAssertEqual(WordTimelineTrust.assess(estimatedSamples()), .estimated)
        XCTAssertFalse(WordTimelineTrust.canAnalyze(estimatedSamples()),
                       "拿均摊值当真对齐会把重音位置指错 —— 必须退化")
    }

    func testUnusableDataIsRejected() {
        XCTAssertEqual(WordTimelineTrust.assess([]), .unusable)
        XCTAssertEqual(WordTimelineTrust.assess([realSamples()[0]]), .unusable, "一个词看不出规律")
        XCTAssertEqual(WordTimelineTrust.assess([
            ProsodyWordSample(word: "a", start: 1.0, end: 1.2),
            ProsodyWordSample(word: "b", start: 0.0, end: 0.2)
        ]), .unusable, "时间逆序")
        XCTAssertEqual(WordTimelineTrust.assess([
            ProsodyWordSample(word: "a", start: 0.2, end: 0.2),
            ProsodyWordSample(word: "b", start: 0.3, end: 0.5)
        ]), .unusable, "时长为 0")
        XCTAssertEqual(WordTimelineTrust.assess([
            ProsodyWordSample(word: "a", start: 0, end: .nan),
            ProsodyWordSample(word: "b", start: 0.3, end: 0.5)
        ]), .unusable, "非有限数")
    }

    // MARK: - 词级重音

    func testStressedWordIsTheLoudestOne() throws {
        let marks = WordStressAnalyzer.analyze(realSamples())
        XCTAssertEqual(marks.count, realSamples().count)
        XCTAssertEqual(try XCTUnwrap(marks.first { $0.word == "order" }).level, .stressed,
                       "order 明显最响，该判重读")
        XCTAssertEqual(try XCTUnwrap(marks.first { $0.word == "to" }).level, .reduced,
                       "to 很轻，该判弱读（每个词一样重是最常见的语调问题）")
        XCTAssertEqual(try XCTUnwrap(marks.first { $0.word == "want" }).level, .normal)
    }

    /// 用中位数而不是平均：一个特别响的词不该把其余全压成弱读。
    func testMedianBeatsMeanForOutliers() {
        let samples = (1...5).map { index in
            ProsodyWordSample(
                word: "w\(index)",
                start: Double(index) * 0.1,
                end: Double(index) * 0.1 + 0.4,
                energy: index == 5 ? 3.0 : 0.30
            )
        }
        let marks = WordStressAnalyzer.analyze(samples)
        XCTAssertEqual(marks.filter { $0.level == .stressed }.map(\.word), ["w5"])
        XCTAssertEqual(marks.filter { $0.level == .reduced }.count, 0,
                       "其余四个词一样响，不该被判成弱读（用平均的话它们全会被判弱读）")
    }

    func testStressAnalysisRefusesOnTooFewWordsOrSilence() {
        XCTAssertTrue(WordStressAnalyzer.analyze(Array(realSamples().prefix(2))).isEmpty,
                      "两个词没有「重读分布」可言")
        XCTAssertEqual(WordStressAnalyzer.analyze(realSamples()), WordStressAnalyzer.analyze(realSamples()),
                       "纯函数：同样输入必须同样输出")
        let silent = realSamples().map {
            ProsodyWordSample(word: $0.word, start: $0.start, end: $0.end, energy: 0, pitch: $0.pitch)
        }
        XCTAssertTrue(WordStressAnalyzer.analyze(silent).isEmpty,
                      "全静音说明没采到能量 → 不产出标记，而不是判成「全是弱读」")
    }

    // MARK: - 韵律轮廓

    func testFallingContourIsDetected() throws {
        let contour = try XCTUnwrap(IntonationAnalyzer.contour(realSamples()))
        XCTAssertEqual(contour.shape, .falling, "latre 末尾降到 168Hz，整句是降调")
        XCTAssertLessThan(contour.slope, 0)
        XCTAssertEqual(contour.points.count, 5, "清音词 a 没有基频，不进轮廓")
    }

    func testRisingContourIsDetected() throws {
        let rising = [
            ProsodyWordSample(word: "so", start: 0, end: 0.2, energy: 0.4, pitch: 150),
            ProsodyWordSample(word: "really", start: 0.2, end: 0.6, energy: 0.4, pitch: 190),
            ProsodyWordSample(word: "sure", start: 0.6, end: 0.9, energy: 0.4, pitch: 245)
        ]
        let contour = try XCTUnwrap(IntonationAnalyzer.contour(rising))
        XCTAssertEqual(contour.shape, .rising)
        XCTAssertGreaterThan(contour.slope, 0)
    }

    func testMonotoneReadingIsFlaggedAsFlat() throws {
        let flat = (1...4).map { index in
            ProsodyWordSample(
                word: "w\(index)", start: Double(index) * 0.1, end: Double(index) * 0.1 + 0.3,
                energy: 0.4, pitch: 200 + Double(index % 2)
            )
        }
        let contour = try XCTUnwrap(IntonationAnalyzer.contour(flat))
        XCTAssertEqual(contour.shape, .flat, "音高几乎不动 = 念稿")
    }

    /// 够不上条件时**返回 nil**，不能给一个假结论。
    func testContourRefusesWithoutEnoughVoicedWords() {
        XCTAssertNil(IntonationAnalyzer.contour(Array(realSamples().prefix(2))))
        let mostlyVoiceless = [
            ProsodyWordSample(word: "a", start: 0, end: 0.1, energy: 0.3, pitch: nil),
            ProsodyWordSample(word: "the", start: 0.1, end: 0.3, energy: 0.3, pitch: nil),
            ProsodyWordSample(word: "cat", start: 0.3, end: 0.6, energy: 0.4, pitch: 210)
        ]
        XCTAssertNil(IntonationAnalyzer.contour(mostlyVoiceless), "只有一个浊音点谈不上走向")
        XCTAssertNil(IntonationAnalyzer.contour([
            ProsodyWordSample(word: "a", start: 0, end: 0.1, energy: 0.3, pitch: 0),
            ProsodyWordSample(word: "b", start: 0.1, end: 0.3, energy: 0.3, pitch: -1)
        ]), "非法基频（0 / 负）不采信")
    }

    // MARK: - 连读启发式

    func testLinkingPairIsDetectedFromTextAlone() {
        XCTAssertTrue(LinkingHeuristic.isLinkingPair("pick", "it"), "辅音结尾 + 元音开头")
        XCTAssertTrue(LinkingHeuristic.isLinkingPair("an", "apple"))
        XCTAssertFalse(LinkingHeuristic.isLinkingPair("cat", "sat"), "辅音 + 辅音不成连读")
        XCTAssertFalse(LinkingHeuristic.isLinkingPair("the", "book"), "元音 + 辅音不成连读")
        XCTAssertFalse(LinkingHeuristic.isLinkingPair("pick", "you"), "y 读 /j/ 辅音，不是元音")
        XCTAssertFalse(LinkingHeuristic.isLinkingPair("", "it"), "空词不许判")
    }

    func testPunctuationDoesNotBreakTheCheck() {
        XCTAssertTrue(LinkingHeuristic.endsWithConsonant("pick."))
        XCTAssertTrue(LinkingHeuristic.startsWithVowel("\"apple\""))
        XCTAssertFalse(LinkingHeuristic.startsWithVowel("42"))
    }

    func testSpansReportWhetherTheLearnerActuallyLinked() throws {
        // pick it up：pick→it 该连，it→up 也该连。
        let linked = [
            ProsodyWordSample(word: "pick", start: 0.00, end: 0.30, energy: 0.5),
            ProsodyWordSample(word: "it", start: 0.30, end: 0.36, energy: 0.4),
            ProsodyWordSample(word: "up", start: 0.36, end: 0.60, energy: 0.5)
        ]
        let spans = LinkingHeuristic.spans(linked)
        XCTAssertEqual(spans.count, 2)
        XCTAssertTrue(spans.allSatisfy(\.didLink), "间隙 < 60ms → 读连上了")
        XCTAssertEqual(LinkingHeuristic.linkedCount(spans), 2)

        // 同样的词，但两处都断了 0.3 秒。
        let broken = [
            ProsodyWordSample(word: "pick", start: 0.00, end: 0.30, energy: 0.5),
            ProsodyWordSample(word: "it", start: 0.60, end: 0.70, energy: 0.4),
            ProsodyWordSample(word: "up", start: 1.00, end: 1.30, energy: 0.5)
        ]
        XCTAssertEqual(LinkingHeuristic.linkedCount(LinkingHeuristic.spans(broken)), 0)
    }

    func testNoCandidateMeansNoCount() {
        XCTAssertNil(LinkingHeuristic.linkedCount([]), "一个候选都没有 → 别显示「0/0」")
        XCTAssertTrue(LinkingHeuristic.spans([realSamples()[0]]).isEmpty)
    }
}