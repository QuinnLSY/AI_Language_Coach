import AIDomain
import AIInfrastructure
import XCTest

/// 入学定级（进阶 ⑤）：出卷 / 定级判定 / 题库闸门。
///
/// 全是纯函数 —— 摸底从头到尾不发一个请求，判分口径才钉得住。
final class EntrancePlacementTests: XCTestCase {

    private func question(
        id: String,
        level: CEFRLevel,
        kind: PlacementQuestionKind = .vocabulary,
        answer: Int = 0,
        options: [String] = ["对", "错一", "错二", "错三"]
    ) -> PlacementQuestion {
        PlacementQuestion(
            id: id, level: level, kind: kind, prompt: "prompt-\(id)",
            options: options, answer: answer, explain: "解释"
        )
    }

    /// 一档 5 题的标准题库。
    private func bank() -> [PlacementQuestion] {
        CEFRLevel.allCases.flatMap { level in
            (0..<5).map { question(id: "\(level.rawValue)_\($0)", level: level) }
        }
    }

    // MARK: - 出卷

    /// 每档抽 3 题，一共 12 题。
    func testPaperTakesPerLevelFromEveryLevel() {
        let paper = EntrancePlacementRule.paper(from: bank())
        XCTAssertEqual(paper.questionCount, CEFRLevel.allCases.count * EntrancePlacementRule.questionsPerLevel)
        for level in CEFRLevel.allCases {
            XCTAssertEqual(paper.count(of: level), EntrancePlacementRule.questionsPerLevel)
        }
        XCTAssertEqual(paper.levels, CEFRLevel.allCases, "四档都要有题")
    }

    /// 换种子换一批题（重测不该是同一张卷子）；同种子必须可复现。
    func testSeedRotatesThePaperButStaysReproducible() {
        let same = EntrancePlacementRule.paper(from: bank(), seed: 1)
        let again = EntrancePlacementRule.paper(from: bank(), seed: 1)
        let next = EntrancePlacementRule.paper(from: bank(), seed: 2)
        XCTAssertEqual(same.questions.map(\.id), again.questions.map(\.id), "同种子必须同一份卷")
        XCTAssertNotEqual(same.questions.map(\.id), next.questions.map(\.id), "换种子要换题")
    }

    /// 坏题一律不许上考场：答案下标越界 / 选项重复 / 选项数不对。
    func testUnplayableQuestionsAreFilteredOut() {
        let good = question(id: "a1_good", level: .a1)
        let badAnswer = question(id: "a1_bad_answer", level: .a1, answer: 9)
        let duplicated = question(id: "a1_dup", level: .a1, options: ["same", "same", "x", "y"])
        let shortOptions = question(id: "a1_short", level: .a1, options: ["只有", "两个"])

        XCTAssertTrue(good.isPlayable)
        XCTAssertFalse(badAnswer.isPlayable)
        XCTAssertFalse(duplicated.isPlayable)
        XCTAssertFalse(shortOptions.isPlayable)

        let paper = EntrancePlacementRule.paper(from: [good, badAnswer, duplicated, shortOptions])
        XCTAssertEqual(paper.questions.map(\.id), ["a1_good"], "坏题必须被剔除，而不是硬塞进考场")
    }

    /// 一档一道可用的都没有 → 跳过那一档，不让整份卷子作废。
    func testMissingLevelIsSkippedInsteadOfKillingThePaper() {
        let onlyA1 = (0..<4).map { question(id: "a1_\($0)", level: .a1) }
        let paper = EntrancePlacementRule.paper(from: onlyA1)
        XCTAssertEqual(paper.levels, [.a1])
        XCTAssertEqual(paper.questionCount, EntrancePlacementRule.questionsPerLevel)
    }

    func testEmptyBankMeansEmptyPaper() {
        XCTAssertTrue(EntrancePlacementRule.paper(from: []).isEmpty)
        XCTAssertTrue(EntrancePlacementRule.paper(from: [question(id: "bad", level: .a1, answer: -1)]).isEmpty)
    }

    // MARK: - 定级判定

    /// 全过 → 最高的那一档。
    func testAllPassedMeansHighestLevel() {
        let scores = CEFRLevel.allCases.map { PlacementLevelScore(level: $0, correct: 3, total: 3, isPassed: true) }
        XCTAssertEqual(EntrancePlacementRule.level(from: scores), .b2)
    }

