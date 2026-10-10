import AIDomain
import XCTest
@testable import AppUI

/// 年轮徽记（#418-B）单测：把「近一年练了多少」物化进风景的判据。
///
/// 全部纯函数 + 装配哨兵，不碰数据库。
final class TreeRingsTests: XCTestCase {

    // MARK: - ① 圈数

    func testRingCountGrowsEveryThirtyDaysAndCapsAtSix() {
        XCTAssertEqual(TreeRings.ringCount(practicedDays: 0), 0, "没练过就没有年轮")
        XCTAssertEqual(TreeRings.ringCount(practicedDays: 29), 0, "不满 30 天不长圈")
        XCTAssertEqual(TreeRings.ringCount(practicedDays: 30), 1)
        XCTAssertEqual(TreeRings.ringCount(practicedDays: 179), 5)
        XCTAssertEqual(TreeRings.ringCount(practicedDays: 180), 6)
        XCTAssertEqual(TreeRings.ringCount(practicedDays: 400), 6, "封顶 6 圈 —— 再多就糊成一团")
    }

    // MARK: - ② 火苗与存在性

    func testFlameNeedsThreeDayStreak() {
        XCTAssertFalse(TreeRings.showsFlame(longestStreak: 0))
        XCTAssertFalse(TreeRings.showsFlame(longestStreak: 2))
        XCTAssertTrue(TreeRings.showsFlame(longestStreak: 3))
        XCTAssertTrue(TreeRings.showsFlame(longestStreak: 30))
    }

    func testEmblemIsHiddenUntilTheFirstPracticeDay() {
        XCTAssertFalse(TreeRings.showsEmblem(practicedDays: 0), "全年没练就别画徽记（树根等第一天）")
        XCTAssertTrue(TreeRings.showsEmblem(practicedDays: 1))
    }

    // MARK: - ③ 读屏文案

    func testAccessibilityLabelSpeaksDaysAndStreak() {
        XCTAssertNil(TreeRings.accessibilityLabel(practicedDays: 0, longestStreak: 0),
                     "没练过 → 徽记不存在，不该多出一个无内容的读屏节点")
        XCTAssertEqual(TreeRings.accessibilityLabel(practicedDays: 45, longestStreak: 0),
                       "近一年练习 45 天")
        XCTAssertEqual(TreeRings.accessibilityLabel(practicedDays: 45, longestStreak: 7),
                       "近一年练习 45 天 · 最长连续 7 天")
    }

    // MARK: - ④ 摘要映射

    /// `TreeAnnualSummary(recap:)` 必须真的取自年度记录（不是各算各的）。
    func testSummaryReadsTheAnnualRecap() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!

        func activity(daysAgo: Int) -> DailyActivity {
            let day = calendar.date(byAdding: .day, value: -daysAgo,
                                    to: calendar.startOfDay(for: now))!
            return DailyActivity(day: day, seconds: 600, messages: 2,
                                 shadowingAttempts: 0, vocabularyReviewed: 0)
        }

