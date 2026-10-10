import Foundation
import XCTest

/// ③ AI 课程挂大树的**接线**哨兵（行为由 `CourseTreeTests` 与 `TreeViewportTests` 钉，
/// 这里只钉「接线顺序」—— 那是最容易写反、且写反了整条路静默失效的一处）。
///
/// 两条顺序约束：
/// 1. `merge` 必须排在 `services.loadProgress()` **之后** ——
///    `LearnerProgress.applyScenarioBindings` 会把所有关卡的 `scenarioID` 覆盖成绑定表里的值，
///    而 `scenario_id` 不在 `levels` 表里。反了的话课程关卡永远点不进去。
/// 2. 树冠那一格的高度必须**跟着树一起下移**（课程段占了画布顶部）——
///    树冠留在画布顶部就会浮在课程关卡上面。
final class CourseTreeWiringTests: XCTestCase {

    private nonisolated static func code(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    /// 开屏那一次：`loadProgress()` 之后必须立刻把课目录读回来并合并。
    func testStartupMergesCourseLevelsRightAfterLoadingProgress() throws {
        let raw = try Self.code("Sources/AppUI/AppState.swift")
        let loaded = try XCTUnwrap(
            raw.range(of: "progress = await services.loadProgress()"),
            "找不到开屏读进度那一行（真源搬走了？）"
        )
        let after = raw[loaded.upperBound...]
        let merged = try XCTUnwrap(
            after.range(of: "await refreshScenarioCatalog()"),
            "开屏读进度之后必须并一次课内关卡 —— 否则树是开屏就在画的，课内关卡晚一拍出现"
        )
        // 中间不得夹着别的一次 progress 赋值（那会把合并结果冲掉）。
        let between = String(raw[loaded.upperBound..<merged.lowerBound])
        XCTAssertFalse(between.contains("progress ="), "合并与读进度之间不得再改一次 progress：\(between)")
    }

    /// `syncCourseLevels` 的存在与两条关键注释都在（顺序陷阱就在这个函数里）。
    func testCourseLevelSyncLivesBesideTheCatalogRefresh() throws {
        let raw = try Self.code("Sources/AppUI/AppState+Course.swift")
        XCTAssertTrue(raw.contains("func syncCourseLevels()"), "并课内关卡的那一步要有自己的函数")
        XCTAssertTrue(raw.contains("CourseTreeRule.merge(progress: progress, courses: courses)"),
                      "必须走领域层那个纯函数，别在 AppState 里手搓关卡")
        XCTAssertTrue(raw.contains("await services.saveProgress(progress)"),
                      "合并后必须落库：关卡行在 levels 表里，不落库星星重启就没了")
        let refresh = try XCTUnwrap(raw.range(of: "func refreshScenarioCatalog()"))
        let body = String(raw[refresh.upperBound...])
        let reload = try XCTUnwrap(body.range(of: "await services.reloadCourses()"))
        let sync = try XCTUnwrap(body.range(of: "await syncCourseLevels()"))
        // ⚠️ 两个下标必须来自**同一段**字符串（拿 `raw` 的下标去比 `body` 的，永远不等）。
        XCTAssertLessThan(reload.upperBound, sync.lowerBound,
                          "合并必须排在「课与课内情景都换好」之后 —— 两份缓存还没换就合并等于拿旧的并")
    }

    /// 树冠必须**回到树顶**（用户 2026-10-10 报障：「树冠也要一直保持在树顶，
/// 现在这个形象太突兀了」），分界交给云带。
func testCanopyStaysAtTheTopAndCloudsMarkTheBoundary() throws {
        let raw = try Self.code("Sources/AppUI/Components/TreeCanvas.swift")
        XCTAssertTrue(raw.contains(".offset(y: Self.canopyOffsetY(for: progress))"),
                      "树冠的位置必须走 `canopyOffsetY(for:)`（有课程关卡时挂在最高一格之上）")
        XCTAssertTrue(raw.contains("if TreeCanvas.showsCourseBand(for: progress)"),
                      "云带只在**有**课程关卡时出现 —— 没有更高的一段时挂一朵云等于凭空多一个层级")
        XCTAssertTrue(raw.contains("CourseCloudBand(theme: theme)"),
                      "正文与课程之间要有云带做分界（用户 2026-10-10 定的）")
        // 云带必须画在关卡节点**之前**（更下层），否则会盖住关卡的读屏标签。
        let band = try XCTUnwrap(raw.range(of: "CourseCloudBand(theme: theme)"))
        let nodes = try XCTUnwrap(raw.range(of: "ForEach(progress.levels) { level in"))
        XCTAssertLessThan(band.lowerBound, nodes.lowerBound, "云带要画在关卡节点之前（更下层）")
    }

    /// 学员只走树干：`climbFraction` 越界要夹在树冠，不许被送进课程段。
    func testLearnerNeverEscapesIntoTheCourseBand() throws {
        let raw = try Self.code("Sources/AppUI/Components/TreeCanvas.swift")
        XCTAssertTrue(raw.contains("let clamped = min(max(climbFraction, 0), 1)"),
                      "learnerY 必须先夹住进度 —— 越界值会被 >1 的课程段接走，学员会「飞」到树冠之上")
    }
}