import AIDomain
@testable import AppUI
import XCTest

/// 大树重构（2026-10-17）的**几何回归**：叶簇表 / 枝位表 / 树干剖面 / 果位覆盖。
///
/// 这一批把「果实挂簇上、枝梢藏冠里、簇间有缝隙、板根在坡面外扩」全部数值预验证过
/// （Python 移植 `ForestNoise.fbm` + 团块轮廓，判据见各测试注释）。那些验证当时是
/// 一次性的 —— 本文件把同四条判据钉进 Swift：改 `Canopy.clusters` /
/// `TreeBranches.branches` / `TrunkProfile` / `FruitLayer.placements` 任何一张表，
/// 这里当场红。v5（二轮重构）终值：16 果全覆盖最窄 7.3pt / 覆盖率 0.77 / 58 处缝。
///
/// ⚠️ 判据走 `Path.contains(_:)`（叶簇/剪影都是简单闭合曲线，无自交，两种缠绕
/// 规则结果一致）。坐标一律换算进**树冠那 300pt 帧**（局部坐标 → `rect` 坐标）。
final class TreeGeometryTests: XCTestCase {

    /// 树冠帧（与 `TreeCanvas.body` 里 `.frame(width: height: 300)` 同一张）。
    private let canopyRect = CGRect(x: 0, y: 0, width: 340, height: 300)

