import AppKit
import AppUI
import SwiftUI
import XCTest

/// 森林统一地基（`ForestScene.swift`）的纯函数回归。
///
/// 这个文件钉的是**「一层一块」的反面**：所有插画层从同一条景深轴取数，
/// 所以下列性质必须成立 —— 深度单调、跨层风场同相位、大气透视单调趋近霾色、
/// 草坡表面连续。每条断言都写着「撤掉对应实现会红在哪」。
final class ForestSceneTests: XCTestCase {

    // MARK: - 几何：唯一的 groundLine 与景深轴

    /// 画布空间的地心引力：depth 0 = 树根线，depth 1 = 地平线，中间单调。
    ///
    /// 反证：把 `standingY` 改成与 depth 无关（返回常量）→ 单调断言红。
    func testCanvasDepthAxisIsMonotonic() {
        let canvas: CGFloat = 1080
        let ground = ForestSceneGeometry.groundLine(canvasHeight: canvas)
        let horizon = ForestSceneGeometry.horizonY(canvasHeight: canvas)

        XCTAssertEqual(ground, canvas - ForestSceneGeometry.trunkGroundHeight)
        XCTAssertEqual(horizon, ground - ForestSceneGeometry.horizonSpan)
        XCTAssertEqual(ForestSceneGeometry.standingY(forDepth: 0, canvasHeight: canvas), ground)
        XCTAssertEqual(ForestSceneGeometry.standingY(forDepth: 1, canvasHeight: canvas), horizon)

        var previous = ForestSceneGeometry.standingY(forDepth: 0, canvasHeight: canvas)
        for step in 1...20 {
            let y = ForestSceneGeometry.standingY(
                forDepth: CGFloat(step) / 20, canvasHeight: canvas)
            XCTAssertLessThan(y, previous, "越远必须越高（screen y 越小）：depth \(step)/20")
            previous = y
        }
        // 反查闭环：y → depth → y 还原
        for step in 0...20 {
            let depth = CGFloat(step) / 20
            let y = ForestSceneGeometry.standingY(forDepth: depth, canvasHeight: canvas)
            XCTAssertEqual(
                ForestSceneGeometry.depth(forStandingY: y, canvasHeight: canvas),
                depth, accuracy: 1e-6)
        }
    }

    /// 地面带空间锚在草坡表面线上：depth 0 = 坡面，depth 1 = 带顶（天际）。
    ///
    /// 反证：把 `bandY(forDepth: 0)` 改成返回 0 → 本条红（坡面不再是基准）。
    func testBandDepthAxisAnchorsAtTheSlopeLine() {
        let band = ForestSceneGeometry.groundBandHeight
        XCTAssertEqual(ForestSceneGeometry.slopeLine(bandHeight: band), band - ForestSceneGeometry.slopeInset)
        XCTAssertEqual(ForestSceneGeometry.bandY(forDepth: 0, bandHeight: band),
                       ForestSceneGeometry.slopeLine(bandHeight: band))
        XCTAssertEqual(ForestSceneGeometry.bandY(forDepth: 1, bandHeight: band), 0)
        for step in 0...20 {
            let depth = CGFloat(step) / 20
            let y = ForestSceneGeometry.bandY(forDepth: depth, bandHeight: band)
            XCTAssertEqual(
                ForestSceneGeometry.bandDepth(forY: y, bandHeight: band),
                depth, accuracy: 1e-6)
        }
    }

    /// 两个坐标空间在「滚到底」时缝合：树根线落在地面带里，不在带外漂着。
    ///
    /// 反证：改 `trunkGroundHeight` 或 `groundBandHeight` 任一个使
    /// `groundBandHeight − trunkGroundHeight` 越出 [0, bandHeight] → 红。
    func testCanvasGroundLineLandsInsideTheGroundBand() {
        let band = ForestSceneGeometry.groundBandHeight
        let offsetInBand = band - ForestSceneGeometry.trunkGroundHeight
        XCTAssertGreaterThan(offsetInBand, 0, "树根线必须落在地面带内（树干扎进草坡）")
        XCTAssertLessThan(offsetInBand, band, "树根线不能越过地面带顶")
    }

