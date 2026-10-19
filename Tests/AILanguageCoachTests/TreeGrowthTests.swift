import AppUI
import XCTest

/// #601「成长之树从幼苗开始」的换算层单测。
///
/// 判据全部走 `TreeGrowth` 纯函数（不渲染）：精确值 + 单调 + 满星恒等。
/// 「满星与改动前逐像素相同」这条**只能**在这里钉 —— 渲染测试没有「从前的图」
/// 可比，能比的只有「幼 / 成两档真的不同」（见 `TreeGrowthRenderTests`）。
final class TreeGrowthTests: XCTestCase {

    // MARK: - 树干粗细

    /// 三档精确值 + 满星恒等于改动前的常数（0.24 / 0.10）。
    ///
    /// 反证：把 `trunkWidths` 改成恒返回成年值 → 幼苗档断言红（第一屏没有变细）。
    func testTrunkWidthsHitExactValuesAtThreeStages() {
        XCTAssertEqual(TreeGrowth.trunkWidths(growth: 0).bottom, 0.13, accuracy: 0.0001)
        XCTAssertEqual(TreeGrowth.trunkWidths(growth: 0).top, 0.055, accuracy: 0.0001)
        XCTAssertEqual(TreeGrowth.trunkWidths(growth: 1).bottom, 0.24, accuracy: 0.0001)
        XCTAssertEqual(TreeGrowth.trunkWidths(growth: 1).top, 0.10, accuracy: 0.0001)
        // 中段线性：0.5 处恰好是中点。
        XCTAssertEqual(TreeGrowth.trunkWidths(growth: 0.5).bottom, 0.185, accuracy: 0.0001)
    }

    /// 越界钳住：负成熟度当幼苗、超过 1 当成年 —— 绝不画出负宽度。
    func testTrunkWidthsClampOutOfRangeGrowth() {
        XCTAssertEqual(TreeGrowth.trunkWidths(growth: -3).bottom,
                       TreeGrowth.trunkWidths(growth: 0).bottom, accuracy: 0.0001)
        XCTAssertEqual(TreeGrowth.trunkWidths(growth: 9).bottom,
                       TreeGrowth.trunkWidths(growth: 1).bottom, accuracy: 0.0001)
    }

    /// 单调：成熟度每涨一格，底宽顶宽都不许回缩。
    func testTrunkWidthsGrowMonotonically() {
        var previous = TreeGrowth.trunkWidths(growth: 0)
        for step in 1...20 {
            let current = TreeGrowth.trunkWidths(growth: Double(step) / 20)
            XCTAssertGreaterThanOrEqual(current.bottom, previous.bottom)
            XCTAssertGreaterThanOrEqual(current.top, previous.top)
            previous = current
        }
    }

    // MARK: - 树冠缩放

    /// 幼苗档 0.64（树冠明显缩着）、成年档 1.03 = 改动前的 `0.97 + 1.0*0.06`。
    ///
    /// 反证：把 `crownScale` 改成恒 1.03 → 幼苗档断言红。
    func testCrownScaleHitsExactValuesAtBothEnds() {
        XCTAssertEqual(TreeGrowth.crownScale(growth: 0), 0.64, accuracy: 0.0001)
        XCTAssertEqual(TreeGrowth.crownScale(growth: 1), 1.03, accuracy: 0.0001)
    }

    /// ⚠️ 这条判据**曾经是假的**（2026-10-19 用户报障「树冠顶部的树干都突出来了」后重写）。
    ///
    /// 从前的写法按「树冠艺术填满画框顶部」推算：0.64 时冠顶落在框内 y≈127、
    /// 刚接住树干尖（130）。可树冠艺术的**中列比画框顶低一截** —— 实测幼苗态
    /// 中列绿边在 y≈144，尖照样戳出来 16pt。缩放下限只保证「不为负、不出小冠长尖」，
    /// 真正把尖接住的是 `crownLift`（整冠上抬，见下一条）；
    /// 几何上的铁证在 `TreeGrowthRenderTests.testTrunkTipNeverPokesAboveTheCrown`。
    func testCrownScaleFloorIsOnlyHalfOfTheStory() {
        let scale = TreeGrowth.crownScale(growth: 0)
        XCTAssertGreaterThan(scale, 0, "缩放不为负")
        XCTAssertLessThan(scale, 1, "幼苗档必须明显缩着")
        // 光靠缩放接不住尖 —— 必须另有抬升（这就是从前漏掉的那一半）。
        XCTAssertGreaterThan(TreeGrowth.crownLift(growth: 0), 0,
                             "幼苗档没有抬升量，树干尖会从树冠上方戳出来")
    }

    // MARK: - 树冠上抬（接住树干尖）

    /// 幼苗档抬 26pt、满星恒 0。
    ///
    /// 满星恒 0 不是省的：成年态尖本来就埋在叶里（实测中列从 y≈80 起全是叶），
    /// 抬一下只会破坏「满星与从前逐像素相同」。
    ///
    /// 反证：`crownLift` 恒 0 → 幼苗档断言红。
    func testCrownLiftHitsExactValuesAtBothEnds() {
        XCTAssertEqual(TreeGrowth.crownLift(growth: 0), 26, accuracy: 0.0001)
        XCTAssertEqual(TreeGrowth.crownLift(growth: 1), 0, accuracy: 0.0001)
        XCTAssertEqual(TreeGrowth.crownLift(growth: 0.5), 13, accuracy: 0.0001)
    }

