@testable import AppUI
import Foundation
import XCTest

/// 批次六 · E 可玩彩蛋：连点节拍、天空点击翻译、拖天体切日夜、点草地的花坛账本。
final class PlayfulEasterEggTests: XCTestCase {

    // MARK: - 连点节拍器

    /// 窗口内凑满 5 次 → 恰好第 5 次触发一次，且此后从零重数。
    ///
    /// 反证：删掉 AmbienceTapPacer.register 里的 `stamps.removeAll()` → 第二轮提前触发 → 红。
    func testFiveTapsInsideTheWindowTriggerExactlyOnceThenRestart() {
        var pacer = AmbienceTapPacer(requiredTaps: 5, window: 2.0)
        let base = Date(timeIntervalSince1970: 1_000)

        for offset in [0.0, 0.3, 0.6, 0.9] {
            XCTAssertFalse(pacer.register(at: base.addingTimeInterval(offset)),
                           "第 \(Int(offset / 0.3) + 1) 次不该触发")
        }
        XCTAssertTrue(pacer.register(at: base.addingTimeInterval(1.2)), "第 5 次应当触发")

        // 触发后从零重数：再来 2 次远远不够。
        XCTAssertFalse(pacer.register(at: base.addingTimeInterval(1.5)))
        XCTAssertFalse(pacer.register(at: base.addingTimeInterval(1.8)))
    }

    /// 超出窗口的点击不累计：慢慢点永远攒不出一次「连点」。
    func testTapsOutsideTheWindowNeverAccumulate() {
        var pacer = AmbienceTapPacer(requiredTaps: 5, window: 2.0)
        let base = Date(timeIntervalSince1970: 1_000)

        for index in 0..<20 {
            XCTAssertFalse(
                pacer.register(at: base.addingTimeInterval(Double(index) * 2.1)),
                "每 2.1 秒点一下（窗口 2 秒）永远不该触发；第 \(index + 1) 次却触发了"
            )
        }
    }

    /// 窗口是滑动的：前 4 次、歇一拍（< 窗口）、再点 —— 最早的几次已出窗，不能凑数。
    func testWindowSlidesSoStaleTapsExpire() {
        var pacer = AmbienceTapPacer(requiredTaps: 5, window: 2.0)
        let base = Date(timeIntervalSince1970: 1_000)

        for offset in [0.0, 0.3, 0.6, 0.9] {
            _ = pacer.register(at: base.addingTimeInterval(offset))
        }
        // 2.7s 后再点：0.0/0.3/0.6 三次都已出窗（距今 > 2s），只剩 0.9 这次。
        XCTAssertFalse(pacer.register(at: base.addingTimeInterval(2.7)), "过期点击不该被算数")
        // 从有效点击重新凑满：0.9 + 2.7…3.0，第 5 次有效点击触发。
        for offset in [2.8, 2.9, 3.0] {
            XCTAssertFalse(pacer.register(at: base.addingTimeInterval(offset)))
        }
        XCTAssertTrue(pacer.register(at: base.addingTimeInterval(3.1)), "过期清理后连点应照常凑满")
    }

    // MARK: - ForestStage 的天空翻译

    /// 每次点天空都记一笔叶脉冲；不满连点时氛围演出照常。
    ///
    /// 反证：删掉 ForestStage.registerSkyTap 里的 `skyTapTick += 1` → 红。
    @MainActor
    func testSkyTapsRecordLeafPulsesWithoutHidingAmbience() {
        let stage = ForestStage()
        let base = Date()

        for index in 0..<4 {
            stage.registerSkyTap(at: base.addingTimeInterval(Double(index) * 0.3))
        }
        XCTAssertEqual(stage.skyTapTick, 4)
        XCTAssertFalse(stage.ambientHidden, "4 连点不该触发隐藏")
    }

    /// 窗口内 5 连点 → 第 5 次把氛围演出收起来；再连点 5 次换回来。
    ///
    /// 反证：删掉 registerSkyTap 里的 pacer 分支（ambientHidden.toggle()）→ 红。
    @MainActor
    func testFiveQuickSkyTapsToggleTheAmbienceOffAndOn() {
        let stage = ForestStage()
        let base = Date()

        for index in 0..<5 {
            stage.registerSkyTap(at: base.addingTimeInterval(Double(index) * 0.3))
        }
        XCTAssertEqual(stage.skyTapTick, 5, "隐藏档也是一次点击，叶脉冲照记")
        XCTAssertTrue(stage.ambientHidden, "5 连点应收起氛围演出")

        // 再来 5 次：第 10 下换回默认演出。
        for index in 5..<10 {
            stage.registerSkyTap(at: base.addingTimeInterval(Double(index) * 0.3))
        }
        XCTAssertFalse(stage.ambientHidden, "再来 5 连点应恢复演出")
        XCTAssertEqual(stage.skyTapTick, 10)
    }

