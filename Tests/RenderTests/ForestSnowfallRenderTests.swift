import AppKit
import AIDomain
@testable import AppUI
import SwiftUI
import XCTest

/// 下雪层（2026-10-21 重写）的**离屏渲染**回归。
///
/// 逻辑正确性由 `ForestSnowfallTests` 钉住（只往下 / 只左右摆 / 节奏 / 确定性）；
/// 这里只回答一个纯函数答不出的问题：**人眼看不看得见**。
/// 用户原话：「下雪时，雪花几乎看不见，雪花应该像下雨一样清晰可见」。
///
/// 判据走墨迹差 + 「雪在浅底上也要有轮廓」，不比色值（离屏过色彩空间换算）。
/// 反证：把 `FlakeFigure` 的 `snowCore` 换成 `snowHalo`（雪花整片化进背景）→ 红；
/// 把 `ForestSnowfall` 的 `ForEach` 删掉（一层都不画）→ 红。
@MainActor
final class ForestSnowfallRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let canvas = CGSize(width: 320, height: 320)

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
        RunLoop.current.run(until: Date().addingTimeInterval(0.18))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, scale: CGFloat(rep.pixelsHigh) / max(size.height, 1))
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

    private func theme(night: Bool = false) -> ForestTheme {
        ForestTheme(palette: night ? .night : .day, season: .winter, weather: .snow)
    }

    /// 天空底 + 下雪层（`still` = 冻结在行程中段，出图与判据都确定）。
    private func snowOnSky(night: Bool = false, still: Bool = true,
                           reduceMotion: Bool = false, draws: Bool = true) throws -> Render {
        let theme = theme(night: night)
        return try makeHost(
            ZStack {
                LinearGradient(colors: theme.sky, startPoint: .top, endPoint: .bottom)
                if draws {
                    ForestSnowfall(theme: theme, density: .near, still: still)
                }
            }
            .environment(\.appMotion,
                         AppMotionDescriptor(reduceMotion: reduceMotion, reduceTransparency: true))
            .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
    }

    // MARK: - 看得见

    /// 白天的雪：在天空渐变上必须**一眼可辨**（不是几个若隐若现的白点）。
    func testDaySnowIsClearlyVisibleOnTheSky() throws {
        let bare = try snowOnSky(night: false, draws: false)
        let snowy = try snowOnSky(night: false, draws: true)
        XCTAssertGreaterThan(differencePoints(snowy, bare), 220,
                             "白天的雪花几乎看不见（墨迹差太小）")
    }

    /// 夜里的雪：压夜空，墨差更大。
    func testNightSnowIsClearlyVisibleOnTheSky() throws {
        let bare = try snowOnSky(night: true, draws: false)
        let snowy = try snowOnSky(night: true, draws: true)
        XCTAssertGreaterThan(differencePoints(snowy, bare), 220, "夜里的雪花看不见")
    }

    /// 最苛刻的底：**近白的雪地**（用户就是在这种底上抱怨看不见）。
    ///
    /// 雪必须靠「白芯 + 柔边 + 柔影」在浅底上立出轮廓 —— 这一条是本次修的核心。
    func testSnowStaysVisibleOnAPaleSnowField() throws {
        let theme = theme()
        let pale = ZStack {
            Color(hex: 0xEDF4FA)
            ForestSnowfall(theme: theme, density: .near, still: true)
        }
        .frame(width: canvas.width, height: canvas.height)
        let bare = ZStack { Color(hex: 0xEDF4FA) }
            .frame(width: canvas.width, height: canvas.height)
        XCTAssertGreaterThan(differencePoints(try makeHost(pale, size: canvas),
                                              try makeHost(bare, size: canvas)),
                             220, "雪花在近白雪地上整片化掉了（没有轮廓）")
    }

    /// 近景层比远景更「实」：同一块画布上，近景的墨迹量必须更大。
    func testNearLayerDrawsMoreInkThanFarLayer() throws {
        let theme = theme()
        let near = try makeHost(
            ZStack {
                Color(hex: 0xDDEBF5)
                ForestSnowfall(theme: theme, density: .near, still: true)
            }.frame(width: canvas.width, height: canvas.height), size: canvas)
        let far = try makeHost(
            ZStack {
                Color(hex: 0xDDEBF5)
                ForestSnowfall(theme: theme, density: .far, still: true)
            }.frame(width: canvas.width, height: canvas.height), size: canvas)
        let bare = try makeHost(
            ZStack { Color(hex: 0xDDEBF5) }
                .frame(width: canvas.width, height: canvas.height), size: canvas)
        XCTAssertGreaterThan(differencePoints(near, bare), differencePoints(far, bare) * 2,
                             "近景雪层没有比远景更显眼（景深读不出来）")
    }

    // MARK: - 确定性 / 静止

    /// 冻结档渲染两遍必须逐像素一致（位置由纯函数算，不许有帧间抖动）。
    func testFrozenFramesAreIdentical() throws {
        let first = try snowOnSky()
        let second = try snowOnSky()
        XCTAssertEqual(differencePoints(first, second), 0, "冻结档两帧不一致（有隐藏抖动）")
    }

    /// 「减弱动态效果」打开时：雪**还在**，只是不动 —— 关动效不许做成关内容。
    ///
    /// 反证：把 `ForestSnowfall` 的 `frozen` 分支改成 `return Color.clear`（静止就整层收）
    /// → 红。
    func testReduceMotionStillShowsSnow() throws {
        let bare = try snowOnSky(reduceMotion: true, draws: false)
        let frozen = try snowOnSky(still: false, reduceMotion: true, draws: true)
        XCTAssertGreaterThan(differencePoints(frozen, bare), 220,
                             "开了减弱动态效果之后雪整层消失了（关动效不该关内容）")
    }

    // MARK: - 出图（人眼复核）

    /// 出图：`.workbuddy/verify/`。「雪下得好不好看」断言管不了 —— 人眼看。
    func testDumpsSnowfallForHumanReview() throws {
        try dump(try snowOnSky(night: false).rep, name: "snowfall-day-20261021.png")
        try dump(try snowOnSky(night: true).rep, name: "snowfall-night-20261021.png")
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }
}
