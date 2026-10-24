import CoreGraphics
@testable import AppUI
import XCTest

/// 冬季积雪（#626）的布局纯函数。
///
/// 每条判据配一句「反证」——把实现换回错写法，断言必须红在**这一条**上。
final class ForestSnowCoverTests: XCTestCase {

    /// 树冠画框（与 `TreeCrownRenderTests` 同一档）。
    private let crown = CGSize(width: 380, height: 300)
    /// 地面带的现实尺寸。
    private let band = CGSize(width: 420, height: ForestSceneGeometry.groundBandHeight)

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

    /// 这顶帽子**骑在哪一团叶子上**（按几何反查，不靠另存的 id）。
    ///
    /// ⚠️ 不能只按 x 找：镜像成对的两团 x 相同，`first(where:)` 会随手抓到错的
    /// 那一团，于是「帽子坐在团顶」这条判据会对着别人喊红（第一版实测如此）。
    /// 三个条件都验：团心 x、帽心 y 的换算关系、帽宽比例 —— 三者同时对上才算。
    private func host(of cap: SnowCap, in size: CGSize) -> LeafCluster? {
        CanopyLayout.clusters(in: size).first { cluster in
            abs(cluster.center.x - cap.center.x) < 0.001
                && abs(cluster.center.y - cap.center.y) < 0.001
                && abs(cluster.radii.width - cap.radii.width) < 0.001
                && abs(cluster.radii.height - cap.radii.height) < 0.001
        }
    }

    // MARK: - 雪帽

    /// 雪只积在冠的**上面那三分之二**：冠底是叶背、被上层叶子挡着，积不上雪。
    ///
    /// ⚠️ 上界**不许**写成 `crown.height * dustedPortion` —— 那是拿实现给自己当判据，
    /// 把 `dustedPortion` 调到 1.2（哪一团都扣帽）也照样绿（实测踩过）。这里改成
    /// 按**冠底那 28% 的叶团**反查：那些团身上一顶帽子也不许有。
    ///
    /// 反证：把 `dustedPortion` 改成 1.2 → 红。
    func testSnowOnlyOnTheUpperCrown() {
        let caps = SnowCoverLayout.allCaps(in: crown)
        XCTAssertGreaterThan(caps.count, 8, "树冠上一顶雪帽都没有")
        let bottom = CanopyLayout.clusters(in: crown)
            .filter { $0.center.y > crown.height * 0.72 }
        XCTAssertFalse(bottom.isEmpty, "冠底没有叶团（判据会空转）")
        for cap in caps {
            let sitsOnBottom = bottom.contains { cluster in
                abs(cluster.center.x - cap.center.x) < 0.001
                    && abs(cluster.center.y - cap.center.y) < 0.001
            }
            XCTAssertFalse(sitsOnBottom, "雪扣在冠底的叶背上了（那里积不上雪）")
            XCTAssertGreaterThan(cap.center.y, 0, "雪帽飘到画框外面去了")
        }
    }

    /// 每道雪脊都**贴着某一团叶的轮廓**（同中心、同半径 —— 雪压在叶缘上）。
    ///
    /// ⚠️ 这条判据钉的是「雪脊不是另画的小椭圆」：小椭圆那版实测是「一冠白色荷叶」，
    /// 白斑浮在叶团中间、不贴叶缘。
    ///
    /// 反证：把 `caps` 里的半径改成 `cluster.radii * 0.6` → 红在半径那条。
    func testEveryCapFollowsItsClusterOutline() {
        let all = CanopyLayout.clusters(in: crown)
        XCTAssertFalse(all.isEmpty)
        for cap in SnowCoverLayout.allCaps(in: crown) {
            guard let host = host(of: cap, in: crown) else {
                XCTFail("有一道雪脊不贴着任何一团叶（雪飘在叶外）")
                continue
            }
            XCTAssertEqual(cap.radii.width, host.radii.width, accuracy: 1e-9,
                           "雪脊比叶团窄（成了浮在中间的白斑）")
            XCTAssertEqual(cap.radii.height, host.radii.height, accuracy: 1e-9,
                           "雪脊比叶团矮（成了浮在中间的白斑）")
        }
    }