    /// depth → 视觉参数四件套全部单调（近大远小、近实远淡、近清晰远糊、近本色远融天）。
    ///
    /// 反证：任一条曲线方向写反（如 opacity 随 depth 上涨）→ 红。
    func testDepthStyleMovesMonotonicallyTowardTheHorizon() {
        var previous = ForestSceneGeometry.style(forDepth: 0)
        for step in 1...20 {
            let style = ForestSceneGeometry.style(forDepth: CGFloat(step) / 20)
            XCTAssertLessThan(style.scale, previous.scale, "越远越小")
            XCTAssertLessThan(style.opacity, previous.opacity, "越远越淡")
            XCTAssertGreaterThan(style.blur, previous.blur, "越远越糊")
            XCTAssertGreaterThan(style.haze, previous.haze, "越远越融进天空")
            previous = style
        }
        XCTAssertEqual(previous.scale, 0.78, accuracy: 1e-3)
        XCTAssertEqual(previous.opacity, 0.70, accuracy: 1e-3)
    }

    /// 景深轴有界：越过地平线没有更远，穿过地面没有更近。
    func testDepthIsClamped() {
        let canvas: CGFloat = 1080
        XCTAssertEqual(ForestSceneGeometry.standingY(forDepth: 5, canvasHeight: canvas),
                       ForestSceneGeometry.horizonY(canvasHeight: canvas))
        XCTAssertEqual(ForestSceneGeometry.standingY(forDepth: -3, canvasHeight: canvas),
                       ForestSceneGeometry.groundLine(canvasHeight: canvas))
        XCTAssertEqual(ForestSceneGeometry.style(forDepth: 9).scale,
                       ForestSceneGeometry.style(forDepth: 1).scale)
    }

    // MARK: - 草坡表面曲线（「一块一块」的直接解药）

    /// 坡面曲线与 `HillCap` 的鼓包逐点一致：两角在底、中心是峰、左右对称。
    ///
    /// 反证：把 `hillSurfaceY` 的中心值改成 `bandHeight`（拉成直线）→ 中心 < 坡面线断言红。
    func testHillSurfaceCurveMatchesTheMound() {
        let band = ForestSceneGeometry.groundBandHeight
        let width: CGFloat = 340
        let surface = ForestSceneGeometry.slopeLine(bandHeight: band)

        // 两角贴底（与 HillCap 的 move/addLine 到 maxY 一致）
        XCTAssertEqual(ForestSceneGeometry.hillSurfaceY(x: 0, bandWidth: width, bandHeight: band),
                       band, accuracy: 1e-6)
        XCTAssertEqual(ForestSceneGeometry.hillSurfaceY(x: width, bandWidth: width, bandHeight: band),
                       band, accuracy: 1e-6)

        // 中心是峰：capTop + C/2 − bulge/2 = 54 + 48 − 6 = 96
        let apex = ForestSceneGeometry.hillSurfaceY(x: width / 2, bandWidth: width, bandHeight: band)
        XCTAssertEqual(apex, 96, accuracy: 1e-6)
        // 峰高出草坡表面线 20pt —— 这正是「草叶站在直线上、坡却是个鼓包」的错位量
        XCTAssertLessThan(apex, surface, "鼓包必须高出曾经的直线基准，否则曲线白改")

        // 左右对称
        for fraction in stride(from: CGFloat(0.05), through: 0.95, by: 0.05) {
            let left = ForestSceneGeometry.hillSurfaceY(
                x: width * fraction, bandWidth: width, bandHeight: band)
            let right = ForestSceneGeometry.hillSurfaceY(
                x: width * (1 - fraction), bandWidth: width, bandHeight: band)
            XCTAssertEqual(left, right, accuracy: 1e-6, "坡面左右对称：x = \(fraction)")
        }
    }

    /// 坡面连续：细扫没有跳变（层与层的接缝不许出现在坡上）。
    ///
    /// 反证：把曲线换成查表 + 最近邻取整 → 最大步长越界 → 红。
    func testHillSurfaceIsContiguous() {
        let band = ForestSceneGeometry.groundBandHeight
        let width: CGFloat = 340
        var previous = ForestSceneGeometry.hillSurfaceY(x: 0, bandWidth: width, bandHeight: band)
        var maxStep: CGFloat = 0
        for step in 1...3400 {
            let x = CGFloat(step) * 0.1
            let y = ForestSceneGeometry.hillSurfaceY(x: x, bandWidth: width, bandHeight: band)
            maxStep = max(maxStep, abs(y - previous))
            previous = y
        }
        XCTAssertLessThan(maxStep, 0.5, "0.1pt 步长下坡面最多移动 \(maxStep)pt")
    }

