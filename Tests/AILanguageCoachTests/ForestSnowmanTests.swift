import CoreGraphics
@testable import AppUI
import XCTest

/// 冬季雪人（#627）的布局纯函数。
///
/// 每条判据配一句「反证」——把实现换回错写法，断言必须红在**这一条**上。
final class ForestSnowmanTests: XCTestCase {

    private let band = CGSize(width: 420, height: ForestSceneGeometry.groundBandHeight)

    /// ⚠️ `ForestGroundSurface` 是 `@Sendable`：不能传实例方法（会把非 Sendable 的
    /// `self` 捕进闭包），只能写成闭包属性。
    private let groundLine: ForestGroundSurface = { x in
        ForestSceneGeometry.hillSurfaceY(
            x: x, bandWidth: 420, bandHeight: ForestSceneGeometry.groundBandHeight)
    }

    private func surface(_ width: CGFloat) -> ForestGroundSurface {
        { x in
            ForestSceneGeometry.hillSurfaceY(
                x: x, bandWidth: width, bandHeight: ForestSceneGeometry.groundBandHeight)
        }
    }

    private func quantized(_ width: CGFloat) -> CGFloat { (width / 28).rounded() * 28 }

    private func box(
        _ snowman: ForestSnowman, width: CGFloat = 420
    ) -> CGRect {
        SnowmanLayout.frame(
            snowman,
            width: width,
            quantizedWidth: quantized(width),
            groundLine: width == 420 ? groundLine : surface(width)
        )
    }

    // MARK: - 站位

    /// 三个雪人**散开**站着，谁也不叠在谁身上（叠了就读成「一个大的」）。
    ///
    /// 反证：把 `anchors` 全改成 0.5 → 红在间距那条。
    func testThreeSnowmenStandApart() {
        let men = SnowmanLayout.winterGlade
        XCTAssertEqual(men.count, 3)
        let lanes = men.map(\.lane).sorted()
        for index in 1..<lanes.count {
            XCTAssertGreaterThan(lanes[index] - lanes[index - 1], 0.20,
                                 "两个雪人挤在一处了（读成一个）")
        }
        // 三个都要落在画面里，且不贴着边（贴边会被面板切掉一半）
        for lane in lanes {
            XCTAssertGreaterThan(lane, 0.10)
            XCTAssertLessThan(lane, 0.90)
        }
    }

    /// 雪人站在**草坡表面**上（和小动物、南瓜踩的是同一条曲线）。
    ///
    /// 反证：把 `baseY` 改成常量 → 红。
    func testSnowmenStandOnTheSlope() {
        for snowman in SnowmanLayout.winterGlade {
            let expected = groundLine(band.width * snowman.lane) + snowman.sink
            XCTAssertEqual(
                SnowmanLayout.baseY(snowman, width: band.width, groundLine: groundLine),
                expected, accuracy: 1e-9, "雪人没踩在坡面上")
            XCTAssertEqual(
                box(snowman).maxY, expected, accuracy: 1e-9, "雪人底没落在坡面上")
        }
        // 坡是鼓包：靠边的雪人比靠中间的坐得低
        let sorted = SnowmanLayout.winterGlade.sorted {
            abs($0.lane - 0.5) > abs($1.lane - 0.5)
        }
        let outer = sorted.first!
        let inner = SnowmanLayout.winterGlade.min { abs($0.lane - 0.5) < abs($1.lane - 0.5) }!
        XCTAssertGreaterThan(
            SnowmanLayout.baseY(outer, width: band.width, groundLine: groundLine),
            SnowmanLayout.baseY(inner, width: band.width, groundLine: groundLine),
            "坡是鼓包：靠边的雪人该坐得低一些")
    }

    /// 每个雪人整只都在地面带里（不许戳出带顶 / 甩到带外）。
    ///
    /// 反证：把 `heightScale` 改成 4 → 红在 minY 那条。
    func testEverySnowmanStaysInsideTheBand() {
        for width in [300, 336, 392, 420, 476, 560, 700] as [CGFloat] {
            for snowman in SnowmanLayout.winterGlade {
                let frame = box(snowman, width: width)
                XCTAssertGreaterThanOrEqual(frame.minY, 0, "\(width)pt：雪人戳出地面带上沿")
                XCTAssertLessThanOrEqual(frame.maxY, band.height, "\(width)pt：雪人掉出地面带")
                XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(width)pt：雪人被左边界切掉")
                XCTAssertLessThanOrEqual(frame.maxX, width, "\(width)pt：雪人被右边界切掉")
            }
        }
    }

    // MARK: - 个头（同一把尺）

