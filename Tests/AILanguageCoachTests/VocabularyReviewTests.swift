import AIDomain
import XCTest

/// 词汇复习闭环（P1-3）的**领域层**回归。
///
/// 这一层全是纯函数：不碰模型、不碰数据库、不碰界面 —— 所以断言可以直接钉死
/// 「到期的词怎么排、判分怎么推进、结算怎么说」这三件事的每一条规则。
///
/// 贯穿全部用例的一条口径：**口径只能有一把尺子**。
/// 到期与否一律问 `ReviewScheduler`，本文件不自己算间隔 —— 否则
/// 「待复习 N 个」和「点进去看到的张数」就会各说各话。
final class VocabularyReviewTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private let day: TimeInterval = 86_400

    // MARK: - 造数据

    private func entry(
        _ word: String,
        mastery: Int = 0,
        reviewedDaysAgo: Double? = nil,
        reviewCount: Int = 0
    ) -> VocabularyEntry {
        VocabularyEntry(
            word: word,
            mastery: mastery,
            reviewCount: reviewCount,
            lastReviewedAt: reviewedDaysAgo.map { now.addingTimeInterval(-$0 * day) }
        )
    }

    // MARK: - ① 队列只收真的到期的词

    func testQueueTakesOnlyDueWords() {
        let fresh = entry("fresh")                                   // 没复习过 → 永远到期
        let farAway = entry("later", mastery: 3, reviewedDaysAgo: 1) // 间隔 4 天，昨天刚复习 → 不到期
        let overdue = entry("overdue", mastery: 3, reviewedDaysAgo: 5)

        let session = VocabularyReviewSession(entries: [farAway, fresh, overdue], now: now)
        XCTAssertEqual(session.queue.map(\.word), ["fresh", "overdue"], "不到期的词绝不能进队列")
        XCTAssertEqual(session.total, 2)
    }

    /// 到期判据与 `ReviewScheduler` **逐字同源**：把这一层删掉也不该算出别的结果。
    func testQueueAgreesWithReviewScheduler() {
        let entries = [
            entry("a"), entry("b", mastery: 1, reviewedDaysAgo: 2),
            entry("c", mastery: 4, reviewedDaysAgo: 1), entry("d", mastery: 5, reviewedDaysAgo: 30),
            entry("e", mastery: 2, reviewedDaysAgo: 3)
        ]
        let expected = Set(ReviewScheduler.dueEntries(entries, now: now).map(\.word))
        let actual = Set(VocabularyReviewSession.queue(from: entries, now: now).map(\.word))
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(expected, ["a", "b", "e"], "这一组里只有这三个该到期")
    }

    func testMasteredWordsNeverEnterTheQueue() {
        let mastered = entry("mastered", mastery: ReviewScheduler.maxMastery, reviewedDaysAgo: 400)
        XCTAssertTrue(VocabularyReviewSession(entries: [mastered], now: now).queue.isEmpty)
    }

    // MARK: - ② 队列顺序与上限

    func testQueueOrdersByMasteryThenOldestThenAlphabetical() {
        let entries = [
            entry("banana", mastery: 2, reviewedDaysAgo: 10),
            entry("apple", mastery: 2, reviewedDaysAgo: 10),
            entry("cherry", mastery: 1, reviewedDaysAgo: 1)
        ]
        let queue = VocabularyReviewSession.queue(from: entries, now: now)
        XCTAssertEqual(
            queue.map(\.word), ["cherry", "apple", "banana"],
            "最不熟的先复习；同样不熟时最久没碰的先来；最后按字母序兜底（顺序必须确定）"
        )
    }

    func testQueueIsCappedAtMaxCards() {
        let entries = (0..<25).map { entry("word\($0)") }
        let session = VocabularyReviewSession(entries: entries, now: now)
        XCTAssertEqual(session.total, VocabularyReviewSession.maxCards, "一轮最多走 maxCards 个")
        XCTAssertEqual(session.queue.count, 20)
    }

    func testZeroLimitYieldsEmptyQueue() {
        let session = VocabularyReviewSession(entries: [entry("a")], now: now, limit: 0)
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertTrue(session.isFinished)
    }

    // MARK: - ③ 判分推进

    func testGradingAdvancesAndRecordsMasteryDelta() {
        var session = VocabularyReviewSession(entries: [entry("apple", mastery: 0)], now: now)
        XCTAssertEqual(session.current?.word, "apple")
        XCTAssertFalse(session.isFinished)

        let outcome = session.grade(remembered: true, now: now)
        XCTAssertEqual(outcome?.masteryBefore, 0)
        XCTAssertEqual(outcome?.masteryAfter, 1)
        XCTAssertEqual(outcome?.masteryDelta, 1)
        XCTAssertEqual(session.reviewed, 1)
        XCTAssertNil(session.current)
        XCTAssertTrue(session.isFinished)
    }

    func testForgottenLowersMasteryAndDoesNotGoBelowZero() {
        var session = VocabularyReviewSession(entries: [entry("apple", mastery: 0)], now: now)
        let outcome = session.grade(remembered: false, now: now)
        XCTAssertEqual(outcome?.masteryAfter, 0, "掌握度保底 0，不出现负数")
        XCTAssertEqual(outcome?.masteryDelta, 0)
    }

    /// 「忘了」之后**掌握度归零的词当天还会到期** —— 这是间隔重复的本意，
    /// 也是「复习完待复习数字没变」的正当理由，必须算在结算里如实说出来。
    func testForgottenWordStillDueTodayOnlyWhenMasteryHitsZero() {
        var dropToZero = VocabularyReviewSession(entries: [entry("a", mastery: 1, reviewedDaysAgo: 2)], now: now)
        let zero = dropToZero.grade(remembered: false, now: now)
        XCTAssertEqual(zero?.masteryAfter, 0)
        XCTAssertEqual(zero?.stillDue, true, "掌握度 0 → 间隔 0 天 → 今天还到期")

        var staysPositive = VocabularyReviewSession(entries: [entry("b", mastery: 3, reviewedDaysAgo: 5)], now: now)
        let positive = staysPositive.grade(remembered: false, now: now)
        XCTAssertEqual(positive?.masteryAfter, 2)
        XCTAssertEqual(positive?.stillDue, false, "掌握度还有 2 → 间隔 2 天 → 今天不再出现")
    }

    func testRememberedWordLeavesTheDueQueue() {
        var session = VocabularyReviewSession(entries: [entry("a", mastery: 0)], now: now)
        let outcome = session.grade(remembered: true, now: now)
        XCTAssertEqual(outcome?.stillDue, false, "记住了：下次明天见，今天不必再来一遍")
    }

    func testGradingPastTheEndIsANoOp() {
        var session = VocabularyReviewSession(entries: [entry("a")], now: now)
        session.grade(remembered: true, now: now)
        XCTAssertNil(session.grade(remembered: true, now: now), "走完就没有当前卡了")
        XCTAssertEqual(session.outcomes.count, 1, "多按一次不能凭空多一条记录")
    }

    func testEmptyQueueIsFinishedWithNothingToDo() {
        let session = VocabularyReviewSession(entries: [], now: now)
        XCTAssertTrue(session.isFinished)
        XCTAssertNil(session.current)
        XCTAssertEqual(session.progress, 1, "没活可干 = 已完成，不能显示成 0%")
        XCTAssertEqual(session.summary.total, 0)
        XCTAssertTrue(session.summary.headline.contains("没有到期"), "如实说没有到期的词")
    }

    func testProgressTracksReviewedCount() {
        var session = VocabularyReviewSession(entries: [entry("a"), entry("b")], now: now)
        XCTAssertEqual(session.progress, 0, accuracy: 0.0001)
        session.grade(remembered: true, now: now)
        XCTAssertEqual(session.progress, 0.5, accuracy: 0.0001)
        session.grade(remembered: false, now: now)
        XCTAssertEqual(session.progress, 1, accuracy: 0.0001)
        XCTAssertEqual(session.remaining, 0)
    }

    // MARK: - ④ 结算

    func testSummaryCountsRememberedAndForgotten() {
        var session = VocabularyReviewSession(
            entries: [entry("a", mastery: 1, reviewedDaysAgo: 2), entry("b"), entry("c")],
            now: now
        )
        session.grade(remembered: true, now: now)
        session.grade(remembered: true, now: now)
        session.grade(remembered: false, now: now)

        let summary = session.summary
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.remembered, 2)
        XCTAssertEqual(summary.forgotten, 1)
        XCTAssertEqual(summary.accuracyPercent, 67, "2/3 → 67%")
        XCTAssertEqual(summary.stillDue, 1, "只有归零的那个今天还到期")
        XCTAssertTrue(summary.headline.contains("3 个词"), "标题要报出这一轮的规模：\(summary.headline)")
    }

    /// 朗读分只统计**真读过**的卡；没读的卡不按 0 分算进平均。
    func testSummaryAveragesOnlyCardsThatWereActuallySpoken() {
        var session = VocabularyReviewSession(entries: [entry("a"), entry("b")], now: now)
        session.grade(remembered: true, pronunciationScore: 80, phonemeSource: .inference, now: now)
        session.grade(remembered: true, now: now)

        let summary = session.summary
        XCTAssertEqual(summary.spokenCount, 1)
        XCTAssertEqual(summary.averagePronunciationPercent, 80)
        XCTAssertTrue(summary.hasSpokenData)
    }

    func testNoSpokenDataMeansNoPronunciationNumber() {
        var session = VocabularyReviewSession(entries: [entry("a")], now: now)
        session.grade(remembered: true, now: now)
        XCTAssertNil(session.summary.averagePronunciation, "一次都没读 → 不给朗读分，而不是给 0 分")
        XCTAssertFalse(session.summary.hasSpokenData)
    }

    /// 规则推断的音素明细**必须自报家门**（推断 ≠ 声学实测）。
    func testSummaryFlagsInferredChannelHonestly() {
        var session = VocabularyReviewSession(entries: [entry("a"), entry("b")], now: now)
        session.grade(remembered: true, pronunciationScore: 70, phonemeSource: .inference, now: now)
        session.grade(remembered: true, pronunciationScore: 70, phonemeSource: .acoustic, now: now)

        let summary = session.summary
        XCTAssertEqual(summary.inferredCount, 1, "只有走推断的那一张算推断")
        XCTAssertTrue(summary.detail.contains("推断"), "结算文字要说明「不是声学实测」")
        XCTAssertTrue(summary.detail.contains("2 个"), "朗读只算读过的：\(summary.detail)")
    }

    func testDetailSaysForgottenWordsAreStillDue() {
        var session = VocabularyReviewSession(entries: [entry("a", mastery: 0)], now: now)
        session.grade(remembered: false, now: now)
        XCTAssertTrue(
            session.summary.detail.contains("待复习"),
            "必须解释「复习完了为什么还有到期」：\(session.summary.detail)"
        )
    }

    func testDetailStaysQuietWhenThereIsNothingToSay() {
        var session = VocabularyReviewSession(entries: [entry("a")], now: now)
        session.grade(remembered: true, now: now)
        XCTAssertTrue(session.summary.detail.isEmpty, "没事可说就不要凑一句话：\(session.summary.detail)")
    }

    // MARK: - ⑤ 朗读分绝不替学员判分

    /// 这一条是整块功能的价值底线：**会读 ≠ 记得意思**。
    /// 哪怕朗读只有 15 分，学员按了「认识」就得记「认识」。
    func testSpokenScoreNeverOverridesTheLearnersGrade() {
        var session = VocabularyReviewSession(entries: [entry("a")], now: now)
        let outcome = session.grade(
            remembered: true, pronunciationScore: 15, phonemeSource: .inference, now: now
        )
        XCTAssertEqual(outcome?.remembered, true, "朗读分低不能把人判成「忘了」")
        XCTAssertEqual(outcome?.masteryAfter, 1, "掌握度按学员自己按的那个走")
        XCTAssertEqual(outcome?.pronunciationScore, 15, "朗读分照记，只作参考")
    }

    func testSpokenScoreIsRecordedEvenWhenTheLearnerForgot() {
        var session = VocabularyReviewSession(entries: [entry("a", mastery: 2, reviewedDaysAgo: 5)], now: now)
        let outcome = session.grade(
            remembered: false, pronunciationScore: 92, phonemeSource: .acoustic, now: now
        )
        XCTAssertEqual(outcome?.remembered, false, "读得再准，忘了就是忘了")
        XCTAssertEqual(outcome?.masteryAfter, 1)
        XCTAssertEqual(outcome?.pronunciationScore, 92)
        XCTAssertEqual(outcome?.phonemeSource, .acoustic)
    }
}
