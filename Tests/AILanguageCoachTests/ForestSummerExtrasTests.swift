import CoreGraphics
@testable import AppUI
import XCTest

/// 夏天草地上的光斑与流萤（#623）的布局纯函数。
final class ForestSummerExtrasTests: XCTestCase {

    private var dapples: [ForestDapple] { DappleLayout.summerGlade }
    private var flies: [ForestFirefly] { FireflyLayout.summerNight }

    // MARK: - 光斑

    /// 十块光斑，横向铺开（不堆在一处）。
    func testDapplesArePlaced() {
        XCTAssertEqual(dapples.count, 10)
        let lanes = dapples.map(\.lane).sorted()
        for index in 1..<lanes.count {
            XCTAssertLessThan(lanes[index] - lanes[index - 1], 0.5, "光斑之间的空档太大")
        }
    }

    /// 光斑**落在坡面上**（是摊在地上的光，不是浮在半空的一团）。
    ///
    /// 反证：把 `center` 里的 `y: groundY` 改成 `groundY - 40` → 红。
    func testDapplesLieOnTheGround() {
        for dapple in dapples {
            let spot = DappleLayout.center(dapple, width: 420, groundY: 120, windDrift: 0)
            XCTAssertEqual(spot.y, 120, accuracy: 1e-9)
        }
    }

