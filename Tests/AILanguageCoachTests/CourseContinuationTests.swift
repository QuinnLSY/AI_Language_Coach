import AIDomain
import XCTest

/// AI 排的课随进度续排（③ 的下半截）。
///
/// ③ 排完一条课就静止了：闯完不会往下接、卡住不会降档。这一组钉住续排的两条硬边界 ——
/// **只追加、不重排已有节**（否则学员攒的星跟着 id 一起消失），
/// 以及**不该续就不续**（还有没练的节时催人跳着练，只会让课断成两截）。
final class CourseContinuationTests: XCTestCase {

    // MARK: - 夹具

    private func lesson(courseID: String, order: Int, title: String) -> CourseLesson {
        let id = "\(courseID)-l\(order)"
        return CourseLesson(
            id: id,
            order: order,
            title: title,
            titleZh: title,
            goal: "practice \(order)",
            scenario: Scenario(
                id: id,
                title: title,
                titleZh: title,
                category: CourseBlueprintRule.category,
                difficulty: 3,
                level: "B1",
                objective: "practice \(order)",
                aiRole: "barista",
                learnerRole: "customer",
                opening: "Hi there!",
                targetSentences: ["Could I get a latte?"],
                origin: .course
            )
        )
    }

    private func course(
        id: String = "course-a",
        titles: [String] = ["点单", "结账", "投诉"],
        level: CEFRLevel? = .b1
    ) -> CourseBlueprint {
        CourseBlueprint(
            id: id,
            title: "Coffee Course",
            titleZh: "咖啡店口语",
            focus: "盯住时态",
            targetLevel: level,
            rationale: "现在 B1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lessons: titles.enumerated().map { index, title in
                lesson(courseID: id, order: index + 1, title: title)
            }
        )
    }

    /// 把课并进树、再按给定的状态改那几格（续排判据读的就是树上这几格）。
    private func progress(
        for course: CourseBlueprint,
        states: [LevelState] = [],
        stars: [Int] = []
    ) -> LearnerProgress {
        var merged = CourseTreeRule.merge(progress: .seed(), courses: [course])
        let levels = CourseTreeRule.levels(of: course, in: merged)
        for (index, level) in levels.enumerated() {
            guard let at = merged.levels.firstIndex(where: { $0.id == level.id }) else { continue }
            if index < states.count { merged.levels[at].state = states[index] }
            if index < stars.count { merged.levels[at].earnedStars = stars[index] }
        }
        return merged
    }

    // MARK: - 该不该续排

    func testUntouchedCourseIsLeftAlone() {
        let course = self.course()
        let state = CourseContinuationRule.progressState(of: course, in: progress(for: course))
        XCTAssertEqual(state.total, 3)
        XCTAssertEqual(state.untouched, 3)
        XCTAssertEqual(CourseContinuationRule.decision(for: state), .none,
                       "还有三节没动就催续排 = 让人跳着练")
        XCTAssertFalse(CourseContinuationRule.shouldContinue(course, in: progress(for: course)))
    }

    func testFinishedCourseAsksForMore() {
        let course = self.course()
        let done = progress(for: course, states: [.completed, .completed, .completed])
        XCTAssertEqual(CourseContinuationRule.decision(
            for: CourseContinuationRule.progressState(of: course, in: done)), .advance)
        XCTAssertTrue(CourseContinuationRule.shouldContinue(course, in: done))
    }

    /// 星星够也算闯完 —— 状态是 `.inProgress` 但星满了，不该被算成「卡住」。
    func testStarsAloneCountAsDone() {
        let course = self.course()
        let starred = progress(for: course, stars: [3, 3, 3])
        XCTAssertEqual(CourseContinuationRule.decision(
            for: CourseContinuationRule.progressState(of: course, in: starred)), .advance)
    }

    /// 一次没达标只是状态不好，两次才算「这条课排难了」。
    func testOneStuckLessonIsNotEnoughToEase() {
        let course = self.course()
        let one = progress(for: course, states: [.inProgress, .completed, .completed])
        XCTAssertEqual(CourseContinuationRule.decision(
            for: CourseContinuationRule.progressState(of: course, in: one)), .none)

        let two = progress(for: course, states: [.inProgress, .inProgress, .completed])
        XCTAssertEqual(CourseContinuationRule.decision(
            for: CourseContinuationRule.progressState(of: course, in: two)), .easier)
    }

    func testEmptyCourseNeverAsksForMore() {
        let course = self.course(titles: [])
        XCTAssertEqual(CourseContinuationRule.decision(
            for: CourseContinuationRule.progressState(of: course, in: progress(for: course))), .none)
    }

    // MARK: - 降档

    func testLoweredLevelStepsDownOneBand() {
        XCTAssertEqual(CourseContinuationRule.lowered(.b1), .a2)
        XCTAssertEqual(CourseContinuationRule.lowered(.b2), .b1)
        XCTAssertEqual(CourseContinuationRule.lowered(.a1), .a1, "已经最低档就别动 —— 返回 nil 会让续排整条消失")
        XCTAssertNil(CourseContinuationRule.lowered(nil))
    }

    // MARK: - 续排请求

    func testContinuationRequestCarriesTheExistingTitles() {
        let course = self.course()
        let base = CourseRequest(level: .b1, topics: ["面试"])
        let request = CourseContinuationRule.continuationRequest(
            base: base,
            course: course,
            progress: progress(for: course, states: [.completed, .completed, .completed])
        )
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.avoidTitles, ["点单", "结账", "投诉"],
                       "已有几节必须报给模型 —— 不然它会把练过的课再排一遍")
        XCTAssertEqual(request?.topics, ["面试"], "自填主题要留着")
        XCTAssertEqual(request?.level, .b1, "没卡住就不降档")
    }

    /// 卡住时降一档；已有节的难度一个都不改（改了等于把练过的内容换掉）。
    func testStuckCourseAsksForAnEasierBatch() {
        let course = self.course()
        let stuck = progress(for: course, states: [.inProgress, .inProgress, .completed])
        let request = CourseContinuationRule.continuationRequest(
            base: CourseRequest(level: .b1),
            course: course,
            progress: stuck
        )
        XCTAssertEqual(request?.level, .a2)
        XCTAssertFalse(course.lessons.contains { $0.scenario.difficulty != 3 },
                       "已有节的难度必须原样不动")
    }

    /// 续排**不是**另一条课：档位没变时，续排请求算出的课 id 必须与首次排课**相同**。
    ///
    /// 进了指纹的话，续排会另存一条新课，树上凭空多一条、学员还得猜哪条是续的。
    func testAvoidTitlesStayOutOfTheFingerprint() {
        let base = CourseRequest(level: .b1, topics: ["面试"])
        let course = self.course()
        let request = CourseContinuationRule.continuationRequest(
            base: base, course: course,
            progress: progress(for: course, states: [.completed, .completed, .completed])
        )
        XCTAssertEqual(CourseBlueprintRule.stableID(request: base),
                       CourseBlueprintRule.stableID(request: request ?? base))
    }

    /// 不该续排时不给请求（nil）—— 返回一份请求的话，服务层会照着排一批没用的节。
    func testNoRequestWhenNothingToContinue() {
        let course = self.course()
        XCTAssertNil(CourseContinuationRule.continuationRequest(
            base: CourseRequest(level: .b1), course: course, progress: progress(for: course)
        ))
    }

    /// 学员还没定位时，用这条课自己的目标档兜底（否则没定位过的学员永远续不了排）。
    func testFallsBackToTheCourseOwnLevel() {
        let course = self.course()
        let request = CourseContinuationRule.continuationRequest(
            base: CourseRequest(),
            course: course,
            progress: progress(for: course, states: [.completed, .completed, .completed])
        )
        XCTAssertEqual(request?.level, .b1)
    }

    // MARK: - 追加

    func testAppendingKeepsExistingLessonsUntouched() {
        let course = self.course()
        let before = course.lessons
        let merged = CourseContinuationRule.appending(
            [lesson(courseID: course.id, order: 1, title: "退款")],
            to: course
        )
        XCTAssertEqual(merged.lessons.count, 4)
        XCTAssertEqual(Array(merged.lessons.prefix(3)), before,
                       "前三节的 id / 序号 / 内容必须一字不改：改了就是重排，学员的星会跟着消失")
        XCTAssertEqual(merged.lessons.last?.order, 4, "序号接着往下编")
        XCTAssertNotEqual(merged.lessons.last?.id, "course-a-l1", "新节的 id 必须重算，不能撞上旧节")
    }

    /// 节 id 与课内情景 id 是同一个（`CourseLesson.id == scenario.id`）：
    /// 只换一个的话，面板点进去查的是旧 id，大树认不出那一格。
    func testAppendedLessonKeepsItsScenarioIDInSync() {
        let course = self.course()
        let merged = CourseContinuationRule.appending(
            [lesson(courseID: course.id, order: 1, title: "退款")],
            to: course
        )
        let last = merged.lessons.last
        XCTAssertEqual(last?.scenario.id, last?.id)
        XCTAssertEqual(last?.scenario.origin, .course, "换 id 不能把来源弄丢")
    }

    /// 模型没听进去「别重复」时，同名的节要被挡掉 —— 学员看到的是「续排排出了我已经练过的课」。
    func testAppendingDropsDuplicateTitles() {
        let course = self.course()
        let merged = CourseContinuationRule.appending(
            [lesson(courseID: course.id, order: 1, title: "点单"),
             lesson(courseID: course.id, order: 2, title: "开发票")],
            to: course
        )
        XCTAssertEqual(merged.lessons.count, 4)
        XCTAssertEqual(merged.lessons.map(\.displayTitle), ["点单", "结账", "投诉", "开发票"])
    }

    /// 排出来的全是已有内容 → 一条都不加（服务层据此报错、不落盘）。
    func testAppendingNothingWhenEverythingIsDuplicate() {
        let course = self.course()
        let merged = CourseContinuationRule.appending(
            [lesson(courseID: course.id, order: 1, title: "点单")],
            to: course
        )
        XCTAssertEqual(merged.lessons.count, course.lessons.count)
    }

    /// 一批里自己重名（模型排重复了）也要去一个。
    func testAppendingDropsDuplicatesWithinTheNewBatch() {
        let course = self.course()
        let merged = CourseContinuationRule.appending(
            [lesson(courseID: course.id, order: 1, title: "开发票"),
             lesson(courseID: course.id, order: 2, title: "开发票")],
            to: course
        )
        XCTAssertEqual(merged.lessons.count, 4)
    }

    // MARK: - 文案

    func testSummaryAlwaysCarriesAComparableNumber() {
        XCTAssertEqual(
            CourseContinuationRule.summary(for: CourseProgressState(total: 3, completed: 3)),
            "3 节都闯完了"
        )
        XCTAssertEqual(
            CourseContinuationRule.summary(for: CourseProgressState(total: 3, stuck: 2, untouched: 1)),
            "3 节里有 2 节卡住了"
        )
        XCTAssertEqual(
            CourseContinuationRule.summary(for: CourseProgressState(total: 3, completed: 1, untouched: 2)),
            "3 节里闯完 1 节，还有 2 节没动"
        )
    }
}
