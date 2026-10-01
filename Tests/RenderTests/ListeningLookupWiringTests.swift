import XCTest

/// 听力页划词 + 打卡徽章悬浮卡的**接线哨兵**。
///
/// 为什么用源码扫描：
/// - 划词链路的上半段（探测 / 气泡摆位）已由通用组件自带回归；这里要钉的是
///   「听力页有没有把 `AppState.wordLookupContext` 递到三张卡」—— 纯接线事实，
///   源码即真相。且离屏环境没有 `AppState`，三张卡在测试里走的是「不可划词」
///   退路，渲染回归照不出「实机能不能划」。
/// - 徽章悬浮卡由 `.onHover` 驱动（原生 `.help` 在点击后不再弹出，2026-09-24 报障）；
///   悬停路径离屏搭不出来，能钉住的是「自绘卡挂在 onHover 上、不再依赖 `.help`」。
final class ListeningLookupWiringTests: XCTestCase {

    /// 仓库根：Tests/RenderTests/本文件.swift → 上溯三级。
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 两张听力卡的**原文展示**都必须走 `LookupText`（有上下文 = 可划词）。
    ///
    /// ⚠️ 只钉对照屏里那一句：`revealCard` / `reveal` 是两卡里唯一构造原文的地方，
    /// 答题前不出原文的不变量不因划词而破。
    func testListeningReferenceLinesUseLookupText() throws {
        let drill = try source("Sources/AppUI/Components/ListeningDrillCard.swift")
        let meaning = try source("Sources/AppUI/Components/ListeningMeaningCard.swift")

        XCTAssertTrue(
            drill.contains("LookupText("),
            "精听默写 / 关键词捕捉的对照屏原文要走 LookupText（可划词）"
        )
        XCTAssertTrue(
            meaning.contains("LookupText("),
            "听句选义判完亮出的原文要走 LookupText（可划词）"
        )
    }

    /// 听力页必须把划词上下文递给两张卡（三张卡 = 两种问法 + 选义）。
    ///
    /// 反证：删掉 ListeningView 里的 `wordLookup: state.wordLookupContext` → 红。
    func testListeningViewPassesTheLookupContext() throws {
        let view = try source("Sources/AppUI/Views/ListeningView.swift")
        let passes = view.components(separatedBy: "wordLookup: state.wordLookupContext").count - 1
        XCTAssertEqual(
            passes, 2,
            "ListeningView 应把划词上下文传给 ListeningDrillCard 与 ListeningMeaningCard，实测 \(passes) 处"
        )
    }

    /// 打卡徽章：悬浮说明由 `.onHover` 自绘卡驱动，**不许退回原生 `.help`**。
    ///
    /// 原生 tooltip 由 AppKit 悬浮状态机管理：点击之后鼠标不移出再移回就不再弹出
    /// （2026-09-24 用户报障「点了徽章气泡不显示了」）。
    /// 反证：把 `.help(` 加回 StreakBadgeView → 红。
    func testStreakBadgeTooltipIsHoverDrivenNotNativeHelp() throws {
        let badge = try source("Sources/AppUI/Components/StreakBadgeView.swift")
        XCTAssertTrue(
            badge.contains(".onHover"),
            "徽章悬浮卡必须挂在 .onHover 上（自绘），不能依赖 AppKit 的悬浮状态机"
        )
        XCTAssertFalse(
            badge.contains(".help("),
            "徽章不许再用原生 .help：点击后它不再弹出（2026-09-24 报障本体）"
        )
    }

    /// 徽章浮卡要画在**整窗最上层**。
    ///
    /// 它挂在侧栏的浮层里、会伸出侧栏 220pt 之外，而分隔线 / 中间栏 / 右栏都是
    /// **更晚的兄弟节点**，默认会把溢出的浮卡画在下面 —— 2026-09-24 报障：
    /// 浮卡右半截被中间栏底色盖住。侧栏抬一层（`.zIndex`）即可，浮卡自己
    /// `allowsHitTesting(false)`，不抢任何点击。
    ///
    /// 为什么用源码扫描：三栏主界面要真的 `AppState`，离屏搭不出来；这是纯接线事实。
    /// 反证：删掉 MainView 里 `AppSidebar` 挂载处的 `.zIndex` → 红。
    func testSidebarIsLiftedAboveTheLaterColumns() throws {
        let view = try source("Sources/AppUI/Views/MainView.swift")
        let lines = view.components(separatedBy: .newlines)
        let index = try XCTUnwrap(
            // #417 起挂载点带 `widthAllowsExpansion:` 参数 → 前缀匹配，别钉死旧签名。
            lines.firstIndex { $0.contains("AppSidebar(state: state") },
            "MainView 里找不到 AppSidebar 的挂载点"
        )
        let mount = lines[index..<min(index + 8, lines.count)].joined(separator: "\n")
        XCTAssertTrue(
            mount.contains(".zIndex("),
            "侧栏必须抬一层（.zIndex）—— 否则徽章浮卡伸出侧栏的那半截会被后面的栏盖住"
        )
    }
}