    /// 雪人**一个半小动物高**（1.45 倍）。
    ///
    /// ⚠️ 钉的是**字面 1.45**，不是「在 1.0 与果树之间」——区间断言放过 2.0、1.2，
    /// 「一个半」这个需求就什么都没钉住（实测 2.0 全绿 = 假闸）。
    ///
    /// 反证：把 `animalHeights` 改成 2.0 → 红在第一条。
    func testSnowmanIsOneAndAHalfAnimals() {
        XCTAssertEqual(SnowmanLayout.animalHeights, 1.45, accuracy: 1e-9,
                       "雪人该是一个半小动物高")
        for width in [336, 392, 420] as [CGFloat] {
            let qw = quantized(width)
            let animal = ForestGroundPlan.referenceResidentSize(quantizedWidth: qw)
            for snowman in SnowmanLayout.winterGlade {
                XCTAssertEqual(
                    SnowmanLayout.height(snowman, quantizedWidth: qw),
                    animal * 1.45 * snowman.heightScale,
                    accuracy: 1e-9,
                    "\(width)pt：雪人不是拿小动物的高量出来的")
            }
        }
        // 比小动物高、比果树矮 —— 中间那一档
        XCTAssertGreaterThan(SnowmanLayout.animalHeights, 1.0, "雪人比小动物还矮")
        XCTAssertLessThan(SnowmanLayout.animalHeights, OrchardLayout.animalHeights,
                          "雪人比果树还高")
    }

    /// 尺子只有一把：不许在这里另抄一份「28 + quantizedWidth * 0.045」。
    ///
    /// 反证：把 `height` 里的 `referenceResidentSize` 换成内联公式 → 红。
    func testTheRulerIsTheAnimalsOwn() throws {
        let source = try String(
            contentsOfFile: "Sources/AppUI/Components/ForestSnowman.swift", encoding: .utf8)
        XCTAssertTrue(source.contains("ForestGroundPlan.referenceResidentSize("),
                      "雪人的个头没走小动物那把尺")
        XCTAssertFalse(source.contains("28 + quantizedWidth * 0.045"),
                       "雪人这里另抄了一份居民体型公式（改一处就会两把尺）")
    }

    // MARK: - 造型

    /// 两个雪球**叠着**：头比身小、头底压进身球（不是两个球上下分开摆）。
    ///
    /// 反证：把 `headOverlap` 改成 -0.5（头悬在身子上方）→ 红在「不相交/相切」那条。
    func testHeadSitsOnTheBody() {
        for snowman in SnowmanLayout.winterGlade {
            let frame = box(snowman)
            let body = SnowmanLayout.bodyRect(in: frame)
            let head = SnowmanLayout.headRect(in: frame)
            XCTAssertLessThan(head.width, body.width, "头比身子还宽")
            XCTAssertLessThan(head.height, body.height, "头比身子还高")
            XCTAssertGreaterThan(head.maxY, body.minY, "头悬在身子上方（两个球没叠着）")
            XCTAssertLessThan(head.maxY, body.midY, "头压进身子太深（脖子没了）")
            XCTAssertGreaterThan(head.minY, frame.minY, "头顶顶到框顶了（没给帽子留位置）")
        }
    }

    /// 尖顶帽坐在头上：帽底在头顶附近、比头窄、帽檐比帽宽。
    ///
    /// 反证：把 `hatRect` 的宽改成 `head.width * 1.4` → 红。
    func testHatRidesTheHead() {
        for snowman in SnowmanLayout.winterGlade {
            let frame = box(snowman)
            let head = SnowmanLayout.headRect(in: frame)
            let hat = SnowmanLayout.hatRect(in: frame)
            let brim = SnowmanLayout.hatBrimRect(in: frame)
            XCTAssertLessThanOrEqual(hat.maxY, head.minY + head.height * 0.12,
                                     "帽子没坐在头顶（挂到脸上了）")
            XCTAssertLessThan(hat.width, head.width, "帽子比头还宽")
            XCTAssertGreaterThan(hat.height, head.height * 0.25, "帽子太扁，读成一道横线")
            XCTAssertGreaterThan(brim.width, hat.width, "帽檐没比帽身宽（帽子成了三角纸）")
        }
    }

    /// 胡萝卜从脸上伸出来：起点在头中线附近、尖在头的右侧、整根落在头框里。
    ///
    /// 反证：把 `noseRect` 的 x 改成 `head.maxX` → 红在「起点在头中线附近」那条。
    func testNoseSticksOutOfTheFace() {
        for snowman in SnowmanLayout.winterGlade {
            let frame = box(snowman)
            let head = SnowmanLayout.headRect(in: frame)
            let nose = SnowmanLayout.noseRect(in: frame)
            XCTAssertGreaterThan(nose.minX, head.minX, "鼻子从左脸外面插进来")
            XCTAssertLessThan(nose.minX, head.midX + head.width * 0.12,
                              "鼻子的根不在脸中间（挂到耳朵上了）")
            XCTAssertGreaterThan(nose.maxX, head.midX, "鼻子没伸出来")
            XCTAssertLessThanOrEqual(nose.maxX, head.maxX, "鼻子伸到脸外面去了")
            XCTAssertGreaterThan(nose.width, nose.height * 1.6, "鼻子不够细长（读成一块斑）")
        }
    }

