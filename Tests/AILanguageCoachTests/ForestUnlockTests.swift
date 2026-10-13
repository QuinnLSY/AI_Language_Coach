import AIDomain
import XCTest

/// ⑦-C③ 森林解锁的纯规则。
///
/// ⚠️ 判据是**累计练习时长**而不是连续天数：连续天数会断，而一位伙伴来了就不许收回去。
/// 这一条要是改成按天算，断一次签林子里就少一只 —— 那是惩罚，不是激励。
final class ForestUnlockTests: XCTestCase {

    private func minutes(_ m: Int) -> TimeInterval { TimeInterval(m * 60) }

    // MARK: - 人数

    func testForestStartsWithAFewCompanions() {
        XCTAssertEqual(ForestUnlock.companions(totalSeconds: 0), ForestUnlock.baseCompanions,
                       "刚开林也是个有人住的森林，不是空地")
    }

    func testOneMoreCompanionPerThreshold() {
        XCTAssertEqual(ForestUnlock.companions(totalSeconds: minutes(24)),
                       ForestUnlock.baseCompanions, "差一分钟也不给")
        XCTAssertEqual(ForestUnlock.companions(totalSeconds: minutes(25)),
                       ForestUnlock.baseCompanions + 1)
        XCTAssertEqual(ForestUnlock.companions(totalSeconds: minutes(50)),
                       ForestUnlock.baseCompanions + 2)
    }

    /// 上限钉死：**练得再多也不会掉出物种表**（多出来的下标会取不到动物）。
    func testCompanionsNeverExceedTheSpeciesTable() {
        XCTAssertLessThanOrEqual(ForestUnlock.companions(totalSeconds: minutes(100_000)),
                                 ForestUnlock.maxCompanions)
        XCTAssertEqual(ForestUnlock.companions(totalSeconds: minutes(100_000)),
                       ForestUnlock.maxCompanions)
    }

    /// 负数时长（脏数据）不该算出负数个伙伴。
    func testNegativeDurationClampsToABase() {
        XCTAssertEqual(ForestUnlock.companions(totalSeconds: -999), ForestUnlock.baseCompanions)
    }

    // MARK: - 还差多少

    func testMinutesToNextCountsDownTowardsTheThreshold() {
        XCTAssertEqual(ForestUnlock.minutesToNext(totalSeconds: 0), ForestUnlock.minutesPerCompanion)
        XCTAssertEqual(ForestUnlock.minutesToNext(totalSeconds: minutes(24)), 1)
        XCTAssertEqual(ForestUnlock.minutesToNext(totalSeconds: minutes(25)),
                       ForestUnlock.minutesPerCompanion, "刚来一位，下一位重新起算")
    }

    /// 满员之后**不再报「还差」**：挂一句永远兑现不了的倒计时就是假话。
    func testNoCountdownOnceTheForestIsFull() {
        XCTAssertNil(ForestUnlock.minutesToNext(totalSeconds: minutes(100_000)))
        XCTAssertNil(ForestUnlock.nextIndex(totalSeconds: minutes(100_000)))
    }

    /// 下一位的下标 = 现有人数（顺序表里第 N 个就是下一个）。
    func testNextIndexFollowsTheCurrentCount() {
        XCTAssertEqual(ForestUnlock.nextIndex(totalSeconds: 0), ForestUnlock.baseCompanions)
        XCTAssertEqual(ForestUnlock.nextIndex(totalSeconds: minutes(25)),
                       ForestUnlock.baseCompanions + 1)
    }

    // MARK: - 文案

    func testPreviewNamesTheMinutesAndStopsWhenFull() {
        XCTAssertEqual(ForestUnlock.previewText(totalSeconds: minutes(7)),
                       "再练 \(ForestUnlock.minutesPerCompanion - 7) 分钟，林子里多一位伙伴")
        XCTAssertEqual(ForestUnlock.previewText(totalSeconds: minutes(100_000)),
                       "\(ForestUnlock.maxCompanions) 位伙伴都到齐了")
        XCTAssertFalse(ForestUnlock.previewText(totalSeconds: minutes(100_000)).contains("再练"))
    }

    func testHeadlineCarriesTheRealCount() {
        XCTAssertEqual(ForestUnlock.headline(totalSeconds: minutes(50)),
                       "林子里 \(ForestUnlock.baseCompanions + 2) 位伙伴")
    }
}