    /// `inset`（往坡里落的深浅）**只加一次** —— 加两次光斑整片沉进坡里。
    ///
    /// 这是 2026-10-23 审计实测到的缺陷：`center` 自己加了 `inset`，调用点照
    /// 落叶堆 / 南瓜那几处的写法又加了一遍（`groundLine(x) + dapple.inset`），
    /// 十块光斑于是沉下 0…20pt（而不是 0…10）。
    ///
    /// 两条断言互相兜底，缺一条就能溜过去：
    /// - `center` 不许再加 `inset`（否则 `baseY` + `center` = 两倍）；
    /// - `baseY` 必须加 `inset`（否则整片光斑浮在坡面上）。
    ///
    /// 反证：在 `center` 里加回 `+ dapple.inset` → 红在第一条；
    /// 把 `baseY` 的 `+ dapple.inset` 删掉 → 红在第二条。
    func testDappleInsetIsAppliedExactlyOnce() {
        let ground: ForestGroundSurface = { _ in 120 }
        for dapple in dapples {
            // ① center 是纯透传：传什么高度就落在什么高度
            let passed = DappleLayout.center(dapple, width: 420, groundY: 130, windDrift: 0)
            XCTAssertEqual(passed.y, 130, accuracy: 1e-9,
                           "center 自己加了 inset：调用点再走 baseY 就翻成两倍")
            // ② baseY 才是唯一加 inset 的地方
            let base = DappleLayout.baseY(dapple, width: 420, groundLine: ground)
            XCTAssertEqual(base, 120 + dapple.inset, accuracy: 1e-9,
                           "baseY 没把 inset 加进去：光斑浮在坡面上方")
            // ③ 视图用的合成口径：坡面 + inset 恰好一次
            let composed = DappleLayout.center(dapple, width: 420, groundY: base, windDrift: 0)
            XCTAssertEqual(composed.y, 120 + dapple.inset, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(composed.y - 120, 10 + 1e-9,
                                     "inset 上限是 10pt：再深就是被加了两遍")
        }
    }

    /// 呼吸在 0.55…1 之间，且真的在变（树冠在动，光就一明一暗）。
    ///
    /// 反证：把 `brightness` 改成常量 → 红在「真的在变」这条。
    func testDapplesBreatheWithinBounds() {
        for dapple in dapples {
            var seen = Set<String>()
            for step in 0..<24 {
                let value = DappleLayout.brightness(dapple, elapsed: Double(step) * 0.3)
                XCTAssertGreaterThanOrEqual(value, 0.55 - 1e-9)
                XCTAssertLessThanOrEqual(value, 1 + 1e-9)
                seen.insert(String(format: "%.4f", value))
            }
            XCTAssertGreaterThan(seen.count, 6, "光斑没有在呼吸")
        }
    }

    /// 冻结档停在**不暗**的那一档（关动效不许做成「光没了」）。
    ///
    /// 反证：把 `frozenElapsed` 改成 `return 0` → 有机会红（停在呼吸的低点）。
    func testFrozenDapplesStayBright() {
        for dapple in dapples {
            // 允许为负：正弦是周期的，负的时刻等价于这一周期里靠后的那一瞬
            XCTAssertNotEqual(DappleLayout.frozenElapsed(dapple), 0)
            let value = DappleLayout.brightness(dapple, elapsed: DappleLayout.frozenElapsed(dapple))
            XCTAssertEqual(value, 1, accuracy: 1e-9, "冻结时必须停在最亮那一瞬")
        }
    }

    // MARK: - 流萤

    /// 六只，巡航高度必须大于起伏（不许飞着飞着钻进草里）。
    ///
    /// 反证：把 `altitude` 改回独立随机 → 有机会红。
    func testFirefliesStayAboveTheGrass() {
        XCTAssertEqual(flies.count, 6)
        for fly in flies {
            XCTAssertGreaterThan(fly.altitude, fly.travelY)
            for step in 0..<40 {
                let spot = FireflyLayout.position(fly, width: 420, groundY: 120,
                                                  elapsed: Double(step) * 0.4)
                XCTAssertLessThan(spot.y, 120, "萤火虫钻进草里了")
            }
        }
    }

    /// 航线是 8 字（纵向频率是横向的两倍），与蝴蝶同一条纪律。
    func testFireflyPathIsFigureEight() {
        let fly = flies[0]
        let first = FireflyLayout.position(fly, width: 420, groundY: 120, elapsed: 1.1)
        let later = FireflyLayout.position(fly, width: 420, groundY: 120,
                                           elapsed: 1.1 + fly.period / 2)
        XCTAssertNotEqual(first.x, later.x)
        XCTAssertEqual(first.y, later.y, accuracy: 1e-9)
    }

    /// 明灭在 0.18…1 之间，且与漫游**不同频**（同频就是整片一起亮一起暗）。
    func testFirefliesBlinkOnTheirOwnClock() {
        for fly in flies {
            var seen = Set<String>()
            for step in 0..<20 {
                let value = FireflyLayout.glow(fly, elapsed: Double(step) * 0.17)
                XCTAssertGreaterThanOrEqual(value, 0.18 - 1e-9)
                XCTAssertLessThanOrEqual(value, 1 + 1e-9)
                seen.insert(String(format: "%.4f", value))
            }
            XCTAssertGreaterThan(seen.count, 6, "萤火虫没有在明灭")
            XCTAssertNotEqual(fly.blinkPeriod, fly.period, "明灭不许与漫游同频")
        }
    }

    /// 冻结档停在**亮着**的那一档（关动效不许做成关灯）。
    func testFrozenFirefliesStayLit() {
        for fly in flies {
            XCTAssertNotEqual(FireflyLayout.frozenElapsed(fly), 0)
            let value = FireflyLayout.glow(fly, elapsed: FireflyLayout.frozenElapsed(fly))
            XCTAssertEqual(value, 1, accuracy: 1e-9, "冻结时萤火虫必须是最亮的")
        }
    }

    /// 同种子同结果。
    func testLayoutsAreDeterministic() {
        XCTAssertEqual(DappleLayout.make(seed: 0x4441_504C, count: 10),
                       DappleLayout.make(seed: 0x4441_504C, count: 10))
        XCTAssertEqual(FireflyLayout.make(seed: 0x4649_5246, count: 6),
                       FireflyLayout.make(seed: 0x4649_5246, count: 6))
    }

    // MARK: - 蜻蜓

    /// 蜻蜓的冻结档**停在悬停段的正中间**，与「什么时候渲染」无关。
    ///
    /// 这是 `ForestDragonfliesRenderTests.testStillFrameIsDeterministic` 的真正落点：
    /// 离屏 `TimelineView` 不推进相位，渲染侧那条「两遍一致」只是弱闸；
    /// 只要 `frozenElapsed` 还是飞虫的纯函数，静态帧就不该抖。
    ///
    /// ⚠️ 相位在算式里**正好抵消**：`raw = hoverFraction*0.5 − phase + 1 + phase`，
    /// 所以 `local` 与 `phase` 无关，恒等于 `hoverFraction * 0.5`。
    ///
    /// 反证：把 `frozenElapsed` 改成 `fly.dartPeriod * (0.5 − fly.phase + 1)`
    /// （周期中段）→ 红在「必须落在悬停段」—— 中段可能落进急转，
    /// 那是一只被钉在半空的蜻蜓。
    func testFrozenDragonfliesRestMidHover() {
        let glade = DragonflyLayout.summerGlade
        XCTAssertFalse(glade.isEmpty, "夏天草尖上得有蜻蜓")
        for fly in glade {
            let raw = DragonflyLayout.frozenElapsed(fly) / fly.dartPeriod + fly.phase
            let local = raw - raw.rounded(.down)
            XCTAssertEqual(local, DragonflyLayout.hoverFraction * 0.5, accuracy: 1e-9,
                           "冻结档必须停在悬停段正中间")
            XCTAssertLessThan(local, DragonflyLayout.hoverFraction,
                              "冻结档不许落进急转段（会被定格在半空）")
        }
    }

    /// 冻结姿态重复求值完全一致（悬停点是种子派生的，不是 `Double.random`）。
    func testFrozenDragonflyPosesRepeatExactly() {
        let pose = { (fly: ForestDragonfly) in
            DragonflyLayout.position(fly, width: 420, groundY: 120,
                                     elapsed: DragonflyLayout.frozenElapsed(fly))
        }
        let first = DragonflyLayout.summerGlade.map(pose)
        let second = DragonflyLayout.summerGlade.map(pose)
        XCTAssertEqual(first, second, "静态档连姿态都会变 = 有人在渲染路径里放了真随机")
        XCTAssertEqual(first.count, DragonflyLayout.summerGlade.count)
    }
}
