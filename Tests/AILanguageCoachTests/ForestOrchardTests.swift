import CoreGraphics
@testable import AppUI
import XCTest

/// 秋天小果园的布局纯函数（#624）。
///
/// 每条判据配一句「反证」——把实现换回错写法，断言必须红在**这一条**上。
final class ForestOrchardTests: XCTestCase {

    private var grove: [ForestFruitTree] { OrchardLayout.autumnGrove }
    /// 地面带的现实尺寸（与 `TreeViewport.groundBandHeight` 同值）。
    private let band = CGSize(width: 420, height: ForestSceneGeometry.groundBandHeight)

    /// 草坡表面（地面带局部坐标）—— 与地面带里那一支**同一条曲线**。
    ///
    /// ⚠️ 写成闭包属性而不是方法：`ForestGroundSurface` 是 `@Sendable`，
    /// 传方法进去会把非 Sendable 的 `self` 一起捕进去（编译不过）。
    private let groundLine: ForestGroundSurface = { x in
        ForestSceneGeometry.hillSurfaceY(
            x: x, bandWidth: 420, bandHeight: ForestSceneGeometry.groundBandHeight)
    }

    private func frame(_ tree: ForestFruitTree) -> CGRect {
        OrchardLayout.frame(
            tree, width: band.width,
            quantizedWidth: (band.width / 28).rounded() * 28,
            groundLine: groundLine
        )
    }

    // MARK: - 站位

    /// 四棵，左两棵右两棵 —— 中间那棵大树要露出来（不许挡在正中间）。
    ///
    /// 反证：把 `lane` 改成 0.5 → 红在第一条。
    func testFourTreesFlankTheBigTree() {
        XCTAssertEqual(grove.count, 4)
        let lanes = grove.map(\.lane)
        XCTAssertEqual(lanes.filter { $0 < 0.5 }.count, 2, "左边该有两棵")
        XCTAssertEqual(lanes.filter { $0 > 0.5 }.count, 2, "右边该有两棵")
        for lane in lanes {
            XCTAssertLessThan(abs(lane - 0.5), 0.46, "果树站到了画面边上")
            XCTAssertGreaterThan(abs(lane - 0.5), 0.28, "果树挡住了中间的大树")
        }
    }

    /// 同侧两棵错开（不叠成一棵）。
    ///
    /// 反证：把 `stride` 改成 0 → 红。
    func testNeighboursDoNotStack() {
        for side in [0, 1] {
            let lanes = grove.filter { $0.id % 2 == side }.map(\.lane).sorted()
            guard lanes.count > 1 else { continue }
            for index in 1..<lanes.count {
                XCTAssertGreaterThan(lanes[index] - lanes[index - 1], 0.07,
                                     "同一侧的两棵挨太近")
            }
        }
    }

    // MARK: - 「两个半小动物高」

    /// 正常宽度下，**画出来的**树高恒等于参照动物高 × 2.5。
    ///
    /// 反证：把 `animalHeights` 改成 2 → 红。
    /// （只在净空够宽的档位上钉「精确 2.5」—— 再宽的档位归下一条判据管。）
    func testTreeHeightIsTwoAndAHalfAnimals() {
        for raw in [336, 392, 420] {
            let width = CGFloat(raw)
            let animal = ForestGroundPlan.referenceResidentSize(quantizedWidth: (width / 28).rounded() * 28)
            for tree in grove {
                let box = OrchardLayout.frame(
                    tree, width: width, quantizedWidth: (width / 28).rounded() * 28,
                    groundLine: { x in
                        ForestSceneGeometry.hillSurfaceY(
                            x: x, bandWidth: width, bandHeight: ForestSceneGeometry.groundBandHeight)
                    })
                XCTAssertEqual(box.height, animal * 2.5, accuracy: 1e-9,
                               "\(raw)pt 面板上画出来的树不是两个半小动物高")
            }
        }
    }

