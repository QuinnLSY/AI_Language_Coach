import AIDomain
import XCTest

/// ⑦-C① 限时连击的纯规则。
///
/// 钉的几件事：连击怎么涨怎么断、**超时之后判的算不算**、倒计时不许负数、
/// 以及「没开始」那几种情况的文案不许写成一次失败。
final class ReviewBlitzTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func blitz(startedAt: Date? = nil) -> ReviewBlitz {
        ReviewBlitz(startedAt: startedAt ?? start)
    }

    private func after(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    // MARK: - 计时

    func testCountdownShrinksWithWallClock() {
        var b = blitz()
        XCTAssertEqual(b.remainingSeconds(now: after(0)), ReviewBlitz.windowSeconds)
        XCTAssertEqual(b.remainingSeconds(now: after(17)), ReviewBlitz.windowSeconds - 17)
        _ = b.grade(remembered: true, now: after(17))
        XCTAssertEqual(b.elapsedSeconds(now: after(17)), 17)
    }

    /// 倒计时**下限 0**：卡一下机器不会画出「还剩 -3 秒」。
    func testRemainingNeverGoesNegative() {
        let b = blitz()
        XCTAssertEqual(b.remainingSeconds(now: after(600)), 0)
        XCTAssertTrue(b.isExpired(now: after(600)))
        XCTAssertFalse(b.isExpired(now: after(59)))
    }

    /// 时间条的比例：刚开始满、一半时半、到点为空，且**不越界**。
    func testTimeFractionStaysWithinZeroAndOne() {
        let b = blitz()
        XCTAssertEqual(b.timeFraction(now: after(0)), 1, accuracy: 0.001)
        XCTAssertEqual(b.timeFraction(now: after(30)), 0.5, accuracy: 0.001)
        XCTAssertEqual(b.timeFraction(now: after(60)), 0)
        XCTAssertEqual(b.timeFraction(now: after(999)), 0)
    }

    // MARK: - 连击

    func testComboGrowsOnRememberedAndResetsOnForgotten() {
        var b = blitz()
        _ = b.grade(remembered: true, now: after(1))
        _ = b.grade(remembered: true, now: after(2))
        XCTAssertEqual(b.combo, 2)
        XCTAssertEqual(b.bestCombo, 2)

        _ = b.grade(remembered: false, now: after(3))
        XCTAssertEqual(b.combo, 0, "忘了就断，连击不许带着上一个词往前滚")
        XCTAssertEqual(b.bestCombo, 2, "断的是当前连击，最高纪录留着")

        _ = b.grade(remembered: true, now: after(4))
        XCTAssertEqual(b.combo, 1)
        XCTAssertEqual(b.bestCombo, 2)
    }

    /// **超时之后判的那一张照常计数，但不进连击** —— 否则「早就到点了，数字还在跳」。
    func testGradesAfterExpiryCountButDoNotExtendTheCombo() {
        var b = blitz()
        XCTAssertTrue(b.grade(remembered: true, now: after(10)))
        XCTAssertTrue(b.grade(remembered: true, now: after(20)))
        XCTAssertEqual(b.combo, 2)

        XCTAssertFalse(b.grade(remembered: true, now: after(61)), "超时那一张不该进连击")
        XCTAssertEqual(b.combo, 2, "连击停在到点那一刻")
        XCTAssertEqual(b.correct, 3, "超时之后判的这个词**真的复习过了**，得记进去")
        XCTAssertEqual(b.graded, 3)
    }

    /// 超时之后答错也不许把已经到手的最高连击抹掉。
    func testMissAfterExpiryKeepsBestCombo() {
        var b = blitz()
        _ = b.grade(remembered: true, now: after(5))
        _ = b.grade(remembered: false, now: after(61))
        XCTAssertEqual(b.bestCombo, 1)
        XCTAssertEqual(b.missed, 1)
    }

    // MARK: - 文案

    func testComboTextDoesNotSayZeroAtTheStart() {
        let b = blitz()
        XCTAssertEqual(b.comboText, "答对一个就起连击",
                       "一轮还没判就写「连对 0」是把「还没开始」说成「刚开始就失败」")

        var running = blitz()
        _ = running.grade(remembered: true, now: after(1))
        XCTAssertEqual(running.comboText, "连对 1 个")
    }

    func testCountdownTextNeverShowsNegativeSeconds() {
        let b = blitz()
        XCTAssertEqual(b.countdownText(now: after(12)), "还剩 \(ReviewBlitz.windowSeconds - 12) 秒")
        XCTAssertEqual(b.countdownText(now: after(61)), "这一轮到点了")
        // 界面拿到的就是「还剩几秒」这个数，不许自己再抓一次时钟。
        XCTAssertEqual(ReviewBlitz.countdownText(remaining: 9), "还剩 9 秒")
        XCTAssertEqual(ReviewBlitz.countdownText(remaining: 0), "这一轮到点了")
        XCTAssertEqual(ReviewBlitz.countdownText(remaining: -4), "这一轮到点了")
    }

    /// 一张都没判就到点（开了复习就走开）**不写「答对 0/0」** —— 那是在给没发生过的事打分。
    func testSummaryStaysSilentWhenNothingWasGraded() {
        let b = blitz()
        XCTAssertEqual(b.summaryText, "这一轮还没开始判")
    }

    func testSummaryReportsBothCountsAndBestCombo() {
        var b = blitz()
        _ = b.grade(remembered: true, now: after(1))
        _ = b.grade(remembered: true, now: after(2))
        _ = b.grade(remembered: false, now: after(3))
        _ = b.grade(remembered: true, now: after(4))
        XCTAssertEqual(b.summaryText, "答对 3/4 个 · 最高连击 2")
    }

    /// 一张都没连起来（答一个忘一个）：那句该说「没连起来」，而不是报一个最高连击 0。
    func testSummaryAdmitsWhenNoComboWasBuilt() {
        var b = blitz()
        _ = b.grade(remembered: false, now: after(1))
        _ = b.grade(remembered: true, now: after(2))
        XCTAssertEqual(b.summaryText, "答对 1/2 个，这轮还没连起来",
                   "连对一个只叫答对一个，不叫连击")
    }

    // MARK: - 纪录

    func testRecordOnlyCountsWhenItIsReallyBeaten() {
        XCTAssertTrue(ReviewBlitzRecord.isNewRecord(best: 3, combo: 4))
        XCTAssertFalse(ReviewBlitzRecord.isNewRecord(best: 4, combo: 4), "打平不算破纪录")
        XCTAssertFalse(ReviewBlitzRecord.isNewRecord(best: 4, combo: 2))
        XCTAssertFalse(ReviewBlitzRecord.isNewRecord(best: 0, combo: 0),
                       "连击 0 不算破纪录 —— 第一次用就弹「新纪录」是在笑人")
    }
}