    // MARK: - 大气透视

    /// 所有插画色（日夜两档）都随景深**单调趋近霾色**。
    ///
    /// 反证：把 `adjust` 的混合方向写反（往本色收敛）→ 距离不再递减 → 红。
    func testAerialPerspectiveConvergesMonotonicallyTowardHaze() {
        let palettes: [(String, ForestTheme, Color)] = [
            ("day", ForestTheme(palette: .day), Color(hex: 0xE9F8DE)),
            ("night", ForestTheme(palette: .night), Color(hex: 0x24405A)),
        ]
        for (name, theme, haze) in palettes {
            let colors = [
                theme.hillFar, theme.hillMid, theme.hillNear,
                theme.foliage, theme.foliageDeep, theme.trunk, theme.trunkShade,
            ]
            for color in colors {
                let base = distance(color, to: haze)
                let near = distance(
                    ForestAerialPerspective.adjust(color, depth: 0.35, haze: haze), to: haze)
                let far = distance(
                    ForestAerialPerspective.adjust(color, depth: 1, haze: haze), to: haze)
                XCTAssertLessThan(far, base, "\(name)：地平线处必须比本色更接近霾色")
                XCTAssertLessThan(far, near, "\(name)：趋近必须单调（0.35 → 1 继续靠近）")
            }
        }
    }

    /// depth 0 保持本色（近处不瞎调）；饱和度与明度方向正确。
    ///
    /// 反证：删掉 `adjust` 里 `d > 0` 的提前返回 → depth 0 也被改动 → 红。
    func testNearDepthKeepsTheColorAndFarDepthGreysIt() {
        let color = ForestTheme(palette: .day).hillNear
        let haze = ForestTheme(palette: .day).aerialHaze
        XCTAssertEqual(
            ForestAerialPerspective.adjust(color, depth: 0, haze: haze),
            color, "depth 0 必须原样返回（近处不掺假）")
        XCTAssertLessThan(
            ForestAerialPerspective.saturation(depth: 1),
            ForestAerialPerspective.saturation(depth: 0), "越远越灰")
        XCTAssertGreaterThan(
            ForestAerialPerspective.brightness(depth: 1),
            ForestAerialPerspective.brightness(depth: 0), "越远越亮")
        XCTAssertEqual(ForestAerialPerspective.hazeAmount(depth: 0), ForestAerialPerspective.nearHaze)
        XCTAssertEqual(ForestAerialPerspective.hazeAmount(depth: 1), ForestAerialPerspective.farHaze)
    }

    /// 霾色取天空渐变末端（贴地平线那一档），不是天顶。
    func testHazeIsTakenFromTheHorizonEndOfTheSky() {
        let theme = ForestTheme(palette: .day)
        XCTAssertEqual(theme.aerialHaze, theme.sky.last)
    }

    // MARK: - 全局光照

    /// 太阳在右上 → 所有深度的影子都朝左下；近处长且实，远处短且淡。
    ///
    /// 反证：把 `light` 的 dy 改成负 → 影子朝天 → 红。
    func testShadowsAllFallTheSameWay() {
        var previousLength = ForestLighting.shadowLength(forDepth: 0)
        var previousStrength: Double = 2
        for step in 0...20 {
            let depth = CGFloat(step) / 20
            let offset = ForestLighting.shadowOffset(forDepth: depth)
            XCTAssertLessThan(offset.width, 0, "影子朝左（太阳在右）")
            XCTAssertGreaterThan(offset.height, 0, "影子朝下（太阳在上）")
            let length = ForestLighting.shadowLength(forDepth: depth)
            let strength = ForestLighting.shadowStrength(forDepth: depth)
            if step > 0 {
                XCTAssertLessThan(length, previousLength, "越远影子越短")
                XCTAssertLessThan(strength, previousStrength, "越远影子越淡")
            }
            previousLength = length
            previousStrength = strength
        }
    }

    // MARK: - 全局风场

