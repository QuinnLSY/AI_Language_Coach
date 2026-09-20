import AIDomain
import XCTest

/// 段落级影子跟读（#232）的纯逻辑：**段落切分**与**整段识别回填到每一句**。
///
/// 这两块决定了「用户看到的是不是他真读出来的」，因此全部脱机单测 ——
/// 不碰麦克风、不碰模型、不碰数据库。
final class ShadowingPassageTests: XCTestCase {

    // MARK: - 辅助

    private func drill(_ id: String, _ text: String, topic: String = "情景", difficulty: Int = 1) -> ShadowingDrill {
        ShadowingDrill(id: id, text: text, translation: "", topic: topic, difficulty: difficulty, focus: "")
    }

    /// 一天 20 句：5 个情景 × 4 句（与 `ShadowingDailyRule.parse` 产出的 id 形态一致）。
    private var dailyDrills: [ShadowingDrill] {
        (0..<5).flatMap { topic in
            (0..<4).map { index in
                drill("daily-\(topic)-\(index)", "sentence \(topic) \(index) words here", topic: "情景\(topic)")
            }
        }
    }

    // MARK: - 段落切分

    func testPassagesFollowScenarioGroupsInOrder() {
        let passages = ShadowingPassageRule.passages(from: dailyDrills)
        XCTAssertEqual(passages.count, 5, "20 句 / 每情景 4 句 = 5 段")
        XCTAssertEqual(passages.map(\.drills.count), [4, 4, 4, 4, 4])
        // 顺序必须保持：换了顺序，「第 3 段」就指不到原来那段了。
        XCTAssertEqual(passages.first?.drills.first?.id, "daily-0-0")
        XCTAssertEqual(passages.last?.drills.last?.id, "daily-4-3")
    }

    func testPassageKeepsScenarioTitleAndHardestDifficulty() {
        let passages = ShadowingPassageRule.passages(
            from: [
                drill("daily-0-0", "a b", topic: "机场值机", difficulty: 2),
                drill("daily-0-1", "c d", topic: "机场值机", difficulty: 4),
            ]
        )
        XCTAssertEqual(passages.count, 1)
        XCTAssertEqual(passages[0].title, "机场值机")
        XCTAssertEqual(passages[0].difficulty, 4, "段落难度取段内最难的一句")
    }

    /// 两个情景**同名**时不能并成一段 —— 按 id 里的情景序号切，而不是按情景名。
    func testSameTopicNameDoesNotMergePassages() {
        let passages = ShadowingPassageRule.passages(
            from: [
                drill("daily-0-0", "a", topic: "点餐"),
                drill("daily-0-1", "b", topic: "点餐"),
                drill("daily-1-0", "c", topic: "点餐"),
            ]
        )
        XCTAssertEqual(passages.count, 2, "情景名重了也要按序号分开，否则段落会凭空变长")
    }

    /// 内置素材没有 `daily-x-y` 的 id，退回按 topic 归段。
    func testBundledDrillsGroupByTopic() {
        let passages = ShadowingPassageRule.passages(
            from: [
                drill("greet_01", "hello", topic: "问候"),
                drill("greet_02", "hi there", topic: "问候"),
                drill("hotel_01", "a room", topic: "酒店"),
            ]
        )
        XCTAssertEqual(passages.count, 2)
        XCTAssertEqual(passages[0].drills.count, 2)
        XCTAssertEqual(passages[1].drills.count, 1)
    }

    func testPassagesEmptyForNoDrills() {
        XCTAssertTrue(ShadowingPassageRule.passages(from: []).isEmpty)
    }

    // MARK: - 整段回填

    private let sentences = [
        "I would like a coffee",
        "and a slice of cake",
        "we are in a hurry",
        "thank you very much",
    ]

    func testPerfectReadScoresEverySentence() {
        let passage = ShadowingPassage(id: "p", title: "点餐", drills: sentences.enumerated().map { drill("daily-0-\($0.offset)", $0.element) })
        let result = ShadowingPassageScorer.evaluate(passage: passage, recognized: sentences.joined(separator: " "))
        XCTAssertEqual(result.accuracy, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result.verdict, .perfect)
        XCTAssertTrue(result.sentences.allSatisfy { $0.verdict == .perfect })
        XCTAssertEqual(result.matched, result.referenceCount)
    }

    /// 段落模式的核心价值：**漏掉第 3 句**时，其它三句仍然是满分。
    /// 只给整段一个总分的话，用户看不出自己是卡在第几句。
    func testSkippingOneSentenceOnlyHurtsThatSentence() {
        let passage = ShadowingPassage(id: "p", title: "点餐", drills: sentences.enumerated().map { drill("daily-0-\($0.offset)", $0.element) })
        let spoken = [sentences[0], sentences[1], sentences[3]].joined(separator: " ")
        let result = ShadowingPassageScorer.evaluate(passage: passage, recognized: spoken)

        XCTAssertEqual(result.weakestIndex, 2, "最弱的应当是第 3 句")
        XCTAssertEqual(result.sentences[2].accuracy, 0, accuracy: 1e-9)
        XCTAssertEqual(result.sentences[0].accuracy, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result.sentences[1].accuracy, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result.sentences[3].accuracy, 1.0, accuracy: 1e-9)
        XCTAssertTrue(result.hint.contains("第 3 句"), "反馈要点名第几句：\(result.hint)")
    }

