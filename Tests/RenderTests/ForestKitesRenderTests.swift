import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 春天风筝的离屏渲染回归（#620）。
///
/// 判据走**区域墨迹差**，不比色值（离屏过色彩空间换算）：
/// - 风筝必须**画在上三分之一**（上带有差异、下带零差异）——飘到中间就是挡住树的贴纸；
/// - 静态档两遍零差异（布局与姿态是纯函数，不许抖）；
/// - `reduceMotion` 下**冻结但还在**（关动效不许做成关内容）；
/// - 夜里也画得出来。
@MainActor
final class ForestKitesRenderTests: XCTestCase {

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

    /// 同一块白底上，画风筝 / 不画风筝。
    private func scene(kites: Bool, theme: ForestTheme, reduceMotion: Bool = false) throws -> Render {
        try makeHost(
            ZStack {
                Color.white
                if kites { ForestKites(theme: theme, still: true) }
            }
            .environment(\.appMotion, AppMotionDescriptor(reduceMotion: reduceMotion,
                                                          reduceTransparency: true))
            .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
    }

    /// 两帧在给定区域内的不同像素个数（换算回点；nil = 整帧）。
    private func differencePoints(_ lhs: Render, _ rhs: Render, in rect: CGRect? = nil) -> Int {
        guard let a = lhs.rep.bitmapData, let b = rhs.rep.bitmapData else { return 0 }
        let width = lhs.rep.pixelsWide, height = lhs.rep.pixelsHigh
        let scale = lhs.scale
        let pixelRange: (x: Range<Int>, y: Range<Int>)
        if let rect {
            pixelRange = (
                x: Int(rect.minX * scale)..<min(Int(rect.maxX * scale), width),
                y: Int(rect.minY * scale)..<min(Int(rect.maxY * scale), height)
            )
        } else {
            pixelRange = (x: 0..<width, y: 0..<height)
        }
        var count = 0
        for y in pixelRange.y {
            for x in pixelRange.x {
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

    private func theme(isNight: Bool = false) -> ForestTheme {
        ForestThemeResolver.resolve(
            mode: isNight ? .night : .day, systemIsDark: false,
            hour: isNight ? 22 : 12, month: 3,
            followsClock: true, followsSeason: true
        )
    }

    // MARK: - 位置上三分之一

    /// 风筝画在上三分之一：上带有墨迹、下带零差异。
    ///
    /// 反证：把 `KiteLayout.make` 里 `altitude` 的 clamp 上界改成 0.8 → 红在下带那条。
    func testKitesDrawnInUpperThirdOnly() throws {
        let withKites = try scene(kites: true, theme: theme())
        let without = try scene(kites: false, theme: theme())
        let upper = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height / 3)
        let lower = CGRect(x: 0, y: canvas.height * 2 / 3,
                           width: canvas.width, height: canvas.height / 3)
        XCTAssertGreaterThan(differencePoints(withKites, without, in: upper), 60,
                             "上三分之一没有风筝（没画上去或画太小）")
        XCTAssertEqual(differencePoints(withKites, without, in: lower), 0,
                       "风筝飘到下三分之一去了（那里是树与草地）")
    }

    // MARK: - 确定性

    /// 静态档渲染两遍零差异（布局与姿态是纯函数）。
    func testStillFrameIsDeterministic() throws {
        let first = try scene(kites: true, theme: theme())
        let second = try scene(kites: true, theme: theme())
        XCTAssertEqual(differencePoints(first, second), 0, "静态档不许有任何抖动")
    }

    // MARK: - 减弱动效

    /// `reduceMotion`：风筝**还在**（不许做成关内容），且两遍一致（冻结）。
    ///
    /// 反证：把 body 里的 `frozen` 判据拿掉、改成「reduceMotion 直接不画」→ 红在第一条。
    func testReduceMotionKeepsKitesFrozen() throws {
        let frozen = try scene(kites: true, theme: theme(), reduceMotion: true)
        let again = try scene(kites: true, theme: theme(), reduceMotion: true)
        let blank = try scene(kites: false, theme: theme(), reduceMotion: true)
        XCTAssertGreaterThan(differencePoints(frozen, blank), 60,
                             "关掉动效后风筝不该消失（关动效 ≠ 关内容）")
        XCTAssertEqual(differencePoints(frozen, again), 0, "减弱动效下风筝必须冻结")
    }

    // MARK: - 夜档

    /// 夜里也看得见（夜里压暗一档，但不许暗到没了）。
    func testNightKitesAreStillVisible() throws {
        let withKites = try scene(kites: true, theme: theme(isNight: true))
        let without = try scene(kites: false, theme: theme(isNight: true))
        XCTAssertGreaterThan(differencePoints(withKites, without), 60, "夜里的风筝看不见")
    }
}
