import CoreGraphics
@testable import AppUI
import XCTest

/// 秋天草地上的落叶堆与南瓜（#625）的布局纯函数。
///
/// 每条判据配一句「反证」——把实现换回错写法，断言必须红在**这一条**上。
final class ForestAutumnExtrasTests: XCTestCase {

    private var piles: [ForestLeafPile] { LeafPileLayout.autumnGlade }
    private var pumpkins: [ForestPumpkin] { PumpkinLayout.autumnPatch }
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

    private func quantized(_ width: CGFloat) -> CGFloat { (width / 28).rounded() * 28 }

    /// **这一档宽度**的草坡表面。
    ///
    /// ⚠️ 不能拿 420pt 那一条去量 700pt 的面板：坡面是 `x / bandWidth` 的函数，
    /// 带宽写死会让宽面板上的 x 全部夹到 1（= 带底 150pt），于是「堆掉出地面带」
    /// 这种假警报就来了 —— 判据要的是**这块面板自己的坡**。
    private func surface(_ width: CGFloat) -> ForestGroundSurface {
        { x in
            ForestSceneGeometry.hillSurfaceY(
                x: x, bandWidth: width, bandHeight: ForestSceneGeometry.groundBandHeight)
        }
    }

    private func pileFrame(_ pile: ForestLeafPile, width: CGFloat = 420) -> CGRect {
        LeafPileLayout.frame(
            pile, width: width, quantizedWidth: quantized(width), groundLine: surface(width))
    }

    private func pumpkinFrame(_ pumpkin: ForestPumpkin, width: CGFloat = 420) -> CGRect {
        PumpkinLayout.frame(
            pumpkin, width: width, quantizedWidth: quantized(width), groundLine: surface(width))
    }

    // MARK: - 落叶堆：站位

    /// 四堆，横向铺开（不许两堆叠在一处 —— 那就读成「一堆」了）。
    ///
    /// 反证：把 `lane` 改成常量 → 红在间距那条。
    func testFourPilesLineTheClearing() {
        XCTAssertEqual(piles.count, 4)
        let lanes = piles.map(\.lane).sorted()
        for lane in lanes {
            XCTAssertGreaterThan(lane, 0.11, "落叶堆堆到画面外了")
            XCTAssertLessThan(lane, 0.89, "落叶堆堆到画面外了")
        }
        for index in 1..<lanes.count {
            XCTAssertGreaterThan(lanes[index] - lanes[index - 1], 0.12, "两堆落叶挨太近")
        }
    }

    /// 堆底踩在**草坡表面**上（和小动物、果树踩的是同一条曲线）。
    ///
    /// 反证：把 `baseY` 改成常量 → 红在第一条。
    func testPilesSitOnTheSlope() {
        for pile in piles {
            let expected = groundLine(band.width * pile.lane) + pile.inset
            XCTAssertEqual(
                LeafPileLayout.baseY(pile, width: band.width, groundLine: groundLine),
                expected, accuracy: 1e-9, "落叶堆没踩在坡面上")
            XCTAssertEqual(pileFrame(pile).maxY, expected, accuracy: 1e-9,
                           "堆底没落在坡面上")
        }
        // 坡是鼓包：靠边的那堆比靠中间那堆站得低（y 更大）
        let outer = piles.filter { abs($0.lane - 0.5) > 0.30 }
        let inner = piles.filter { abs($0.lane - 0.5) < 0.20 }
        XCTAssertFalse(outer.isEmpty, "没有靠边的落叶堆（种子换了要重挑）")
        XCTAssertFalse(inner.isEmpty, "没有靠中间的落叶堆（种子换了要重挑）")
        for out in outer {
            for inn in inner {
                XCTAssertGreaterThan(
                    LeafPileLayout.baseY(out, width: band.width, groundLine: groundLine),
                    LeafPileLayout.baseY(inn, width: band.width, groundLine: groundLine),
                    "坡是鼓包：靠边的落叶堆该站得低一些")
            }
        }
    }

    /// 一堆落叶是**扁的**（不是一座小山），且整堆都在地面带里。
    ///
    /// 反证：把 `squash` 改成 1（堆成一座山）→ 红在第一条。
    func testPilesAreFlatMounds() {
        for width in [300, 420, 560, 700] as [CGFloat] {
            for pile in piles {
                let box = pileFrame(pile, width: width)
                // 扁但有厚度：够两三层叶子（太扁就只剩底下一摊褐色）
                XCTAssertLessThan(box.height, box.width * 0.62,
                                  "\(width)pt：落叶堆堆成一座小山了")
                XCTAssertGreaterThan(box.height, box.width * 0.34,
                                     "\(width)pt：落叶堆太扁，盖不住底下一坨")
                XCTAssertGreaterThanOrEqual(box.minY, 0, "\(width)pt：落叶堆戳出地面带")
                XCTAssertLessThanOrEqual(box.maxY, band.height, "\(width)pt：落叶堆掉出地面带")
            }
        }
    }

