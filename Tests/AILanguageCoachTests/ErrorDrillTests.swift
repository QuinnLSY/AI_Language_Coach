import AIDomain
import XCTest

/// 改错练习（把「记住的错」变成「练过的错」）：队列 / 判定 / 连对账本。
///
/// 全部是纯函数 —— 判定不发起任何模型请求，才能把这些口径钉死在测试里。
final class ErrorDrillTests: XCTestCase {

    private func makeError(
        original: String = "I have gone to Paris",
        corrected: String = "I have been to Paris",
        explanation: String = "去过用 been",
        count: Int = 3
    ) -> RecurringError {
        RecurringError(
            original: original, corrected: corrected,
            explanation: explanation, count: count, lastSeen: Date()
        )
    }

    // MARK: - 队列

    func testQueueSkipsConqueredErrors() {
        let first = makeError(original: "a1", corrected: "a2")
        let second = makeError(original: "b1", corrected: "b2")
        let session = ErrorDrillSession(errors: [first, second], mastered: [first.id])
        XCTAssertEqual(session.queue.map(\.id), [second.id], "已攻克的不再进队列")
    }

    /// 队列**沿用检索层排好的顺序**，不自己再排一遍。
    func testQueueKeepsRetrieverOrderAndCapsAtLimit() {
        let errors = (0..<8).map { makeError(original: "o\($0)", corrected: "c\($0)") }
        let session = ErrorDrillSession(errors: errors, limit: 3)
        XCTAssertEqual(session.queue.map(\.original), ["o0", "o1", "o2"])
    }

    // MARK: - 判定

    /// 判的是「语法改对了没有」，大小写 / 尾随标点 / 多余空格都不该算错。
    func testMatcherIgnoresCasePunctuationAndSpacing() {
        let expected = "I have been to Paris"
        XCTAssertTrue(ErrorDrillMatcher.isCorrect(answer: "I HAVE BEEN TO PARIS", expected: expected))
        XCTAssertTrue(ErrorDrillMatcher.isCorrect(answer: "i have been to paris.", expected: expected))
        XCTAssertTrue(ErrorDrillMatcher.isCorrect(answer: "I  have   been to Paris", expected: expected))
    }

    func testMatcherRejectsBlankAndWrongAnswers() {
        let expected = "I have been to Paris"
        // ⚠️ 空答案一律判错：什么都不写不算「改对了」。
        XCTAssertFalse(ErrorDrillMatcher.isCorrect(answer: "   ", expected: expected))
        XCTAssertFalse(ErrorDrillMatcher.isCorrect(answer: "I have gone to Paris", expected: expected))
    }

    // MARK: - 连对账本

    /// 答错**清零**而不是减一：既然标准是「连对两次」，中间错一次就得从头来。
    func testStreakResetsToZeroOnMistake() {
        XCTAssertEqual(ErrorDrillProgress.streak(after: true, previous: 0), 1)
        XCTAssertEqual(ErrorDrillProgress.streak(after: false, previous: 3), 0)
        XCTAssertTrue(ErrorDrillProgress.isMastered(streak: 2))
        XCTAssertFalse(ErrorDrillProgress.isMastered(streak: 1))
    }

    /// 「本轮新攻克」只数**跨过门槛的那一次**，已经攻克过的再对一次不能重复计。
    func testAppliedCountsEachErrorAsConqueredOnlyOnce() {
        let outcome = ErrorDrillSession.Outcome(errorID: "x", answer: "ok", isCorrect: true)
        let (ledger, conquered) = ErrorDrillProgress.applied([outcome], to: ["x": 1])
        XCTAssertEqual(ledger["x"], 2)
        XCTAssertEqual(conquered, 1)

        let (_, again) = ErrorDrillProgress.applied([outcome], to: ["x": 2])
        XCTAssertEqual(again, 0, "已经攻克过的不再重复计入")
    }

    // MARK: - 一轮的流程

    func testSessionWalksThroughAndSummarises() {
        var session = ErrorDrillSession(
            errors: [makeError(original: "a", corrected: "A"), makeError(original: "b", corrected: "B")]
        )
        let first = session.submit("A")
        XCTAssertEqual(first?.isCorrect, true)
        // 判完停在上一题给回执，同时 `current` 已经是下一题。
        XCTAssertEqual(session.previous?.original, "a")
        XCTAssertEqual(session.current?.original, "b")
        XCTAssertEqual(session.progress.done, 1)

        let second = session.submit("wrong")
        XCTAssertEqual(second?.isCorrect, false)
        XCTAssertTrue(session.isFinished)
        XCTAssertNil(session.current)

        let summary = session.summary(conquered: 1)
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.correct, 1)
        XCTAssertEqual(summary.wrong, 1)
        XCTAssertEqual(summary.conquered, 1)
    }

    /// 空队列时不该有任何题，也不该崩。
    func testEmptyQueueProducesNoCards() {
        var session = ErrorDrillSession(errors: [], mastered: [])
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertTrue(session.isFinished)
        XCTAssertNil(session.submit("anything"))
        XCTAssertEqual(session.summary().total, 0)
    }
}
