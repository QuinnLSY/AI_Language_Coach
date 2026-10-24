import CoreGraphics
@testable import AppUI
import XCTest

/// 夏天蜻蜓的悬停 / 急转纯函数（#635）。
///
/// 每条判据都配一句「反证」——把实现换回错写法，断言必须红在**这一条**上。
final class ForestDragonfliesTests: XCTestCase {

    private var swarm: [ForestDragonfly] { DragonflyLayout.summerGlade }

    private let width: CGFloat = 460
    private let groundY: CGFloat = 150

    /// 让「周期内的进度」正好落在 `local` 的那个时刻（反解 `position` 里的 raw）。
    private func elapsed(_ fly: ForestDragonfly, atLocal local: Double, lap: Int = 1) -> Double {
        fly.dartPeriod * (local - fly.phase + Double(lap))
    }

    private func spot(_ fly: ForestDragonfly, atLocal local: Double, lap: Int = 1) -> CGPoint {
        DragonflyLayout.position(fly, width: width, groundY: groundY,
                                 elapsed: elapsed(fly, atLocal: local, lap: lap))
    }

    // MARK: - 站位

    /// 五只、横向错落（挤在一起就不是「各自占一根草尖」了）。
    ///
    /// 反证：把 `make` 里 `lane` 改成常量 0.5 → 红。
    func testFiveDragonfliesSpreadAcrossTheBand() {
        XCTAssertEqual(swarm.count, 5)
        let lanes = swarm.map(\.lane).sorted()
        XCTAssertEqual(lanes, swarm.map(\.lane), "站位必须从左往右排（分区生成）")
        for index in 1..<lanes.count {
            XCTAssertGreaterThan(lanes[index] - lanes[index - 1], 0.05,
                                 "第 \(index) 只与前一只挨太近（挤成一堆）")
        }
    }

    /// 同种子同结果：重绘不许换一批蜻蜓，也不许换一批悬停点。
    func testLayoutIsDeterministic() {
        XCTAssertEqual(DragonflyLayout.make(seed: 0x4452_4144, count: 5),
                       DragonflyLayout.make(seed: 0x4452_4144, count: 5))
        XCTAssertNotEqual(DragonflyLayout.make(seed: 0x4452_4144, count: 5),
                          DragonflyLayout.make(seed: 0x4452_4145, count: 5))
        let fly = swarm[0]
        for lap in 1...4 {
            XCTAssertEqual(DragonflyLayout.hoverAnchor(fly, cycle: lap, width: width, groundY: groundY),
                           DragonflyLayout.hoverAnchor(fly, cycle: lap, width: width, groundY: groundY))
        }
    }

    // MARK: - 悬停

    /// 悬停段里它**待在原地**（只在微颤的幅度内抖），不是在飞。
    ///
    /// 反证：把 `jitter` 那一项删掉改成按 `dartSpan` 漫游 → 红。
    func testHoverHoldsItInOnePlace() {
        for fly in swarm {
            let perch = DragonflyLayout.hoverAnchor(fly, cycle: 2, width: width, groundY: groundY)
            for step in 0...20 {
                let local = DragonflyLayout.hoverFraction * 0.9 * Double(step) / 20
                let spot = spot(fly, atLocal: local, lap: 2)
                let offset = hypot(spot.x - perch.x, spot.y - perch.y)
                XCTAssertLessThan(offset, fly.jitter * 1.2 + 0.01,
                                  "第 \(fly.id) 只悬停时挪出了微颤范围（那是在飞，不是在停）")
            }
        }
    }

    /// 悬停段的两端必须**正好落在悬停点上**。
    ///
    /// ⚠️ 这是「每次进出悬停都瞬移一下」的唯一硬判据：微颤取整数个振荡
    /// （`hoverBeats`），首尾才都归零。只采样看「跳得大不大」是测不出来的 ——
    /// 小的相位误差照样是瞬移。
    ///
    /// 反证：把 `hoverBeats` 改成 2.5 → 红在这一条（末端不再回到悬停点）。
    func testHoverSegmentStartsAndEndsOnThePerch() {
        for fly in swarm {
            for lap in 1...3 {
                let perch = DragonflyLayout.hoverAnchor(fly, cycle: lap,
                                                        width: width, groundY: groundY)
                let start = spot(fly, atLocal: 0, lap: lap)
                XCTAssertEqual(start.x, perch.x, accuracy: 1e-6, "悬停开始处不在悬停点上")
                XCTAssertEqual(start.y, perch.y, accuracy: 1e-6, "悬停开始处不在悬停点上")
                let end = spot(fly, atLocal: DragonflyLayout.hoverFraction - 1e-9, lap: lap)
                XCTAssertEqual(end.x, perch.x, accuracy: 1e-6, "悬停结束处不在悬停点上（瞬移了）")
                XCTAssertEqual(end.y, perch.y, accuracy: 1e-6, "悬停结束处不在悬停点上（瞬移了）")
            }
        }
    }

