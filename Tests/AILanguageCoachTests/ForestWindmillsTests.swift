import CoreGraphics
@testable import AppUI
import XCTest

/// 夏天风车的布局纯函数（#622；2026-10-22 改成「两座 + 站在坡上 + 看得清」）。
///
/// 每条判据配一句「反证」——把实现换回错写法，断言必须红在**这一条**上。
final class ForestWindmillsTests: XCTestCase {

    private var mills: [ForestWindmill] { WindmillLayout.summerField }
    private let panel = CGSize(width: 420, height: 700)

    /// 面板里地面带的顶（面板坐标）。地面带钉在面板底部、高 150。
    private var bandTop: CGFloat { panel.height - ForestSceneGeometry.groundBandHeight }

    /// 面板里 `lane` 处的**远坡**坡面高度（面板坐标）。
    private func meadowY(at lane: Double) -> CGFloat {
        WindmillLayout.meadowSurfaceY(
            x: panel.width * lane, width: panel.width, panelHeight: panel.height)
    }

    /// 面板里 `lane` 处的**近坡**（小动物站的坡）高度（面板坐标）。
    private func nearSlopeY(at lane: Double) -> CGFloat {
        WindmillLayout.nearSlopeY(
            x: panel.width * lane, width: panel.width, panelHeight: panel.height)
    }

    /// 两座，一左一右分在树干两边（各一座，不挤在一起、也不贴面板边）。
    ///
    /// 反证：把 `lanes` 改成 `[0.42, 0.58]`（都贴着树干）→ 红在左右那两条；
    /// 把 `lanes` 改成 `[0.94, 0.96]` → 红在贴边那条。
    func testTwoMillsFlankTheTrunk() {
        XCTAssertEqual(mills.count, 2, "风车数量按用户要求是两座")
        XCTAssertEqual(mills.filter { $0.lane < 0.5 }.count, 1, "树干左边必须正好一座")
        XCTAssertEqual(mills.filter { $0.lane > 0.5 }.count, 1, "树干右边必须正好一座")
        for mill in mills {
            XCTAssertGreaterThan(mill.lane, 0.08, "贴到面板左边缘了")
            XCTAssertLessThan(mill.lane, 0.92, "贴到面板右边缘了")
        }
    }

    /// **塔基咬在远坡上**，而且整座都在面板里（今天最要紧的一条）。
    ///
    /// 反证：把 `groundY` 换回旧式 `panelHeight − 带高 + 26 − horizonSpan × depth`
    /// → 塔基跑到地面带**上方** 20~100pt（飘回天上）→ 红在「塔基没咬在远坡上」；
    /// 把 `farMeadowHeight` 调到 400（远坡顶到画面上半幅）→ 红在「塔顶出了地面带」。
    func testMillsStandOnTheFarMeadow() {
        for mill in mills {
            let base = WindmillLayout.groundY(
                mill, width: panel.width, panelHeight: panel.height)
            XCTAssertEqual(base, meadowY(at: mill.lane) + WindmillLayout.footSink,
                           accuracy: 1e-9, "塔基没有咬在远坡上")

            let box = WindmillLayout.frame(
                mill, width: panel.width, panelHeight: panel.height)
            XCTAssertEqual(box.maxY, base, accuracy: 1e-9, "外框的底边不是塔基")
            // 风车比小动物高一档，允许压出带顶几个 pt（那 34pt 是画布的地面段，
            // 果树也伸进去过）。要抓的是「飘到半空」，不是「压线 1pt」。
            XCTAssertGreaterThanOrEqual(box.minY, bandTop - 34, "塔顶戳出地面带 —— 风车又飘起来了")
            XCTAssertLessThanOrEqual(box.maxY, panel.height, "塔基掉出面板下沿")
        }
    }

    /// **远坡必须比近坡高**：不然风车就跟小动物站在同一层、被它们挡住。
    ///
    /// 实测踩过：把风车直接摆在地面带那条近坡上，0.25 / 0.75 两个位置正好压在
    /// 两只小动物身后 —— 出图里只剩几根白色帆叶从兔子耳朵后面露出来。
    ///
    /// 反证：把 `groundY` 改成 `nearSlopeY + footSink` → 红。
    func testFarMeadowSitsAboveTheNearSlope() {
        for mill in mills {
            let base = WindmillLayout.groundY(
                mill, width: panel.width, panelHeight: panel.height)
            XCTAssertLessThan(base, nearSlopeY(at: mill.lane) - 10,
                              "远坡没高出近坡 —— 风车会跟小动物挤在同一层")
            XCTAssertLessThan(nearSlopeY(at: mill.lane), panel.height,
                              "近坡掉到面板外面了（判据会空转）")
        }
    }