    /// 树高上限：**任何宽度下都容得进林间空地**（宁可矮一点，也不许砍在带顶上）。
    ///
    /// 地面带只有 150pt，草坡是鼓包（中心高、两角低）—— 宽面板上小动物更大、
    /// 果树更高，靠中间那棵最先顶到带顶。这条判据钉住的是「不会发生」。
    ///
    /// 反证：把 `groveHeight` 直接返回 `desired`（去掉净空上限）→ 560/700 红。
    func testGroveAlwaysFitsInsideTheClearing() {
        for raw in [300, 336, 392, 420, 448, 476, 504, 560, 700] {
            let width = CGFloat(raw)
            let quantized = (width / 28).rounded() * 28
            let surface: ForestGroundSurface = { x in
                ForestSceneGeometry.hillSurfaceY(
                    x: x, bandWidth: width, bandHeight: ForestSceneGeometry.groundBandHeight)
            }
            let height = OrchardLayout.groveHeight(
                width: width, quantizedWidth: quantized, groundLine: surface)
            for tree in grove {
                let box = OrchardLayout.frame(
                    tree, width: width, quantizedWidth: quantized, groundLine: surface)
                XCTAssertEqual(box.height, height, accuracy: 1e-9,
                               "\(raw)pt：全园必须一个高度")
                XCTAssertGreaterThanOrEqual(box.minY, OrchardLayout.topMargin - 0.001,
                                            "\(raw)pt：树冠戳出了地面带上沿")
            }
            // 被截住也不许缩成矮树丛：至少还有两倍小动物高
            let animal = ForestGroundPlan.referenceResidentSize(quantizedWidth: quantized)
            XCTAssertGreaterThan(height, animal * 2.0, "\(raw)pt：果树被截得太矮了")
        }
    }

    /// 尺寸必须来自「小动物那把尺」本身，不是另拍一个数（换算出来说得通不算数）。
    ///
    /// 反证：把 `treeHeight` 里的 `referenceResidentSize` 换成字面量 → 红在第一条。
    func testTheRulerIsTheAnimalsOwn() {
        XCTAssertEqual(ForestGroundPlan.referenceResidentSize(quantizedWidth: 420),
                       ForestGroundPlan.residentSize(quantizedWidth: 420, depth: 0.5, spread: 0.5),
                       accuracy: 1e-9, "参照体型必须是同一条公式的中位值")
        // 窄面板小动物小、宽面板小动物大 —— 果树必须跟着一起变
        let narrow = OrchardLayout.treeHeight(quantizedWidth: 336)
        let wide = OrchardLayout.treeHeight(quantizedWidth: 560)
        XCTAssertGreaterThan(wide - narrow, 20, "面板宽了，小动物大了，果树却没跟着长")
        // 中位档真的落在个体区间里（不是拍脑袋的极端值）
        let smallest = ForestGroundPlan.residentSize(quantizedWidth: 420, depth: 0, spread: 0)
        let largest = ForestGroundPlan.residentSize(quantizedWidth: 420, depth: 1, spread: 1)
        let mid = ForestGroundPlan.referenceResidentSize(quantizedWidth: 420)
        XCTAssertGreaterThan(mid, smallest)
        XCTAssertLessThan(mid, largest)
    }

    /// 果树与小动物**共用同一条算式**（不是各抄一份）。
    ///
    /// ⚠️ 钉的是调用形态：地面带必须走 `ForestGroundPlan.residentSize`，
    /// 且那条公式不许在地面带里再抄一遍（抄两份就是改了一处忘了另一处）。
    ///
    /// 反证：把 `homePosition` 改回内联公式 → 红在第二条。
    func testGroundBandMeasuresWithTheSameFunction() throws {
        let canvas = try String(
            contentsOfFile: "Sources/AppUI/Components/TreeCanvas.swift", encoding: .utf8)
        XCTAssertTrue(canvas.contains("ForestGroundPlan.residentSize("),
                      "地面带没有共用居民体型函数")
        XCTAssertFalse(canvas.contains("28 + quantizedWidth * 0.045"),
                       "体型公式在地面带里又抄了一份")
    }

    // MARK: - 站在坡上