    // MARK: - 落叶堆：造型

    /// 叶子是**堆起来的**（山形：越往上站得越窄），不是在整个框里均匀撒开的。
    ///
    /// 反证：把 `leafSpots` 改成 `x` 在 0…1 上均匀撒 → 红（顶上的叶子会跑到堆外）。
    func testLeavesArePiledNotScattered() {
        for pile in piles {
            for spot in LeafPileLayout.leafSpots(pile) {
                XCTAssertGreaterThanOrEqual(spot.y, 0.13, "叶子飘到堆顶上方去了")
                XCTAssertLessThanOrEqual(spot.y, 1.0, "叶子陷到堆底下去了")
                // 山形的边界：这一层的横向可站范围
                let level = (1.0 - spot.y) / 0.86
                let allowed = 0.46 * (1 - level * 0.58)
                XCTAssertLessThanOrEqual(abs(spot.x - 0.5), allowed + 1e-9,
                                         "叶子撒到堆外面去了（不是堆起来的）")
            }
        }
    }

    /// 越往上的叶子越小（堆尖上是碎叶，不是一片大叶子盖着）。
    ///
    /// 反证：把 `scale` 里的 `- level * 0.12` 删掉 → 红。
    func testHigherLeavesAreSmaller() {
        for pile in piles {
            let spots = LeafPileLayout.leafSpots(pile)
            let sorted = spots.sorted { $0.y < $1.y }
            guard sorted.count > 3 else { continue }
            let top = sorted.prefix(2).reduce(0.0) { $0 + $1.scale } / 2
            let bottom = sorted.suffix(2).reduce(0.0) { $0 + $1.scale } / 2
            XCTAssertLessThan(top, bottom, "堆尖上的叶子不比堆底的小")
        }
    }

    /// 堆脚边那几片**散在堆外**（散叶本来就在堆外 —— 落在堆里就读成堆的一部分了）。
    ///
    /// 反证：把 `looseSpots` 的 `0.54` 改成 0.2 → 红。
    func testLooseLeavesFallOutsideTheMound() {
        for pile in piles {
            XCTAssertGreaterThanOrEqual(pile.looseCount, 1, "堆脚边没有散叶")
            for spot in LeafPileLayout.looseSpots(pile) {
                XCTAssertGreaterThan(abs(spot.x - 0.5), 0.5, "散叶落在堆里了")
                XCTAssertLessThan(abs(spot.x - 0.5), 0.85, "散叶滚得太远")
            }
        }
    }

    /// 一堆得有够多的叶子（三四片读不出「一堆」），且三色混着。
    ///
    /// 反证：把 `leafCount` 改成 3 → 红在第一条；把 tone 改成常量 → 红在第二条。
    func testEveryPileHasEnoughLeaves() {
        for pile in piles {
            // 叶子得够多：堆宽 ~39pt 上一片叶 ~12pt，十几片才盖得住堆底那一坨
            XCTAssertGreaterThanOrEqual(pile.leafCount, 12, "一堆落叶的叶子太少")
            let spots = LeafPileLayout.leafSpots(pile)
            XCTAssertEqual(spots.count, pile.leafCount)
            XCTAssertGreaterThan(Set(spots.map(\.tone)).count, 1,
                                 "一堆落叶只有一个颜色，读成一块色斑")
            // 叶子是转着落下来的（不是一片片平铺对齐的）
            XCTAssertGreaterThan(Set(spots.map { String(format: "%.3f", $0.angle) }).count, 4)
        }
    }

    /// 四堆不是一个模子翻出来的（宽度 / 扁度 / 倾斜各不相同）。
    ///
    /// 反证：把这三个字段改成常量 → 红。
    func testNoTwoPilesAreTheSamePile() {
        XCTAssertEqual(Set(piles.map { String(format: "%.4f", $0.spanScale) }).count, 4,
                       "堆宽必须堆堆不同")
        XCTAssertEqual(Set(piles.map { String(format: "%.4f", $0.squash) }).count, 4,
                       "扁度必须堆堆不同")
        XCTAssertEqual(Set(piles.map { String(format: "%.4f", $0.tilt) }).count, 4,
                       "倾斜必须堆堆不同")
    }