    /// 冠上每一团（上面那三分之二）都积了雪，且**厚薄各不相同**（雪不是均厚一层）。
    ///
    /// 反证：把 `cover` 改成常量 → 红在第二条。
    func testEveryUpperClusterCarriesSnow() {
        let clusters = CanopyLayout.clusters(in: crown)
            .filter { $0.center.y < crown.height * SnowCoverLayout.dustedPortion }
        let caps = SnowCoverLayout.allCaps(in: crown)
        XCTAssertGreaterThan(caps.count, 6)
        XCTAssertEqual(caps.count, clusters.count, "冠上有的叶团没积雪（雪线会断）")
        XCTAssertGreaterThan(Set(caps.map { String(format: "%.4f", $0.cover) }).count, 3,
                             "每团盖得一样厚 —— 雪成了一床被子")
    }

    /// 帽子按**层**分：四层加起来正好是全冠那些，谁也不重复（雪得跟着本层的叶子晃）。
    ///
    /// 反证：把 `caps` 里的 band 过滤删掉（每层都返回全冠）→ 红在第一条。
    func testCapsSplitByBand() {
        let perBand = (0..<CanopyLayout.bandCount).map {
            SnowCoverLayout.caps(in: crown, band: $0)
        }
        let total = perBand.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, SnowCoverLayout.allCaps(in: crown).count,
                       "分层取的雪帽与整冠取的数目对不上（有重复或漏取）")
        // 每顶帽子只属于一层（按**它所骑的那一团**的 y 判，不按帽子自己的 y ——
        // 帽子是往上挪过的，用它的 y 反查会掉到上一层去）
        for (band, caps) in perBand.enumerated() {
            for cap in caps {
                guard let host = host(of: cap, in: crown) else {
                    XCTFail("有一顶雪帽不属于任何一团叶")
                    continue
                }
                XCTAssertEqual(
                    CanopyLayout.bandIndex(atY: host.center.y, in: crown), band,
                    "帽子归错了层（雪会跟着别人的叶子晃）")
            }
        }
    }

    /// 雪盖的比例落在「一块雪」这个区间里：不是一条白线、也不是整团糊白。
    ///
    /// 反证：把 `coverRatio` 改成 0.05 → 红。
    func testCoverProportionsReadAsSnow() {
        XCTAssertGreaterThan(SnowCoverLayout.coverRatio, 0.25, "雪太薄，读成描边")
        XCTAssertLessThan(SnowCoverLayout.coverRatio, 0.60, "雪太厚，整团叶糊白")
        XCTAssertLessThan(SnowCoverLayout.coverVariation, SnowCoverLayout.coverRatio * 0.5,
                          "厚薄差太大，有的团会白透、有的团一点雪也没有")
        for cap in SnowCoverLayout.allCaps(in: crown) {
            XCTAssertGreaterThan(cap.cover, 0.25)
            XCTAssertLessThan(cap.cover, 0.60)
        }
    }

    // MARK: - 枝上的雪

    /// 雪线走枝的**上表面**（相对枝心朝上），且只在枝的中段。
    ///
    /// 反证：把 `lift` 的符号反过来（画到枝下面）→ 红。
    func testLimbSnowRidesTheUpperSide() throws {
        let limbs = CanopyLayout.bands(in: crown).limbs.flatMap { $0 }
        XCTAssertFalse(limbs.isEmpty, "这棵树没有枝（判据会空转）")
        var checked = 0
        for limb in limbs {
            guard let snow = SnowCoverLayout.limbSnow(limb) else { continue }
            checked += 1
            XCTAssertEqual(snow.points.count, 7)
            for (index, point) in snow.points.enumerated() {
                let t = 0.12 + (0.62 - 0.12) * CGFloat(index) / 6
                let base = limb.point(at: t)
                XCTAssertLessThan(point.y, base.y + 0.001,
                                  "雪画到枝下面去了（雪不会积在枝的底面）")
            }
            XCTAssertGreaterThan(snow.width, 0, "雪线没有粗细")
            XCTAssertLessThan(snow.width, limb.width(at: 0.3), "雪线比枝还粗")
        }
        XCTAssertGreaterThan(checked, 4, "几乎没有枝挂得上雪")
    }

    /// 太细的枝不挂雪（细枝比头发丝还细，硬画就成了「树杈镶银边」）。
    func testThinTwigsCarryNoSnow() {
        let twig = LimbSpec(
            from: CGPoint(x: 0, y: 100), control: CGPoint(x: 20, y: 60),
            to: CGPoint(x: 40, y: 30), rootWidth: 0.4, tipWidth: 0.3, tone: 0.5)
        XCTAssertNil(SnowCoverLayout.limbSnow(twig))
    }

    // MARK: - 草地上的雪

    /// 雪堆踩在**草坡表面**上（和草叶、小动物踩的是同一条曲线）。
    ///
    /// 反证：把 `baseY` 改成常量 → 红。
    func testSnowDriftsSitOnTheSlope() {
        for drift in SnowDriftLayout.winterGlade {
            let expected = groundLine(band.width * drift.lane) + drift.inset
            XCTAssertEqual(
                SnowDriftLayout.baseY(drift, width: band.width, groundLine: groundLine),
                expected, accuracy: 1e-9, "雪堆没踩在坡面上")
            XCTAssertEqual(
                SnowDriftLayout.frame(drift, width: band.width, groundLine: groundLine).maxY,
                expected, accuracy: 1e-9, "雪堆底没落在坡面上")
        }
        // 坡是鼓包：靠边的雪堆比靠中间的坐得低
        let sorted = SnowDriftLayout.winterGlade.sorted { abs($0.lane - 0.5) > abs($1.lane - 0.5) }
        let outer = sorted.first!
        let inner = SnowDriftLayout.winterGlade.min { abs($0.lane - 0.5) < abs($1.lane - 0.5) }!
        XCTAssertGreaterThan(
            SnowDriftLayout.baseY(outer, width: band.width, groundLine: groundLine),
            SnowDriftLayout.baseY(inner, width: band.width, groundLine: groundLine),
            "坡是鼓包：靠边的雪堆该坐得低一些")
    }

    /// 三个雪堆，整只都在地面带里（不许戳出带顶 / 掉出带底）。
    ///
    /// 反证：把 `height` 改成 40 → 红在 minY 那条。
    func testSnowDriftsStayInsideTheBand() {
        XCTAssertEqual(SnowDriftLayout.winterGlade.count, 3)
        for width in [300, 336, 420, 476, 560, 700] as [CGFloat] {
            for drift in SnowDriftLayout.winterGlade {
                let box = SnowDriftLayout.frame(drift, width: width, groundLine: surface(width))
                XCTAssertGreaterThanOrEqual(box.minY, 0, "\(width)pt：雪堆戳出地面带上沿")
                XCTAssertLessThanOrEqual(box.maxY, band.height, "\(width)pt：雪堆掉出地面带")
            }
        }
    }

    /// 三个雪堆不是一个模子翻出来的，也都比一层雪盖厚（不然看不出是「堆」）。
    ///
    /// 反证：把 `width` / `height` 改成常量 → 红。
    func testSnowDriftsAreNotAllTheSame() {
        let drifts = SnowDriftLayout.winterGlade
        XCTAssertEqual(Set(drifts.map { String(format: "%.4f", $0.width) }).count, 3,
                       "雪堆宽必须个个不同")
        XCTAssertEqual(Set(drifts.map { String(format: "%.4f", $0.height) }).count, 3,
                       "雪堆高必须个个不同")
        for drift in drifts {
            XCTAssertGreaterThan(CGFloat(drift.height), SnowCoverLayout.blanketThickness * 0.6,
                                 "雪堆比一层雪盖还薄，看不出是堆")
            XCTAssertGreaterThan(drift.width, drift.height * 2, "雪堆不够扁")
        }
    }

    /// 雪盖得有厚度、有起伏（一条直线读成「草地贴了张白纸」）。
    ///
    /// 反证：把 `blanketRipple` 改成 0 → 红在第二条。
    func testBlanketHasThicknessAndRipple() {
        XCTAssertGreaterThan(SnowCoverLayout.blanketThickness, 4, "雪盖太薄，压不住草根")
        XCTAssertLessThan(SnowCoverLayout.blanketThickness, 18, "雪盖太厚，把草地整个埋了")
        XCTAssertGreaterThan(SnowCoverLayout.blanketRipple, 1, "雪线下沿是一条直线")
    }

    // MARK: - 接线（源码哨兵）

    /// 冠上的雪必须**逐层**包进风里（否则「叶子在晃、雪钉在半空」）。
    ///
    /// ⚠️ 钉的是调用形态：`CrownSnow` 与外层包着的 `swaying(band:` 必须成对出现。
    /// 只钉「出现了 CrownSnow」是不够的 —— 它完全可以被挪到 swaying 外面。
    ///
    /// 反证：把 `CrownSnow` 从 `swaying` 里挪出去 → 红。
    func testCrownSnowIsWrappedInTheBandSway() throws {
        let source = try String(
            contentsOfFile: "Sources/AppUI/Components/TreeCrown.swift", encoding: .utf8)
        let lines = source.split(separator: "\n").map(String.init)
        guard let snowLine = lines.firstIndex(where: { $0.contains("CrownSnow(theme:") })
        else {
            XCTFail("树冠里没有积雪层")
            return
        }
        // 往上找最近的那一层 swaying 包装：中间不许夹着它的收尾
        let above = lines[..<snowLine].reversed()
        var wrapped = false
        for line in above {
            if line.contains("swaying(band:") { wrapped = true; break }
            if line.contains("if theme.season == .winter") { break }
        }
        XCTAssertTrue(wrapped, "积雪层没有被包进本层的 WindSway（雪不会跟着叶子晃）")
    }

    /// 草地的雪盖必须画在**草叶之前**（草从雪里冒出来，而不是雪盖住草）。
    ///
    /// 反证：把 `ForestSnowField` 那一段移到 `grassBlade` 之后 → 红。
    func testSnowFieldIsDrawnUnderTheGrass() throws {
        let source = try String(
            contentsOfFile: "Sources/AppUI/Components/TreeCanvas.swift", encoding: .utf8)
        let snow = try XCTUnwrap(source.range(of: "ForestSnowField(theme:"),
                                 "地面带里没有雪盖")
        let grass = try XCTUnwrap(source.range(of: "grassBlade(x:"),
                                  "地面带里没有草叶（判据要跟着改）")
        XCTAssertLessThan(snow.lowerBound, grass.lowerBound,
                          "雪盖画在草叶之后了：草被雪埋住，成了「草地贴了张白纸」")
        // 只在冬天画（季节一关，草坡不许还白着）
        XCTAssertTrue(source.contains("if theme.season == .winter {"),
                      "雪盖没有季节开关")
    }

    // MARK: - 确定性

    /// 同种子同结果（重绘不许换一场雪）。
    func testLayoutIsDeterministic() {
        XCTAssertEqual(SnowCoverLayout.allCaps(in: crown), SnowCoverLayout.allCaps(in: crown))
        XCTAssertEqual(SnowDriftLayout.make(seed: 0x4452_4946, count: 3),
                       SnowDriftLayout.make(seed: 0x4452_4946, count: 3))
    }
}