    /// 塔基确实**沉进**坡里几 pt（不沉就是贴在坡线上，3pt 的缝都看得见）。
    ///
    /// 反证：把 `footSink` 改成 0 → 红。
    func testFeetAreSunkIntoTheMeadow() {
        XCTAssertGreaterThan(WindmillLayout.footSink, 0)
        for mill in mills {
            let base = WindmillLayout.groundY(
                mill, width: panel.width, panelHeight: panel.height)
            XCTAssertGreaterThan(base, meadowY(at: mill.lane), "塔基贴在坡面上，没沉进去")
        }
    }

    /// 看得清是座风车：不褪色、不失焦，融天只留一点点。
    ///
    /// 反证：`style` 改回整套 `ForestSceneGeometry.style(forDepth:)`
    /// → opacity ≈ 0.79 / blur ≈ 0.7 / haze ≈ 0.20，三条全红
    /// （用户 2026-10-22：「现在的风车过于虚化了，要有明确的实体」）。
    func testMillsAreSolidNotGhosts() {
        for mill in mills {
            let style = WindmillLayout.style(mill)
            XCTAssertEqual(style.opacity, 1, accuracy: 1e-9, "风车被调淡了")
            XCTAssertEqual(style.blur, 0, accuracy: 1e-9, "风车被失焦了")
            XCTAssertLessThan(style.haze, 0.16, "融天太多，塔身会化进天空里")
        }
    }

    /// 「远 = 小」这条线索还在：塔高按景深缩放，且整体不到小动物的七成。
    ///
    /// 反证：把 `frame` 里的 `mill.height * style.scale` 改成 `mill.height` → 红在第一条；
    /// 把 `height` 的区间改回 46...72 → 红在最后一条（那就成了跟小动物一样高的近景）。
    func testHeightStaysDistant() {
        for mill in mills {
            let box = WindmillLayout.frame(
                mill, width: panel.width, panelHeight: panel.height)
            let expected = mill.height * WindmillLayout.style(mill).scale
            XCTAssertEqual(box.height, expected, accuracy: 1e-9, "塔高没有按景深缩放")
            XCTAssertLessThan(box.height, mill.height, "远处的塔必须比原尺寸小")
            // 小动物约 90~100pt：远处的风车要比它们矮一档，才读得出「在坡后面」。
            XCTAssertLessThan(box.height, 60, "风车太高，跟小动物站在同一层了")
        }
    }

    /// 叶片跟着风相位转（转得动），且两座转速 / 初相不同（不是一个电机带动的）。
    ///
    /// 反证：把 `bladeAngle` 里的 `windPhase * mill.spinGain` 删掉 → 红在第一条。
    func testBladesTurnWithWindPhase() {
        for mill in mills {
            let atRest = WindmillLayout.bladeAngle(mill, windPhase: 0)
            let later = WindmillLayout.bladeAngle(mill, windPhase: 2.5)
            XCTAssertGreaterThan(later - atRest, 30, "叶片没有转（转速太小或没接风相位）")
        }
        XCTAssertEqual(Set(mills.map { String(format: "%.4f", $0.spinGain) }).count, 2,
                       "两座的转速必须各不相同")
        XCTAssertEqual(Set(mills.map { String(format: "%.4f", $0.phase) }).count, 2,
                       "两座的叶片初相必须各不相同")
    }

    /// 两座在画面里（横向不许有半座飘到面板外）。
    func testEveryMillStaysInsidePanelHorizontally() {
        for mill in mills {
            let box = WindmillLayout.frame(
                mill, width: panel.width, panelHeight: panel.height)
            XCTAssertGreaterThanOrEqual(box.minX, 0)
            XCTAssertLessThanOrEqual(box.maxX, panel.width)
        }
    }

    /// 窄面板（树栏最小 300pt）也站得住：远坡随宽度变，塔基得跟着走。
    ///
    /// 反证：把 `groundY` 里的 `width: width` 写死成 420 → 窄面板下红。
    func testNarrowPanelStillStandsOnItsOwnMeadow() {
        let narrow = CGSize(width: 300, height: 640)
        for mill in mills {
            let base = WindmillLayout.groundY(
                mill, width: narrow.width, panelHeight: narrow.height)
            let surface = WindmillLayout.meadowSurfaceY(
                x: narrow.width * mill.lane,
                width: narrow.width,
                panelHeight: narrow.height)
            XCTAssertEqual(base, surface + WindmillLayout.footSink, accuracy: 1e-9)
        }
    }

    /// 同种子同一片草场（重绘不许换一批风车 —— 用户会看见瞬移）。
    func testLayoutIsDeterministic() {
        XCTAssertEqual(WindmillLayout.make(seed: 0x5749_4E44),
                       WindmillLayout.make(seed: 0x5749_4E44))
        XCTAssertNotEqual(WindmillLayout.make(seed: 0x5749_4E44),
                          WindmillLayout.make(seed: 0x5749_4E45))
    }
}
