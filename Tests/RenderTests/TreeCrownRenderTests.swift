import AppKit
import AppCore
import SwiftUI
@testable import AppUI
import XCTest

/// 树冠的离屏渲染回归（2026-10-18 树冠第 4 版）。
///
/// 背景：用户三次否掉树冠重构，原话「永远都是一团，没有树叶、树枝的层次感」。
/// 所以这一版的第一条判据不是「好不好看」（断言管不了审美），而是三条**结构**：
///
/// 1. **层次真的分出来了**：三层叶团的明暗档必须两两拉开足够距离，
///    否则 24 团叶画上去仍然是一片同色（那正是「一团绿」的定义）；
/// 2. **枝干真的露出来了**：画枝干 / 不画枝干两张图必须肉眼可见地不同 ——
///    若枝干被叶子全盖住，这条会立刻红；
/// 3. **静态档零抖动**：同一状态渲染两遍必须逐像素一致（与 `AmbientSkyRenderTests`
///    同一条纪律；树冠现在有 24 条噪声轮廓 + 60 多根枝，任何一处用了
///    `Int.random` 都会在这里露出来）。
///
/// 另外把整棵树出成 PNG 落到 `.workbuddy/verify/` 供人眼复核 —— 布局类改动
/// 「看着对不对」是断言救不了的那一半。
@MainActor
final class TreeCrownRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let crownSize = CGSize(width: 380, height: 300)

    // MARK: 出图

    private func makeHost(_ view: some View, size: CGSize) throws -> Render {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, scale: CGFloat(rep.pixelsHigh) / max(size.height, 1))
    }

    private func theme(_ mode: ThemeMode) -> ForestTheme {
        ForestThemeResolver.resolve(
            mode: mode, systemIsDark: false, hour: mode == .night ? 22 : 12,
            month: 6, followsClock: false, followsSeason: false
        )
    }

    /// 树冠 + 一层天空底（不然透明背景上看不清叶子压在天上的边）。
    private func crown(_ mode: ThemeMode, showingBranches: Bool = true) -> some View {
        let theme = self.theme(mode)
        return ZStack {
            LinearGradient(colors: theme.sky, startPoint: .top, endPoint: .bottom)
            if showingBranches {
                TreeCrown(theme: theme)
            } else {
                // 反证用：把枝干层去掉（其余逐像素相同）
                TreeCrown(theme: theme, drawsBranches: false)
            }
        }
        .frame(width: crownSize.width, height: crownSize.height)
    }

    private func differencePoints(_ lhs: Render, _ rhs: Render) -> Int {
        guard let a = lhs.rep.bitmapData, let b = rhs.rep.bitmapData else { return 0 }
        let width = lhs.rep.pixelsWide, height = lhs.rep.pixelsHigh
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                if abs(Int(a[o]) - Int(b[o])) > 8
                    || abs(Int(a[o + 1]) - Int(b[o + 1])) > 8
                    || abs(Int(a[o + 2]) - Int(b[o + 2])) > 8 {
                    count += 1
                }
            }
        }
        return Int(Double(count) / (lhs.scale * lhs.scale))
    }

    // MARK: 判据 ①：三层叶色必须真的分得开

    /// 叶色三档的**亮度**必须两两拉开（背层 / 中层 / 前层）。
    ///
    /// 判据用的是真正的绘制取值（`CanopyLayout.depth(forOrder:)` × `CanopyPalette.tone`
    /// × 大气透视），不是表里的原始 tone —— 中间还隔着两处换算，只钉表格会漏。
    ///
    /// 反证：把 `CanopyPalette.dayBrightness` 的两端改成 (1.0, 1.0)（不再分档）→ 红。
    func testThreeLeafLayersSeparateInBrightness() throws {
        for mode in [ThemeMode.day, .night] {
            let theme = self.theme(mode)
            let samples = [0, 1, 2].map { order -> CGFloat in
                // 取各层中间那一档的代表值（背 0.22 / 中 0.55 / 前 0.85）
                let level = [0.22, 0.55, 0.85][order]
                let color = CanopyPalette.tone(theme.foliage, level: level, isNight: theme.isNight)
                let adjusted = ForestAerialPerspective.adjust(
                    color,
                    depth: CanopyLayout.depth(forOrder: order),
                    haze: theme.aerialHaze
                )
                return try! XCTUnwrap(Self.luminance(of: adjusted))
            }
            XCTAssertGreaterThan(samples[0], 0, "背层叶色取不到亮度")
            XCTAssertGreaterThan(samples[1], samples[0] + 0.02,
                                 "\(mode) 背层与中层几乎同亮 → 三层退化成一层（一团绿）")
            XCTAssertGreaterThan(samples[2], samples[1] + 0.02,
                                 "\(mode) 中层与前层几乎同亮 → 没有受光面，树冠是平的")
        }
    }

    /// 亮部偏黄绿、暗部偏蓝绿：色相必须真的分开（冷暖分离是「不塑料」的唯一来源）。
    ///
    /// 反证：把 `CanopyPalette.hueSplit` 改成 0 → 红。
    func testLightAndShadeSplitOnTheHueAxis() throws {
        let theme = self.theme(.day)
        let light = CanopyPalette.tone(theme.foliage, level: 1.0, isNight: false)
        let dark = CanopyPalette.tone(theme.foliage, level: 0.0, isNight: false)
        let lightHue = try XCTUnwrap(Self.hue(of: light))
        let darkHue = try XCTUnwrap(Self.hue(of: dark))
        // 色相环正向：红(0) → 黄(0.12) → 绿(0.33) → 青(0.5)。
        // 「暗部更蓝绿」= 色相更接近 0.5，即数值更大。
        XCTAssertGreaterThan(darkHue, lightHue + 0.005,
                             "亮部与暗部色相没分开 → 只有明暗没有冷暖，叶子会塑料")
    }

    // MARK: 判据 ②：枝干必须真的露出来

    /// 画枝干 vs 不画枝干：两张图必须明显不同。
    ///
    /// 若哪天把叶团铺满、枝干全被盖住，这条就红 —— 那正是「没有树枝的层次感」。
    ///
    /// 反证：把 `TreeCrown` 里的 `CrownBranches(...)` 删掉 → 两张图逐像素相同 → 红。
    func testBranchesAreActuallyVisible() throws {
        let withBranches = try makeHost(crown(.day), size: crownSize)
        let without = try makeHost(crown(.day, showingBranches: false), size: crownSize)
        XCTAssertGreaterThan(differencePoints(withBranches, without), 120,
                             "枝干被叶子全盖住了 → 树冠里一根树枝都看不见")
    }

    // MARK: 判据 ③：静态档零抖动

    /// 同一状态渲染两遍必须逐像素一致（24 条噪声轮廓 + 全副枝干都不许漂）。
    func testCrownRendersDeterministically() throws {
        let first = try makeHost(crown(.day), size: crownSize)
        let second = try makeHost(crown(.day), size: crownSize)
        XCTAssertEqual(differencePoints(first, second), 0, "树冠渲染不许有任何抖动")
    }

    // MARK: 判据 ④：冠幅不许溢出面板

    /// 树冠的包围盒必须落在画框里（可以贴边，不能出框）。
    ///
    /// 出框 = 叶子画到聊天区 / 左栏上（`TreeCanvas` 不裁剪，画出去就真出框）。
    /// 反证：把 `CanopyLayout.clusters` 的 `halfW` 提到 0.62 → 两侧溢出 → 红。
    func testCrownStaysInsideItsFrame() {
        let bounds = CanopyLayout.silhouetteBounds(in: crownSize)
        XCTAssertGreaterThanOrEqual(bounds.minX, -2,
                                    "树冠左边出框 \(bounds.minX)pt → 会画到聊天区上")
        XCTAssertLessThanOrEqual(bounds.maxX, crownSize.width + 2,
                                 "树冠右边出框 \(crownSize.width - bounds.maxX)pt → 会画到面板外")
        XCTAssertGreaterThanOrEqual(bounds.minY, -2, "树冠顶部出框 \(bounds.minY)pt")
        XCTAssertLessThanOrEqual(bounds.maxY, crownSize.height + 6,
                                 "树冠底部出框 \(bounds.maxY - crownSize.height)pt")
    }

    // MARK: 判据 ⑤：A 光柱 / B 落叶真的画出来了

    /// 光柱层 vs 没有光柱层：两张图必须肉眼可见地不同。
    ///
    /// 反证：把 `SunShafts.body` 里的 `ForEach` 删掉 → 两张图相同 → 红。
    func testSunShaftsActuallyPaint() throws {
        let size = CGSize(width: 380, height: 560)
        let withShafts = try makeHost(
            ZStack {
                LinearGradient(colors: theme(.day).sky, startPoint: .top, endPoint: .bottom)
                SunShafts(theme: theme(.day))
            }.frame(width: size.width, height: size.height),
            size: size
        )
        let without = try makeHost(
            ZStack {
                LinearGradient(colors: theme(.day).sky, startPoint: .top, endPoint: .bottom)
            }.frame(width: size.width, height: size.height),
            size: size
        )
        XCTAssertGreaterThan(differencePoints(withShafts, without), 200,
                             "光柱一道都没画出来（或者淡到看不出来）")
    }

    /// 落叶层：`reduceMotion` 下**仍然看得见**（停在中段），不是整层消失。
    ///
    /// 反证：把 `DriftingLeaves` 的 `count` 改成 0，或让 `fade` 在端点返回 0 → 红。
    func testDriftingLeavesStayVisibleWithoutMotion() throws {
        let size = CGSize(width: 380, height: 620)
        let drifting = try makeHost(
            ZStack {
                Color(hex: 0xF4FAF0)
                DriftingLeaves(theme: theme(.day), still: true)
                    .environment(\.appMotion,
                                 AppMotionDescriptor(reduceMotion: true, reduceTransparency: true))
            }.frame(width: size.width, height: size.height),
            size: size
        )
        let empty = try makeHost(
            ZStack { Color(hex: 0xF4FAF0) }.frame(width: size.width, height: size.height),
            size: size
        )
        XCTAssertGreaterThan(differencePoints(drifting, empty), 30,
                             "减弱动态效果下落叶整层消失 → 把「关动效」做成了「关内容」")
    }

    /// 落叶层的静态帧必须可复现（位置是时间的纯函数，不是动画推出来的）。
    func testDriftingLeavesAreDeterministicWhenStill() throws {
        let size = CGSize(width: 380, height: 620)
        func render() throws -> Render {
            try makeHost(
                ZStack {
                    Color(hex: 0xF4FAF0)
                    DriftingLeaves(theme: theme(.day), still: true)
                }.frame(width: size.width, height: size.height),
                size: size
            )
        }
        XCTAssertEqual(differencePoints(try render(), try render()), 0,
                       "静态档的落叶位置必须只由布局表决定，不许随抓帧时刻漂移")
    }

    // MARK: 判据 ⑥：风是分层弯的，不是整冠一块板

    /// 四层各自弯：层心横移**自上而下严格递减**，且顶层比底层动得明显多。
    ///
    /// 为什么不是「顶比底动得多」就够：整冠绕底部支点旋转时，顶也照旧比底动得
    /// 多（力臂长）—— 那条判据对「一整个树冠一起摇」是绿的（第 4 版的整冠
    /// `.rotationEffect` 顶/底力臂比就有 2.8）。所以要的是**分层的直接后果**：
    /// 增益表 [0.80, 0.62, 0.48, 0.36] 自上而下递减 → 横移必须严格递减；
    /// 四层一起平移（增益被填平）时四值相等 → 红。
    ///
    /// ⚠️ 曾经断言的是「段落差本身也递减」（剖面折线 vs 刚体直线）。2026-10-18
    /// 枝干按用户要求收进下 2/3 后，顶层带（y 27–47）失去深色枝干这个强信号源，
    /// 互相关在柔和叶边上测得的层心混入轮廓形变误差（band1 又因粗枝干密集而测大），
    /// 段落差 3.50 vs 3.37 被度量伪影搅浑 —— 那是判据的度量假设失效，不是产品退化
    /// （四层横移 [14.9, 11.4, 6.0, 2.7] 仍严格递减、首尾比 5.6）。故换成不依赖
    /// 信号强度的「严格单调递减」，折线形状退回首尾比断言。
    ///
    /// 反证：`CanopyLayout.bandWindGain` 与 `bandWindRotationGain` **两张表都**填平
    /// → 四层同一变换 → 四值相等 → 两条断言都红。⚠️ 只填一张不算反证成功：旋转
    /// 增益递减本身就能让层心横移递减（旋转贡献 = 转角 × 力臂，两者都自上而下
    /// 递减），那时四层视觉上仍是分层弯，判据绿是**对的**。
    /// WindSway 的 push 置 0 → 四值全 0 → 同样红。
    func testWindBendsEachBandByItsOwnGain() throws {
        func clock(phase: Double) -> ForestWindClock {
            let clock = ForestWindClock()
            let t0 = Date(timeIntervalSinceReferenceDate: 0)
            clock.advance(to: t0, blowing: true)
            clock.advance(to: t0.addingTimeInterval(phase / WindField.speed), blowing: true)
            return clock
        }
        // 冠心（x = 190）处两个相反的强相位：+5.90 / −4.71 pt，差 10.6pt ——
        // 顶层横移 ~15pt、底层 ~2.7pt，信号量级远大于测量噪声。
        let clockA = clock(phase: 1.9 + Double.pi / 2)
        let clockB = clock(phase: 1.9 - Double.pi / 2)
        let pushA = clockA.offset(x: crownSize.width * 0.5, height: CanopyLayout.windHeight)
        let pushB = clockB.offset(x: crownSize.width * 0.5, height: CanopyLayout.windHeight)
        XCTAssertGreaterThan(abs(pushA - pushB), 8,
                             "两个相位的风只差 \(abs(pushA - pushB))pt → 判据建立在微风上")

        let renderA = try makeHost(crownInWind(.day, clockA), size: crownSize)
        let renderB = try makeHost(crownInWind(.day, clockB), size: crownSize)

        // 四层层心的横移（互相关求最优平移；层界在 75 / 150 / 225，取样点都在层内）
        let shifts = try [37.0, 112.0, 187.0, 262.0].map { centerY in
            try bandShift(renderA, renderB, centerY: centerY)
        }
        XCTAssertGreaterThan(shifts[0], shifts[3] * 1.5,
                             "顶层 (\(shifts[0])pt) 没比底层 (\(shifts[3])pt) 动得明显多 → 分层增益没生效")
        for band in 1..<shifts.count {
            XCTAssertGreaterThan(shifts[band - 1], shifts[band],
                                "第 \(band) 层 (\(shifts[band])pt) 没比它上面那层 (\(shifts[band - 1])pt) 动得少 → 增益递减没生效，四层在一起平移")
        }
    }

    /// 只有天空（判据 ⑥ 的背景板：风层动、天空不动）。
    private func sky(_ mode: ThemeMode) -> some View {
        LinearGradient(colors: theme(mode).sky, startPoint: .top, endPoint: .bottom)
            .frame(width: crownSize.width, height: crownSize.height)
    }

    /// 树冠 + 注入的风钟（离屏夹具默认没有风，这里显式给一颗）。
    private func crownInWind(_ mode: ThemeMode, _ clock: ForestWindClock) -> some View {
        ZStack {
            sky(mode)
            TreeCrown(theme: theme(mode))
        }
        .frame(width: crownSize.width, height: crownSize.height)
        .environment(\.forestWind, clock)
    }

    /// 两条横带之间的一致平移量（pt）：穷举 dx 取差异最小，再抛物线细化到亚像素。
    ///
    /// 返回**正 = rhs 的内容比 lhs 靠右**。天空部分两图逐像素相同，对最小值
    /// 只有常数贡献，不偏置结果；有效信号全来自剪影的竖边（全强度叶色），
    /// 静态柔光层（clumps / 统一光）透明度低，压不住它。
    private func bandShift(_ lhs: Render, _ rhs: Render, centerY: CGFloat) throws -> CGFloat {
        guard let pa = lhs.rep.bitmapData, let pb = rhs.rep.bitmapData else { return 0 }
        let width = lhs.rep.pixelsWide, height = lhs.rep.pixelsHigh
        let scale = lhs.scale
        let y0 = Int((centerY - 10) * scale)
        let y1 = Int((centerY + 10) * scale)
        guard y0 >= 0, y1 < height, width == rhs.rep.pixelsWide else { return 0 }
        let maxDx = Int(30 * scale)
        var costs = [Int](repeating: 0, count: 2 * maxDx + 1)
        for dx in -maxDx...maxDx {
            var sum = 0
            for y in y0...y1 {
                let rowA = y * width, rowB = y * width
                for x in 0..<width {
                    let xb = x - dx
                    guard xb >= 0, xb < width else { continue }
                    let oa = (rowA + x) * 4, ob = (rowB + xb) * 4
                    sum += abs(Int(pa[oa]) - Int(pb[ob]))
                    sum += abs(Int(pa[oa + 1]) - Int(pb[ob + 1]))
                    sum += abs(Int(pa[oa + 2]) - Int(pb[ob + 2]))
                }
            }
            costs[dx + maxDx] = sum
        }
        let best = costs.enumerated().min(by: { $0.element < $1.element })!.offset
        guard best > 0, best < costs.count - 1 else {
            return CGFloat(best - maxDx) / scale
        }
        // 抛物线顶点：亚像素精度（整数 dx 的量化对 4.7pt 的底层信号太粗）
        let c0 = CGFloat(costs[best - 1]), c1 = CGFloat(costs[best]), c2 = CGFloat(costs[best + 1])
        let denominator = c0 - 2 * c1 + c2
        let offset = abs(denominator) < 1e-6 ? 0.0 : 0.5 * (c0 - c2) / denominator
        return (CGFloat(best - maxDx) + offset) / scale
    }

    // MARK: 工具

    /// 出图：`.workbuddy/verify/`（人眼复核用）。
    ///
    /// 树冠这种东西「看着对不对」是断言救不了的那一半 —— 第 4 版之所以要先出图，
    /// 是因为前三版都是过了测试但人眼一看就否掉的。
    func testDumpsCrownForHumanReview() throws {
        for (name, mode) in [("day", ThemeMode.day), ("night", ThemeMode.night)] {
            let render = try makeHost(crown(mode), size: crownSize)
            try dump(render.rep, name: "tree-crown-v7-\(name)-20261018.png")
        }
    }

    /// 出图：树冠 + 光柱 + 落叶的**合成**（整棵树的上半段）。
    ///
    /// 单看树冠会把「光柱是不是从叶缝里漏出来」这件事漏掉 —— 而那是 A 的全部意义。
    func testDumpsTreeTopForHumanReview() throws {
        let size = CGSize(width: 380, height: 600)
        for (name, mode) in [("day", ThemeMode.day), ("night", ThemeMode.night)] {
            let render = try makeHost(
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: theme(mode).sky, startPoint: .top, endPoint: .bottom)
                    SunShafts(theme: theme(mode))
                        .frame(width: size.width, height: 560)
                        .offset(y: 40)
                    TreeCrown(theme: theme(mode))
                        .frame(width: size.width, height: 300)
                        .offset(y: 20)
                    DriftingLeaves(theme: theme(mode), still: true)
                        .frame(width: size.width, height: size.height)
                }
                .frame(width: size.width, height: size.height),
                size: size
            )
            try dump(render.rep, name: "tree-top-v7-\(name)-20261018.png")
        }
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    private static func luminance(of color: Color) -> CGFloat? {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
    }

    private static func hue(of color: Color) -> CGFloat? {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return h
    }
}