    /// **跨层一致性的核心恒等式**：波沿 +x 走，x 与相位一起平移，波形不变。
    ///
    /// 反证：把 `wave` 里的 `− x·waveNumber` 改成 `+`（波反向）或删掉相位延迟
    /// → 恒等式不再成立 → 红。
    func testWindWaveTravelsAsOneContinuousField() {
        let phase = 2.3
        for (a, b) in [(0.0, 120.0), (100.0, 350.0), (-40.0, 80.0)] {
            let shifted = (b - a) * WindField.waveNumber
            XCTAssertEqual(
                WindField.wave(x: a, phase: phase),
                WindField.wave(x: b, phase: phase + shifted),
                accuracy: 1e-9,
                "x=\(a)@p 必须与 x=\(b)@p+\((b - a) * WindField.waveNumber) 同波位")
        }
    }

    /// 风场连续：细扫 x 没有跳变（否则层与层接缝处会「跳一下」）。
    func testWindIsContinuousAcrossX() {
        let phase = 1.1
        var previous = WindField.wave(x: 0, phase: phase)
        var maxStep: Double = 0
        for step in 1...3000 {
            let x = CGFloat(step) * 0.1
            let current = WindField.wave(x: x, phase: phase)
            maxStep = max(maxStep, abs(current - previous))
            previous = current
        }
        XCTAssertLessThan(maxStep, 0.01, "0.1pt 步长下波形最多移动 \(maxStep)")
    }

    /// 阵风会呼吸（0.5…1.0 之间真的摆），且是全局标量（与 x 无关）。
    ///
    /// 反证：把 `gust` 改成常量 0.75 → 呼吸区间断言红。
    func testGustBreathesAndIsGlobal() {
        var minGust = Double.greatestFiniteMagnitude
        var maxGust = -Double.greatestFiniteMagnitude
        for step in 0...2000 {
            let value = WindField.gust(Double(step) * 0.05)
            XCTAssertEqual(value, WindField.gust(Double(step) * 0.05), "阵风与 x 无关（全局标量）")
            minGust = min(minGust, value)
            maxGust = max(maxGust, value)
        }
        XCTAssertGreaterThanOrEqual(minGust, 0.5 - 1e-6)
        XCTAssertLessThanOrEqual(maxGust, 1.0 + 1e-6)
        XCTAssertLessThan(minGust, 0.55, "阵风必须真的小下去过")
        XCTAssertGreaterThan(maxGust, 0.95, "阵风必须真的大起来过")
    }

    /// 高处振幅大（树冠比草叶晃得狠），但地面振幅有界。
    ///
    /// 反证：把 `heightFactor` 改成恒 1 → 高低处幅度相等 → 红。
    func testWindGrowsWithHeight() {
        let phase = 0.7
        func peak(_ height: CGFloat) -> Double {
            var peak = 0.0
            for step in 0..<600 {
                peak = max(peak, abs(WindField.offset(
                    x: CGFloat(step) * 3.1, phase: phase, height: height)))
            }
            return peak
        }
        let ground = peak(0)
        let treetop = peak(ForestSceneGeometry.horizonSpan + 150)
        XCTAssertLessThanOrEqual(ground, WindField.baseAmplitude + 1e-6, "地面振幅不超过基准")
        XCTAssertGreaterThan(treetop, ground * 1.5, "高处幅度必须明显大于地面")
    }

    // MARK: - fBm 噪声

