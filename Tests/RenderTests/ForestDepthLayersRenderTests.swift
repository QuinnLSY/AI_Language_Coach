import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 森林纵深补层（远景树线 / 中景植被）的离屏渲染回归。
///
/// 判据走**墨迹差**，不比色值（离屏过色彩空间换算，见技能 macos-ui-verify）：
/// - 两层都必须真的画出东西（撤掉 `Canvas` 里的绘制循环 → 红）；
/// - 树线只许长在脊线以上（下半截留给山体，越界就说明它成了「浮在空中的树」）；
/// - 同一份配置渲染两遍逐像素一致（两层都是静态的，不许偷偷抖）。
@MainActor
final class ForestDepthLayersRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let canvas = CGSize(width: 420, height: 150)

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

    private func differencePoints(_ lhs: Render, _ rhs: Render, in rect: CGRect? = nil) -> Int {
        guard let a = lhs.rep.bitmapData, let b = rhs.rep.bitmapData else { return 0 }
        let width = lhs.rep.pixelsWide
        let height = lhs.rep.pixelsHigh
        let scale = lhs.scale
        let columns: Range<Int>
        let rows: Range<Int>
        if let rect {
            columns = Int(rect.minX * scale)..<min(Int(rect.maxX * scale), width)
            rows = Int(rect.minY * scale)..<min(Int(rect.maxY * scale), height)
        } else {
            columns = 0..<width
            rows = 0..<height
        }
        var count = 0
        for y in rows {
            for x in columns {
                let o = (y * width + x) * 4
                if abs(Int(a[o]) - Int(b[o])) > 8
                    || abs(Int(a[o + 1]) - Int(b[o + 1])) > 8
                    || abs(Int(a[o + 2]) - Int(b[o + 2])) > 8 {
                    count += 1
                }
            }
        }
        return Int(Double(count) / (scale * scale))
    }

    private func blank() throws -> Render {
        try makeHost(Color(white: 0.97).frame(width: canvas.width, height: canvas.height), size: canvas)
    }

    private func treeLine(_ palette: ForestPalette = .day) throws -> Render {
        try makeHost(
            ZStack {
                Color(white: 0.97)
                ForestTreeLine(theme: ForestTheme(palette: palette))
            }
            .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
    }

    private func midVegetation(_ palette: ForestPalette = .day) throws -> Render {
        try makeHost(
            ZStack {
                Color(white: 0.97)
                ForestMidVegetation(theme: ForestTheme(palette: palette))
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
    }

    // MARK: - 判据

    /// 远景树线真的画出来了。
    ///
    /// 反证：把 `Canvas` 里的 `for tree in Self.trees` 循环注释掉 → 红。
    func testTreeLineIsDrawn() throws {
        let drawn = try treeLine()
        let bare = try blank()
        XCTAssertGreaterThan(differencePoints(drawn, bare), 300, "远山脊线上没有林带")
    }

    /// 树线只长在脊线以上：画布最底下那一小条必须一个墨点都没有。
    ///
    /// ⚠️ 不能取「下半部分」当判据 —— 远山的脊线是二次曲线，两端本来就落到画布底部
    /// （t=0.14 与 t=0.86 处的树底约在 73% 高度），所以判据只能盯**最底下那条缝**。
    /// 反证：把 `ForestTreeLine` 里 `baseY` 的 `ridgeY` 换成 `size.height` → 红。
    func testTreeLineStaysAboveTheRidge() throws {
        let drawn = try treeLine()
        let bare = try blank()
        let below = CGRect(x: 0, y: canvas.height * 0.92,
                           width: canvas.width, height: canvas.height * 0.08)
        XCTAssertEqual(differencePoints(drawn, bare, in: below), 0, "树干扎到山脚以下去了")
    }

    /// 中景植被真的画出来了。
    ///
    /// 反证：把 `Canvas` 里的 `for shrub in Self.shrubs` 循环注释掉 → 红。
    func testMidVegetationIsDrawn() throws {
        let drawn = try midVegetation()
        let bare = try blank()
        XCTAssertGreaterThan(differencePoints(drawn, bare), 300, "树与草坡之间还是空的")
    }

    /// 中景植被站在坡上：底部那条带（坡面线以下）不该有墨。
    ///
    /// 反证：把 `hillSurfaceY` 换成 `size.height`（贴底）→ 红。
    func testMidVegetationStandsOnTheSlope() throws {
        let drawn = try midVegetation()
        let bare = try blank()
        let floor = CGRect(x: 0, y: canvas.height * 0.86,
                           width: canvas.width, height: canvas.height * 0.14)
        XCTAssertEqual(differencePoints(drawn, bare, in: floor), 0, "灌木贴到底边了（没站在坡上）")
    }

    /// 两层都是静态的：同一配置渲染两遍必须逐像素一致。
    func testBothLayersAreDeterministic() throws {
        XCTAssertEqual(differencePoints(try treeLine(), try treeLine()), 0, "树线不许抖")
        XCTAssertEqual(differencePoints(try midVegetation(), try midVegetation()), 0, "中景植被不许抖")
    }

    /// 夜间档也要画得出（夜景里林带不能整个消失）。
    func testLayersSurviveTheNightPalette() throws {
        let drawn = try treeLine(.night)
        let bare = try blank()
        XCTAssertGreaterThan(differencePoints(drawn, bare), 200, "夜景里树线不见了")
    }

    // MARK: - 出图（人眼复核）

    func testDumpsLayersForHumanReview() throws {
        try dump(try treeLine().rep, name: "tree-line-20261101.png")
        try dump(try midVegetation().rep, name: "mid-vegetation-20261101.png")
        // 树线单独看没有意义 —— 它必须和远山叠在一起才读得出「山上有林」。
        let size = CGSize(width: 420, height: 300)
        let sky = try makeHost(
            ForestSky(theme: ForestTheme(palette: .day), showsCelestial: false, ambientStill: true)
                .environment(\.appMotion, AppMotionDescriptor(reduceMotion: true, reduceTransparency: true))
                .frame(width: size.width, height: size.height),
            size: size
        )
        try dump(sky.rep, name: "sky-with-tree-line-20261101.png")
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
}
