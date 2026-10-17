import AIDomain
@testable import AppUI
import XCTest

/// P0-C「统一地基接线」的测试：几何同源 + 坡面站位 + 层间过渡。
///
/// 分两类判据：
/// - **值等价**：各使用点读的是同一个常量（数值逐一相同，所以「无课程关卡时树逐像素不变」）；
/// - **源码哨兵**：接线断了不报错也不崩溃，只是森林又回到「各画各的」——
///   编译器发现不了，只能扫源码（同 ForestResponsiveness 的做法）。
///
/// ⚠️ 反证必须**真删/真改**：`codeLines` 扫的是非注释行，注释掉的接线照样算接上。
final class ForestSceneWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 源码的**非注释行**（`//` / `///` 开头的整行去掉）。
    private func codeLines(_ source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    // MARK: - ① 常量同源（值等价）

    /// 树与地面带的「地面」只能是同一个数：树干带高、林带高都读 `ForestSceneGeometry`。
    ///
    /// 反证：把任一处改回字面量（120 / 150）→ 与地基常量脱钩 → 红。
    func testGroundHeightsComeFromTheSceneGeometry() {
        XCTAssertEqual(TreeCanvas.groundHeight, ForestSceneGeometry.trunkGroundHeight,
                       "树干的扎根带高必须与地基同源（各拍一个数就会又错位）")
        XCTAssertEqual(TreeViewport.groundBandHeight, ForestSceneGeometry.groundBandHeight,
                       "林间地面带的现实高度必须与地基同源")
    }

    /// 画布的树根线就是地基的 groundLine（同一函数，两种写法也不许分出两个值）。
    ///
    /// 反证：改 `groundLine(canvasHeight:)` 的算式 → 与 `canvasHeight − groundHeight` 不等 → 红。
    func testTreeRootLineIsTheSceneGroundLine() {
        for height in [CGFloat(1080), 1308, 1662, 2040] {
            XCTAssertEqual(ForestSceneGeometry.groundLine(canvasHeight: height),
                           height - TreeCanvas.groundHeight,
                           accuracy: 0.0001,
                           "树根线必须处处等于「画布高 − 扎根带」（画布高 \(height) 处脱钩）")
        }
    }

    // MARK: - ② 坡面站位（源码哨兵）

    /// 地面带里站着的那些东西（草叶 / 灌木 / 小花 / 居民 / 对话植物）必须问坡要高度。
    ///
    /// 反证：把 `groundLine` 改回直线（`height − 34`）→ 坡面函数消失 → 红。
    func testGroundBandStandsOnTheHillSurface() throws {
        let ground = codeLines(try source("AppUI/Components/TreeCanvas.swift"))
        XCTAssertTrue(ground.contains {
            $0.contains("ForestSceneGeometry.hillSurfaceY(x: x, bandWidth: width, bandHeight: height)")
        }, "地面带必须把坡面函数（hillSurfaceY）接上 —— 改回直线就是「中心埋坡、两角浮空」")

        // 函数类型也真的换了：签名里不能再出现标量 groundLine。
        XCTAssertFalse(ground.contains { $0.contains("groundLine: CGFloat") },
                       "坡面是函数不是标量：签名漏改说明有调用点还在按直线算")
    }

    /// 草坡的形状常量读地基：高度与鼓包量都不许再各写一份。
    ///
    /// 反证：把 `.frame(height: 96)` 或 `minY - 12` 写回字面量 → 红。
    func testHillCapReadsTheSharedCurveConstants() throws {
        let ground = try source("AppUI/Components/TreeCanvas.swift")
        XCTAssertTrue(ground.contains(".frame(height: ForestSceneGeometry.hillCapHeight)"),
                      "草坡高度必须读地基常量（写回 96 就又多一处会漂的数）")
        XCTAssertTrue(ground.contains("rect.minY - ForestSceneGeometry.hillCapBulge"),
                      "草坡鼓包量必须读地基常量（曲线与 hillSurfaceY 从此不会只改一侧）")
    }

    /// 对话植物也站在同一条坡面上（它此前的浮空正是「花浮在半空」报障的来源）。
    ///
    /// 反证：把 ForestFloraBed 的入参改回 CGFloat 直线 → 红。
    func testConversationFloraStandsOnTheSameSurface() throws {
        let flora = codeLines(try source("AppUI/Components/GladeFloor.swift"))
        XCTAssertTrue(flora.contains { $0.contains("let groundLine: ForestGroundSurface") },
                      "对话植物的草坪入参必须是坡面函数")
        XCTAssertTrue(flora.contains { $0.contains("groundLine(x) - 2") },
                      "植株必须按自己的 x 问坡要高度")
    }

    // MARK: - ③ 层间过渡（山丘与草坡同一个地平线）

    /// 天空那三层山丘与地面带草坡同族：最近一层直接取 `hillCapHeight`——
    /// 它的脊线因此与草坡脊线落在同一水平线上（两栏共用一个地平线）。
    ///
    /// 反证：把近处那层改回 78（或另起一条曲线）→ 红。
    func testSkyHillsShareTheMoundRidgeLine() throws {
        let sky = try source("AppUI/Components/ForestSky.swift")
        XCTAssertTrue(sky.contains("frame(height: ForestSceneGeometry.hillCapHeight)"),
                      "最近的天空山丘必须与草坡同高（脊线对齐，两个栏落一个地平线）")
        // 三层都过大气透视：最远那层要融进天际的霾色。
        for depth in ["farHillDepth", "midHillDepth", "nearHillDepth"] {
            XCTAssertTrue(sky.contains("depth: ForestSceneGeometry.\(depth)"),
                          "山丘层 \(depth) 没接大气透视（又回到各画各的颜色）")
        }
        XCTAssertTrue(sky.contains("haze: theme.aerialHaze"),
                      "融天目标必须是当时天空在地平线附近的霾色")
    }

    /// 山丘轮廓与草坡是同一条曲线家族（单段对称二次曲线，鼓包比例相同）。
    ///
    /// 反证：把 HillShape 改回双段不对称曲线 → 红。
    func testSkyHillCurveMatchesTheMoundFamily() throws {
        let sky = codeLines(try source("AppUI/Components/ForestSky.swift"))
        XCTAssertTrue(sky.contains { $0.contains("rect.minY - rect.height * 0.125") },
                      "山丘鼓包比例必须与 HillCap 一致（hillCapBulge / hillCapHeight）")
        XCTAssertFalse(sky.contains { $0.contains("bump") },
                       "不许再保留自创的 bump 参数（两套曲线参数就是两条山脊线）")
    }

    // MARK: - ④ 缝合不变量（语义）

    /// 滚到底时画布的树根线落在地面带里（两个坐标空间的缝合点仍在原处）。
    ///
    /// 反证：改 `trunkGroundHeight` 或 `groundBandHeight` 任一个使落点越出草坡 → 红。
    func testCanvasRootLandsInsideTheGroundBandWhenScrolledToTheEnd() {
        let band = ForestSceneGeometry.groundBandHeight
        let landing = band - ForestSceneGeometry.trunkGroundHeight
        XCTAssertGreaterThan(landing, 0, "树根线落到了林带外面（树干浮空）")
        XCTAssertLessThan(landing, ForestSceneGeometry.slopeLine(bandHeight: band),
                          "树根线落到了草坡表面之上（树干戳出坡面）")
    }

    /// 年轮徽记读的是同一处林带高（它与 `learnerTargetY` 共用一套常量）。
    ///
    /// 反证：把 emblemY 改成另拍一个高度 → 与「林带 + 呼吸位」不等 → 红。
    func testEmblemReadsTheSameBandHeight() {
        let canvasHeight = TreeCanvas.canvasHeight(for: .seed())
        let expected = canvasHeight - ForestSceneGeometry.groundBandHeight - TreeViewport.clearance
        XCTAssertEqual(TreeRings.emblemY(canvasHeight: canvasHeight), expected, accuracy: 0.0001,
                       "徽记必须贴在林带之上同一个呼吸位（另算一条线就又会飘）")
    }
}