    /// 三种噪声都守在 [0,1] 且确定（同输入同输出 —— 重绘不许换轮廓）。
    ///
    /// 反证：把 `lattice` 的返回值改成未归一化的原始哈希 → 越界 → 红。
    func testNoiseStaysInUnitRangeAndIsDeterministic() {
        for step in 0..<400 {
            let x = Double(step) * 0.37
            for value in [
                ForestNoise.value(x, 3.1),
                ForestNoise.fbm(x, 2.2),
                ForestNoise.ridge(x),
            ] {
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
            XCTAssertEqual(ForestNoise.value(x, 3.1), ForestNoise.value(x, 3.1))
            XCTAssertEqual(ForestNoise.fbm(x, 2.2), ForestNoise.fbm(x, 2.2))
            XCTAssertEqual(ForestNoise.ridge(x), ForestNoise.ridge(x))
        }
    }

    /// 噪声真的在读种子与坐标（不是返回常量）。
    ///
    /// 反证：把 `lattice` 里的种子混合删掉 → 种子不敏感 → 红。
    func testNoiseRespondsToSeedAndPosition() {
        XCTAssertNotEqual(ForestNoise.value(3.3, 4.4, seed: 1), ForestNoise.value(3.3, 4.4, seed: 2))
        XCTAssertNotEqual(ForestNoise.value(3.3, 4.4), ForestNoise.value(3.31, 4.4))
        XCTAssertNotEqual(ForestNoise.ridge(3.3, seed: 7), ForestNoise.ridge(3.3, seed: 9))
    }

    /// 噪声连续：邻近输入 → 邻近输出（有机边缘不许有折角）。
    func testNoiseIsContinuous() {
        func maxStep(_ sample: (Double) -> Double) -> Double {
            var previous = sample(0)
            var peak = 0.0
            for step in 1...4000 {
                let current = sample(Double(step) * 0.001)
                peak = max(peak, abs(current - previous))
                previous = current
            }
            return peak
        }
        XCTAssertLessThan(maxStep { ForestNoise.value($0, 1.7) }, 0.01)
        XCTAssertLessThan(maxStep { ForestNoise.fbm($0, 1.7) }, 0.01)
        XCTAssertLessThan(maxStep { ForestNoise.ridge($0) }, 0.02)
    }

    /// 山脊噪声有锋利的 crest：长距离上既冲得上高、也沉得下低。
    ///
    /// 反证：把脊化变换 `1 − |2v−1|` 删掉（退回普通 fbm）→ 峰值塌掉 → 红。
    func testRidgeNoiseHasCrests() {
        var peak = 0.0
        var trough = 1.0
        for step in 0..<450 {
            let value = ForestNoise.ridge(Double(step) * 0.11)
            peak = max(peak, value)
            trough = min(trough, value)
        }
        XCTAssertGreaterThan(peak, 0.8, "山脊线要冲得上高峰，实测 \(peak)")
        XCTAssertLessThan(trough, 0.35, "山脊线要沉得下低谷，实测 \(trough)")
    }

    // MARK: - 度量

    /// sRGB 空间的两色距离（大气透视断言用）。
    private func distance(_ color: Color, to other: Color) -> Double {
        guard let a = NSColor(color).usingColorSpace(.sRGB),
              let b = NSColor(other).usingColorSpace(.sRGB) else { return 0 }
        let dr = Double(a.redComponent) - Double(b.redComponent)
        let dg = Double(a.greenComponent) - Double(b.greenComponent)
        let db = Double(a.blueComponent) - Double(b.blueComponent)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    // MARK: - 明暗档（ForestTone.deepen）

    /// 压暗必须真的更暗、且朝着墨的方向走（不是乱混）。
    func testDeepenMovesTowardTheInk() {
        let theme = ForestTheme(palette: .day)
        let base = theme.foliage
        let deepened = ForestTone.deepen(base, amount: 0.5, ink: theme.shadow)
        XCTAssertLessThan(distance(deepened, to: theme.shadow),
                          distance(base, to: theme.shadow),
                          "压暗后必须离墨更近")
        let channel = { (color: Color) -> Double in
            NSColor(color).usingColorSpace(.sRGB).map { Double($0.redComponent) } ?? 0
        }
        XCTAssertLessThan(channel(deepened), channel(base), "压暗后红通道必须下降")
    }

    /// amount = 0 与上限都要守住：0 不动，超过 1 夹住（不会翻过去）。
    func testDeepenClampsTheAmount() {
        let theme = ForestTheme(palette: .day)
        XCTAssertEqual(ForestTone.deepen(theme.foliage, amount: 0, ink: theme.shadow),
                       theme.foliage)
        let clamped = ForestTone.deepen(theme.foliage, amount: 4, ink: theme.shadow)
        let full = ForestTone.deepen(theme.foliage, amount: 1, ink: theme.shadow)
        XCTAssertEqual(clamped, full, "amount 超过 1 必须夹住（不许翻过去）")
    }

    /// 夜档的墨是近黑：同一 amount 下夜档压得更暗（墨自身浓度乘了进来）。
    func testDeepenRespectsTheInkOpacity() {
        let day = ForestTheme(palette: .day)
        let night = ForestTheme(palette: .night)
        let dayInk = ForestTone.deepen(day.foliage, amount: 1, ink: day.shadow)
        let nightInk = ForestTone.deepen(night.foliage, amount: 1, ink: night.shadow)
        let luminance = { (color: Color) -> Double in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return 1 }
            return 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent)
                + 0.0722 * Double(c.blueComponent)
        }
        XCTAssertLessThan(luminance(nightInk), luminance(dayInk),
                          "夜档墨更浓（shadow 不透明度更高），压出来必须更暗")
    }
}
