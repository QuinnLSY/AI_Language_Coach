import CoreGraphics
@testable import AppUI
import XCTest

/// 春天草地上的蝴蝶与蒲公英（#621）的布局纯函数。
///
/// 每条判据配一句「反证」——把实现换回错写法，断言必须红在**这一条**上。
final class ForestSpringExtrasTests: XCTestCase {

    private var butterflies: [ForestButterfly] { ButterflyLayout.springMeadow }
    private var stems: [ForestDandelion] { DandelionLayout.stems }
    private var fluffs: [ForestFluff] { DandelionLayout.fluffs }

    // MARK: - 蝴蝶

    /// 三只，各自站位错落（不挤成一堆、也不排排站）。
    ///
    /// 反证：把 `lane` 改成常量 0.5 → 红。
    func testButterfliesAreSpread() {
        XCTAssertEqual(butterflies.count, 3)
        let lanes = butterflies.map(\.lane).sorted()
        XCTAssertEqual(lanes, butterflies.map(\.lane), "站位必须从左往右排")
        for index in 1..<lanes.count {
            XCTAssertGreaterThan(lanes[index] - lanes[index - 1], 0.08, "两只蝴蝶挨太近")
        }
    }

    /// 航线的最低点必须**在草坡之上**：起伏不许大过巡航高度（否则一头扎进地里）。
    ///
    /// 反证：把 `altitude` 改回独立的 `rng.next(in: 16...52)` → 有机会红。
    func testFlightNeverDipsBelowGround() {
        let groundY: CGFloat = 100
        for butterfly in butterflies {
            for step in 0..<60 {
                let point = ButterflyLayout.position(
                    butterfly, width: 420, groundY: groundY,
                    elapsed: Double(step) * 0.21
                )
                XCTAssertLessThan(point.y, groundY,
                                  "\(butterfly.id) 号蝴蝶扎进草坡了（起伏大过高度）")
            }
        }
        // 直接钉数据关系：高度 > 起伏
        for butterfly in butterflies {
            XCTAssertGreaterThan(butterfly.altitude, butterfly.travelY)
        }
    }

    /// 航线是 8 字：纵向的频率是横向的**两倍**。
    ///
    /// 判据：过半个横向周期，横坐标换了、纵坐标回到原处（8 字的中点）。
    /// 反证：把 `position` 里的 `sin(2 * t)` 改成 `sin(t)`（变成斜椭圆）→ 红。
    func testFlightPathIsFigureEight() {
        let butterfly = butterflies[0]
        let half = butterfly.period / 2
        let first = ButterflyLayout.position(butterfly, width: 420, groundY: 100, elapsed: 1.3)
        let later = ButterflyLayout.position(butterfly, width: 420, groundY: 100, elapsed: 1.3 + half)
        XCTAssertNotEqual(first.x, later.x, "半周期后横向必须换位置")
        XCTAssertEqual(first.y, later.y, accuracy: 1e-9,
                       "半周期后纵向必须回到原处（纵向频率是横向的两倍）")
    }

    /// 翅膀在扇（压缩比随时间变），且始终在 0.28…1 之间（不许翻过来或缩成 0）。
    ///
    /// 反证：把 `flapScale` 改成常量 1 → 红在第一条。
    func testWingsFlapWithinBounds() {
        let butterfly = butterflies[1]
        var seen = Set<String>()
        for step in 0..<24 {
            let scale = ButterflyLayout.flapScale(butterfly, elapsed: Double(step) * 0.02)
            XCTAssertGreaterThanOrEqual(scale, 0.28 - 1e-9)
            XCTAssertLessThanOrEqual(scale, 1 + 1e-9)
            seen.insert(String(format: "%.4f", scale))
        }
        XCTAssertGreaterThan(seen.count, 6, "翅膀没有在扇")
    }

    /// 会掉头：航线上既有朝左也有朝右的时刻（朝左时翻面，不然永远一个侧影）。
    func testButterfliesTurnAround() {
        let butterfly = butterflies[2]
        var left = false
        var right = false
        for step in 0..<40 {
            let heading = ButterflyLayout.heading(butterfly, elapsed: Double(step) * 0.3)
            if heading < 0 { left = true }
            if heading > 0 { right = true }
        }
        XCTAssertTrue(left && right, "蝴蝶必须会掉头（航线是来回的 8 字）")
    }

    // MARK: - 蒲公英

    /// 三株、五缕絮，站位错落。
    func testDandelionsArePlaced() {
        XCTAssertEqual(stems.count, 3)
        XCTAssertEqual(fluffs.count, 5)
        let lanes = stems.map(\.lane).sorted()
        XCTAssertEqual(lanes, stems.map(\.lane))
    }