    // MARK: - 南瓜：站位

    /// 三个，站在**中间那片空地**上（两边外侧留给果树），彼此不叠。
    ///
    /// 反证：把 `lane` 的 `stride` 改成 0 → 红在「叠在一处」那条。
    func testThreePumpkinsSitInTheOpen() {
        XCTAssertEqual(pumpkins.count, 3)
        for pumpkin in pumpkins {
            XCTAssertLessThan(abs(pumpkin.lane - 0.5), 0.30, "南瓜挤到边上跟果树打架了")
        }
        for width in [300, 420, 560, 700] as [CGFloat] {
            let boxes = pumpkins.map { pumpkinFrame($0, width: width) }
            for i in 0..<boxes.count {
                for j in (i + 1)..<boxes.count {
                    let gap = abs(boxes[i].midX - boxes[j].midX)
                    XCTAssertGreaterThan(gap, (boxes[i].width + boxes[j].width) / 2,
                                         "\(width)pt：两个南瓜叠在一处了")
                }
            }
        }
    }

    /// 南瓜**比小动物矮一半还多**（是躺在地上的，不能跟小动物抢个头）。
    ///
    /// 反证：把 `animalHeights` 改成 1.2 → 红。
    func testPumpkinsAreShorterThanAnAnimal() {
        for width in [336, 420, 560] as [CGFloat] {
            let animal = ForestGroundPlan.referenceResidentSize(quantizedWidth: quantized(width))
            for pumpkin in pumpkins {
                let box = pumpkinFrame(pumpkin, width: width)
                XCTAssertLessThan(box.height, animal * 0.60,
                                  "\(width)pt：南瓜跟小动物一样高了")
                XCTAssertGreaterThan(box.height, animal * 0.25,
                                     "\(width)pt：南瓜小得看不见了")
                XCTAssertGreaterThan(box.width, box.height, "南瓜得是扁的（宽大于高）")
            }
        }
    }

    /// 三个不是一个模子翻出来的（高矮 / 扁瘦 / 歪向各不相同）。
    ///
    /// 反证：把这三个字段改成常量 → 红。
    func testNoTwoPumpkinsAreTheSameGourd() {
        XCTAssertEqual(Set(pumpkins.map { String(format: "%.4f", $0.heightScale) }).count, 3,
                       "高矮必须个个不同")
        XCTAssertEqual(Set(pumpkins.map { String(format: "%.4f", $0.widthRatio) }).count, 3,
                       "扁瘦必须个个不同")
        XCTAssertEqual(Set(pumpkins.map { String(format: "%.4f", $0.lean) }).count, 3,
                       "歪向必须个个不同")
    }

    /// 瓜底踩在**草坡表面**上（还往下陷一点 —— 南瓜是重的）。
    ///
    /// 反证：把 `baseY` 里的 `groundLine` 去掉 → 红。
    func testPumpkinsSitOnTheSlope() {
        for pumpkin in pumpkins {
            let expected = groundLine(band.width * pumpkin.lane) + pumpkin.sink
            XCTAssertEqual(
                PumpkinLayout.baseY(pumpkin, width: band.width, groundLine: groundLine),
                expected, accuracy: 1e-9, "南瓜没坐在坡面上")
            XCTAssertEqual(pumpkinFrame(pumpkin).maxY, expected, accuracy: 1e-9,
                           "瓜底没落在坡面上")
        }
        // 坡是鼓包：靠边那只比靠中间那只坐得低
        let outer = pumpkins.filter { abs($0.lane - 0.5) > 0.18 }
        let inner = pumpkins.filter { abs($0.lane - 0.5) < 0.06 }
        XCTAssertFalse(outer.isEmpty)
        XCTAssertFalse(inner.isEmpty)
        for out in outer {
            for inn in inner {
                XCTAssertGreaterThan(
                    PumpkinLayout.baseY(out, width: band.width, groundLine: groundLine),
                    PumpkinLayout.baseY(inn, width: band.width, groundLine: groundLine),
                    "坡是鼓包：靠边的南瓜该坐得低一些")
            }
        }
    }