    /// 局部坐标（中心原点、y 向下）→ 树冠帧坐标。
    private func frame(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: canopyRect.midX + x, y: canopyRect.midY + y)
    }

    // MARK: - ① 果实必须挂在叶簇上（不是悬在深色托底里）

    /// 16 个果位每个都要落在某颗叶簇**轮廓内**。
    ///
    /// 反证：把任一颗果位挪出叶簇并集（或删掉覆盖它的那颗簇）→ 果实悬在
    /// 深色托底上 → 红。（Python 预验证的最窄余量 8.0pt，这里取「在内」这个
    /// 布尔判据 —— 余量本身随噪声走，钉不住；钉「在不在」足够防回退。）
    func testEveryFruitSitsInsideALeafCluster() throws {
        var uncovered: [String] = []
        for fruit in FruitLayer.placements {
            let point = frame(CGFloat(fruit.0), CGFloat(fruit.1))
            let onCluster = Canopy.clusters.contains { cluster in
                CanopyBlob(offset: cluster.offset, radii: cluster.radii,
                           seed: cluster.seed, frequency: cluster.frequency,
                           noiseAmount: cluster.noiseAmount)
                    .path(in: canopyRect)
                    .contains(point)
            }
            if !onCluster { uncovered.append("(\(fruit.0), \(fruit.1))") }
        }
        XCTAssertTrue(uncovered.isEmpty,
                      "这些果位不在任何叶簇内（会悬在深色托底上）: \(uncovered.joined(separator: " "))")
    }

    /// 果位表本身不许悄悄变形（数量 / 边界 / 两两距离 —— 与 `ForestEventTests` 同判据，
    /// 这里从「几何消费者」一侧再钉一遍：表一换，簇覆盖就可能破）。
    func testFruitPlacementTableStaysStable() {
        XCTAssertEqual(FruitLayer.placements.count, 16)
        for placement in FruitLayer.placements {
            XCTAssert(abs(placement.0) <= 170 && abs(placement.1) <= 160,
                      "果位越出树冠边界: \(placement)")
        }
        for (index, lhs) in FruitLayer.placements.enumerated() {
            for rhs in FruitLayer.placements.dropFirst(index + 1) {
                let distance = hypot(lhs.0 - rhs.0, lhs.1 - rhs.1)
                XCTAssertGreaterThan(distance, 24, "果位 \(lhs) 与 \(rhs) 太近（\(distance)）")
            }
        }
    }

    // MARK: - ② 枝梢必须藏进树冠剪影（不会从冠形上戳出来）

    /// 六根枝的梢头都要在 `CanopyMass` 轮廓内。
    ///
    /// 反证：把任一根枝的梢头拖出剪影（或改动剪影四团）→ 枝头戳出冠形 → 红。
    /// （Python 预验证的梢头余量 14–25pt。）
    func testBranchTipsAreHiddenInsideTheCrownSilhouette() throws {
        let mass = CanopyMass().path(in: canopyRect)
        for branch in TreeBranches.branches {
            let tip = branch.points[branch.points.count - 1]
            XCTAssertTrue(mass.contains(frame(tip.x, tip.y)),
                          "枝梢 (\(tip.x), \(tip.y)) 不在树冠剪影内，会戳出冠形")
        }
    }

    /// 枝基必须长在树干上：基座 |x| 不超过该高度树干的半宽。
    ///
    /// 反证：把基座挪出树干（或改动 `TrunkProfile` 让树干变细）→ 枝从树侧
    /// 浮出来 → 红。
    func testBranchBasesGrowOutOfTheTrunk() throws {
        for branch in TreeBranches.branches {
            let base = branch.points[0]
            // 无课程关卡：树冠帧顶在画布 20 处，中心在 170 → 基座画布 y = 170 + base.y
            let canvasY: CGFloat = 20 + 150 + base.y
            let halfWidth = TrunkProfile.halfWidthFraction(
                canvasY: canvasY, tipY: 130, canvasHeight: 1080) * 340
            XCTAssertLessThanOrEqual(abs(base.x), halfWidth - 2,
                                     "枝基 (\(base.x), \(base.y)) 浮在树干外（该高半宽 \(halfWidth)）")
        }
    }

    // MARK: - ③ 叶簇之间必须有缝隙（否则还是一团绿）

    /// 剪影内要有 10%–35% 的面积不被叶簇覆盖 —— 缝隙是「一簇一簇」的来源。
    ///
    /// 反证：把叶簇表改到铺满剪影（或删掉本测试允许的下限）→ 树冠退回一只
    /// 绿气球 → 红。
    func testClustersLeaveVisibleGapsInsideTheCrown() throws {
        // 路径只建一次（每个点重建一遍要跑 2 万次 fBm，10 秒量级）
        let mass = CanopyMass().path(in: canopyRect)
        let clusters = Canopy.clusters.map {
            CanopyBlob(offset: $0.offset, radii: $0.radii, seed: $0.seed,
                       frequency: $0.frequency, noiseAmount: $0.noiseAmount)
                .path(in: canopyRect)
        }
        var inside = 0
        var covered = 0
        var y = canopyRect.minY - 130
        while y <= canopyRect.midY + 180 {
            var x = canopyRect.midX - 200
            while x <= canopyRect.midX + 190 {
                let point = CGPoint(x: x, y: y)
                if mass.contains(point) {
                    inside += 1
                    if clusters.contains(where: { $0.contains(point) }) { covered += 1 }
                }
                x += 4
            }
            y += 4
        }
        let gapRatio = Double(inside - covered) / Double(inside)
        // 下限 0.18：v5 实测 ~0.23；v4（细缝版）只有 ~0.13，必须红在这一条上
        // —— 否则「缝隙够不够宽」这根判据压根没在钉东西。
        XCTAssertGreaterThan(gapRatio, 0.18, "叶簇铺满了剪影（缝隙仅 \(gapRatio)），又是一团绿")
        XCTAssertLessThan(gapRatio, 0.35, "缝隙过大（\(gapRatio)），树冠会碎成几丛")
    }

    // MARK: - ④ 树干剖面：板根外扩（根线以下必须继续变宽）

    /// 树根线处宽度钉死 0.24（正文几何），坡面线处必须宽过它（板根），
    /// 且根线以下单调外扩。
    ///
    /// 反证：把剖面改回「树尖到画布底一根锥」→ 根线以下不再变宽 → 红。
    func testTrunkFlaresBelowTheRootLine() throws {
        let rootY: CGFloat = 1080 - ForestSceneGeometry.trunkGroundHeight
        let surfaceY: CGFloat = 1080 - ForestSceneGeometry.slopeInset
        let rootHalf = TrunkProfile.halfWidthFraction(canvasY: rootY, tipY: 130, canvasHeight: 1080)
        let surfaceHalf = TrunkProfile.halfWidthFraction(canvasY: surfaceY, tipY: 130, canvasHeight: 1080)
        let bottomHalf = TrunkProfile.halfWidthFraction(canvasY: 1080, tipY: 130, canvasHeight: 1080)
        XCTAssertEqual(rootHalf * 2, 0.24, accuracy: 0.0001,
                       "树根线处的宽度是正文几何（关卡/锚点都按这棵树排），不许动")
        XCTAssertGreaterThan(surfaceHalf, rootHalf, "坡面线处必须外翻（板根第一级）")
        XCTAssertGreaterThan(bottomHalf, surfaceHalf, "画布底必须是最宽处（根展埋进土里）")
        // 根线以下单调外扩
        var previous = rootHalf
        var y = rootY + 6
        while y <= 1080 {
            let half = TrunkProfile.halfWidthFraction(canvasY: y, tipY: 130, canvasHeight: 1080)
            XCTAssertGreaterThanOrEqual(half, previous - 0.0001, "板根在 y=\(y) 处内缩了")
            previous = half
            y += 6
        }
    }
}
