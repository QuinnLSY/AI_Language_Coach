import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 春天草地上的蝴蝶与蒲公英（#621）的离屏渲染回归。
///
/// 判据走**区域墨迹差**，不比色值：
/// - 画得出来（有虫有花，不是空草地）；
/// - **全在草坡之上**：坡面以下的区域零差异（蝴蝶不许扎进地里、茎从坡面往上长）；
/// - 静态档两遍零差异；`reduceMotion` 下冻结但仍在。
@MainActor
final class ForestSpringExtrasRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    /// 地面带的现实尺寸（与 `ForestGroundBand` 同高）。
    private let canvas = CGSize(width: 420, height: 150)
    /// 草坡表面（本测试里是一条平地，方便按区域切上下）。
    private let groundY: CGFloat = 120

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

    /// `still: true` 才是**真静态档**（两个组件各自按 `frozenElapsed` 冻结）。
    ///
    /// ⚠️ 2026-10-21 修：这个夹具以前没传 `still`（默认 false），于是
    /// `TimelineView` 照走 —— 两个 host 的 `origin` 各不相同，捕获时落在同一个
    /// 20Hz 帧就零差异、落进相邻帧就抖出几百点。也就是说「静态档不许抖」这条
    /// **一直是偶发假绿**，全量跑时才露出来。
    private func scene(extras: Bool, still: Bool = false,
                       reduceMotion: Bool = false) throws -> Render {
        let theme = ForestThemeResolver.resolve(
            mode: .day, systemIsDark: false, hour: 12, month: 3,
            followsClock: true, followsSeason: true
        )
        let groundY = self.groundY
        return try makeHost(
            ZStack {
                Color.white
                if extras {
                    ForestDandelions(theme: theme, groundLine: { _ in groundY }, still: still)
                    ForestButterflies(theme: theme, groundLine: { _ in groundY }, still: still)
                }
            }
            .environment(\.appMotion, AppMotionDescriptor(reduceMotion: reduceMotion,
                                                          reduceTransparency: true))
            .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
    }

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

    /// 春天真的画出了东西（有蝴蝶、有蒲公英）。
    ///
    /// 反证：把组件换成 `EmptyView`（或把 `stems` / `springMeadow` 清空）→ 红。
    func testSpringExtrasAreDrawn() throws {
        let withExtras = try scene(extras: true)
        let without = try scene(extras: false)
        XCTAssertGreaterThan(differencePoints(withExtras, without), 40,
                             "春天草地上没有蝴蝶也没有蒲公英")
    }

    /// 全在草坡**之上**：坡面以下零差异。
    ///
    /// 反证：把 `ButterflyLayout.position` 的 `- butterfly.altitude` 删掉 → 红。
    func testNothingDipsBelowTheSlope() throws {
        let withExtras = try scene(extras: true)
        let without = try scene(extras: false)
        // ⚠️ 起点只留 2pt 余量（茎脚的 round cap 会压到坡面上一点点）。
        // 反证实测：留 6pt 余量时「蝴蝶扎地」也抓不到（假闸）——余量必须小于
        // 「一只蝴蝶掉到坡面以下能画出的高度」（半个画框 ≈ 8pt）。
        let below = CGRect(x: 0, y: groundY + 2,
                           width: canvas.width, height: canvas.height - groundY - 2)
        XCTAssertEqual(differencePoints(withExtras, without, in: below), 0,
                       "有东西画到草坡下面去了（蝴蝶扎地 / 茎长反了）")
    }

    /// 静态档两遍零差异（布局与姿态是纯函数）。
    ///
    /// 反证：把 `still` 丢掉（退回真实时钟）→ 两个 host 的 `origin` 不同 → 多数帧上红
    /// （落进同一帧时碰巧绿 —— 旧版就是这样骗过去的）。
    func testStillFrameIsDeterministic() throws {
        let first = try scene(extras: true, still: true)
        let second = try scene(extras: true, still: true)
        XCTAssertEqual(differencePoints(first, second), 0, "静态档不许抖")
    }

    /// `reduceMotion`：还在，但冻结（关动效 ≠ 关内容）。
    ///
    /// 反证：reduceMotion 时整层不画 → 红在第一条。
    func testReduceMotionKeepsExtrasFrozen() throws {
        let frozen = try scene(extras: true, reduceMotion: true)
        let again = try scene(extras: true, reduceMotion: true)
        let blank = try scene(extras: false, reduceMotion: true)
        XCTAssertGreaterThan(differencePoints(frozen, blank), 40,
                             "关掉动效后蝴蝶与蒲公英不该消失")
        XCTAssertEqual(differencePoints(frozen, again), 0, "减弱动效下必须冻结")
    }
}