    /// 树基踩在**草坡表面**上（和小动物踩的是同一条曲线），不是一条直线。
    ///
    /// 反证：把 `baseY` 改成常量 → 红。
    func testTreesStandOnTheSlope() {
        for tree in grove {
            let expected = groundLine(band.width * tree.lane)
            XCTAssertEqual(OrchardLayout.baseY(tree, width: band.width, groundLine: groundLine),
                           expected, accuracy: 1e-9, "树基没踩在坡面上")
            XCTAssertEqual(frame(tree).maxY, expected, accuracy: 1e-9, "树根没落在树基上")
        }
        // 坡是鼓包：外侧那两棵站得比内侧低（y 更大）
        let outer = grove.filter { abs($0.lane - 0.5) > 0.38 }
        let inner = grove.filter { abs($0.lane - 0.5) < 0.32 }
        XCTAssertFalse(outer.isEmpty)
        XCTAssertFalse(inner.isEmpty)
        for out in outer {
            for inn in inner {
                XCTAssertGreaterThan(
                    OrchardLayout.baseY(out, width: band.width, groundLine: groundLine),
                    OrchardLayout.baseY(inn, width: band.width, groundLine: groundLine),
                    "坡是鼓包：外侧的树该站得低一些")
            }
        }
    }

    /// 整棵都在地面带里（不许有半棵戳出带顶 / 掉出带底）。
    ///
    /// 反证：把 `animalHeights` 调到 4 → 红在 minY 这条。
    func testEveryTreeStaysInsideTheBand() {
        for raw in [336, 392, 420] {
            let width = CGFloat(raw)
            let quantized = (width / 28).rounded() * 28
            let surface: ForestGroundSurface = { x in
                ForestSceneGeometry.hillSurfaceY(
                    x: x, bandWidth: width, bandHeight: ForestSceneGeometry.groundBandHeight)
            }
            for tree in grove {
                let box = OrchardLayout.frame(
                    tree, width: width, quantizedWidth: quantized, groundLine: surface)
                XCTAssertGreaterThanOrEqual(box.minY, 0, "\(width)pt：树冠戳出地面带上沿")
                XCTAssertLessThanOrEqual(box.maxY, band.height, "\(width)pt：树根掉出地面带")
            }
        }
    }

    // MARK: - 造型

    /// 树冠骑在树干之上、比树干宽（读得出「一棵树」，不是一根棒子挑个球）。
    ///
    /// 反证：把 `trunkRatio` 钳到 1 → 红在第一条。
    func testCanopyRidesAboveATrunk() {
        for tree in grove {
            let box = frame(tree)
            let trunk = OrchardLayout.trunkRect(tree, in: box)
            let crown = OrchardLayout.canopyRect(tree, in: box)
            XCTAssertLessThanOrEqual(crown.maxY, trunk.minY + 0.001, "树冠压到树干上了")
            XCTAssertGreaterThan(crown.width, trunk.width * 3, "树冠不比树干宽，读不出是树")
            XCTAssertLessThan(trunkRatio(tree), 0.6)
            // 树干底下有个根盘（不是一根等宽的柱）
            XCTAssertEqual(trunk.maxY, box.maxY, accuracy: 1e-9, "树干没扎到树基")
        }
    }

    private func trunkRatio(_ tree: ForestFruitTree) -> CGFloat { tree.trunkRatio }

    /// 四棵不是一个模子翻出来的（冠幅 / 干高比 / 倾角 / 果子各不相同）。
    ///
    /// 反证：把这四个字段改成常量 → 红。
    func testNoTwoTreesAreTheSameTree() {
        XCTAssertEqual(Set(grove.map { String(format: "%.4f", $0.canopySpan) }).count, 4,
                       "冠幅必须棵棵不同")
        XCTAssertEqual(Set(grove.map { String(format: "%.4f", $0.trunkRatio) }).count, 4,
                       "干高比必须棵棵不同")
        XCTAssertEqual(Set(grove.map { String(format: "%.4f", $0.lean) }).count, 4,
                       "倾角必须棵棵不同")
        XCTAssertEqual(Set(grove.map { String(format: "%.4f", $0.swayGain) }).count, 4,
                       "摆幅必须棵棵不同")
        // 三种果子都出场了（认得出这是苹果树 / 桃树 / 橘树）
        let kinds = Set(grove.map(\.fruit))
        XCTAssertTrue(kinds.contains(.apple) && kinds.contains(.peach) && kinds.contains(.citrus),
                      "三种果子没有都出场")
        // 相邻两棵不结同一种果
        for index in 1..<grove.count {
            XCTAssertNotEqual(grove[index].fruit, grove[index - 1].fruit, "相邻两棵结一样的果")
        }
    }