    /// 最低档就不过 → A1（不猜、不抬）。
    func testFailingTheFirstLevelStaysAtA1() {
        let scores = [
            PlacementLevelScore(level: .a1, correct: 1, total: 3, isPassed: false),
            PlacementLevelScore(level: .a2, correct: 3, total: 3, isPassed: true),
            PlacementLevelScore(level: .b1, correct: 3, total: 3, isPassed: true),
        ]
        XCTAssertEqual(EntrancePlacementRule.level(from: scores), .a1)
    }

    /// 中间档不过 → 停在它**下面**那一档（这是这套判定的核心）。
    ///
    /// ⚠️ 反证目标：把 `level(from:)` 改成「取最高的达标档」，B1 会被
    /// 那两条蒙对的记录抬上去 —— 每档只 3 题，抬高一档对用户是实实在在的伤害。
    func testFailingMiddleLevelStopsAtTheLevelBelow() {
        let scores = [
            PlacementLevelScore(level: .a1, correct: 3, total: 3, isPassed: true),
            PlacementLevelScore(level: .a2, correct: 1, total: 3, isPassed: false),
            PlacementLevelScore(level: .b1, correct: 3, total: 3, isPassed: true),
        ]
        XCTAssertEqual(EntrancePlacementRule.level(from: scores), .a1)
    }

    /// 前两档过了、B1 没过 → A2。
    func testStopsAtA2WhenB1Fails() {
        let scores = [
            PlacementLevelScore(level: .a1, correct: 3, total: 3, isPassed: true),
            PlacementLevelScore(level: .a2, correct: 2, total: 3, isPassed: true),
            PlacementLevelScore(level: .b1, correct: 0, total: 3, isPassed: false),
            PlacementLevelScore(level: .b2, correct: 2, total: 3, isPassed: true),
        ]
        XCTAssertEqual(EntrancePlacementRule.level(from: scores), .a2)
    }

    /// 一档题都没有（空明细）时不许崩，也不许给个假档位。
    func testNoScoresFallsBackToA1() {
        XCTAssertEqual(EntrancePlacementRule.level(from: []), .a1)
    }

    /// 达标线：3 题里要 2 题（0.6 向上取整）。
    func testPassThresholdRoundsUp() {
        XCTAssertEqual(EntrancePlacementRule.passThreshold(total: 3), 2)
        XCTAssertEqual(EntrancePlacementRule.passThreshold(total: 5), 3)
        XCTAssertEqual(EntrancePlacementRule.passThreshold(total: 1), 1)
        XCTAssertEqual(EntrancePlacementRule.passThreshold(total: 0), 1, "0 题也要给一个不为零的门槛")
    }

    // MARK: - 判分

    func testResultCountsPerLevelAndOverall() {
        let paper = EntrancePlacementRule.paper(from: bank(), seed: 0)
        // 全对。
        let allRight = Dictionary(uniqueKeysWithValues: paper.questions.map { ($0.id, $0.answer) })
        let perfect = EntrancePlacementRule.result(paper: paper, answers: allRight)
        XCTAssertEqual(perfect.correct, paper.questionCount)
        XCTAssertEqual(perfect.accuracyPercent, 100)
        XCTAssertEqual(perfect.level, .b2)
        XCTAssertEqual(perfect.perLevel.count, CEFRLevel.allCases.count)
        XCTAssertNil(perfect.firstFailedLevel, "全过就没有「没过的那一档」")

        // 一道不做 → 按错算（不猜也是选择，但不给分）。
        var partial = allRight
        if let first = paper.questions.first { partial.removeValue(forKey: first.id) }
        let outcome = EntrancePlacementRule.result(paper: paper, answers: partial)
        XCTAssertEqual(outcome.correct, paper.questionCount - 1)
    }

    /// 选错也要计入「答了但不对」，而不是从分母里消失。
    func testWrongAnswerCountsAgainst() {
        let paper = EntrancePlacementRule.paper(from: bank(), seed: 0)
        let wrong = Dictionary(uniqueKeysWithValues: paper.questions.map { ($0.id, ($0.answer + 1) % 4) })
        let outcome = EntrancePlacementRule.result(paper: paper, answers: wrong)
        XCTAssertEqual(outcome.correct, 0)
        XCTAssertEqual(outcome.total, paper.questionCount)
        XCTAssertEqual(outcome.level, .a1)
        XCTAssertEqual(outcome.firstFailedLevel, .a1)
    }

    func testResultHeadlineAndAdvice() {
        let result = PlacementResult(
            level: .a2, correct: 7, total: 12, seed: 3,
            perLevel: [PlacementLevelScore(level: .a2, correct: 2, total: 3, isPassed: true)]
        )
        XCTAssertEqual(result.headline, "12 题对 7 题")
        XCTAssertEqual(result.accuracyPercent, 58)
        XCTAssertFalse(result.level.placementAdvice.isEmpty)
    }

