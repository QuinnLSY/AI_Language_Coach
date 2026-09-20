import AIDomain
import XCTest

/// #231 每日短文阅读：解析 / 本地判分 / 主题轮换（全纯函数）。
final class ReadingTests: XCTestCase {

    // MARK: 解析

    func testParseFullOutput() {
        let raw = """
        title: The Lighthouse Cat
        passage: Mimo lived in a lighthouse.
        Every morning she chased the gulls.
        q: Where did Mimo live?
        opt: In a school. || In a lighthouse. || On a farm. || In a boat.
        answer: 1
        quote: Mimo lived in a lighthouse.
        explain: 第一段第一句直接说了住处。
        trap: 其余选项都不在原文里，靠常识容易选船。
        q: What did Mimo chase?
        opt: mice || gulls || dogs || fish
        answer: 0
        quote: Every morning she chased the gulls.
        explain: chase 后面接追逐对象。
        trap: A 和 B 顺序易混。
        """
        let passage = ReadingReviewRule.parse(raw, dayKey: 42)
        XCTAssertEqual(passage.title, "The Lighthouse Cat")
        XCTAssertEqual(passage.dayKey, 42)
        XCTAssertTrue(passage.text.contains("Mimo lived in a lighthouse."))
        XCTAssertTrue(passage.text.contains("Every morning she chased the gulls."))
        XCTAssertEqual(passage.questions.count, 2)

        let first = passage.questions[0]
        XCTAssertEqual(first.options.count, 4)
        XCTAssertEqual(first.options[1], "In a lighthouse.")
        XCTAssertEqual(first.correctIndex, 1)
        XCTAssertEqual(first.quote, "Mimo lived in a lighthouse.")
        XCTAssertFalse(first.explain.isEmpty)
        XCTAssertFalse(first.trap.isEmpty)
    }

    func testParseDropsInvalidQuestions() {
        // 答案越界 / 选项不足 4 / 没有题干 —— 宁缺毋滥，整题丢弃。
        let raw = """
        passage: Some text.
        q: bad answer
        opt: a || b || c || d
        answer: 7
        q: too few options
        opt: a || b || c
        answer: 0
        q: good one
        opt: a || b || c || d
        answer: 3
        """
        let passage = ReadingReviewRule.parse(raw, dayKey: 1)
        XCTAssertEqual(passage.questions.count, 1)
        XCTAssertEqual(passage.questions[0].correctIndex, 3)
    }

    func testParseExtraOptionsAreCappedToFour() {
        let raw = """
        passage: T.
        q: how many?
        opt: a || b || c || d || e
        answer: 2
        """
        let passage = ReadingReviewRule.parse(raw, dayKey: 3)
        XCTAssertEqual(passage.questions.count, 1)
        XCTAssertEqual(passage.questions[0].options, ["a", "b", "c", "d"])
    }

    func testParseToleratesMissingTrapAndQuote() {
        let raw = """
        passage: Text only.
        q: bare question
        opt: a || b || c || d
        answer: 0
        """
        let passage = ReadingReviewRule.parse(raw, dayKey: 5)
        XCTAssertEqual(passage.questions.count, 1)
        XCTAssertTrue(passage.questions[0].quote.isEmpty)
        XCTAssertTrue(passage.questions[0].trap.isEmpty)
    }

    func testParseGarbageReturnsEmpty() {
        let passage = ReadingReviewRule.parse("no keys at all, just chatter", dayKey: 0)
        XCTAssertTrue(passage.isEmpty)
        XCTAssertTrue(passage.questions.isEmpty)
    }

    // MARK: 本地判分

    func testGraderCountsCorrectAndWrong() {
        let passage = ReadingReviewRule.parse(
            """
            passage: T.
            q: one
            opt: a || b || c || d
            answer: 0
            q: two
            opt: a || b || c || d
            answer: 2
            """,
            dayKey: 1
        )
        // 第 1 题对、第 2 题错。
        XCTAssertEqual(ReadingGrader.grade(passage, choices: [0: 0, 1: 1]), [true, false])
        XCTAssertEqual(ReadingGrader.correctCount(passage, choices: [0: 0, 1: 1]), 1)
        // 未答按错计。
        XCTAssertEqual(ReadingGrader.grade(passage, choices: [0: 0]), [true, false])
        XCTAssertEqual(ReadingGrader.correctCount(passage, choices: [:]), 0)
        XCTAssertEqual(ReadingGrader.correctCount(passage, choices: [0: 0, 1: 2]), 2)
    }

    // MARK: 溯源定位

    func testQuoteOffsetFindsSentence() {
        let passageText = "Mimo lived in a lighthouse. She liked the fog."
        XCTAssertEqual(WritingReviewRule.locate("mimo lived in a lighthouse.", in: passageText), 0)
        XCTAssertEqual(WritingReviewRule.locate("She liked the fog.", in: passageText), 28)
        // 逐字对不上 → nil（UI 照样展示，只是不高亮）。
        XCTAssertNil(WritingReviewRule.locate("Mimo lived on a boat.", in: passageText))
    }

    // MARK: 主题轮换

    func testThemeIsConstantWithinADayAndRotates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 8))!
        let night = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 23))!
        let nextDay = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 8))!
        XCTAssertEqual(ReadingThemeLibrary.theme(for: morning, calendar: calendar),
                       ReadingThemeLibrary.theme(for: night, calendar: calendar))
        XCTAssertNotEqual(ReadingThemeLibrary.theme(for: morning, calendar: calendar),
                          ReadingThemeLibrary.theme(for: nextDay, calendar: calendar))
    }
}
