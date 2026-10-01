import AppCore
@testable import AppUI
import XCTest

/// 窗口布局档位（#417 窄窗降级）：纯函数与常量。
///
/// 判据三块：
/// ①窗口下限**只有一个真相**（AppMain / MainView 两处引用同一常量，
///   由源码哨兵钉住「不许再写字面量」）；
/// ②侧栏收起是**派生值**：用户偏好 ∧ 窗口允许 —— 窗口不能悄悄改写偏好；
/// ③最小窗口下三栏必须摆得开（树 ≥ 下限、聊天 ≥ 下限），这是 880 这个数成立的前提。
final class AppLayoutMetricsTests: XCTestCase {

    // MARK: - 窗口下限：单一真相

    func testWindowMinimumsAreTheSingleSourceOfTruth() throws {
        XCTAssertEqual(AppLayoutMetrics.minWindowWidth, 880)
        XCTAssertEqual(AppLayoutMetrics.minWindowHeight, 640)
        // AppMain 与 MainView 都必须引用常量，不许再写死 1080/720 字面量。
        for path in ["Sources/AppMain/AppMain.swift", "Sources/AppUI/Views/MainView.swift"] {
            let raw = try String(contentsOfFile: path, encoding: .utf8)
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let text = lines.joined(separator: "\n")
            XCTAssertFalse(text.contains("minWidth: 1080"), "\(path) 又把窗口最小宽写死了")
            XCTAssertFalse(text.contains("minHeight: 720"), "\(path) 又把窗口最小高写死了")
            XCTAssertTrue(text.contains("AppLayoutMetrics.minWindow"), "\(path) 没有引用 AppLayoutMetrics")
        }
    }

    // MARK: - 侧栏派生展开

    func testSidebarExpansionRequiresBothPreferenceAndWidth() {
        XCTAssertTrue(AppLayoutMetrics.sidebarExpanded(userPrefers: true, windowWidth: 1000), "恰好到阈值仍是展开")
        XCTAssertFalse(
            AppLayoutMetrics.sidebarExpanded(userPrefers: true, windowWidth: 999),
            "阈值之下必须收成图标栏"
        )
        XCTAssertFalse(
            AppLayoutMetrics.sidebarExpanded(userPrefers: false, windowWidth: 1400),
            "用户收起的偏好不能被宽窗口悄悄推翻"
        )
        // 阈值本身必须落在最小宽之上，否则最小窗口下展开态的树宽没有设计余量。
        XCTAssertGreaterThan(AppLayoutMetrics.sidebarCollapseBelow, AppLayoutMetrics.minWindowWidth)
    }

    // MARK: - 最小窗口下三栏摆得开

    /// 880 宽、侧栏收起（窄窗派生态）时：树与聊天各自不低于下限。
    func testMinimumWidthFitsAllPanesWithCollapsedSidebar() {
        let available = AppLayoutMetrics.minWindowWidth
            - AppSidebar.collapsedWidth  // 侧栏（窄窗强制收起）
            - 1 - 14                     // 分隔线 + 拖拽把手
        let tree = AppLayoutMetrics.treeWidth(preferred: 380, available: available)
        let chat = available - tree
        XCTAssertGreaterThanOrEqual(tree, AppLayoutMetrics.treeMinWidth, "树不能低于下限")
        XCTAssertGreaterThanOrEqual(chat, AppLayoutMetrics.chatMinWidth, "聊天区不能低于下限")
    }

    /// 880 宽、用户偏好展开被**临时**忽略之前（≥1000 才展开）——这个区间外，
    /// 就算侧栏展开，新下限也应保证摆得开（阈值是比例取舍，不是硬约束）。
    func testExpandedSidebarStillFitsAtThresholdWidth() {
        let available = AppLayoutMetrics.sidebarCollapseBelow
            - AppSidebar.expandedWidth - 1 - 14
        let tree = AppLayoutMetrics.treeWidth(preferred: 380, available: available)
        let chat = available - tree
        XCTAssertGreaterThanOrEqual(tree, AppLayoutMetrics.treeMinWidth)
        XCTAssertGreaterThanOrEqual(chat, AppLayoutMetrics.chatMinWidth)
    }

    /// 夹取函数本身：偏好过小托到下限、过大压到上限、上限兜底不倒挂。
    func testTreeWidthClampIsSymmetric() {
        XCTAssertEqual(AppLayoutMetrics.treeWidth(preferred: 100, available: 1000),
                       AppLayoutMetrics.treeMinWidth, "偏好小于下限要托起")
        XCTAssertEqual(AppLayoutMetrics.treeWidth(preferred: 5000, available: 1000),
                       1000 - AppLayoutMetrics.chatMinWidth, "偏好大到离谱要压回（聊天保住下限）")
        // 可用宽比两个下限加起来还小（理论到不了，窗口下限挡着）：不能倒挂出负值。
        XCTAssertGreaterThanOrEqual(
            AppLayoutMetrics.treeWidth(preferred: 380, available: 100),
            AppLayoutMetrics.treeMinWidth,
            "可用宽不足时树仍取下限，绝不允许算出负宽"
        )
    }

    // MARK: - 侧栏接线哨兵

    /// MainView 必须把「窗口允许」传给侧栏；侧栏的展开判定必须是「偏好 ∧ 允许」。
    /// 反证：MainView 改回 `AppSidebar(state: state)` → 本用例红。
    func testMainViewPassesWidthAllowanceToSidebar() throws {
        let raw = try String(contentsOfFile: "Sources/AppUI/Views/MainView.swift", encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("widthAllowsExpansion: sidebarExpanded"), "MainView 没把窗口允许传给侧栏")
        XCTAssertTrue(
            text.contains("AppLayoutMetrics.sidebarExpanded(") && text.contains("userPrefers: state.isSidebarExpanded"),
            "MainView 没走派生函数"
        )
    }

    /// 侧栏导航列表必须能滚（矮窗降级 + Xcode 27 SDK 高度回归的修复本体）。
    /// 反证：撤掉 navList 的 ScrollView → 本用例红（且矮窗渲染回归会真的压扁头部）。
    func testSidebarNavListScrolls() throws {
        let raw = try String(contentsOfFile: "Sources/AppUI/Components/AppSidebar.swift", encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("ScrollView(.vertical"), "navList 没套 ScrollView：矮窗会压扁头栏")
    }

    // MARK: - 浮层高度不能顶穿最小窗口

    /// 考后结算卡的设计高 660 > 最小窗高 640：不夹取的话最矮窗口下上下各被切 10pt，
    /// 而这张卡的出口**只有**底部那两个按钮（点遮罩不关）→ 等于「考完出不来」。
    func testExamReportHeightFitsInsideTheShortestWindow() {
        XCTAssertEqual(AppLayoutMetrics.examReportHeight(available: 640), 600)
        XCTAssertEqual(AppLayoutMetrics.examReportHeight(available: 900), 660, "高窗下照旧用设计高")
        XCTAssertEqual(AppLayoutMetrics.examReportHeight(available: 300), 420, "再矮也留一个下限")
        XCTAssertLessThanOrEqual(AppLayoutMetrics.examReportHeight(available: 640), 640)
    }

    func testExamReportHeightIsWiredIntoMainView() throws {
        let raw = try String(contentsOfFile: "Sources/AppUI/Views/MainView.swift", encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("AppLayoutMetrics.examReportHeight(available:"),
                      "结算卡高度没接布局常量")
        XCTAssertFalse(text.contains("frame(width: 560, height: 660)"),
                       "别再写死 660：最小窗高已经降到 640")
    }
}