    // MARK: - 拖天体切日夜

    /// 白天往下拖太阳过阈值 → 切；往上拖（反方向）不切。
    ///
    /// 反证：把 shouldToggleByDrag 的方向判断删掉（只比大小）→ 反方向分支红。
    func testDraggingTheSunDownPastThresholdTogglesNight() {
        XCTAssertFalse(ForestAtmosphere.shouldToggleByDrag(isNight: false, dragHeight: 89),
                       "差 1pt 都不算拖到位")
        XCTAssertTrue(ForestAtmosphere.shouldToggleByDrag(isNight: false, dragHeight: 90))
        XCTAssertTrue(ForestAtmosphere.shouldToggleByDrag(isNight: false, dragHeight: 200))
        XCTAssertFalse(ForestAtmosphere.shouldToggleByDrag(isNight: false, dragHeight: -200),
                       "白天把太阳往上拖不该切到夜里")
        XCTAssertFalse(ForestAtmosphere.shouldToggleByDrag(isNight: false, dragHeight: 0))
    }

    /// 夜里往上拖月亮过阈值 → 切；往下拖不切。
    func testDraggingTheMoonUpPastThresholdTogglesDay() {
        XCTAssertTrue(ForestAtmosphere.shouldToggleByDrag(isNight: true, dragHeight: -90))
        XCTAssertTrue(ForestAtmosphere.shouldToggleByDrag(isNight: true, dragHeight: -200))
        XCTAssertFalse(ForestAtmosphere.shouldToggleByDrag(isNight: true, dragHeight: -89))
        XCTAssertFalse(ForestAtmosphere.shouldToggleByDrag(isNight: true, dragHeight: 200),
                       "夜里把月亮往下拖不该切到白天")
    }

    /// 拖拽位移只放行「该方向」，越界钳住（拖不动的手感）；反方向位移一律归零。
    ///
    /// 反证：把 clampedDragOffset 的方向分支删掉 → 反方向/越界用例红。
    func testDragOffsetClampsInTheDragDirectionOnly() {
        // 白天：只认向下，钳到 +130。
        XCTAssertEqual(ForestAtmosphere.clampedDragOffset(isNight: false, dragHeight: 60), 60)
        XCTAssertEqual(ForestAtmosphere.clampedDragOffset(isNight: false, dragHeight: 500), 130)
        XCTAssertEqual(ForestAtmosphere.clampedDragOffset(isNight: false, dragHeight: -60), 0)
        // 夜里：只认向上，钳到 -130。
        XCTAssertEqual(ForestAtmosphere.clampedDragOffset(isNight: true, dragHeight: -60), -60)
        XCTAssertEqual(ForestAtmosphere.clampedDragOffset(isNight: true, dragHeight: -500), -130)
        XCTAssertEqual(ForestAtmosphere.clampedDragOffset(isNight: true, dragHeight: 60), 0)
    }

    // MARK: - 点草地的花坛账本

    /// 上限之内随便长；超过 12 朵挤掉最早那朵（最新的心意最要紧）。
    ///
    /// 反证：删掉 GroundFlowerBed.push 里的挤掉分支 → 红。
    func testBedKeepsTheNewestWithinTheCap() {
        var bed: [PlantedFlower] = []
        for id in 0..<15 {
            bed = GroundFlowerBed.push(PlantedFlower(id: id, x: 30, palette: 0), into: bed)
        }
        XCTAssertEqual(bed.count, GroundFlowerBed.cap)
        XCTAssertEqual(bed.first?.id, 3, "挤掉的应当是最早的三朵（id 0-2）")
        XCTAssertEqual(bed.last?.id, 14, "最新的那朵必须还在")
    }

    func testBedUnderCapJustAppends() {
        var bed: [PlantedFlower] = []
        for id in 0..<5 {
            bed = GroundFlowerBed.push(PlantedFlower(id: id, x: 30, palette: 1), into: bed)
        }
        XCTAssertEqual(bed.map(\.id), [0, 1, 2, 3, 4], "没到上限一朵都不许丢")
    }
}
