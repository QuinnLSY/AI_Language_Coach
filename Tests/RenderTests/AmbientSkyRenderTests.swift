import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 批次六 · E：氛围演出隐藏档（连点天空 5 次触发）的离屏渲染回归。
///
/// 判据走**墨迹差**，不比色值（离屏过色彩空间换算，见技能 macos-ui-verify）：
/// - 演出在 vs 演出隐藏，画面必须真的不同（云 / 萤火虫收起来了）；
/// - 同一档位渲染两遍必须逐像素一致（氛围档不许引入抖动）。
@MainActor
final class AmbientSkyRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let canvas = CGSize(width: 420, height: 360)

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

    private func sky(_ theme: ForestTheme, still: Bool) throws -> Render {
        try makeHost(
            ForestSky(theme: theme, showsCelestial: false, ambientStill: still)
                .environment(\.appMotion, AppMotionDescriptor(reduceMotion: true, reduceTransparency: true))
                .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
    }

    /// 两帧不同像素的个数（换算回点）。
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

    /// 白天：演出档有云、静态档没有 —— 画面必须有可见差异。
    ///
    /// 反证：把 ForestSky 里 `if !ambientStill { Clouds() }` 的条件删掉（云常驻）→ 红。
    func testDaySkyDiffersBetweenPerformanceAndStill() throws {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false,
                                                hour: 12, month: 6, followsClock: false)
        let lively = try sky(theme, still: false)
        let still = try sky(theme, still: true)
        XCTAssertGreaterThan(differencePoints(lively, still), 40,
                             "白天收起云之后画面应当肉眼可见地不同")
    }

    /// 夜里：演出档有萤火虫、星星在眨眼 —— 静态档同样必须有可见差异。
    func testNightSkyDiffersBetweenPerformanceAndStill() throws {
        let theme = ForestThemeResolver.resolve(mode: .night, systemIsDark: false,
                                                hour: 22, month: 6, followsClock: false)
        XCTAssertTrue(theme.isNight, "取的时刻必须是夜")
        let lively = try sky(theme, still: false)
        let still = try sky(theme, still: true)
        XCTAssertGreaterThan(differencePoints(lively, still), 40,
                             "夜里收起萤火虫之后画面应当肉眼可见地不同")
    }

    /// 同一档位两帧必须零差异：氛围档不许引入随机（差出来的每一点墨都是 bug）。
    func testStillSkyRendersDeterministically() throws {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false,
                                                hour: 12, month: 6, followsClock: false)
        let first = try sky(theme, still: true)
        let second = try sky(theme, still: true)
        XCTAssertEqual(differencePoints(first, second), 0, "静态档渲染不许有任何抖动")
    }
}
