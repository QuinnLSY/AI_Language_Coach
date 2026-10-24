import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 夏天草尖上的蜻蜓（#635）的离屏渲染回归。
///
/// 判据走**区域墨迹差**（底色用草绿，模拟真实的草地 —— 蓝身子压在白底上会
/// 显得比实际更跳，而它真正的难题是「压在绿草上还看不看得见」）：
/// - 白天画得出来、夜里**整层不画**（白天蜻蜓 / 夜里流萤，一天两副样子）；
/// - 静态档两遍零差异（悬停点是纯函数派生，不许抖）；
/// - `reduceMotion` 下**还在且冻结**（关动效不许做成关内容，也不许定格在半空）。
@MainActor
final class ForestDragonfliesRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let canvas = CGSize(width: 420, height: 150)
    private let groundY: CGFloat = 120
    /// 草地的本色（白天 `hillNear` 的量级）：蜻蜓的辨识度就是「压在绿草上」。
    private let meadow = Color(red: 0.25, green: 0.62, blue: 0.40)

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

    private func theme(isNight: Bool) -> ForestTheme {
        ForestThemeResolver.resolve(
            mode: isNight ? .night : .day, systemIsDark: false,
            hour: isNight ? 22 : 12, month: 6,
            followsClock: true, followsSeason: true
        )
    }

    private func scene(dragonflies: Bool, isNight: Bool = false,
                       reduceMotion: Bool = false, still: Bool = false) throws -> Render {
        let theme = self.theme(isNight: isNight)
        let groundY = self.groundY
        return try makeHost(
            ZStack {
                meadow
                if dragonflies {
                    ForestDragonflies(theme: theme, groundLine: { _ in groundY }, still: still)
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

    /// 白天：蜻蜓画得出来（压在绿草上也认得出 —— 取蓝就是为这个）。
    ///
    /// 反证：把 `ForestDragonflies` 的 body 改成恒 `EmptyView` → 红。
    func testDragonfliesShowInDaylight() throws {
        let withFlies = try scene(dragonflies: true)
        let without = try scene(dragonflies: false)
        // ⚠️ 门槛取 250 而不是「比 60 大」：蜻蜓是当季白天唯一有轮廓的活物，
        // 画得太细（第一版 17…25pt、翅面 1pt）实测只有 294 —— 判据松了等于没钉。
        XCTAssertGreaterThan(differencePoints(withFlies, without), 250, "白天草尖上没有蜻蜓")
    }

    /// 夜里：蜻蜓**整层不画**（夜里那一档是流萤）。
    ///
    /// 反证：把 `guard !theme.isNight` 那句删掉 → 红。
    func testDragonfliesVanishAtNight() throws {
        let withFlies = try scene(dragonflies: true, isNight: true)
        let without = try scene(dragonflies: false, isNight: true)
        XCTAssertEqual(differencePoints(withFlies, without), 0, "夜里不该有蜻蜓（夜里是流萤）")
    }

    /// 静态档两遍零差异（悬停点是纯函数派生的）。
    ///
    /// ⚠️ 必须显式传 `still: true`：活体档是**墙上时钟**驱动的
    /// （`now = context.date.timeIntervalSince(origin)`，`origin` 是 `@State Date()`），
    /// 第一帧的 elapsed 取决于宿主布局花了多久 —— 机器一忙两遍就对不上
    /// （2026-10-23 全量跑实测差 278，单跑必绿：典型的负载型偶发。
    /// `ForestSummerExtrasRenderTests` 同一处坑一并修掉）。
    /// ⚠️ 离屏 `TimelineView` 不推进相位，这条因此是**弱闸**；真正钉住
    /// 「静态姿态不随时间漂」的是
    /// `ForestSummerExtrasTests.testFrozenDragonfliesRestMidHover`。
    func testStillFrameIsDeterministic() throws {
        let first = try scene(dragonflies: true, still: true)
        let second = try scene(dragonflies: true, still: true)
        XCTAssertEqual(differencePoints(first, second), 0, "静态档不许抖")
    }

    /// `reduceMotion`：蜻蜓**还在**（关动效 ≠ 关内容）且走冻结档（停在悬停中）。
    ///
    /// ⚠️ 判据是「与静态档**同一个姿态**」不是「两遍一致」：离屏窗口里
    /// `TimelineView` 不推进相位，连拍两遍永远一致 —— 那条断言是假绿
    /// （与 `ForestGeeseRenderTests` 同一处教训）。
    ///
    /// 反证（已实测）：把组件里 `frozen` 的 `|| motion.reduceMotion` 删掉 →
    /// 红在「必须走冻结档」。
    /// 「定格在悬停段而不是半空」由
    /// `ForestDragonfliesTests.testFrozenPoseIsHoveringNotMidAir` 钉（纯函数层）。
    func testReduceMotionKeepsDragonfliesFrozen() throws {
        let reduced = try scene(dragonflies: true, reduceMotion: true, still: false)
        let still = try scene(dragonflies: true, reduceMotion: false, still: true)
        let blank = try scene(dragonflies: false, reduceMotion: true, still: false)
        XCTAssertGreaterThan(differencePoints(reduced, blank), 250, "关掉动效后蜻蜓不该消失")
        XCTAssertEqual(differencePoints(reduced, still), 0, "减弱动效必须走冻结档（与静态档同一姿态）")
    }
}