    /// 每棵都**真的结了果**（冠上挂得住、树下有熟透掉下来的）。
    func testEveryTreeBearsFruit() {
        for tree in grove {
            XCTAssertGreaterThanOrEqual(tree.fruitCount, 6, "冠上果子太少，看不出是果树")
            XCTAssertGreaterThanOrEqual(tree.droppedCount, 1, "树下没有落果")
            XCTAssertEqual(OrchardLayout.fruitSpots(tree).count, tree.fruitCount)
            XCTAssertEqual(OrchardLayout.droppedSpots(tree).count, tree.droppedCount)
        }
    }

    /// 果子**挂在某团叶子里**（不是撒在整个冠框里 → 会浮在叶子外的空处）。
    ///
    /// 反证：把 `fruitSpots` 改成在 0…1 上均匀撒 → 红。
    func testFruitHangsInsideAClumpOfLeaves() {
        for tree in grove {
            let lobes = OrchardLayout.canopyLobes(tree)
            for spot in OrchardLayout.fruitSpots(tree) {
                let inside = lobes.contains { lobe in
                    let dx = spot.x - lobe.x
                    let dy = (spot.y - lobe.y) / 0.82
                    return sqrt(dx * dx + dy * dy) <= lobe.r
                }
                XCTAssertTrue(inside, "有果子挂在叶子外面")
            }
        }
    }

    /// 落果散在树脚两侧（不是堆在正中间）。
    func testDroppedFruitSettlesBesideTheTrunk() {
        for tree in grove {
            for drop in OrchardLayout.droppedSpots(tree) {
                XCTAssertGreaterThan(abs(drop.x - 0.5), 0.15, "落果压在树干上了")
                XCTAssertLessThan(abs(drop.x - 0.5), 0.50, "落果滚出树冠范围了")
            }
        }
    }

    // MARK: - 风

    /// 无风站直、有风歪，且四棵歪得不一样（不是一个电机带动的）。
    ///
    /// 反证：把 `swayDegrees` 里的 `push` 删掉 → 红在第一条。
    func testSwayFollowsTheWind() {
        for tree in grove {
            XCTAssertEqual(OrchardLayout.swayDegrees(tree, push: 0), 0, accuracy: 1e-9,
                           "没风的时候树该是直的")
            let bent = OrchardLayout.swayDegrees(tree, push: 3)
            XCTAssertGreaterThan(abs(bent), 2, "风推了 3pt，树几乎没歪")
            // 方向跟着风走
            XCTAssertEqual(OrchardLayout.swayDegrees(tree, push: -3), -bent, accuracy: 1e-9)
        }
        let bends = Set(grove.map { String(format: "%.4f", OrchardLayout.swayDegrees($0, push: 3)) })
        XCTAssertEqual(bends.count, 4, "四棵的摆幅必须各不相同")
    }

    // MARK: - 确定性

    /// 同种子同一片果园（重绘不许换一批树）。
    func testLayoutIsDeterministic() {
        XCTAssertEqual(OrchardLayout.make(seed: 0x4652_5549, count: 4),
                       OrchardLayout.make(seed: 0x4652_5549, count: 4))
        XCTAssertNotEqual(OrchardLayout.make(seed: 0x4652_5549, count: 4),
                          OrchardLayout.make(seed: 0x4652_554A, count: 4))
        for tree in grove {
            XCTAssertEqual(OrchardLayout.canopyLobes(tree), OrchardLayout.canopyLobes(tree))
            XCTAssertEqual(OrchardLayout.fruitSpots(tree), OrchardLayout.fruitSpots(tree))
            XCTAssertEqual(OrchardLayout.droppedSpots(tree), OrchardLayout.droppedSpots(tree))
        }
    }

    /// 树冠的团不许跑到冠框外太多（否则树冠比框大一圈，风一吹就糊成一片）。
    func testLobesStayWithinTheCrown() {
        for tree in grove {
            let box = frame(tree)
            let crown = OrchardLayout.canopyRect(tree, in: box)
            let basis = min(crown.width, crown.height)
            for lobe in OrchardLayout.canopyLobes(tree) {
                XCTAssertGreaterThanOrEqual(crown.width * (lobe.x - lobe.r), -basis * 0.25)
                XCTAssertLessThanOrEqual(crown.width * (lobe.x + lobe.r),
                                         crown.width + basis * 0.25)
                XCTAssertGreaterThanOrEqual(crown.height * (lobe.y - lobe.r), -basis * 0.25)
            }
        }
    }
}
