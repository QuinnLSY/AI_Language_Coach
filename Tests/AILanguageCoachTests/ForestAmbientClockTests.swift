@testable import AppUI
import XCTest

/// 统一氛围钟（#651）的回归：**纯函数单测 + 接线哨兵**。
///
/// 这一轮把九层「自己起一颗 `TimelineView`」的氛围装饰收敛成一颗共享的
/// `ForestAmbientClock`（春蝶 / 蒲公英絮 / 风筝 / 落叶 / 四季飞鸟 / 流萤 /
/// 叶隙光斑 / 蜻蜓 / 落雪）。三条判据各自守一类「不会报错、只是变卡」的病：
///
/// 1. **钟本身**：间隔照累计、停了一会儿不累计（否则一恢复播放落叶瞬移回树冠）；
/// 2. **帧率预算**：幅宽越大帧率越低（每帧像素多了，帧数就得让）；
/// 3. **接线**：MainView 必须挂驱动器 + 把钟灌进环境；九层不许再自己起表。
///
/// ⚠️ 第 3 条为什么非有不可：`AmbientTicker` 在「没注入钟」时会**自己起一颗表**
/// （离屏渲染夹具走这条路，既有渲染测试因此零影响）—— 这意味着万一驱动器
/// 忘了挂，画面照常动，只是又回到九颗表的老路，没有任何测试会红。
/// 哨兵钉的就是这个「静默退化」。
@MainActor
final class ForestAmbientClockTests: XCTestCase {

    // MARK: - 钟本身

    func testClockStartsAtZero() {
        XCTAssertEqual(ForestAmbientClock().elapsed, 0)
    }

    /// 正常间隔照累计：一帧帧往前走，elapsed 就是墙上时钟。
    func testNormalGapsAccumulate() {
        let clock = ForestAmbientClock()
        let start = Date()
        clock.advance(to: start)
        XCTAssertEqual(clock.elapsed, 0, "第一帧只立基准，不该凭空多出时间")
        clock.advance(to: start.addingTimeInterval(0.05))
        clock.advance(to: start.addingTimeInterval(0.10))
        clock.advance(to: start.addingTimeInterval(0.15))
        XCTAssertEqual(clock.elapsed, 0.15, accuracy: 1e-6)
    }

    /// 停了一会儿（应用失活 / 机器卡住）**不累计**。
    ///
    /// 反证：把 `advance` 里 `gap <= Self.stallThreshold` 那道闸去掉 →
    /// 红在「不累计」。少了它，用户切到别的应用三分钟再回来，
    /// 第一帧就把三分钟补进相位，落叶从半空瞬移到树冠、鸟群跳过小半个画面。
    func testLongGapIsNotAccumulated() {
        let clock = ForestAmbientClock()
        let start = Date()
        clock.advance(to: start)
        clock.advance(to: start.addingTimeInterval(0.20))
        XCTAssertEqual(clock.elapsed, 0.20, accuracy: 1e-6)
        // 失活三分钟后恢复：只搬基准，不把这三分钟算进去
        clock.advance(to: start.addingTimeInterval(180.20))
        XCTAssertEqual(clock.elapsed, 0.20, accuracy: 1e-6,
                       "长间隔被累计进去了 —— 恢复播放会集体瞬移")
        // 恢复后照常往前走
        clock.advance(to: start.addingTimeInterval(180.25))
        XCTAssertEqual(clock.elapsed, 0.25, accuracy: 1e-6)
    }

    /// 夹具缝：把钟直接拨到某个相位（离屏渲染要用它对齐冻结档）。
    func testSeedPutsTheClockAtThatPhase() {
        let clock = ForestAmbientClock()
        clock.seed(elapsed: 30.72)
        XCTAssertEqual(clock.elapsed, 30.72, accuracy: 1e-6)
        // 拨完接着 advance 也从新相位继续走（lastTick 被清掉，不会补一段）
        //
        // ⚠️ 基准**只取一次**：原先两次各调 `Date()`，中间真实耗时（构造 Date 那几微秒）
        // 会叠进 0.05 里，机器一忙就冲过 1e-6 容差 —— 2026-10-24 全量跑实测
        // 30.77000102519989 vs 30.77 红了一次。判据要钉的是「相位从 30.72 接着走」，
        // 不是「这台机器此刻有多快」。
        let base = Date()
        clock.advance(to: base)
        clock.advance(to: base.addingTimeInterval(0.05))
        XCTAssertEqual(clock.elapsed, 30.77, accuracy: 1e-6)
    }