    /// 多说的词**不许被悄悄丢掉**：必须挂在某一句上让用户看见。
    func testExtraWordsAreAttributedNotDropped() {
        let passage = ShadowingPassage(id: "p", title: "点餐", drills: sentences.enumerated().map { drill("daily-0-\($0.offset)", $0.element) })
        let spoken = sentences[0] + " banana helicopter " + sentences[1] + " " + sentences[2] + " " + sentences[3]
        let result = ShadowingPassageScorer.evaluate(passage: passage, recognized: spoken)
        let extras = result.sentences.flatMap { $0.tokens.filter { $0.status == .extra } }.map(\.word)
        XCTAssertTrue(extras.contains("banana"), "多说的词要出现逐词反馈里，实际：\(extras)")
        XCTAssertTrue(extras.contains("helicopter"))
    }

    /// 学员只把第 1 句连读三遍：第 1 句要满分，重复产生的废词要挂在它头上，
    /// 整段分要明显低 —— 不能因为「词都在」就当成整段跟上了。
    ///
    /// ⚠️ 这里不断言「第 2 句一个词都没有」：逐词匹配用的是与一句一练**同一把尺**（LCS），
    /// 重复的虚词（a / I）本来就能在后面几句里撞上。这是既有评分口径的固有行为，
    /// 段落模式不私下换尺 —— 换尺会让「一句一练 85%」和「段落第 2 句 85%」不是一回事。
    func testRepeatedFirstSentenceDoesNotPassAsWholePassage() {
        let passage = ShadowingPassage(id: "p", title: "点餐", drills: sentences.enumerated().map { drill("daily-0-\($0.offset)", $0.element) })
        let spoken = Array(repeating: sentences[0], count: 3).joined(separator: " ")
        let result = ShadowingPassageScorer.evaluate(passage: passage, recognized: spoken)

        XCTAssertEqual(result.sentences[0].accuracy, 1.0, accuracy: 1e-9, "第 1 句确实读了")
        XCTAssertGreaterThan(
            result.sentences[0].tokens.filter { $0.status == .extra }.count, 0,
            "重复产生的废词要挂在第 1 句上让用户看见，实际：\(result.sentences[0].tokens)"
        )
        XCTAssertNotEqual(result.weakestIndex, 0, "整段里最弱的不该是读了的那句")
        XCTAssertLessThan(result.accuracy, 0.5, "只读了一句不该拿到整段高分：\(result.accuracy)")
    }

    func testSilenceScoresZeroAndSaysSo() {
        let passage = ShadowingPassage(id: "p", title: "点餐", drills: sentences.enumerated().map { drill("daily-0-\($0.offset)", $0.element) })
        let result = ShadowingPassageScorer.evaluate(passage: passage, recognized: "")
        XCTAssertEqual(result.accuracy, 0)
        XCTAssertEqual(result.verdict, .retry)
        XCTAssertTrue(result.hint.contains("没有听到声音"), "静音要明说没听到，实际：\(result.hint)")
    }

    func testEmptyPassageDoesNotDivideByZero() {
        let passage = ShadowingPassage(id: "p", title: "", drills: [])
        let result = ShadowingPassageScorer.evaluate(passage: passage, recognized: "hello")
        XCTAssertEqual(result.accuracy, 0)
        XCTAssertEqual(result.accuracyPercent, 0, "空段落不能冒出 NaN")
        XCTAssertNil(result.weakestIndex)
    }

    /// 单句段落必须走**和一句一练完全相同**的路径（不额外做 DP）。
    func testSingleSentencePassageMatchesSentenceMode() {
        let passage = ShadowingPassage(id: "p", drills: [drill("daily-0-0", "I would like a coffee")])
        let spoken = "I would like a tea"
        let aligned = ShadowingPassageScorer.align(sentences: passage.sentences, recognized: spoken)
        let direct = ShadowingScorer.compare(reference: passage.sentences[0], recognized: spoken)
        XCTAssertEqual(aligned.count, 1)
        XCTAssertEqual(aligned[0], direct)
    }

    /// 倒着读（先读末句）不应当拿到高分：保序切分只认顺序。
    func testOutOfOrderReadingIsNotRewarded() {
        let passage = ShadowingPassage(id: "p", title: "点餐", drills: sentences.enumerated().map { drill("daily-0-\($0.offset)", $0.element) })
        let reversed = sentences.reversed().joined(separator: " ")
        let result = ShadowingPassageScorer.evaluate(passage: passage, recognized: reversed)
        XCTAssertLessThan(result.accuracy, 0.7, "倒着读不该当成跟上：\(result.accuracy)")
    }

    /// 识别文本长到离谱（ASR 发疯）时要有兜底：不崩、不超时、结果仍是合法比例。
    func testPathologicalLongTranscriptStaysSane() {
        let passage = ShadowingPassage(id: "p", title: "点餐", drills: sentences.enumerated().map { drill("daily-0-\($0.offset)", $0.element) })
        let noisy = Array(repeating: "the quick brown fox jumps over the lazy dog", count: 30).joined(separator: " ")
        let start = Date()
        let result = ShadowingPassageScorer.evaluate(passage: passage, recognized: noisy)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "段落对齐必须在 1 秒内跑完，实际 \(elapsed)s")
        XCTAssertEqual(result.sentences.count, 4)
        XCTAssertTrue((0...1).contains(result.accuracy))
    }
}
