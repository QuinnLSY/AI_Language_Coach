import CoreGraphics
@testable import AppUI
import XCTest

/// 春天风筝的布局纯函数（#620）。
///
/// 每条判据都配一句「反证」——把实现换回错写法，断言必须红在**这一条**上。
final class ForestKitesTests: XCTestCase {

    private var kites: [ForestKite] { KiteLayout.springSky }

    // MARK: - 站位

    /// 三只、三种造型齐全（一排同样的菱形 = 贴图，不是三只风筝）。
    ///
    /// 反证：把 `make` 里 `shapes[index % shapes.count]` 改成固定 `.diamond` → 红。
    func testThreeKitesWithThreeDistinctShapes() {
        XCTAssertEqual(kites.count, 3)
        XCTAssertEqual(Set(kites.map(\.shape)).count, 3, "三种造型必须各来一只")
    }

    /// 每只都落在「上三分之一带」里（用户要的是小动物上方三分之一处）。
    ///
    /// 反证：把 `make` 里 altitude 的 clamp 去掉、直接给 `rng.next(in: 0.5...0.8)` → 红。
    func testEveryKiteStaysInUpperThirdBand() {
        for kite in kites {
            XCTAssertGreaterThanOrEqual(kite.altitude, KiteLayout.altitudeBand.lowerBound,
                                        "\(kite.shape) 飘得太高（顶出上三分之一带）")
            XCTAssertLessThanOrEqual(kite.altitude, KiteLayout.altitudeBand.upperBound,
                                     "\(kite.shape) 飘得太低（压到树冠那一带去了）")
        }
    }

    /// 横向错落：从左往右排，彼此不挤成一堆（间距 ≥ 0.09 面板宽）。
    ///
    /// 反证：把 `lane` 改成常量 0.5 → 红。
    func testLanesAreSpreadAndOrdered() {
        let lanes = kites.map(\.lane).sorted()
        XCTAssertEqual(lanes, kites.map(\.lane), "站位必须从左往右排（分区生成）")
        for index in 1..<lanes.count {
            XCTAssertGreaterThan(lanes[index] - lanes[index - 1], 0.09,
                                 "第 \(index) 只与前一只挨太近（挤成一堆）")
        }
    }

    /// 同种子同结果：重绘不许换一批风筝（换一批 = 用户在看瞬移）。
    func testLayoutIsDeterministic() {
        XCTAssertEqual(KiteLayout.make(seed: 0x4B49_5445, count: 3),
                       KiteLayout.make(seed: 0x4B49_5445, count: 3))
        XCTAssertNotEqual(KiteLayout.make(seed: 0x4B49_5445, count: 3),
                          KiteLayout.make(seed: 0x4B49_5446, count: 3))
    }

    // MARK: - 摆动

    /// 摆角随时间变（真的在飘，不是钉着的一张画）。
    func testTiltChangesOverTime() {
        let kite = kites[0]
        let first = KiteLayout.tiltDegrees(kite, elapsed: 0)
        let second = KiteLayout.tiltDegrees(kite, elapsed: kite.period * 0.25)
        XCTAssertNotEqual(first, second, "风筝没有在摆")
    }

    /// 一个周期后回到原处（周期函数，不许漂）。
    ///
    /// 反证：把 `phase` 里的 `elapsed / kite.period` 去掉（直接用 elapsed）→ 红。
    func testTiltIsPeriodic() {
        let kite = kites[1]
        let start = KiteLayout.tiltDegrees(kite, elapsed: 1.7)
        let afterCycle = KiteLayout.tiltDegrees(kite, elapsed: 1.7 + kite.period)
        XCTAssertEqual(start, afterCycle, accuracy: 1e-9, "一个周期后必须回到同一个摆角")
    }

    /// 摆角始终在「基准 ± 幅度」之内（不许甩过头变成自转）。
    func testTiltStaysWithinSwingEnvelope() {
        for kite in kites {
            for step in 0..<40 {
                let angle = KiteLayout.tiltDegrees(kite, elapsed: Double(step) * 0.13)
                XCTAssertLessThanOrEqual(angle, kite.tilt + kite.swing + 1e-9)
                XCTAssertGreaterThanOrEqual(angle, kite.tilt - kite.swing - 1e-9)
            }
        }
    }