    // MARK: - 帧率预算

    /// 幅宽越大帧率越低：每帧要合成的像素随幅宽涨，帧数照旧就会掉帧。
    ///
    /// 反证：把 `frameInterval` 三档改成恒 `1/20` → 红在「大窗口帧率更低」。
    func testFrameIntervalGrowsWithWindowWidth() {
        let narrow = ForestAmbientDriver.frameInterval(windowWidth: 1100)
        let mid = ForestAmbientDriver.frameInterval(windowWidth: 1300)
        let wide = ForestAmbientDriver.frameInterval(windowWidth: 1700)
        XCTAssertLessThan(narrow, mid, "档位没分开（1100 与 1300 同帧率）")
        XCTAssertLessThan(mid, wide, "幅宽变大帧率没让下来（大窗口每帧更贵）")
        // 默认（最小窗宽 1080）就是改造前各层的 20fps
        XCTAssertEqual(narrow, 1.0 / 20.0, accuracy: 1e-6)
    }

    // MARK: - 接线哨兵

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: relativePath, encoding: .utf8)
    }

    /// 去掉整行注释后的文本行 —— 注释里提到组件名不该让哨兵报绿
    /// （`ForestSeasonWiringTests` 被自己的文档注释绊倒过一次）。
    private func codeLines(_ source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { raw in
                let line = String(raw)
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return nil }
                return line
            }
    }

    /// 九层氛围装饰（改造前各起一颗表的那一批）。
    private static let ambientLayerFiles = [
        "Sources/AppUI/Components/ForestBirds.swift",
        "Sources/AppUI/Components/ForestKites.swift",
        "Sources/AppUI/Components/DriftingLeaves.swift",
        "Sources/AppUI/Components/ForestSnowfall.swift",
        "Sources/AppUI/Components/ForestSpringExtras.swift",
        "Sources/AppUI/Components/ForestSummerExtras.swift",
    ]

    /// MainView 必须挂上氛围钟驱动器、并把钟灌进环境。
    ///
    /// 反证 1：把 `ForestAmbientDriver(...)` 那行删掉 → 红在「挂驱动器」。
    /// 反证 2：把 `.environment(\.forestAmbientClock, ambientClock)` 删掉 →
    /// 红在「灌环境」。两条都不会让任何渲染测试变红 —— 画面照常动，
    /// 只是静默退回九颗表的老路，所以必须由哨兵钉着。
    func testMainViewMountsTheAmbientDriverAndInjectsTheClock() throws {
        let lines = codeLines(try source("Sources/AppUI/Views/MainView.swift"))
        let body = lines.joined(separator: "\n")
        XCTAssertTrue(body.contains("ForestAmbientDriver(clock: ambientClock"),
                      "MainView 没挂氛围钟驱动器 —— 九层会静默退回自己起表")
        XCTAssertTrue(body.contains(".environment(\\.forestAmbientClock, ambientClock)"),
                      "MainView 没把氛围钟灌进环境 —— 层读不到，驱动器等于白挂")
        // 驱动器要拿到窗口幅宽（帧率预算的自变量）
        XCTAssertTrue(body.contains("windowWidth: total"),
                      "驱动器没拿到窗口幅宽 —— 帧率预算那一档形同虚设")
    }

    /// 九层**不许再自己起表**：一个 `TimelineView` / 一个 `origin = Date()` 都不该有。
    ///
    /// ⚠️ 这是**结构不变量**而不是「某函数被调用」：判据方向是「多一个就红」，
    /// 所以 `if false { TimelineView(...) }` 这类死代码也会让它红（假阳，不是假绿）。
    ///
    /// 反证：往 `ForestBirds.swift` 里加回一行 `TimelineView(.animation(...))` →
    /// 红在对应文件。
    func testNoAmbientLayerKeepsItsOwnTicker() throws {
        for path in Self.ambientLayerFiles {
            let text = try source(path)
            XCTAssertFalse(text.contains("TimelineView("),
                           "\(path) 还在自己起表 —— 统一帧源被绕过去了")
            XCTAssertFalse(text.contains("origin = Date()"),
                           "\(path) 还留着自己的计时起点 —— 时间源没收敛")
        }
    }
}
