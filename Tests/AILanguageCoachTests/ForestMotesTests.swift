import AppKit
@testable import AppUI
import SwiftUI
import XCTest

// MARK: - 氛围微粒（P1-②：萤火虫 / 花粉）

/// 微粒层的**布局与节奏**回归。
///
/// 这一组只钉纯函数部分（`ForestMotes.make`）；画面上「真的在飘吗」由
/// `RenderTests/ForestMotesRenderTests` 用墨迹差判。
///
/// 判据纪律：不写「游走时长 ≠ 明灭时长」这类**恒真**断言（两段区间本就不重叠，
/// 怎么写都绿，抓不到任何回归）—— 只钉「换实现就会红」的那几条。
final class ForestMotesTests: XCTestCase {

    // MARK: 确定性（重绘不许换一场）

    func testLayoutIsDeterministicForAGivenSeed() {
        let first = ForestMotes.make(seed: 20_261_017, count: 14, night: true)
        let second = ForestMotes.make(seed: 20_261_017, count: 14, night: true)
        XCTAssertEqual(first, second, "同种子两次布局不同 → 每次重绘换一批萤火虫，观感是虫在瞬移")
    }

    func testDifferentSeedsGiveDifferentLayouts() {
        let fireflies = ForestMotes.make(seed: 20_261_017, count: 14, night: true)
        let pollen = ForestMotes.make(seed: 20_261_018, count: 18, night: false)
        // 日夜用的是两套种子：布局若重合，切到夜里就是「同一批点换了颜色」，
        // 而不是「萤火虫飞出来了」。
        XCTAssertNotEqual(Array(fireflies.prefix(8)), Array(pollen.prefix(8)),
                          "日夜布局重合 → 种子没生效，或两套布局是同一个常数表")
    }

    /// 反证：把 `make` 换成 `Double.random` 之后，上面那条确定性断言必须红。
    /// 这里用「递增种子给出不同布局」证明 `SeededRandom` 真的在被喂种子。
    func testSeedActuallyDrivesTheLayout() {
        let a = ForestMotes.make(seed: 1, count: 6, night: true)
        let b = ForestMotes.make(seed: 2, count: 6, night: true)
        XCTAssertNotEqual(a, b, "换种子布局不变 → 种子是摆设，布局其实是硬编码的")
    }

    func testPresetLayoutsAreStableAcrossCalls() {
        // 静态属性是真正上屏的那两份：它们也必须钉死。
        XCTAssertEqual(ForestMotes.fireflies, ForestMotes.make(seed: 20_261_017, count: 14, night: true))
        XCTAssertEqual(ForestMotes.pollen, ForestMotes.make(seed: 20_261_018, count: 18, night: false))
        XCTAssertEqual(ForestMotes.fireflies.count, 14)
        XCTAssertEqual(ForestMotes.pollen.count, 18)
    }

    // MARK: 布局合法性

    func testEveryMoteStaysInsideItsContainer() {
        for mote in ForestMotes.fireflies + ForestMotes.pollen {
            XCTAssertGreaterThanOrEqual(mote.x, 0.05, "横向出界 → 粒子贴在窗口边缘上")
            XCTAssertLessThanOrEqual(mote.x, 0.95)
            XCTAssertGreaterThanOrEqual(mote.y, 0.10)
            XCTAssertLessThanOrEqual(mote.y, 0.90)
            XCTAssertGreaterThan(mote.size, 0)
            XCTAssertGreaterThan(mote.walkDuration, 0)
            XCTAssertGreaterThan(mote.blinkDuration, 0)
        }
    }

    func testFirefliesKeepToTheLowerSkyWhilePollenSpreadsHigher() {
        // 萤火虫贴着林子在飞，不该飘到天顶去（那会跟星星打架）。
        let fireflyTop = ForestMotes.fireflies.map(\.y).min() ?? 1
        let pollenTop = ForestMotes.pollen.map(\.y).min() ?? 1
        XCTAssertGreaterThan(fireflyTop, pollenTop,
                             "萤火虫飘得比花粉还高 → 夜里山顶一片虫，分不清是虫还是星")
    }

    func testFirefliesAreBolderAndCalmerThanPollen() {
        let fireflySize = ForestMotes.fireflies.map(\.size).reduce(0, +) / Double(ForestMotes.fireflies.count)
        let pollenSize = ForestMotes.pollen.map(\.size).reduce(0, +) / Double(ForestMotes.pollen.count)
        XCTAssertGreaterThan(fireflySize, pollenSize, "夜里的萤火虫该比白天的花粉醒目")

        // 白天飘得慢、幅度小：花粉是「浮」在空气里的，不是被吹着跑。
        let pollenWalk = ForestMotes.pollen.map(\.walkX).reduce(0, +) / Double(ForestMotes.pollen.count)
        let fireflyWalk = ForestMotes.fireflies.map(\.walkX).reduce(0, +) / Double(ForestMotes.fireflies.count)
        XCTAssertLessThan(pollenWalk, fireflyWalk)
    }

    // MARK: 节奏（错峰：整片一起亮一起暗 = 节拍器，不是萤火虫）

    func testBlinkPhasesAreSpreadOut() {
        // 明灭时长的**极差**必须够大：全都一样长就是整片同频闪。
        let durations = ForestMotes.fireflies.map(\.blinkDuration)
        let spread = (durations.max() ?? 0) - (durations.min() ?? 0)
        XCTAssertGreaterThan(spread, 1.0,
                             "所有萤火虫明灭一样快 → 整片同时亮同时暗，是节拍器不是萤火虫")
    }

    func testWalkPhasesAreSpreadOut() {
        let durations = ForestMotes.fireflies.map(\.walkDuration)
        let spread = (durations.max() ?? 0) - (durations.min() ?? 0)
        XCTAssertGreaterThan(spread, 2.0, "所有萤火虫游走一样快 → 整片一起荡，看着像整层在平移")
    }
}
