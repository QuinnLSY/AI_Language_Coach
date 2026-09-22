@testable import AIDomain
import XCTest

/// 听力板块三种形式（#309）里**纯函数**那部分的回归。
///
/// 三种形式的分工（用户采纳的方案）：
///   · 精听默写 `.dictation` —— 整句写下来逐词对（规则在 `ListeningDictation.swift`）；
///   · 关键词捕捉 `.keyword` —— 只抓主干词（`ListeningKeywordRule`）；
///   · 听句选义 `.meaning` —— 四个释义挑一个（`ListeningMeaningRule`）。
///
/// 这里钉的是**判分口径**，而口径一旦悄悄变了，界面上完全看不出来 ——
/// 只会以「怎么分数变松了」的形式被用户察觉。所以每条都对着具体词句断言。
///
/// ⚠️ 三种形式都是**零模型请求**：本文件不碰 runtime、不碰网络、不碰 UserDefaults。
final class ListeningModesTests: XCTestCase {

    private func drill(
        _ id: String, _ text: String, _ translation: String = ""
    ) -> ShadowingDrill {
        ShadowingDrill(id: id, text: text, translation: translation, topic: "测试")
    }

    // MARK: - 关键词挑选（`keyWords`）

    /// 长词留住、短词与虚词踢掉，最后**按原句顺序**排回去。
    ///
    /// 顺序这条不是洁癖：屏幕上是从左到右读的，按长度排会让人以为那是「重要度排序」
    /// （它不是 —— 长度只是最省事的「内容度」代理）。
    func testKeyWordsKeepContentWordsInSentenceOrder() {
        let words = ListeningKeywordRule.keyWords(of: "Can I have a receipt for the flight")
        XCTAssertEqual(
            words, ["receipt", "flight"],
            "`have` 是虚词、`Can` 只有 3 个字母，都不该进来"
        )
    }

    /// 非字母的东西一律不是词：`check-in`（连字符）、`12`（数字）、`I'd`（撇号）都进不来。
    func testKeyWordsRejectNonLetterTokens() {
        let words = ListeningKeywordRule.keyWords(of: "I'd like to check-in at gate 12")
        XCTAssertFalse(words.contains("check-in"), "带连字符的不是一个词")
        XCTAssertFalse(words.contains("12"), "数字不是词")
        XCTAssertFalse(words.contains("i'd"), "带撇号的不是词")
        XCTAssertTrue(words.contains("gate"))
    }

    /// 一句最多 `keyWordLimit` 个，且留下的是**最长的**那几个。
    func testKeyWordsCapAtTheLimitPickingTheLongest() {
        let sentence = "reservation confirmation receipt luggage departure terminal"
        let words = ListeningKeywordRule.keyWords(of: sentence)
        XCTAssertEqual(words.count, ListeningKeywordRule.keyWordLimit)
        XCTAssertEqual(
            words, ["reservation", "confirmation", "departure", "terminal"],
            "留下最长的四个（receipt / luggage 都是 7 个字母，排在后面），再按原句顺序排"
        )
    }

    /// 同一个词重复出现只算一次 —— 复读一遍不该让这个词占掉两个位置。
    func testKeyWordsAreDeduplicated() {
        let words = ListeningKeywordRule.keyWords(of: "receipt receipt receipt please")
        XCTAssertEqual(words.filter { $0 == "receipt" }.count, 1)
    }

    /// 整句都是虚词时也要出得了题。
    ///
    /// 没有这条兜底，`They have been here before` 这种句子一个关键词都挑不出来 ——
    /// 模式对短句直接失效，而屏幕上只会显得「这一句没题」。
    func testKeyWordsStillProduceSomethingForAllStopwordSentences() {
        let words = ListeningKeywordRule.keyWords(of: "They have been here before")
        XCTAssertFalse(words.isEmpty, "全是虚词的句子也必须能出题")
        XCTAssertLessThanOrEqual(words.count, ListeningKeywordRule.keyWordLimit)
    }

    /// 字母数不足 4 的词**一个字都不收**（兜底也救不了它们）。
    func testKeyWordsEmptyWhenNothingIsLongEnough() {
        XCTAssertTrue(
            ListeningKeywordRule.keyWords(of: "It is at my go").isEmpty,
            "全是 2 个字母的词 → 挑不出关键词（这时命中率算 0，见下一条）"
        )
    }

