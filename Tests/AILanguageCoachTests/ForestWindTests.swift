import AppKit
import AppUI
import SwiftUI
import XCTest

// MARK: - 全局风场接线（P1）

/// 风场接线回归：`WindField` 的空间性质本身已在 `ForestSceneTests` 钉住，
/// 这一组钉的是**接线之后**才存在的东西 —— 共享时钟、冻结语义、各层受风参数。
///
/// 设计前提（也是这一批的承诺）：全场景只有**一颗**风相位源。各层若各算各的
/// 相位，「阵风呼吸」会错开（草在最盛时花在收敛），观感就退化成各抖各的。
@MainActor
final class ForestWindTests: XCTestCase {

    // MARK: 共享时钟

    func testEveryLayerSharesTheSameGustAtTheSameSpot() {
        let clock = ForestWindClock()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        clock.advance(to: t0, blowing: true)
        clock.advance(to: t0.addingTimeInterval(3.4), blowing: true)

        // 同一 x、同一帧：草叶（18pt）与灌木顶（300pt）的位移只差一个「高度放大」，
        // 余下的 gust × wave 必须**逐位相同** —— 这就是「同一阵风」的数学定义。
        let grass = clock.offset(x: 200, height: 18)
        let bushTop = clock.offset(x: 200, height: 300)
        XCTAssertNotEqual(grass, bushTop, "高处本就该摆得大；相等说明高度放大丢了")
        XCTAssertEqual(grass / WindField.heightFactor(18),
                       bushTop / WindField.heightFactor(300),
                       accuracy: 1e-9,
                       "同一位置的两层看到的风不一样 → 各层在用自己的阵风，不是同一阵风")
    }

    func testWindTravelsAsOneWaveAcrossTheScene() {
        let clock = ForestWindClock()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        clock.advance(to: t0, blowing: true)
        clock.advance(to: t0.addingTimeInterval(2.0), blowing: true)

        // 相距半个波长（λ/2 = π / waveNumber）的两处，位移必须反号：
        // 风的「波」是被踢着走的，不是每处各抖各的。
        let halfWave = CGFloat(Double.pi / WindField.waveNumber)
        let here = clock.offset(x: 120, height: 20)
        let there = clock.offset(x: 120 + halfWave, height: 20)
        XCTAssertEqual(here, -there, accuracy: 1e-6, "半波长外位移不反号 → 风不是一条行波")
    }

    func testClockPhaseAdvancesSmoothly() {
        let clock = ForestWindClock()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        clock.advance(to: t0, blowing: true)
        clock.advance(to: t0.addingTimeInterval(0.1), blowing: true)
        clock.advance(to: t0.addingTimeInterval(0.2), blowing: true)

        // 累计 0.2s × speed = 相位
        XCTAssertEqual(clock.phase, 0.2 * WindField.speed, accuracy: 1e-9)
        XCTAssertTrue(clock.isBlowing)
    }

    // MARK: 冻结语义

    func testFrozenWindStandsStraightInsteadOfFreezingMidLean() {
        let clock = ForestWindClock()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        clock.advance(to: t0, blowing: true)
        clock.advance(to: t0.addingTimeInterval(2.0), blowing: true)

        clock.advance(to: t0.addingTimeInterval(2.1), blowing: false)
        XCTAssertFalse(clock.isBlowing, "开关一关，风场就应当不存在")

        // 冻结 = 归零，不是「停在当时的弯度上」：一棵歪着上半身的草比瞬间立正更瘆人。
        for x in stride(from: CGFloat(0), through: 600, by: 50) {
            XCTAssertEqual(clock.offset(x: x, height: 20), 0, accuracy: 1e-12,
                           "x=\(x) 冻结后仍有位移 → 草会歪着不动")
        }
    }

    func testPausedClockDoesNotJumpWhenTheWindResumes() {
        let clock = ForestWindClock()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        clock.advance(to: t0, blowing: true)
        clock.advance(to: t0.addingTimeInterval(1.0), blowing: true)
        let beforePause = clock.offset(x: 180, height: 20)

        // 暂停 60 秒（足够跨越好几个摆动周期）
        for step in 1...6 {
            clock.advance(to: t0.addingTimeInterval(1.0 + Double(step) * 10), blowing: false)
        }
        // 恢复后只走了 1/30 秒
        clock.advance(to: t0.addingTimeInterval(61.0 + 1.0 / 30.0), blowing: true)
        let afterResume = clock.offset(x: 180, height: 20)

        // 若暂停期间也在累计相位，恢复瞬间会跳 60×speed ≈ 54 弧度（≈8.6 个周期），
        // 位移会整个翻掉 —— 这个阈值对跳变是致命的，对正常一帧则宽松得很。
        XCTAssertLessThan(abs(afterResume - beforePause), 0.5,
                          "暂停期间累计了相位 → 风一恢复草就被甩到反方向")
    }

    // MARK: 总闸（真值表全走一遍：漏一个组合就是只在真机上才看得见的错）

    func testWindStopsWhenAmbientIsHiddenOrMotionIsReduced() {
        XCTAssertTrue(WindField.isBlowing(ambientHidden: false, reduceMotion: false))
        XCTAssertFalse(WindField.isBlowing(ambientHidden: true, reduceMotion: false),
                       "氛围隐藏档：林子应当完全安静（与云收起同一句承诺）")
        XCTAssertFalse(WindField.isBlowing(ambientHidden: false, reduceMotion: true),
                       "减弱动态效果：风必须停 —— 用户级开关，优先级最高")
        XCTAssertFalse(WindField.isBlowing(ambientHidden: true, reduceMotion: true))
    }

