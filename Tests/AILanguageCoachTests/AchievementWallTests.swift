import AIDomain
import XCTest

/// ⑦-C② 成就墙的纯规则。
///
/// 三条纪律各钉一条：
/// ① 只数累计量（不会回退 → 成就不会「昨天亮今天灰」）；
/// ② 未达成只摆最接近的几条（一堵灰墙只会让人想关 App）；
/// ③ 已经达成的那格不许再写「还差 0」。
final class AchievementWallTests: XCTestCase {

    private func snapshot(
        messages: Int = 0,
        seconds: TimeInterval = 0,
        mastered: Int = 0,
        collected: Int = 0,
        shadowing: Int = 0,
        stars: Int = 0
    ) -> ProgressSnapshot {
        ProgressSnapshot(
            today: DailyActivity(day: Date(), seconds: 0, messages: 0),
            totalSeconds: seconds,
            totalMessages: messages,
            totalStars: stars,
            vocabulary: VocabularyStats(
                total: collected, due: 0, mastered: mastered, defined: 0,
                dueAtDayStart: 0, dueAtDayStartReviewed: 0
            ),
            shadowing: ShadowingStats(attempts: shadowing, bestAccuracy: 0,
                                      averageAccuracy: 0, lastAccuracy: nil)
        )
    }

    // MARK: - 达成判定

    func testNothingIsUnlockedOnAnEmptyHistory() {
        let items = AchievementWall.all(snapshot: snapshot())
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { !$0.isUnlocked })
        XCTAssertEqual(AchievementWall.display(snapshot: snapshot()).count,
                       AchievementWall.previewLimit,
                       "一条都没达成时，墙上只摆最接近的三条")
    }

    /// 差一个就不算达成（判据不许写成 `>=` 之外的样子）。
    func testOneShortIsStillLocked() {
        let item = Achievement(id: "x", title: "开口 50 句", unit: "句", current: 49, target: 50)
        XCTAssertFalse(item.isUnlocked)
        XCTAssertEqual(item.remaining, 1)
        XCTAssertEqual(item.remainingText, "还差 1 句")
        XCTAssertEqual(Achievement(id: "x", title: "", unit: "句", current: 50, target: 50).isUnlocked, true)
    }

    /// 已达成那格**不写「还差 0 句」**。
    func testUnlockedTileStopsReportingRemaining() {
        let item = Achievement(id: "x", title: "开口 50 句", unit: "句", current: 80, target: 50)
        XCTAssertNil(item.remainingText)
        XCTAssertEqual(item.remaining, 0)
        XCTAssertEqual(item.progress, 1, accuracy: 0.001, "超出的部分按满格算，不许画出 160% 的进度条")
    }

    // MARK: - 只摆最接近的几条

    /// 已达成**全部**列出来，未达成只补最接近的三条。
    func testDisplayShowsEveryUnlockedPlusTheNearestFew() {
        let snap = snapshot(messages: 60, seconds: 90 * 60, mastered: 40)
        let all = AchievementWall.all(snapshot: snap)
        let shown = AchievementWall.display(snapshot: snap)

        let unlocked = all.filter(\.isUnlocked)
        XCTAssertFalse(unlocked.isEmpty)
        XCTAssertEqual(shown.filter(\.isUnlocked).count, unlocked.count, "已达成的全部上榜")
        XCTAssertEqual(shown.filter { !$0.isUnlocked }.count,
                       min(AchievementWall.previewLimit, all.count - unlocked.count))
        // 已达成在前：一眼先看见做到的，而不是先看见没做到的。
        XCTAssertTrue(shown.prefix(unlocked.count).allSatisfy(\.isUnlocked))
    }

    /// 未达成那几条按**最接近**排（进度高在前）。
    func testNearestLockedIsSortedByProgressDescending() {
        // 开口 500 句（120/500=0.24）比 跟读 50 次（3/50=0.06）近，
        // 掌握 100 个词（45/100=0.45）又比它俩都近。
        let snap = snapshot(messages: 120, mastered: 45, shadowing: 3)
        let nearest = AchievementWall.nearestLocked(snapshot: snap)
        XCTAssertEqual(nearest.map(\.id), ["mastered.100", "talk.500", "shadow.50"])
    }

    /// 同进度时按清单顺序（结果可复现，不随字典序/哈希抖动）。
    func testTiesFallBackToTheChecklistOrder() {
        let snap = snapshot()
        let nearest = AchievementWall.nearestLocked(snapshot: snap)
        let all = AchievementWall.all(snapshot: snap)
        let ids = Set(nearest.map(\.id))
        XCTAssertTrue(nearest.map(\.id).allSatisfy { ids.contains($0) })
        // 全 0 时三条必须是清单里最靠前的三条（顺序稳定，重跑一致）。
        XCTAssertEqual(nearest.map(\.id), all.prefix(AchievementWall.previewLimit).map(\.id))
    }

    // MARK: - 墙头那行

    func testHeadlineNamesTheNextOne() {
        let snap = snapshot(messages: 38)
        let text = AchievementWall.headline(snapshot: snap)
        XCTAssertTrue(text.contains("开口 50 句"), "墙头要点出下一个是什么")
        XCTAssertTrue(text.contains("还差 12 句"), "差多少要插真值，不能写死")
    }

    /// 全解锁之后**不再挂「还差」** —— 那句话会永远兑现不了，变成假预告。
    func testHeadlineStopsPreviewingWhenEverythingIsUnlocked() {
        let snap = snapshot(messages: 900, seconds: 700 * 60, mastered: 200,
                            collected: 300, shadowing: 90, stars: 60)
        XCTAssertTrue(AchievementWall.all(snapshot: snap).allSatisfy(\.isUnlocked))
        XCTAssertEqual(AchievementWall.headline(snapshot: snap), "9/9 项已解锁")
        XCTAssertFalse(AchievementWall.headline(snapshot: snap).contains("还差"))
    }
}