    // MARK: - 命中判定（`matches`）

    /// 三档口径：全等 = 命中；前缀够长 = 命中（听清了但没写全）；**子串不算**。
    func testKeywordMatchAcceptsExactAndLongPrefixButNotSubstring() {
        XCTAssertTrue(ListeningKeywordRule.matches(typed: "receipt", key: "receipt"), "全等")
        XCTAssertTrue(
            ListeningKeywordRule.matches(typed: "recei", key: "receipt"),
            "前缀够长（5 ≥ 4）＝ 听清了，只是没写全"
        )
        XCTAssertTrue(
            ListeningKeywordRule.matches(typed: "rece", key: "receipt"),
            "前缀刚好 4 个字母：`minimumPrefixMatch` 是**含**边界的"
        )
        XCTAssertFalse(
            ListeningKeywordRule.matches(typed: "rec", key: "receipt"),
            "前缀只有 3 个字母：那只是碰巧对上开头"
        )
        XCTAssertFalse(
            ListeningKeywordRule.matches(typed: "ecei", key: "receipt"),
            "落在词中间的片段不是「差几个字母」，是没听清开头"
        )
    }

    /// 判定门槛与常量是绑在一起的：`minimumPrefixMatch` 一动，这条就该跟着红。
    func testPrefixThresholdMatchesTheDocumentedConstant() {
        XCTAssertEqual(ListeningKeywordRule.minimumPrefixMatch, 4)
        let justEnough = String(repeating: "x", count: ListeningKeywordRule.minimumPrefixMatch)
        let oneShort = String(repeating: "x", count: ListeningKeywordRule.minimumPrefixMatch - 1)
        XCTAssertTrue(ListeningKeywordRule.matches(typed: justEnough, key: justEnough + "tail"))
        XCTAssertFalse(ListeningKeywordRule.matches(typed: oneShort, key: oneShort + "tail"))
    }

    // MARK: - 对照（`capture`）

    func testCaptureSeparatesCaughtFromMissed() {
        let capture = ListeningKeywordRule.capture(
            drillID: "d0",
            reference: "The reservation is confirmed",
            translation: "预订确认了",
            typed: "reservation serv",
            playCount: 2
        )
        XCTAssertEqual(capture.keyWords, ["reservation", "confirmed"])
        XCTAssertEqual(capture.caught, ["reservation"], "`serv` 是子串 → 不算抓住 confirmed")
        XCTAssertEqual(capture.missed, ["confirmed"])
        XCTAssertEqual(capture.hitRatio, 0.5, accuracy: 1e-9)
        XCTAssertEqual(capture.hitPercent, 50)
        XCTAssertEqual(capture.playCount, 2)
        XCTAssertEqual(capture.scoreText, "抓住了 1 / 2")
    }

    func testCaptureCountsPrefixHits() {
        let capture = ListeningKeywordRule.capture(
            drillID: "d0", reference: "The reservation is confirmed", typed: "reserv confirm", playCount: 1
        )
        XCTAssertEqual(capture.caught, ["reservation", "confirmed"], "两个都是「写全了大半」的前缀")
        XCTAssertTrue(capture.missed.isEmpty)
        XCTAssertEqual(capture.hitRatio, 1.0, accuracy: 1e-9)
    }

    /// ⚠️ 挑不出关键词的句子命中率算 **0**，不是 1。
    ///
    /// 给满分会让平均分虚高：那种句子本来就出不了题，不该被算成「全抓住了」。
    func testCaptureScoresZeroWhenTheSentenceHasNoKeyWords() {
        let capture = ListeningKeywordRule.capture(
            drillID: "d0", reference: "It is at my go", typed: "it is at my go", playCount: 0
        )
        XCTAssertTrue(capture.keyWords.isEmpty)
        XCTAssertEqual(capture.hitRatio, 0, accuracy: 1e-9, "没题可出 ≠ 满分")
        XCTAssertEqual(capture.total, 0)
        XCTAssertEqual(capture.scoreText, "抓住了 0 / 0")
    }

