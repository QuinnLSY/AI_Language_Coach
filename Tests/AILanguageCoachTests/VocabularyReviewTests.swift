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
        // 顺序按到期时刻：overdue 的到期时刻 = 5 天前 + 4 天间隔 = 昨天；
        // fresh 是新词，到期时刻 = 收录时刻（最晚）→ 排后面。
        XCTAssertEqual(session.queue.map(\.word), ["overdue", "fresh"], "不到期的词绝不能进队列")
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

    func testQueueOrdersByDueTimeThenAlphabetical() {
        // banana / apple：mastery 2 → 间隔 2 天，10 天前复习 → 到期时刻 = 8 天前。
        // cherry：mastery 1 → 间隔 1 天，1 天前复习 → 到期时刻 = 刚刚到期（最晚）。
        let entries = [
            entry("banana", mastery: 2, reviewedDaysAgo: 10),
            entry("apple", mastery: 2, reviewedDaysAgo: 10),
            entry("cherry", mastery: 1, reviewedDaysAgo: 1)
        ]
        let queue = VocabularyReviewSession.queue(from: entries, now: now)
        XCTAssertEqual(
            queue.map(\.word), ["apple", "banana", "cherry"],
            "按到期时刻升序：欠得最久的先来，同样到期时刻按字母序兜底（顺序必须确定）"
        )
    }

    /// 2026-09-24 用户报障的本体：**新词不许再霸占队首**。
    ///
    /// 老口径按 mastery 升序，新词 mastery 恒 0 → 整批新词永远排最前，
    /// 把每日任务要清的「到期单词」积压挤到队尾 —— 复习了很多词，
    /// 「复习到期单词」却迟迟完不成。新口径下今天刚收的新词必须排在
    /// 所有此前就已到期的词后面。
    func testNewlyAddedWordsQueueBehindTheOverdueBacklog() {
        // 三个老词：不同掌握度、不同复习时间，但全部在今天就到期之前就已欠着。
        let backlog = [
            entry("stale1", mastery: 3, reviewedDaysAgo: 5),  // 到期时刻 = 1 天前
            entry("stale2", mastery: 1, reviewedDaysAgo: 2),  // 到期时刻 = 1 天前
            entry("stale3", mastery: 4, reviewedDaysAgo: 9)   // 到期时刻 = 2 天前
        ]
        // 三个今天刚收的新词（createdAt 取实际现在，比测试的 now 还晚 → 排最后）。
        let newcomers = [entry("new-a"), entry("new-b"), entry("new-c")]
        let entry1 = backlog[0]
        let entry2 = backlog[1]
        let entry3 = backlog[2]
        let new1 = newcomers[0]
        let new2 = newcomers[1]
        let new3 = newcomers[2]

        let queue = VocabularyReviewSession.queue(
            from: [new1, entry1, new2, entry2, new3, entry3], now: now
        )
        let words = queue.map(\.word)
        // 前三位全是到期积压（stale3 欠得最久 → 最前；stale1/stale2 同时刻 → 字母序）。
        XCTAssertEqual(Array(words.prefix(3)), ["stale3", "stale1", "stale2"],
                       "到期积压必须先清：\(words)")
        // 新词一个都不许混进积压前面。
        XCTAssertEqual(Set(words.suffix(3)), Set(["new-a", "new-b", "new-c"]),
                       "新词排在所有到期词后面：\(words)")
    }

    /// 「到期时刻」这把尺要和 `isDue` 同源：间隔没到 = 排不到期积压里。
    func testDueTimeMatchesIsDueSemantics() {
        let notYet = entry("later", mastery: 3, reviewedDaysAgo: 1) // 间隔 4 天 → 3 天后才到期
        XCTAssertTrue(ReviewScheduler.dueTime(for: notYet) > now, "没到期的词，到期时刻在未来")
        let overdue = entry("early", mastery: 3, reviewedDaysAgo: 5)
        XCTAssertTrue(ReviewScheduler.dueTime(for: overdue) < now, "欠着的词，到期时刻在过去")
        let fresh = entry("fresh")
        XCTAssertEqual(ReviewScheduler.dueTime(for: fresh), fresh.createdAt,
                       "新词的到期时刻就是收录时刻")
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

    // MARK: - ⑥ 复习途中查到的释义要立刻回到这张卡上

    /// 队列里存的是词条的**值拷贝**：查释义改的是词表那份数据，
    /// 不回填这一张，用户翻面看到的还是「这个词还没有释义」—— 查了等于没查。
    func testUpdateCurrentPutsTheFreshDefinitionOnTheCard() throws {
        var session = VocabularyReviewSession(entries: [entry("apple"), entry("banana")], now: now)
        let current = try XCTUnwrap(session.current)
        XCTAssertTrue(current.meaning.isEmpty)

        var defined = current
        defined.meaning = "n. 苹果"
        session.updateCurrent(defined)

        XCTAssertEqual(session.current?.meaning, "n. 苹果", "查到的释义必须回到卡上")
        XCTAssertEqual(session.current?.id, current.id, "换的是内容，不是换了一张卡")
    }

    func testUpdateCurrentDoesNotTouchTheRestOfTheQueue() throws {
        var session = VocabularyReviewSession(entries: [entry("apple"), entry("banana")], now: now)
        let current = try XCTUnwrap(session.current)
        var defined = current
        defined.meaning = "n. 苹果"
        session.updateCurrent(defined)

        XCTAssertEqual(session.queue.map(\.word), ["apple", "banana"], "队列顺序属于这一轮，不能被改写")
        XCTAssertEqual(session.queue[1].meaning, "", "排在后面的卡还没查到，不该被顺手填上")
        XCTAssertEqual(session.reviewed, 0, "换资料不等于判过分")
        XCTAssertEqual(session.total, 2)
    }

    /// 只认当前这一张：拿别的词条来换（或这一轮已经走完）一律不动。
    func testUpdateCurrentIgnoresAnythingButTheCurrentCard() throws {
        var session = VocabularyReviewSession(entries: [entry("apple"), entry("banana")], now: now)
        let current = try XCTUnwrap(session.current)

        var other = entry("banana")
        other.meaning = "n. 香蕉"
        session.updateCurrent(other)
        XCTAssertTrue(session.current?.meaning.isEmpty == true, "别的词条不能顶替当前这张")

        session.grade(remembered: true, now: now)
        session.grade(remembered: true, now: now)
        XCTAssertTrue(session.isFinished)
        let finished = session
        var late = current
        late.meaning = "n. 苹果"
        session.updateCurrent(late)
        XCTAssertEqual(session, finished, "走完的一轮不该被改写")
    }
}