    func testFreshClockIsStillSoOffscreenRendersStayDeterministic() {
        // 离屏渲染夹具 / 预览里拿到的是一颗从未 advance 过的钟 —— 它必须是静止的，
        // 否则既有渲染回归会跟着墙钟漂移（同一个断言今天绿明天红）。
        let clock = ForestWindClock()
        XCTAssertFalse(clock.isBlowing)
        XCTAssertEqual(clock.offset(x: 300, height: 40), 0, accuracy: 1e-12)
    }

    // MARK: 植株受风参数（质量感：重的摆得小、高的摆得开）

    func testPlantWindParamsOrderByMassAndHeight() {
        let plant = { kind in
            GladeGrowth.Plant(index: 0, kind: kind, x: 0.5, scale: 1)
        }
        let flower = plant(.flowerWarm)
        let fern = plant(.fern)
        let clover = plant(.clover)
        let mushroom = plant(.mushroom)

        // 高度序：蘑菇（贴地伞盖）< 三叶草 < 花 < 蕨（最高的一丛）。
        XCTAssertLessThan(GladeGrowth.windHeight(for: mushroom), GladeGrowth.windHeight(for: clover))
        XCTAssertLessThan(GladeGrowth.windHeight(for: clover), GladeGrowth.windHeight(for: flower))
        XCTAssertLessThan(GladeGrowth.windHeight(for: flower), GladeGrowth.windHeight(for: fern))

        // 增益序：蘑菇 < 三叶草 < 蕨 < 花。
        // ⚠️ 这两条序**故意不同**：蕨最高却不是摆得最开的 —— 它是密叶丛，兜住风
        // 整体欠身；花是一根细茎顶着花头，顶端自由，摆幅反而最大。「越高摆越大」
        // 由风场自己按 height 加（`WindField.heightFactor`），gain 只表达「质量感」。
        XCTAssertLessThan(GladeGrowth.windGain(for: mushroom), GladeGrowth.windGain(for: clover))
        XCTAssertLessThan(GladeGrowth.windGain(for: clover), GladeGrowth.windGain(for: fern))
        XCTAssertLessThan(GladeGrowth.windGain(for: fern), GladeGrowth.windGain(for: flower))

        // 两种花色共用一套受风参数（只是颜色不同，长法一样）。
        XCTAssertEqual(GladeGrowth.windHeight(for: flower), GladeGrowth.windHeight(for: plant(.flowerPale)))
        XCTAssertEqual(GladeGrowth.windGain(for: flower), GladeGrowth.windGain(for: plant(.flowerPale)))
    }

    func testWindGainStaysInsideUnitRangeForEveryKind() {
        for kind in GladeGrowth.Kind.allCases {
            let plant = GladeGrowth.Plant(index: 3, kind: kind, x: 0.4, scale: 0.9)
            let gain = GladeGrowth.windGain(for: plant)
            XCTAssertGreaterThan(gain, 0, "\(kind) 增益为 0 → 这一株在风里纹丝不动，像贴纸")
            XCTAssertLessThanOrEqual(gain, 1)
            XCTAssertGreaterThan(GladeGrowth.windHeight(for: plant), 0)
        }
    }

    func testPlantGainShrinksThePushWithoutBreakingTheSharedGust() {
        // gain 只改幅度、不改相位：两株同 x 的花，风来同时弯腰 ——
        // 若 gain 混进了相位，草坪就会变成一排节拍器。
        let clock = ForestWindClock()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        clock.advance(to: t0, blowing: true)
        clock.advance(to: t0.addingTimeInterval(2.6), blowing: true)

        let flower = GladeGrowth.Plant(index: 0, kind: .flowerWarm, x: 0.5, scale: 1)
        let fern = GladeGrowth.Plant(index: 1, kind: .fern, x: 0.5, scale: 1)
        let flowerPush = clock.offset(x: 200, height: GladeGrowth.windHeight(for: flower))
            * GladeGrowth.windGain(for: flower)
        let fernPush = clock.offset(x: 200, height: GladeGrowth.windHeight(for: fern))
            * GladeGrowth.windGain(for: fern)

        // 先排掉「风恰好吹到零点」的采样相位：那时两株都是 0，符号自然相同，
        // 断言会假绿 —— 判据本身要能证明自己真的验到了东西。
        XCTAssertGreaterThan(abs(flowerPush), 1e-6, "这个相位/位置上风恰好为零，换个采样点")
        XCTAssertEqual(flowerPush > 0, fernPush > 0, "同 x 的两株不同向 → gain 混进了相位")
        XCTAssertGreaterThan(abs(flowerPush), abs(fernPush), "花（轻）本就该比蕨摆得开")
    }

    // MARK: 反证

    func testSharedGustAssertionWouldCatchPerLayerClocks() {
        // 反证：`testEveryLayerSharesTheSameGustAtTheSameSpot` 对「各层各有一颗钟」
        // 是致命的 —— 两颗钟相位错开时，同一位置的归一化位移不再相等。
        let a = WindField.offset(x: 200, phase: 2.0, height: 18) / WindField.heightFactor(18)
        let b = WindField.offset(x: 200, phase: 2.0 + 0.7, height: 300) / WindField.heightFactor(300)
        XCTAssertNotEqual(a, b, accuracy: 1e-6,
                          "相位错开时归一化位移竟然相等 → 那条断言根本抓不到各层各算各的")
    }
}