    /// 类型里存的是「学员写了什么」的原样归一化结果 —— 结算卡要能把人写过的词回显出来。
    func testCaptureKeepsWhatTheLearnerTyped() {
        let capture = ListeningKeywordRule.capture(
            drillID: "d0", reference: "The reservation is confirmed",
            typed: "  Reservation,  CONFIRMED  ", playCount: 1
        )
        XCTAssertEqual(capture.typedWords, ["reservation", "confirmed"], "小写化、去掉标点")
    }

    // MARK: - 关键词模式结算

    func testKeywordSummaryUsesHitRatioAndFullCaptureCount() {
        let full = ListeningKeywordRule.capture(
            drillID: "d0", reference: "The reservation is confirmed",
            typed: "reservation confirmed", playCount: 1
        )
        let half = ListeningKeywordRule.capture(
            drillID: "d1", reference: "Please hold the luggage", typed: "luggage", playCount: 3
        )
        let summary = ListeningSummary.keyword(from: [full, half])

        XCTAssertEqual(summary.mode, .keyword)
        XCTAssertEqual(summary.attempted, 2)
        XCTAssertEqual(summary.averageAccuracy, (1.0 + half.hitRatio) / 2, accuracy: 1e-9)
        XCTAssertEqual(
            summary.firstPassCount, 1,
            "「整句全抓住」在关键词模式里就是默写的「一遍听懂」（同一条口径：一次做对，不用返工）"
        )
        XCTAssertEqual(summary.averagePlays, 2.0, accuracy: 1e-9)
        XCTAssertEqual(summary.missedWords, half.missed, "漏词 = 没抓住的那几个")
    }

    // MARK: - 出题（`ListeningMeaningRule`）

    /// 四个**互不相同**的释义，正确项在其中，且选项全部来自同批素材。
    func testMeaningQuestionOffersFourDistinctTranslations() throws {
        let round = [
            drill("d0", "Can I have a receipt", "能给我一张收据吗"),
            drill("d1", "The flight is delayed", "航班延误了"),
            drill("d2", "Please hold the line", "请别挂断电话"),
            drill("d3", "I would like to check in", "我想办理入住"),
            drill("d4", "Where is the gate", "登机口在哪里"),
        ]
        let question = try XCTUnwrap(ListeningMeaningRule.question(for: round[0], in: round))

        XCTAssertEqual(question.options.count, ListeningMeaningRule.optionCount)
        XCTAssertEqual(Set(question.options).count, question.options.count, "四个选项必须互不相同")
        XCTAssertEqual(question.correctOption, "能给我一张收据吗")
        XCTAssertTrue(question.isCorrect(question.correctIndex))
        XCTAssertFalse(question.isCorrect(nil))
        let pool = Set(round.map(\.translation))
        for option in question.options {
            XCTAssertTrue(pool.contains(option), "干扰项只能是同批素材的释义 —— 编出来的假选项等于把答案指出来")
        }
    }

    /// ⚠️ 同一句**每次进来出的题必须一模一样**（选项顺序也一致）。
    ///
    /// 不这么做的话，退出重进选项位置就换了，那次「重做」量的不是听力而是记忆。
    /// 顺序由句 id 派生的种子定（`DailySeed.seed(for:purpose:)`，FNV-1a，绝不用 `Hasher`）。
    func testMeaningQuestionIsStableForTheSameSentence() throws {
        let round = (0..<6).map { drill("d\($0)", "line \($0)", "第 \($0) 句的意思") }
        let first = try XCTUnwrap(ListeningMeaningRule.question(for: round[2], in: round))
        let second = try XCTUnwrap(ListeningMeaningRule.question(for: round[2], in: round))
        XCTAssertEqual(first.options, second.options, "同一句两次出题必须同一个选项顺序")
        XCTAssertEqual(first.correctIndex, second.correctIndex)
    }

    /// ⚠️ 正确项**不该永远落在同一个位置**。
    ///
    /// 反证目标：`ListeningMeaningRule.question` 里第二次 `options.shuffle`。
    /// 去掉它的话，正确答案永远是拼进去时的那一位（最后一位），
    /// 于是「第 4 个选项」变成一条白送的线索 —— 正确率就没有意义了。
    func testMeaningCorrectOptionIsNotAlwaysInTheSameSlot() {
        let round = (0..<8).map { drill("d\($0)", "line \($0)", "第 \($0) 句的意思") }
        let questions = round.compactMap { ListeningMeaningRule.question(for: $0, in: round) }
        XCTAssertEqual(questions.count, 8, "八句释义互不相同，每句都该出得了题")
        XCTAssertGreaterThanOrEqual(
            Set(questions.map(\.correctIndex)).count, 2,
            "正确项八次都落在同一个位置 —— 选项没被真正打乱"
        )
    }

