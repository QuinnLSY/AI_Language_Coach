import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import SwiftUI
import XCTest

/// ⑥-B「AI 排的课随进度续排」的**离屏渲染**回归。
///
/// 领域层（`CourseContinuationTests`）能证明「该不该续、续什么」算对了，但看不出两件事：
/// ① 浮层里「接着往下排」那一节**真的画出来了**；② **不该续的课不出现**——
/// 「还有几节没动」的课一旦混进来，就是催人跳着练。
@MainActor
final class CourseContinuationRenderTests: XCTestCase {

    private var window: NSWindow?
    private let sheetWidth: CGFloat = 480

    // MARK: - 造数据

    private func lesson(courseID: String, order: Int, title: String) -> CourseLesson {
        CourseLesson(
            id: CourseBlueprintRule.lessonID(courseID: courseID, order: order, title: title),
            order: order,
            title: title,
            titleZh: title,
            goal: "练 \(order)",
            scenario: Scenario(
                id: CourseBlueprintRule.lessonID(courseID: courseID, order: order, title: title),
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

    private func course(lessons: Int, topic: String = "咖啡店点单") -> CourseBlueprint {
        let id = StableFingerprint.hex(prefix: "course", of: topic)
        return CourseBlueprint(
            id: id,
            title: "Coffee Course",
            titleZh: topic,
            focus: "盯住时态",
            targetLevel: .b1,
            rationale: "现在 B1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lessons: (1...lessons).map { lesson(courseID: id, order: $0, title: "\(topic) \($0)") }
        )
    }

    /// 把课并进树、再按给定的状态改那几格（续排判据读的就是树上这几格）。
    ///
    /// ⚠️ 必须先 `CourseTreeRule.merge` —— 直接改 `.seed()` 里没有这些格，
    /// 那样 `progressState` 会把整条课读成「0 节、0 卡住」，看着像「不该续」。
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

    /// 4 节里前 2 节「练了但没达标」→ 恰好等于 stuckThreshold。
    private func stuckCourse() -> (CourseBlueprint, LearnerProgress) {
        let course = course(lessons: 4)
        return (course, progress(for: course, states: [.inProgress, .inProgress], stars: [1, 1, 0, 0]))
    }

    private func doneCourse() -> (CourseBlueprint, LearnerProgress) {
        let course = course(lessons: 3, topic: "机场值机")
        return (course, progress(for: course, states: [.completed, .completed, .completed]))
    }

    /// 一节都没动过 → **不该**出现在「接着往下排」里。
    private func untouchedCourse() -> CourseBlueprint {
        course(lessons: 4, topic: "看医生")
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var size: CGSize
    }

    private func render(_ state: AppState, day: Bool) throws -> Render {
        _ = try? draw(state, day: day)
        return try draw(state, day: day)
    }

    private func draw(_ state: AppState, day: Bool) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xF3F7EF) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            ZStack(alignment: .top) {
                backdrop
                CourseComposerSheet(state: state, onClose: {})
                    .frame(width: sheetWidth)
            }
            .frame(width: sheetWidth)
            .forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: sheetWidth, height: 900)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: host.frame.size)
    }

    private func makeState() -> AppState {
        AppState(services: CoachServices(
            config: ConfigStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("course-continue-\(UUID().uuidString).json")),
            databasePath: ":memory:"
        ))
    }

    private func ink(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 0, y: 0) else { return 0 }
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if delta > 0.15 { count += 1 }
            }
        }
        return count
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 该续的续、不该续的不续

    func testOnlyCoursesThatEarnedItShowUp() {
        let state = makeState()
        let (stuck, stuckProgress) = stuckCourse()
        let (done, doneProgress) = doneCourse()
        let untouched = untouchedCourse()

        state.courses = [stuck, done, untouched]
        state.progress = stuckProgress
        let stuckIDs = state.coursesAwaitingContinuation.map(\.id)
        state.progress = doneProgress
        let doneIDs = state.coursesAwaitingContinuation.map(\.id)

        XCTAssertEqual(stuckIDs, [stuck.id], "卡住 2 节的课该出现")
        XCTAssertEqual(doneIDs, [done.id], "全闯完的课该出现")

        // 一节都没动过的课：把它塞进 courses 也不许出现。
        state.courses = [untouched]
        state.progress = progress(for: untouched)
        XCTAssertTrue(state.coursesAwaitingContinuation.isEmpty,
                      "「还有几节没动」的课不该催续排 —— 催人跳着练只会让课断成两截")
    }

    /// 「全闯完」与「卡住」两个档位的**按钮字与图标必须不同** ——
    /// 都写「继续」的话，用户不知道自己点下去会降难度。
    func testDecisionWordingDiffers() {
        XCTAssertNotEqual(CourseContinuationDecision.advance.title,
                          CourseContinuationDecision.easier.title)
        XCTAssertTrue(CourseContinuationDecision.easier.title.contains("降"),
                      "降档必须写在按钮上：「\(CourseContinuationDecision.easier.title)」")
        // `.none` 有意是空串：那节课不该出现，浮层里根本不会渲染这一行。
        XCTAssertTrue(CourseContinuationDecision.none.title.isEmpty,
                      "不该续的课没有按钮文案（「\(CourseContinuationDecision.none.title)」）")
    }

    // MARK: - ② 浮层里那一节真的画出来了

    /// 撤掉 `continuations` → 墨迹相等 → 立刻红。
    ///
    /// ⚠️ 比**墨迹**不比高度：整页在 `ScrollView` 里，加一块内容不改变页面高度（量高度永远绿）。
    func testSheetDrawsTheContinuationSection() throws {
        let state = makeState()
        let (stuck, progress) = stuckCourse()
        state.courses = [stuck]
        state.progress = progress
        XCTAssertEqual(state.coursesAwaitingContinuation.count, 1, "先确认这节课该出现")
        let with = try render(state, day: true)
        state.courses = []
        let without = try render(state, day: true)

        let withInk = ink(with.rep)
        let withoutInk = ink(without.rep)
        XCTAssertGreaterThan(withInk, withoutInk + 1_000,
                             "「接着往下排」那一节必须真的画出来（差值 \(withInk - withoutInk)）")
        try dump(with.rep, name: "round46-course-continuation-day.png")
    }

    // MARK: - ③ 日夜两版

    func testRendersInBothThemes() throws {
        let state = makeState()
        let (stuck, progress) = stuckCourse()
        state.courses = [stuck]
        state.progress = progress

        let day = try render(state, day: true)
        let night = try render(state, day: false)
        XCTAssertGreaterThan(ink(day.rep), 1_000, "日间版应有内容")
        XCTAssertGreaterThan(ink(night.rep), 1_000, "夜间版应有内容")

        func luma(_ rep: NSBitmapImageRep) throws -> CGFloat {
            let color = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
            return color.redComponent * 0.3 + color.greenComponent * 0.6 + color.blueComponent * 0.1
        }
        XCTAssertGreaterThan(try luma(day.rep), 0.5, "日间底色应偏亮")
        XCTAssertLessThan(try luma(night.rep), 0.3, "夜间底色应偏暗")
        try dump(night.rep, name: "round46-course-continuation-night.png")
    }
}