    /// 茎的摆动不超过摆幅（细茎是弯，不是转圈）。
    func testStemSwayStaysWithinAmplitude() {
        for stem in stems {
            for step in 0..<30 {
                let angle = DandelionLayout.swayDegrees(stem, elapsed: Double(step) * 0.17)
                XCTAssertLessThanOrEqual(abs(angle), stem.sway + 1e-9)
            }
        }
    }

    /// 飘絮永远**在起点之上**（它是往上飘走的，不是往下掉的）。
    ///
    /// 反证：把 `position` 里的 `− rise * t` 改成 `+` → 红。
    func testFluffRisesAwayFromGround() {
        let groundY: CGFloat = 100
        for fluff in fluffs {
            for step in 0..<40 {
                let point = DandelionLayout.position(
                    fluff, width: 420, groundY: groundY, elapsed: Double(step) * 0.4
                )
                XCTAssertLessThanOrEqual(point.y, groundY - fluff.startHeight + 1e-9,
                                         "飘絮不该往下掉")
            }
        }
    }

    /// 飘絮两端淡入淡出（不许在画面上「啪」地出现或消失）。
    ///
    /// 反证：把 `opacity` 的两端分支删掉（恒 1）→ 红。
    func testFluffFadesAtBothEnds() {
        for fluff in fluffs {
            // 反推到「刚脱开绒球」的那一刻（progress = 0）与「半途」（progress = 0.5）
            let born = DandelionLayout.opacity(fluff, elapsed: -fluff.phase * fluff.period)
            let midway = DandelionLayout.opacity(fluff, elapsed: (0.5 - fluff.phase) * fluff.period)
            let gone = DandelionLayout.opacity(fluff, elapsed: (0.98 - fluff.phase) * fluff.period)
            XCTAssertEqual(DandelionLayout.progress(fluff, elapsed: -fluff.phase * fluff.period),
                           0, accuracy: 1e-9)
            XCTAssertLessThan(born, 0.35, "刚脱开时必须是淡的（淡入）")
            XCTAssertEqual(midway, 1, accuracy: 1e-9, "半途最实")
            XCTAssertLessThan(gone, 0.35, "飘远了必须是淡的（淡出）")
        }
    }

    /// 飘絮循环：一个周期后回到同一个进度。
    func testFluffProgressIsCyclic() {
        for fluff in fluffs {
            let start = DandelionLayout.progress(fluff, elapsed: 2.4)
            XCTAssertEqual(start,
                           DandelionLayout.progress(fluff, elapsed: 2.4 + fluff.period),
                           accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(start, 0)
            XCTAssertLessThan(start, 1)
        }
    }

    /// 同种子同结果（重绘不许换一批花、换一批蝴蝶）。
    func testLayoutsAreDeterministic() {
        XCTAssertEqual(ButterflyLayout.make(seed: 0x4255_5446, count: 3),
                       ButterflyLayout.make(seed: 0x4255_5446, count: 3))
        XCTAssertEqual(DandelionLayout.makeStems(seed: 0x4441_4E44, count: 3),
                       DandelionLayout.makeStems(seed: 0x4441_4E44, count: 3))
        XCTAssertEqual(DandelionLayout.makeFluffs(seed: 0x464C_5546, count: 5),
                       DandelionLayout.makeFluffs(seed: 0x464C_5546, count: 5))
    }

    /// 冻结档：每缕絮都停在飘行的**正中间**（最实的那一段，不是刚出球也不是快没）。
    ///
    /// 反证：把 `frozenElapsed(_:)` 改成 `return 0` → 红在「0.5」这条上。
    func testFrozenPosesAreMidway() {
        for fluff in fluffs {
            XCTAssertGreaterThan(DandelionLayout.frozenElapsed(fluff), -fluff.period)
            XCTAssertEqual(DandelionLayout.progress(fluff,
                                                    elapsed: DandelionLayout.frozenElapsed(fluff)),
                           0.5, accuracy: 1e-9, "冻结时每缕絮都必须停在半途")
        }
        // 蝴蝶：每只各停各的（不许三只停在同一处）
        for butterfly in butterflies {
            XCTAssertGreaterThan(ButterflyLayout.frozenElapsed(butterfly), 0)
        }
        let spots = butterflies.map {
            ButterflyLayout.position($0, width: 420, groundY: 100,
                                     elapsed: ButterflyLayout.frozenElapsed($0)).y
        }
        XCTAssertEqual(Set(spots.map { String(format: "%.4f", $0) }).count, 3,
                       "冻结时三只蝴蝶不许停在同一处")
    }
}