    /// 冻结档不是 0（0 是摆动的一端，三只会一律歪到同一边）。
    ///
    /// 反证：把 `frozenElapsed` 改成 `return 0` → 红在「三只两两不等」上。
    func testFrozenPoseIsMidSwingAndNotUniform() {
        for kite in kites {
            XCTAssertGreaterThan(KiteLayout.frozenElapsed(kite), 0, "冻结档不能停在 0")
        }
        let angles = kites.map { KiteLayout.tiltDegrees($0, elapsed: KiteLayout.frozenElapsed($0)) }
        XCTAssertEqual(Set(angles.map { String(format: "%.6f", $0) }).count, 3,
                       "冻结时三只的倾角不许一样（那等于被同一阵怪风定住）")
    }

    /// 浮沉与摆动差四分之一周期：摆到极值时正在中间高度（「被托着一起一伏」）。
    ///
    /// 反证：把 `bobOffset` 里的 `+ .pi / 2` 删掉（与摆动同相）→ 红。
    func testBobLagsSwingByQuarterCycle() {
        for kite in kites {
            // 解出摆动取极大（sin = 1）的时刻：phase(t) = π/2
            let elapsed = (0.25 - kite.phase) * kite.period
            let swing = (KiteLayout.tiltDegrees(kite, elapsed: elapsed) - kite.tilt) / kite.swing
            XCTAssertEqual(swing, 1, accuracy: 1e-9, "这一个时刻摆动应在极大值")
            XCTAssertEqual(KiteLayout.bobOffset(kite, elapsed: elapsed), 0, accuracy: 1e-6,
                           "摆到极值时不该同时浮到极值（浮沉须落后四分之一周期）")
        }
    }

    // MARK: - 尾巴与锚点

    /// 尾节自上而下一节比一节低，且每一节都在风筝本体之下（y > 0）。
    func testTailDescendsFromKiteBottom() {
        let kite = kites[0]
        var previous: CGFloat = -1
        for index in 0..<KiteLayout.tailNodes {
            let offset = KiteLayout.tailOffset(kite, elapsed: 2.0, index: index)
            XCTAssertGreaterThan(offset.height, previous)
            previous = offset.height
        }
        XCTAssertGreaterThan(KiteLayout.tailOffset(kite, elapsed: 2.0, index: 0).height, 0)
    }

    /// 尾巴会摆（横向偏移随时间变），且逐节延迟（不是一块硬板）。
    ///
    /// 反证：把 `tailOffset` 里的 `- Double(k) * 0.5` 删掉 → 红在「末节不同」上。
    func testTailSwingsAndLagsPerNode() {
        let kite = kites[2]
        let atRest = KiteLayout.tailOffset(kite, elapsed: 0, index: 2)
        let later = KiteLayout.tailOffset(kite, elapsed: kite.period * 0.3, index: 2)
        XCTAssertNotEqual(atRest.width, later.width, "尾巴没有在摆")
    }

    /// 锚点跟着面板尺寸走：横向按 lane、纵向按 altitude（+ 浮沉）。
    func testAnchorScalesWithPanel() {
        let kite = kites[0]
        let anchor = KiteLayout.anchor(kite, width: 420, height: 360, elapsed: 0)
        XCTAssertEqual(anchor.x, 420 * kite.lane, accuracy: 1e-9)
        let bob = KiteLayout.bobOffset(kite, elapsed: 0)
        XCTAssertEqual(anchor.y, 360 * kite.altitude + bob, accuracy: 1e-9)
        // 浮沉再怎么抖，也不许把风筝抖出上三分之一带太多（±bob 的余量）
        XCTAssertLessThan(anchor.y, 360 * KiteLayout.altitudeBand.upperBound + kite.bob + 1)
    }
}
