import AppKit
import AIDomain
@testable import AppUI
import SwiftUI
import XCTest

/// ③ AI 课程关卡在大树上的**离屏渲染回归**。
///
/// 判据只走**墨迹差**，不比色值（离屏过色彩空间换算，见技能 macos-ui-verify）：
/// - 同一份进度渲染两遍必须一致（种子随机不许引入抖动）；
/// - 「树冠之上那一片」在**有课程关卡**时必须有墨迹（节点真的画上去了、没被画布裁掉），
///   在**没有课程关卡**时必须是干净的（否则那团墨是别的东西画上去的）；
/// - 最后一例把日夜两版 dump 成 PNG，人工复核「长什么样」—— 这一步测不出来。
@MainActor
final class CourseLevelTreeRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let width: CGFloat = 420

    private func makeHost(_ view: some View, size: CGSize) throws -> Render {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, scale: CGFloat(rep.pixelsHigh) / max(size.height, 1))
    }

    private func inkPoints(_ render: Render, in rect: CGRect) -> Int {
        guard let data = render.rep.bitmapData else { return 0 }
        let scale = render.scale
        let px = Int(rect.minX * scale)..<min(Int(rect.maxX * scale), render.rep.pixelsWide)
        let py = Int(rect.minY * scale)..<min(Int(rect.maxY * scale), render.rep.pixelsHigh)
        guard !px.isEmpty, !py.isEmpty else { return 0 }
        var count = 0
        for y in py {
            for x in px {
                let offset = y * render.rep.bytesPerRow + x * 4
                let alpha = data[offset + 3]
                // 半透明也算墨：树冠是半透明的大色块，节点描边是实色，
                // 只认不透明会把「画上去了」误判成「没画」。
                if alpha > 8 { count += 1 }
            }
        }
        return count
    }

    private func totalInk(_ render: Render) -> Int {
        inkPoints(render, in: CGRect(
            x: 0, y: 0,
            width: CGFloat(render.rep.pixelsWide) / render.scale,
            height: CGFloat(render.rep.pixelsHigh) / render.scale
        ))
    }

    private func resolved(isNight: Bool) -> ForestTheme {
        let base = ForestThemeResolver.resolve(
            mode: isNight ? .night : .day, systemIsDark: false,
            hour: isNight ? 22 : 12, month: 6,
            followsClock: false, followsSeason: false
        )
        return ForestTheme(palette: base.palette, moment: base.moment,
                           season: base.season, weather: nil)
    }

    private func render(
        _ progress: LearnerProgress, night: Bool
    ) throws -> Render {
        let height = TreeCanvas.canvasHeight(for: progress)
        return try makeHost(
            TreeCanvas(theme: resolved(isNight: night), progress: progress)
                .environment(\.appMotion, AppMotionDescriptor(reduceMotion: true, reduceTransparency: true))
                .frame(width: width, height: height),
            size: CGSize(width: width, height: height)
        )
    }

    // MARK: - 夹具

    /// n 节课的课（走真实的 `CourseTreeRule.merge`，别手搓高度）。
    private func progress(courseLessons n: Int) -> LearnerProgress {
        guard n > 0 else { return LearnerProgress.seed() }
        let course = CourseBlueprint(
            id: "course-render",
            title: "Ordering like a local",
            titleZh: "像本地人一样点单",
            focus: "盯住礼貌用语",
            targetLevel: .b1,
            rationale: "现在 B1",
            lessons: (1...n).map { index in
                let id = "course-render-l\(index)"
                return CourseLesson(
                    id: id, order: index,
                    title: "Lesson \(index)", titleZh: "第\(index)节", goal: "",
                    scenario: Scenario(
                        id: id, title: "Lesson \(index)", titleZh: "第\(index)节",
                        category: CourseBlueprintRule.category,
                        difficulty: 3, level: "B1", objective: "",
                        aiRole: "barista", learnerRole: "customer",
                        opening: "Hi there!",
                        targetSentences: ["Could I get a latte?", "Does it cost extra?"],
                        origin: .course
                    )
                )
            }
        )
        return CourseTreeRule.merge(progress: .seed(), courses: [course])
    }

    // MARK: - 用例

    func testRenderingIsDeterministic() throws {
        let target = progress(courseLessons: 3)
        let first = try render(target, night: false)
        let second = try render(target, night: false)
        XCTAssertEqual(totalInk(first), totalInk(second),
                       "同一份进度渲染两遍墨迹数必须一致（种子随机不许引入抖动）")
    }

    /// 反证：把 `y(for:…)` 的课程段判据从 `> 1` 改回夹住 → 课程关卡全叠在树冠 →
    /// 课程那一段会空出来。本条钉的是「**确实画在正文之上、且没被画布裁掉**」。
    ///
    /// ⚠️ 这里**没有**「无课程时同一片干净」那种成对断言：树的画面里到处都有墨
    /// （树干、树枝、内置关卡、年轮），任何一个绝对矩形在两棵树上都能找到东西 ——
    /// 那样的「反证」是自欺。分界靠 `showsCourseBand(for:)` 那种**纯函数**钉，
    /// 「画没画出来」靠下面这条墨迹断言，最后靠 PNG 人眼判。
    func testCourseLevelsAreDrawnAboveTheBuiltInOnes() throws {
        let target = progress(courseLessons: 3)
        let render = try render(target, night: false)
        let band = CGRect(
            x: 0,
            y: TreeCanvas.topmostCourseY(for: target) - 40,
            width: width,
            height: 40 + CGFloat(target.levels.filter(\.isAboveCurriculum).count - 1) * TreeCanvas.courseNodeStep + 40
        )
        XCTAssertGreaterThan(inkPoints(render, in: band), 400,
                             "课程关卡那一段应该有墨（实测 \(inkPoints(render, in: band)) 点）")
    }

    /// 云带只在**有**课程关卡时出现 —— 这是分界的判据，纯函数、可单测。
    func testCourseBandAppearsOnlyWithCourses() {
        XCTAssertFalse(TreeCanvas.showsCourseBand(for: progress(courseLessons: 0)))
        XCTAssertTrue(TreeCanvas.showsCourseBand(for: progress(courseLessons: 1)))
        // 云带必须落在正文顶端与最低一格课程关卡**之间**。
        let target = progress(courseLessons: 3)
        let bandY = TreeCanvas.courseBandY(for: target)
        XCTAssertLessThan(bandY, TreeCanvas.topInset(for: target), "云带在正文关卡之上")
        XCTAssertGreaterThan(bandY, TreeCanvas.topmostCourseY(for: target) + TreeCanvas.courseNodeStep,
                             "云带在最低一格课程关卡之下")
    }

    /// 树冠在树顶：课程关卡存在时，树冠的底沿必须**高于**最高一格，且整体在画布内。
    func testCanopySitsAtTheTopOfTheTree() {
        let target = progress(courseLessons: 3)
        let offset = TreeCanvas.canopyOffsetY(for: target)
        XCTAssertGreaterThanOrEqual(offset, 0, "树冠被推到画布顶端外面去了")
        XCTAssertLessThanOrEqual(
            offset + TreeCanvas.canopyHeight,
            TreeCanvas.topmostCourseY(for: target) - TreeCanvas.canopyGap + 0.5,
            "树冠底沿必须压在最高一格之上（树冠在树顶，课程关卡在树冠下）"
        )
        // 没有课程关卡时与从前逐像素相同（树冠仍罩着顶关）。
        XCTAssertEqual(
            TreeCanvas.canopyOffsetY(for: progress(courseLessons: 0)),
            TreeCanvas.topInset(for: progress(courseLessons: 0)) - 190, accuracy: 0.001
        )
    }

    /// 课程关卡一节都不能被画布裁掉：最上面那一格也要在画布内、且带墨。
    func testTheTopmostLessonIsNotClippedAway() throws {
        let target = progress(courseLessons: 4)
        let render = try render(target, night: false)
        let topMostY = TreeCanvas.y(
            for: 1.08, baseY: TreeCanvas.canvasHeight(for: target) - TreeCanvas.groundHeight,
            topInset: TreeCanvas.topInset(for: target), courseRank: 0
        )
        let band = CGRect(x: 0, y: topMostY - 30, width: width, height: 60)
        XCTAssertGreaterThanOrEqual(band.minY, 0, "最上面那一格跑出画布顶端了")
        XCTAssertGreaterThan(inkPoints(render, in: band), 40, "最上面那一格被裁掉或没画出来")
    }

    /// 日夜两版 dump 成 PNG，供人工复核（这一步测不出来，只有人眼能判）。
    func testRendersInBothThemesAndDumpsPNG() throws {
        let target = progress(courseLessons: 3)
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (isNight, tag) in [(false, "day"), (true, "night")] {
            let render = try render(target, night: isNight)
            guard let data = render.rep.representation(using: .png, properties: [:]) else {
                XCTFail("PNG 编码失败（\(tag)）")
                continue
            }
            let url = directory.appendingPathComponent("round43-course-tree-\(tag).png")
            try data.write(to: url)
            XCTAssertGreaterThan(totalInk(render), 500, "\(tag) 版几乎没画出东西")
        }
    }
}