    /// 整只瓜都在地面带里（不许半个戳出带顶 / 掉出带底）。
    ///
    /// 反证：把 `animalHeights` 调到 2 → 红在 minY 那条。
    func testPumpkinsStayInsideTheBand() {
        for width in [300, 336, 420, 476, 560, 700] as [CGFloat] {
            for pumpkin in pumpkins {
                let box = pumpkinFrame(pumpkin, width: width)
                XCTAssertGreaterThanOrEqual(box.minY, 0, "\(width)pt：南瓜戳出地面带上沿")
                XCTAssertLessThanOrEqual(box.maxY, band.height, "\(width)pt：南瓜掉出地面带")
            }
        }
    }

    // MARK: - 南瓜：造型

    /// 瓜蒂坐在**顶上那个凹里**（不是插在瓜身中间）。
    ///
    /// 反证：把 `stemRect` 的 `y` 改成框中间 → 红在第一条。
    func testStemSitsInTheDipOnTop() {
        for pumpkin in pumpkins {
            let box = pumpkinFrame(pumpkin)
            let stem = PumpkinLayout.stemRect(pumpkin, in: box)
            XCTAssertLessThan(stem.midY, box.minY + box.height * 0.3, "瓜蒂插进瓜身里了")
            XCTAssertGreaterThan(stem.maxY, box.minY, "瓜蒂悬在瓜顶上方（没坐进凹里）")
            XCTAssertEqual(stem.midX, box.midX, accuracy: 1e-9, "瓜蒂没在顶凹的中央")
        }
    }

    /// 每只都有棱（南瓜是被棱分成一瓣瓣的，没有棱就是一颗橙色的球）。
    ///
    /// 反证：把 `ribs` 改成 0 → 红。
    func testEveryPumpkinIsRibbed() {
        for pumpkin in pumpkins {
            XCTAssertGreaterThanOrEqual(pumpkin.ribs, 3, "南瓜没有棱，读成一颗橙球")
            XCTAssertLessThanOrEqual(pumpkin.ribs, 4, "棱太密，读成条纹")
        }
    }

    // MARK: - 尺子

    /// 落叶堆与南瓜都得拿**小动物那把尺**量（不是各拍一个数）。
    ///
    /// 反证：把 `span` / `height` 里的 `referenceResidentSize` 换成字面量 → 红在第三条。
    func testTheRulerIsTheAnimalsOwn() throws {
        let source = try String(
            contentsOfFile: "Sources/AppUI/Components/ForestAutumnExtras.swift",
            encoding: .utf8)
        // 两处都得走同一把尺（按 `PumpkinLayout` 切开，两半各自钉）
        let halves = source.components(separatedBy: "enum PumpkinLayout")
        XCTAssertEqual(halves.count, 2, "布局的划分变了，这条判据要跟着改")
        for (index, half) in halves.enumerated() {
            XCTAssertTrue(half.contains("ForestGroundPlan.referenceResidentSize("),
                          "第 \(index + 1) 段布局没有共用居民体型那把尺")
        }
        XCTAssertFalse(source.contains("28 + quantizedWidth * 0.045"),
                       "体型公式在秋景层里又抄了一份")
        // 换算出来说得通不算数：面板宽了小动物大了，落叶堆与南瓜必须跟着一起长
        let narrowPile = LeafPileLayout.span(piles[0], quantizedWidth: 336)
        let widePile = LeafPileLayout.span(piles[0], quantizedWidth: 560)
        XCTAssertGreaterThan(widePile - narrowPile, 6, "面板宽了，落叶堆却没跟着变大")
        let narrowGourd = PumpkinLayout.height(pumpkins[0], quantizedWidth: 336)
        let wideGourd = PumpkinLayout.height(pumpkins[0], quantizedWidth: 560)
        XCTAssertGreaterThan(wideGourd - narrowGourd, 3, "面板宽了，南瓜却没跟着变大")
    }

    // MARK: - 确定性

    /// 同种子同结果（重绘不许换一批落叶 / 换一批南瓜）。
    func testLayoutsAreDeterministic() {
        XCTAssertEqual(LeafPileLayout.make(seed: 0x4C45_4146, count: 4),
                       LeafPileLayout.make(seed: 0x4C45_4146, count: 4))
        XCTAssertEqual(PumpkinLayout.make(seed: 0x5055_4D50, count: 3),
                       PumpkinLayout.make(seed: 0x5055_4D50, count: 3))
        XCTAssertEqual(LeafPileLayout.leafSpots(piles[0]),
                       LeafPileLayout.leafSpots(piles[0]))
        XCTAssertEqual(LeafPileLayout.looseSpots(piles[1]),
                       LeafPileLayout.looseSpots(piles[1]))
    }
}