        // 连续 5 天（前一天断掉）：practicedDays=5、longestStreak=5。
        let days = (0..<5).map(activity(daysAgo:)) + [activity(daysAgo: 7)]
        let recap = AnnualRecapBuilder.build(days: days, now: now, calendar: calendar)
        let summary = TreeAnnualSummary(recap: recap)
        XCTAssertEqual(summary.practicedDays, recap.practicedDays)
        XCTAssertEqual(summary.longestStreak, recap.longestStreak)
        XCTAssertEqual(summary.practicedDays, 6)
        XCTAssertEqual(summary.longestStreak, 5)
    }

    // MARK: - ⑤ 位置（可见性）

    /// 徽记必须落在**林间地面带之上**。
    ///
    /// 那条 150pt 的带子是钉在视口底部的固定层（草坡不透明），画布能滚到的最后一屏里
    /// 底部 150pt 永远被它压住 —— 画在那后面等于没画。而第一圈年轮要练满 30 天才出现，
    /// 那时视口必然停在半空，于是「练了一整年，树根什么都没有」。
    func testEmblemSitsAboveTheGroundBand() {
        let canvasHeight = TreeCanvas.canvasHeight(for: .seed())
        let y = TreeRings.emblemY(canvasHeight: canvasHeight)
        XCTAssertLessThan(y, canvasHeight - TreeViewport.groundBandHeight,
                          "徽记画在林带遮住区里就永远看不见")
        XCTAssertGreaterThan(y, 0)
        // 也要躲开最低那一格关卡节点（不然徽记压在节点上）。
        XCTAssertLessThan(y, 960)
    }

    /// ⚠️ 徽记是**按画布底边往上定位**的（`canvasHeight - 林带 - 呼吸位`），
    /// 而画布高度现在会随 AI 课程关卡数变长（③）。
    /// 反证：树长高之后徽记必须跟着下移，否则它会停在半空、压在某一节课程关卡上。
    func testEmblemFollowsTheGroundWhenTheTreeGrowsForCourses() {
        let plain = TreeCanvas.canvasHeight(for: .seed())
        let grown = TreeCanvas.canvasHeight(for: .seed().withCourseLevels(3))
        XCTAssertGreaterThan(grown, plain, "有课程关卡时画布必须变长（否则节点被画到画布外）")

        let plainY = TreeRings.emblemY(canvasHeight: plain)
        let grownY = TreeRings.emblemY(canvasHeight: grown)
        XCTAssertEqual(grownY - plainY, grown - plain, accuracy: 0.001,
                       "徽记要贴着地面一起下移（它标的是「树根」那一圈年轮）")
        XCTAssertLessThan(grownY, grown - TreeViewport.groundBandHeight)
    }

    // MARK: - ⑥ 装配哨兵

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 树只吃摘要，不自己找年度数据；年度数据在树面板到场后后台补拉（不占启动关键路径）。
    func testMainViewFeedsTheSummaryAndLoadsTheRecapOffCriticalPath() throws {
        let main = try source("AppUI/Views/MainView.swift")
        XCTAssertTrue(main.contains("annualSummary: state.annualTreeSummary"),
                      "树面板必须从 AppState 拿摘要")
        XCTAssertTrue(main.contains("await state.ensureAnnualRecapLoaded()"),
                      "树面板到场后必须补拉年度汇总（幂等，不重复查询）")
        let scroll = try source("AppUI/Components/TreeScrollView.swift")
        XCTAssertTrue(scroll.contains("annualSummary: annualSummary"),
                      "TreeScrollView 必须把摘要透传给 TreeCanvas")
    }
}

// MARK: - 夹具：给进度并上 n 个 AI 课程关卡（③）

extension LearnerProgress {

    /// 走**真实的** `CourseTreeRule.merge` 并上 n 个课程关卡。
    ///
    /// ⚠️ 不要在手搓 `TreeLevel(heightFraction: 1.08…)` 来测树的课程几何 ——
    /// 那样测的是「我以为的高度」，不是产品真正并进来的高度。
    func withCourseLevels(_ count: Int) -> LearnerProgress {
        let course = CourseBlueprint(
            id: "course-fixture",
            title: "Fixture course",
            titleZh: "夹具课",
            focus: "",
            targetLevel: .b1,
            rationale: "",
            lessons: (1...max(count, 1)).map { index in
                let id = "course-fixture-l\(index)"
                return CourseLesson(
                    id: id,
                    order: index,
                    title: "Lesson \(index)",
                    titleZh: "第\(index)节",
                    goal: "",
                    scenario: Scenario(
                        id: id,
                        title: "Lesson \(index)",
                        titleZh: "第\(index)节",
                        category: CourseBlueprintRule.category,
                        difficulty: 3,
                        level: "B1",
                        objective: "",
                        aiRole: "barista",
                        learnerRole: "customer",
                        opening: "Hi there!",
                        targetSentences: ["Could I get a latte?", "Does it cost extra?"],
                        origin: .course
                    )
                )
            }
        )
        return CourseTreeRule.merge(progress: self, courses: [course])
    }
}
