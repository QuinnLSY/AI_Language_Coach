import AIDomain
@testable import AIDomain
import Foundation
import XCTest

/// ③ AI 课程挂到大树（领域层）：并进关卡表 / 排在正文之上 / 星星与状态留着 / 删课撤格。
///
/// 纯函数，不碰 IO、不碰 UI —— 树上的**几何**由 `TreeCanvas` 那套算式负责，
/// 这里只保证「进表」这件事是对的。
final class CourseTreeTests: XCTestCase {

    // MARK: - 夹具

    private func course(
        _ id: String,
        lessonTitles: [String],
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> CourseBlueprint {
        CourseBlueprint(
            id: id,
            title: "Course \(id)",
            titleZh: "课 \(id)",
            focus: "盯住时态",
            targetLevel: .b1,
            rationale: "现在 B1",
            createdAt: createdAt,
            lessons: lessonTitles.enumerated().map { index, title in
                CourseLesson(
                    id: "\(id)-l\(index + 1)",
                    order: index + 1,
                    title: title,
                    titleZh: title,
                    goal: "practice \(index + 1)",
                    scenario: Scenario(
                        id: "\(id)-l\(index + 1)",
                        title: title,
                        titleZh: title,
                        category: CourseBlueprintRule.category,
                        difficulty: 3,
                        level: "B1",
                        objective: "practice \(index + 1)",
                        aiRole: "barista",
                        learnerRole: "customer",
                        opening: "Hi there!",
                        targetSentences: ["Could I get a latte?", "Does it cost extra?"],
                        origin: .course
                    )
                )
            }
        )
    }

    private var seed: LearnerProgress { .seed() }

    // MARK: - 并进关卡表

    func testMergingOneCourseAppendsOneLevelPerLesson() {
        let merged = CourseTreeRule.merge(
            progress: seed,
            courses: [course("course-a", lessonTitles: ["点单", "结账"])]
        )
        XCTAssertEqual(merged.levels.count, seed.levels.count + 2, "一节课 = 一格")
        let added = merged.levels.suffix(2)
        XCTAssertEqual(added.map(\.title), ["点单", "结账"])
        XCTAssertEqual(added.map(\.subtitle), ["课 course-a", "课 course-a"], "副标题写清它属于哪条课")
        XCTAssertEqual(added.map(\.scenarioID), ["course-a-l1", "course-a-l2"],
                       "必须挂回情景 id —— 树上点它才开得起来")
        XCTAssertEqual(added.map(\.requiredStars), [CourseTreeRule.requiredStars, CourseTreeRule.requiredStars])
        XCTAssertEqual(added.map(\.earnedStars), [0, 0])
    }

    /// ⚠️ 这条是 #492 的核心：正文 8 关最高 0.92，课程那几节必须在它**之上**。
    func testCourseLevelsSitAboveTheHighestBuiltInLevel() {
        let builtInTop = seed.levels.map(\.heightFraction).max() ?? 0
        XCTAssertLessThan(builtInTop, 1.0, "正文关卡不得越过 1.0 —— 那正是「之上」的判据")

        let merged = CourseTreeRule.merge(
            progress: seed,
            courses: [course("course-a", lessonTitles: ["一", "二", "三"])]
        )
        for level in merged.levels where level.isAboveCurriculum {
            XCTAssertGreaterThan(level.heightFraction, builtInTop)
        }
        XCTAssertEqual(merged.levels.filter(\.isAboveCurriculum).count, 3)
        XCTAssertFalse(seed.levels.contains(where: \.isAboveCurriculum), "内置关卡一格都不许被挪上去")
    }

    /// 多条课的高度必须**连着排**：各自从 1.08 起会叠在同一高度上。
    func testHeightsAreAssignedAcrossAllCoursesSoTheyNeverStack() {
        let older = course("course-old", lessonTitles: ["A1", "A2", "A3"],
                           createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = course("course-new", lessonTitles: ["B1", "B2"],
                           createdAt: Date(timeIntervalSince1970: 2_000))
        let merged = CourseTreeRule.merge(progress: seed, courses: [newer, older])
        let heights = merged.levels.filter(\.isAboveCurriculum).map(\.heightFraction)
        XCTAssertEqual(heights.count, 5)
        XCTAssertEqual(heights, heights.sorted(), "旧的课在下、新的紧贴树冠")
        XCTAssertEqual(Set(heights).count, 5, "高度不能重复 —— 重复就是两格叠在一起")
        XCTAssertEqual(heights.first, CourseTreeRule.height(index: 0))
        XCTAssertEqual(heights.last, CourseTreeRule.height(index: 4))
        // 左右交错，避免全挤在一侧。
        let branches = merged.levels.filter(\.isAboveCurriculum).map(\.branch)
        XCTAssertEqual(branches, [.left, .right, .left, .right, .left])
    }

    // MARK: - 重排 / 重启：星星与状态必须接得上

    func testStarsAndStateSurviveAMerge() {
        let target = course("course-a", lessonTitles: ["点单", "结账"])
        let first = CourseTreeRule.merge(progress: seed, courses: [target])
        var earned = first
        let index = try? XCTUnwrap(earned.levels.firstIndex { $0.scenarioID == "course-a-l1" })
        XCTAssertNotNil(index)
        earned.levels[index!].earnedStars = 2
        earned.levels[index!].state = .inProgress
        earned.levels[index!].subtitle = "旧文案"

        // 重排（模型给了不一样的标题）+ 重启（从库里读回来的那份）。
        let regenerated = course("course-a", lessonTitles: ["开口点单", "结账离店"])
        let second = CourseTreeRule.merge(progress: earned, courses: [regenerated])

        let merged = try? XCTUnwrap(second.levels.first { $0.scenarioID == "course-a-l1" })
        XCTAssertNotNil(merged)
        XCTAssertEqual(merged?.earnedStars, 2, "星星是学员练出来的，重排不许清零")
        XCTAssertEqual(merged?.state, .inProgress)
        XCTAssertEqual(merged?.title, "开口点单", "文案要跟着新一节走")
        XCTAssertEqual(merged?.subtitle, "课 course-a", "副标题要刷回最新课名")
        XCTAssertEqual(second.levels.filter(\.isAboveCurriculum).count, 2, "重排不该多出格子")
    }

    func testMergingIsIdempotent() {
        let target = course("course-a", lessonTitles: ["一", "二"])
        let once = CourseTreeRule.merge(progress: seed, courses: [target])
        let twice = CourseTreeRule.merge(progress: once, courses: [target])
        XCTAssertEqual(once.levels.map(\.id), twice.levels.map(\.id), "重复跑不许多出格子")
        XCTAssertEqual(once.totalStars, twice.totalStars)
        XCTAssertEqual(once.climbFraction, twice.climbFraction)
    }

    // MARK: - 删课

    func testDeletingACourseRemovesItsLevelsButKeepsTheBuiltInOnes() {
        let merged = CourseTreeRule.merge(
            progress: seed,
            courses: [course("course-a", lessonTitles: ["一", "二"])]
        )
        let emptied = CourseTreeRule.merge(progress: merged, courses: [])
        XCTAssertEqual(emptied.levels.map(\.id), seed.levels.map(\.id), "正文那一段一根手指都不动")
        XCTAssertEqual(emptied.levels.count, seed.levels.count)
    }

    func testDroppingOneCourseKeepsTheOther() {
        let first = course("course-a", lessonTitles: ["A1", "A2"])
        let second = course("course-b", lessonTitles: ["B1"], createdAt: Date(timeIntervalSince1970: 2_000))
        let merged = CourseTreeRule.merge(progress: seed, courses: [first, second])
        XCTAssertEqual(merged.levels.filter(\.isAboveCurriculum).count, 3)

        let afterDelete = CourseTreeRule.merge(progress: merged, courses: [second])
        let remaining = afterDelete.levels.filter(\.isAboveCurriculum)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.scenarioID, "course-b-l1")
        XCTAssertEqual(afterDelete.levels.filter { !$0.isAboveCurriculum }.count, seed.levels.count)
    }

    /// 重排后少了一节 → 那一格要撤掉，而不是留一个点不开的孤儿。
    func testShrinkingACourseRemovesTheExtraLevel() {
        let three = course("course-a", lessonTitles: ["一", "二", "三"])
        let merged = CourseTreeRule.merge(progress: seed, courses: [three])
        let shrunk = CourseTreeRule.merge(
            progress: merged,
            courses: [course("course-a", lessonTitles: ["一", "二"])]
        )
        XCTAssertEqual(shrunk.levels.filter(\.isAboveCurriculum).count, 2)
        XCTAssertFalse(shrunk.levels.contains { $0.scenarioID == "course-a-l3" })
    }

    // MARK: - 汇总与取数

    /// 用户口径：课程关卡的星**一样计入**总星数与爬树进度。
    func testCourseStarsCountIntoTotalAndClimb() {
        var merged = CourseTreeRule.merge(
            progress: seed,
            courses: [course("course-a", lessonTitles: ["一", "二"])]
        )
        let before = merged.climbFraction
        for index in merged.levels.indices where merged.levels[index].isAboveCurriculum {
            merged.levels[index].earnedStars = merged.levels[index].requiredStars
        }
        merged.recalculateSummary()

        let courseStars = merged.levels.filter(\.isAboveCurriculum).reduce(0) { $0 + $1.earnedStars }
        XCTAssertEqual(courseStars, CourseTreeRule.requiredStars * 2)
        XCTAssertEqual(merged.totalStars, seed.levels.reduce(0) { $0 + $1.earnedStars } + courseStars)
        XCTAssertGreaterThan(merged.climbFraction, before, "练完课程关卡，爬树进度要涨")
    }

    /// 新课程关卡初始态是 `.unlocked` 而不是 `.inProgress` ——
    /// 否则 `currentLevelID` 会从正文那一格跳到树冠之上（开屏定位跟着跳）。
    func testAFreshCourseLevelNeverClaimsToBeTheCurrentLevel() {
        let merged = CourseTreeRule.merge(
            progress: seed,
            courses: [course("course-a", lessonTitles: ["一", "二"])]
        )
        XCTAssertEqual(merged.currentLevelID, seed.currentLevelID,
                       "排完课不能让树自己换「正在学」的那一格")
        XCTAssertTrue(merged.levels.filter(\.isAboveCurriculum).allSatisfy { $0.state == .unlocked })
    }

    func testLevelsOfCourseFindsEveryLessonInOrder() throws {
        let target = course("course-a", lessonTitles: ["一", "二", "三"])
        let merged = CourseTreeRule.merge(progress: seed, courses: [target])
        let found = CourseTreeRule.levels(of: target, in: merged)
        XCTAssertEqual(found.map(\.scenarioID), ["course-a-l1", "course-a-l2", "course-a-l3"])
        XCTAssertEqual(found.map(\.id), target.lessons.map { CourseTreeRule.levelID(for: $0.id) })
    }

    // MARK: - 画布高度

    /// 没有课程关卡时**必须**是 1.0：滚动锚点与开屏定位都读它。
    func testCanvasTopFractionOnlyGrowsWithCourses() {
        XCTAssertEqual(CourseTreeRule.canvasTopFraction(seed), 1.0)
        let merged = CourseTreeRule.merge(
            progress: seed,
            courses: [course("course-a", lessonTitles: ["一", "二"])]
        )
        XCTAssertEqual(CourseTreeRule.canvasTopFraction(merged), CourseTreeRule.height(index: 1) + 0.08)
        XCTAssertGreaterThan(CourseTreeRule.canvasTopFraction(merged), 1.0)
    }

    // MARK: - 稳定 id

    func testLevelIDIsStableAndDistinctPerLesson() {
        XCTAssertEqual(CourseTreeRule.levelID(for: "course-a-l1"), CourseTreeRule.levelID(for: "course-a-l1"))
        XCTAssertNotEqual(CourseTreeRule.levelID(for: "course-a-l1"), CourseTreeRule.levelID(for: "course-a-l2"))
        XCTAssertTrue(CourseTreeRule.levelID(for: "course-a-l1").hasPrefix("course-level-"))
    }

    // MARK: - 高度步长与分支（纯算式）

    func testHeightAndBranchAreDeterministic() {
        XCTAssertEqual(CourseTreeRule.height(index: 0), 1.08)
        XCTAssertEqual(CourseTreeRule.height(index: 1), 1.08 + 0.12, accuracy: 1e-9)
        XCTAssertEqual(CourseTreeRule.height(index: -3), 1.08, "负下标不许算出树冠之下")
        XCTAssertEqual(CourseTreeRule.branch(index: 0), .left)
        XCTAssertEqual(CourseTreeRule.branch(index: 1), .right)
    }
}