    /// 围巾绕在**脖子**上（头与身的交界处），比身子宽一点（是绕上去的）。
    ///
    /// 反证：把 `scarfRect` 的 y 改成 `body.midY` → 红。
    func testScarfWrapsTheNeck() {
        for snowman in SnowmanLayout.winterGlade {
            let frame = box(snowman)
            let body = SnowmanLayout.bodyRect(in: frame)
            let head = SnowmanLayout.headRect(in: frame)
            let scarf = SnowmanLayout.scarfRect(in: frame)
            let neckLow = body.minY - body.height * 0.05
            let neckHigh = head.maxY + body.height * 0.10
            XCTAssertGreaterThan(scarf.midY, neckLow, "围巾掉到肚子上了")
            XCTAssertLessThan(scarf.midY, neckHigh, "围巾糊到脸上了")
            XCTAssertGreaterThan(scarf.width, body.width, "围巾没绕满一圈")
            // 垂下来那一角挂在身子前面、比那一圈窄
            let tail = SnowmanLayout.scarfTailRect(in: frame)
            XCTAssertGreaterThan(tail.maxY, scarf.maxY - 0.001, "围巾角朝上飘了")
            XCTAssertLessThan(tail.width, scarf.width, "围巾角比那一圈还宽")
        }
    }

    /// 两根枝桠从身球两侧伸出去、**朝上**张开（垂着就读成两根树枝）。
    ///
    /// 反证：把 `lift` 取负（手臂朝下）→ 红在「朝上」那条。
    func testArmsReachOutAndUp() {
        for snowman in SnowmanLayout.winterGlade {
            let frame = box(snowman)
            let roots = SnowmanLayout.armRoots(in: frame)
            let body = SnowmanLayout.bodyRect(in: frame)
            let span = frame.height * 0.34
            for (root, side) in [(roots.left, CGFloat(-1)), (roots.right, CGFloat(1))] {
                let points = SnowmanLayout.armPath(
                    root: root, side: side, lift: snowman.armLift, span: span)
                XCTAssertEqual(points.count, 7, "一根枝桠该是「主干 + 两个叉」")
                let tip = points[2]
                XCTAssertLessThan(tip.y, root.y, "手臂朝下垂着（读成两根树枝）")
                if side < 0 {
                    XCTAssertLessThan(tip.x, body.minX, "左手没伸出身外")
                    XCTAssertLessThan(root.x, body.midX, "左手的根长在右半边")
                } else {
                    XCTAssertGreaterThan(tip.x, body.maxX, "右手没伸出身外")
                    XCTAssertGreaterThan(root.x, body.midX, "右手的根长在左半边")
                }
            }
        }
    }

    /// 三个雪人不是一个模子翻出来的（高矮 / 帽角 / 臂角 / 围巾角各不相同）。
    ///
    /// 反证：把 `heightScale` 改成常量 → 红在第一条。
    func testNoTwoSnowmenAreTheSame() {
        let men = SnowmanLayout.winterGlade
        XCTAssertEqual(Set(men.map { String(format: "%.4f", $0.heightScale) }).count, 3,
                       "三个雪人一样高")
        XCTAssertEqual(Set(men.map { String(format: "%.4f", $0.hatTilt) }).count, 3,
                       "三顶帽子歪得一模一样")
        XCTAssertEqual(Set(men.map { String(format: "%.4f", $0.armLift) }).count, 3,
                       "三对手臂抬得一模一样")
        for snowman in men {
            XCTAssertLessThan(abs(snowman.lean), 6, "雪人歪得太厉害（要倒了）")
            XCTAssertGreaterThan(snowman.armLift, 6, "手臂几乎水平（看不出是张开的）")
            XCTAssertLessThan(snowman.armLift, 60, "手臂举过头顶（像在投降）")
        }
    }

    // MARK: - 确定性

    /// 同种子同结果（重绘不许换一批雪人）。
    func testLayoutIsDeterministic() {
        XCTAssertEqual(SnowmanLayout.winterGlade,
                       SnowmanLayout.make(seed: 0x534E_4F57, count: 3))
        XCTAssertEqual(SnowmanLayout.winterGlade, SnowmanLayout.winterGlade)
    }
}