    /// 重测的种子逐次 +1（换一批题），nil 从头开始。
    func testNextSeedIncrements() {
        XCTAssertEqual(EntrancePlacementRule.nextSeed(after: nil), 1)
        XCTAssertEqual(EntrancePlacementRule.nextSeed(after: 1), 2)
    }

    // MARK: - 随包题库（内容本身的质量门）

    /// ⚠️ 这条盯的是**内容**：题库是手写的，写错一个答案下标、少一个选项，
    /// 在考场上只表现为「怎么选都不对」—— 用户永远查不出原因。
    func testBundledBankIsCompleteAndPlayable() {
        let bank = PlacementCatalog.bundled()
        XCTAssertFalse(bank.isEmpty, "题库没读到（Resources/Placement/questions.json）")

        let playable = bank.filter(\.isPlayable)
        XCTAssertEqual(
            playable.count, bank.count,
            "有题不可用：\(bank.filter { !$0.isPlayable }.map(\.id))"
        )
        for level in CEFRLevel.allCases {
            XCTAssertGreaterThanOrEqual(
                bank.count(where: { $0.level == level }), EntrancePlacementRule.questionsPerLevel,
                "\(level.code) 这一档的题不够抽一轮"
            )
        }
        // 两个题型都要有（纯词汇或纯语法都不足以定位）。
        let kinds = Set(bank.map(\.kind))
        XCTAssertTrue(kinds.contains(.vocabulary))
        XCTAssertTrue(kinds.contains(.grammar))
        // id 不许重复（去重之后数量应该不变）。
        XCTAssertEqual(PlacementCatalog.deduplicated(bank).count, bank.count, "题库里有重复 id")
    }

    /// 题库里的答案下标指向的确实是那个「对」的选项 —— 逐题核对一遍。
    ///
    /// 这条用题库自带的解释文本做**弱**校验：解释里应该出现正确选项的词
    /// （手写题库时「答案填错行」是最容易犯的错，而它只会让整份题库静默错位）。
    func testBundledAnswersPointAtTheExplainedOption() {
        for question in PlacementCatalog.bundled() where question.kind == .vocabulary {
            let answer = question.answerText
            XCTAssertTrue(
                question.explain.contains(answer),
                "\(question.id)：答案「\(answer)」与解释「\(question.explain)」对不上"
            )
        }
    }

    /// 手写解码：JSON 里写的是 `"A1"`，域层 rawValue 是小写 —— 少这一步会静默丢光题库。
    func testDecodesUppercaseLevelAndRejectsUnknown() throws {
        let json = """
        {"version": 1, "questions": [
          {"id": "q1", "level": "B1", "kind": "grammar", "prompt": "I ___ here.",
           "options": ["live", "lived", "have lived", "living"], "answer": 2, "explain": "现在完成时"}
        ]}
        """
        let decoded = try PlacementCatalog.decode(Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.level, .b1)
        XCTAssertEqual(decoded.first?.kind, .grammar)

        let broken = """
        {"version": 1, "questions": [
          {"id": "q1", "level": "C2", "kind": "grammar", "prompt": "x",
           "options": ["a", "b", "c", "d"], "answer": 0}
        ]}
        """
        XCTAssertThrowsError(try PlacementCatalog.decode(Data(broken.utf8)), "未知档位必须报错，不能静默兜底成 A1")
    }

    /// 裸数组写法也要认（手写题库时省事）。
    func testDecodesBareArray() throws {
        let json = """
        [{"id": "q1", "level": "a2", "kind": "vocabulary", "prompt": "tidy",
          "options": ["凌乱的", "油腻的", "整洁的", "拥挤的"], "answer": 2}]
        """
        let decoded = try PlacementCatalog.decode(Data(json.utf8))
        XCTAssertEqual(decoded.first?.level, .a2)
        XCTAssertEqual(decoded.first?.explain, "", "缺 explain 不算坏数据，退成空串")
    }

    /// 去重 + 排序：池子顺序不稳，同一颗种子就会抽出不同的题。
    func testDeduplicationKeepsStableOrder() {
        let duplicated = [
            question(id: "a1_b", level: .a1),
            question(id: "a1_a", level: .a1),
            question(id: "a1_b", level: .a1),
            question(id: "a2_a", level: .a2),
        ]
        XCTAssertEqual(PlacementCatalog.deduplicated(duplicated).map(\.id), ["a1_a", "a1_b", "a2_a"])
    }
}