    // MARK: - 急转

    /// 急转的终点正是**下一轮**的悬停点（换地方是换到另一个停点，不是甩出去）。
    ///
    /// 反证：把 `position` 里 `cycle + 1` 改成 `cycle + 2` → 红（且画面上会瞬移）。
    func testDartLandsOnTheNextPerch() {
        for fly in swarm {
            for lap in 1...3 {
                let next = DragonflyLayout.hoverAnchor(fly, cycle: lap + 1,
                                                       width: width, groundY: groundY)
                let landed = spot(fly, atLocal: 1 - 1e-9, lap: lap)
                XCTAssertEqual(landed.x, next.x, accuracy: 1e-6, "急转没落在下一个悬停点上")
                XCTAssertEqual(landed.y, next.y, accuracy: 1e-6, "急转没落在下一个悬停点上")
            }
        }
    }

    /// 急转是真的挪了地方（不是原地抖一下），且比悬停快得多。
    ///
    /// 反证：把 `hoverFraction` 改成 0.98（几乎整轮都在悬停）→ 红在第一条。
    func testDartCoversRealGroundAndIsQuick() {
        for fly in swarm {
            var longest = 0.0
            for lap in 1...6 {
                let from = DragonflyLayout.hoverAnchor(fly, cycle: lap, width: width, groundY: groundY)
                let to = DragonflyLayout.hoverAnchor(fly, cycle: lap + 1,
                                                     width: width, groundY: groundY)
                longest = max(longest, hypot(to.x - from.x, to.y - from.y))
            }
            XCTAssertGreaterThan(longest, 12, "第 \(fly.id) 只六轮都没挪过 12pt（那不是急转）")
            let dartSeconds = fly.dartPeriod * (1 - DragonflyLayout.hoverFraction)
            XCTAssertLessThan(dartSeconds, 3.2, "急转拖得太久（成了慢慢飘过去）")
        }
    }

    /// 整条航迹不许有瞬移（连续性的**兜底网**，硬判据在上面两条）。
    func testTrackHasNoTeleports() {
        for fly in swarm {
            var previous = DragonflyLayout.position(fly, width: width, groundY: groundY, elapsed: 0)
            for step in 1...1200 {
                let now = Double(step) * 0.02
                let spot = DragonflyLayout.position(fly, width: width, groundY: groundY, elapsed: now)
                let jump = hypot(spot.x - previous.x, spot.y - previous.y)
                XCTAssertLessThan(jump, 2.0, "第 \(fly.id) 只在 \(now) 秒处瞬移了 \(jump)pt")
                previous = spot
            }
        }
    }

    /// 始终在草坡**之上**（游走比高度还大的话会一头扎进草里）。
    ///
    /// 反证：把 `make` 里 `altitude` 改成 `rng.next(in: 0...4)` → 红。
    func testDragonfliesStayAboveTheGrassTips() {
        for fly in swarm {
            for step in 0...200 {
                let spot = DragonflyLayout.position(fly, width: width, groundY: groundY,
                                                    elapsed: Double(step) * 0.19)
                XCTAssertLessThan(spot.y, groundY, "第 \(fly.id) 只钻到草坡下面去了")
            }
        }
    }

    // MARK: - 冻结档与扇翅

    /// 冻结档停在**悬停中**，不是停在半空（半空中被定住 = 钉在墙上），也不是停在 0。
    ///
    /// 反证：把 `frozenElapsed` 改成 `return 0` → 红在「大于 0」；
    /// 把 `hoverFraction * 0.5` 改成 `0.9` → 红在「落在悬停段内」。
    func testFrozenPoseIsHoveringNotMidAir() {
        for fly in swarm {
            let frozen = DragonflyLayout.frozenElapsed(fly)
            XCTAssertGreaterThan(frozen, 0, "冻结档不能停在 0")
            let raw = frozen / fly.dartPeriod + fly.phase
            let local = raw - raw.rounded(.down)
            XCTAssertLessThan(local, DragonflyLayout.hoverFraction,
                              "冻结档落在急转段里了（一只被定在半空的蜻蜓）")
            XCTAssertGreaterThan(local, 0, "冻结档落在悬停段之外")
        }
    }

    /// 扇翅量落在 0…1 且是周期的（翅膀不会越扇越大）。
    func testFlapIsBoundedAndPeriodic() {
        for fly in swarm {
            for step in 0...30 {
                let value = DragonflyLayout.flap(fly, elapsed: Double(step) * 0.037)
                XCTAssertGreaterThanOrEqual(value, -1e-9)
                XCTAssertLessThanOrEqual(value, 1 + 1e-9)
            }
            let first = DragonflyLayout.flap(fly, elapsed: 1.3)
            XCTAssertEqual(first, DragonflyLayout.flap(fly, elapsed: 1.3 + fly.flapPeriod),
                           accuracy: 1e-9, "一个扇翅周期后该回到同一姿态")
        }
    }
}
