import AIDomain
import XCTest

/// #230 写作练习与批改：
/// - 题库轮换（同一天同一题、跨天换题、类型轮换）；
/// - 批改解析（键值行 + `||`；缺字段丢弃 —— 漏改不误报）；
/// - 词级 diff 对齐（没改的词不标、删/增分清）。
final class WritingTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    private func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    // MARK: - 题目轮换

    func testSameDaySameTopic() {
        let morning = date(9, 16)
        let evening = calendar.date(byAdding: .hour, value: 8, to: morning)!
        XCTAssertEqual(WritingTopicPicker.topic(for: morning, calendar: calendar), WritingTopicPicker.topic(for: evening, calendar: calendar))
    }

    func testNextDayDifferentTopic() {
        let today = WritingTopicPicker.topic(for: date(9, 16), calendar: calendar)
        let tomorrow = WritingTopicPicker.topic(for: date(9, 17), calendar: calendar)
        XCTAssertNotEqual(today, tomorrow)
        XCTAssertEqual(today.dayKey, WritingTopicPicker.dayKey(for: date(9, 16), calendar: calendar))
        XCTAssertEqual(tomorrow.dayKey, today.dayKey + 1)
    }

    func testTopicKindRotatesAcrossDays() {
        // 连续三天：三种类型都出现（类型按天轮换）。
        let kinds = (0..<3).map { offset -> WritingTopicKind in
            let d = calendar.date(byAdding: .day, value: offset, to: date(9, 16))!
            return WritingTopicPicker.topic(for: d, calendar: calendar).kind
        }
        XCTAssertEqual(Set(kinds).count, 3)
    }

    // MARK: - 批改解析

    private let original = "Yesterday I has go to the park with my friend. It was very fun and we eat ice cream there."

    private let sampleOutput = """
    SCORE: 86
    ADVICE: 注意时态一致性：讲过去的事整句都要用过去式。
    FIX: I has go || I went || has 后面接过去分词，这里直接用过去式 went。
    FIX: we eat ice cream || we ate ice cream || 过去的事用过去式。
    REWRITE: Yesterday I went to the park with my friend. It was very fun and we ate ice cream there.
    WORD: went || v. || go 的过去式
    WORD: ice cream || n. || 冰淇淋
    """

    func testParseFullReview() {
        let review = WritingReviewRule.parse(sampleOutput, original: original)
        XCTAssertEqual(review.score, 86)
        XCTAssertFalse(review.advice.isEmpty)
        XCTAssertEqual(review.fixes.count, 2)
        XCTAssertEqual(review.fixes[0].original, "I has go")
        XCTAssertEqual(review.fixes[0].corrected, "I went")
        XCTAssertFalse(review.fixes[0].note.isEmpty)
        XCTAssertEqual(review.rewrite, "Yesterday I went to the park with my friend. It was very fun and we ate ice cream there.")
        XCTAssertEqual(review.words.count, 2)
        XCTAssertEqual(review.words[0].pos, "v.")
        XCTAssertFalse(review.isEmpty)
    }

    func testLocateOffsetsInOriginal() {
        let review = WritingReviewRule.parse(sampleOutput, original: original)
        // 「I has go」确实在原文里 → 有偏移；偏移处真的以该片段开头。
        for fix in review.fixes {
            let offset = fix.offset
            XCTAssertNotNil(offset, fix.original)
            let start = original.index(original.startIndex, offsetBy: offset!)
            let end = original.index(start, offsetBy: fix.original.count)
            XCTAssertEqual(String(original[start..<end]).lowercased(), fix.original.lowercased())
        }
    }

    func testLocateReturnsNilForMissingSnippet() {
        XCTAssertNil(WritingReviewRule.locate("totally absent phrase", in: original))
        XCTAssertNil(WritingReviewRule.locate("", in: original))
    }

    func testMalformedFixLinesAreDropped() {
        // 缺 `||` / 缺改正 → 整行丢弃（漏改不误报：不猜）。
        let raw = """
        SCORE: 50
        FIX: 只有原文没有改正
        FIX:  ||  || 空的
        FIX: a || b || ok
        """
        let review = WritingReviewRule.parse(raw, original: "a b")
        XCTAssertEqual(review.fixes.count, 1)
        XCTAssertEqual(review.fixes[0].original, "a")
        XCTAssertEqual(review.fixes[0].corrected, "b")
    }

    func testScoreOutOfBoundsBecomesNil() {
        let review = WritingReviewRule.parse("SCORE: 250", original: original)
        XCTAssertNil(review.score)
        let fraction = WritingReviewRule.parse("SCORE: 86/100", original: original)
        XCTAssertEqual(fraction.score, 86)
    }

    func testEmptyOutputIsEmptyReview() {
        let review = WritingReviewRule.parse("好的，我来批改这篇作文。", original: original)
        XCTAssertTrue(review.isEmpty)
    }

    // MARK: - 词级 diff

    func testAlignIdenticalTextAllSame() {
        let text = "I went to the park."
        let segments = WritingDiff.align(original: text, revised: text)
        XCTAssertTrue(segments.allSatisfy(\.isSame))
        XCTAssertEqual(segments.map(\.text).joined(), text)
    }

    func testAlignMarksOnlyChangedWords() {
        let originalText = "I has go to school."
        let revisedText = "I went to school."
        let segments = WritingDiff.align(original: originalText, revised: revisedText)
        let removed = segments.compactMap { segment -> String? in
            if case .removed(let text) = segment { return text }
            return nil
        }.joined()
        let added = segments.compactMap { segment -> String? in
            if case .added(let text) = segment { return text }
            return nil
        }.joined()
        XCTAssertEqual(removed, "has go")
        XCTAssertEqual(added, "went")
        // 没被改动的词不标。
        let same = segments.filter(\.isSame).map(\.text).joined()
        XCTAssertTrue(same.contains("I"))
        XCTAssertTrue(same.contains("to school."))
    }

    func testAlignWholeRewrite() {
        let segments = WritingDiff.align(original: "", revised: "everything new")
        XCTAssertEqual(segments.count, 1)
        if case .added(let text) = segments[0] { XCTAssertEqual(text, "everything new") }
        // 反向：改写为空 → 全部 removed。
        let reverse = WritingDiff.align(original: "old text", revised: "")
        if case .removed(let text) = reverse[0] { XCTAssertEqual(text, "old text") }
    }
}