    /// 缺释义 / 释义不够互不相同 → **不出题**（返回 nil），绝不拿空串或重复项凑一道有白送答案的题。
    func testMeaningQuestionIsNilWhenOptionsCannotBeFilled() {
        XCTAssertNil(
            ListeningMeaningRule.question(for: drill("d0", "line", ""), in: [
                drill("d0", "line", ""), drill("d1", "other", "别的"),
            ]),
            "这一句本身没有释义 → 出不了题"
        )
        XCTAssertNil(
            ListeningMeaningRule.question(for: drill("d0", "line", "一样"), in: [
                drill("d0", "line", "一样"), drill("d1", "a", "一样"), drill("d2", "b", "一样"),
            ]),
            "干扰项重复 → 凑不出四个互不相同的选项"
        )
    }

    /// 一轮里哪些句子出得了题（页面据此**跳过**出不了的那几句）。
    func testAnswerableIDsExcludesSentencesWithoutTranslation() {
        let round = [
            drill("d0", "a", "第一句"),
            drill("d1", "b", "第二句"),
            drill("d2", "c", "第三句"),
            drill("d3", "d", "第四句"),
            drill("d4", "e", ""),
        ]
        XCTAssertEqual(
            ListeningMeaningRule.answerableIDs(in: round), ["d0", "d1", "d2", "d3"]
        )
    }

    // MARK: - 听句选义的结算

    func testMeaningSummaryCountsCorrectAnswersAndKeepsMissedKeyWords() {
        let summary = ListeningSummary.meaning(
            correct: [true, false, true], missedWords: ["delayed", "gate"], averagePlays: 1.5
        )
        XCTAssertEqual(summary.mode, .meaning)
        XCTAssertEqual(summary.attempted, 3)
        XCTAssertEqual(summary.correctCount, 2)
        XCTAssertEqual(summary.accuracyPercent, 67)
        XCTAssertEqual(summary.averagePlays, 1.5, accuracy: 1e-9)
        XCTAssertEqual(summary.missedWords, ["delayed", "gate"])
        XCTAssertTrue(summary.headline.contains("答对 2 句"))
    }

    /// 三种形式的**空结算**各自带自己的模式 —— 结算卡的标签随模式变，
    /// 一律返回那个写死 `.dictation` 的 `.empty` 会让人看到「一遍听懂」而他从没默写过。
    func testEmptySummariesKeepTheirOwnMode() {
        XCTAssertEqual(ListeningSummary.from([]).mode, .dictation)
        XCTAssertEqual(ListeningSummary.keyword(from: []).mode, .keyword)
        XCTAssertEqual(ListeningSummary.meaning(correct: [], missedWords: [], averagePlays: 0).mode, .meaning)
        XCTAssertFalse(ListeningSummary.keyword(from: []).hasAttempts)
    }

    // MARK: - 每次进来是同一套题（种子）

    func testSeedIsStableAndScopedByPurposeAndKey() {
        let a = DailySeed.seed(for: "d0", purpose: "listening-meaning")
        XCTAssertEqual(a, DailySeed.seed(for: "d0", purpose: "listening-meaning"), "同一句必须同一个种子")
        XCTAssertNotEqual(a, DailySeed.seed(for: "d1", purpose: "listening-meaning"), "不同句子分开")
        XCTAssertNotEqual(a, DailySeed.seed(for: "d0", purpose: "other"), "不同用途分开")
    }

    /// splitmix64 的演示性质（顺手钉住「种子不同 → 打乱不同」）：0 号种子被换掉了。
    func testSeededGeneratorIsDeterministicAndAvoidsDegenerateSeed() {
        var first = SeededRandomGenerator(seed: 42)
        var second = SeededRandomGenerator(seed: 42)
        XCTAssertEqual((0..<8).map { _ in first.next() }, (0..<8).map { _ in second.next() })
        var zero = SeededRandomGenerator(seed: 0)
        XCTAssertNotEqual(zero.next(), 0, "0 号种子会退化成弱序列，构造时要换掉它")
    }
}