    /// 越界钳住 + 单调递减（越成熟抬得越少，绝不越长越抬）。
    func testCrownLiftClampsAndDecreasesMonotonically() {
        XCTAssertEqual(TreeGrowth.crownLift(growth: -3),
                       TreeGrowth.crownLift(growth: 0), accuracy: 0.0001)
        XCTAssertEqual(TreeGrowth.crownLift(growth: 9),
                       TreeGrowth.crownLift(growth: 1), accuracy: 0.0001)
        var previous = TreeGrowth.crownLift(growth: 0)
        for step in 1...20 {
            let current = TreeGrowth.crownLift(growth: Double(step) / 20)
            XCTAssertLessThanOrEqual(current, previous)
            previous = current
        }
    }

    // MARK: - 嫩苗可见窗口

    /// 窗口判据：0 星画、到 0.15 淡出完毕就不画。
    func testSproutVisibilityWindow() {
        XCTAssertTrue(TreeGrowth.showsSprout(growth: 0))
        XCTAssertTrue(TreeGrowth.showsSprout(growth: 0.14))
        XCTAssertFalse(TreeGrowth.showsSprout(growth: 0.15))
        XCTAssertFalse(TreeGrowth.showsSprout(growth: 1))
    }

    /// 窗口内透明度从 1 线性淡出到 0，窗口外恒 0。
    func testSproutOpacityFadesOutInsideTheWindow() {
        XCTAssertEqual(TreeGrowth.sproutOpacity(growth: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(TreeGrowth.sproutOpacity(growth: 0.075), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TreeGrowth.sproutOpacity(growth: 0.15), 0, accuracy: 0.0001)
        XCTAssertEqual(TreeGrowth.sproutOpacity(growth: 1), 0, accuracy: 0.0001)
    }

    /// 反证：把淡出窗口改成「永远画」→ 可见性断言红（树长成了还挂一株苗）。
    func testSproutNeverOutlivesTheSeedlingStage() {
        XCTAssertFalse(TreeGrowth.showsSprout(growth: TreeGrowth.sproutFadeoutGrowth),
                       "到淡出窗口边界还不撤，嫩苗会挂在一棵成年树上")
    }

    // MARK: - 接线哨兵（源码）

    /// `TreeCanvas` 必须把成熟度喂给树干 / 树冠 / 嫩苗三处 ——
    /// 换算层算得再对，接线断了画面就纹丝不动。
    ///
    /// 反证：删掉 body 里 `TrunkShape(..., growth: density)` 那一处传参 → 红。
    func testCanvasWiresGrowthIntoAllThreeLayers() throws {
        let source = try Self.canvasSource()
        XCTAssertTrue(source.contains("TrunkShape(tipY: Self.trunkTipY(for: progress), growth: density)"),
                      "树干没有接成熟度（第一屏的『年轻』信号没了）")
        XCTAssertTrue(source.contains("TreeGrowth.crownScale(growth: density)"),
                      "树冠缩放没有走 TreeGrowth（幼苗档冠幅不变）")
        XCTAssertTrue(source.contains("TreeGrowth.showsSprout(growth: density)"),
                      "嫩苗层没有按成熟度守卫（会长大成还挂着的株苗）")
    }

    /// 树冠与光柱必须吃**同一个**抬升量（#601 修）：光柱是「树冠漏下来的光」，
    /// 树冠抬了它不抬，就会从叶缝外面平白射进来。
    ///
    /// 反证：删掉 SunShafts 那一处 `- Self.crownLift(...)` → 红。
    func testCanvasWiresTheSameLiftIntoCrownAndShafts() throws {
        let source = try Self.canvasSource()
        let lift = "crownLift(density: density, hasCourseBand: Self.showsCourseBand(for: progress))"
        XCTAssertTrue(source.contains(lift), "树冠没有走 crownLift（树干尖会戳出来）")

        // 两处各挨着自己的宿主：按宿主切开，看切口后面那段里有没有抬升调用。
        // 窗口 900： canopy 那一处隔着「⚠️ 回到树顶」与「#601 修」两段注释（实测 727）。
        func block(after marker: String) -> String {
            guard let range = source.range(of: marker) else { return "" }
            return String(source[range.upperBound...].prefix(900))
        }
        XCTAssertTrue(block(after: "SunShafts(theme: theme)").contains(lift),
                      "光柱没有跟着树冠一起抬（会从叶缝外面平白射进来）")
        XCTAssertTrue(block(after: "Canopy(theme: theme, density: density,").contains(lift),
                      "树冠没有抬升（幼苗态树干尖戳出叶子）")
    }

    // MARK: - 夹具

    private static func canvasSource() throws -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AILanguageCoachTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Sources/AppUI/Components/TreeCanvas.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }
}
