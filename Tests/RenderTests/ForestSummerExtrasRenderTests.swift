import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 夏天草地上的光斑与流萤（#623）的离屏渲染回归。
///
/// 判据走**区域墨迹差**（底色用草绿，模拟真实的草地 —— 光斑走 `.plusLighter`，
/// 白底上会过曝成白，什么也测不出来）：
/// - 白天有光斑、夜里没有；
/// - 夜里流萤画得出来、白天没有（两者互斥，正是一天两副样子）；
/// - 静态档两遍零差异；`reduceMotion` 下仍在（关动效 ≠ 关内容）。
@MainActor
final class ForestSummerExtrasRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let canvas = CGSize(width: 420, height: 150)
    private let groundY: CGFloat = 120
    /// 草地的本色（白天 `hillNear` 的量级）：光斑是「加上去」的光，白底上过曝。
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

    private func scene(dapples: Bool, fireflies: Bool, isNight: Bool = false,
                       reduceMotion: Bool = false, still: Bool = false) throws -> Render {
        let theme = self.theme(isNight: isNight)
        let groundY = self.groundY
        return try makeHost(
            ZStack {
                meadow
                if dapples {
                    ForestDapples(theme: theme, groundLine: { _ in groundY }, still: still)
                }
                if fireflies {
                    ForestFireflies(theme: theme, groundLine: { _ in groundY }, still: still)
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

    /// 白天：叶隙光斑画得出来。
    ///
    /// 反证：把 `ForestDapples` 的 body 改成恒 `EmptyView` → 红。
    func testDapplesShowInDaylight() throws {
        let withDapples = try scene(dapples: true, fireflies: false)
        let without = try scene(dapples: false, fireflies: false)
        XCTAssertGreaterThan(differencePoints(withDapples, without), 60, "白天没有光斑")
    }

    /// 夜里：光斑**整层不画**（夜里没有阳光）。
    ///
    /// 反证：把 `ForestDapples` 里 `guard !theme.isNight` 那句删掉 → 红。
    func testDapplesVanishAtNight() throws {
        let withDapples = try scene(dapples: true, fireflies: false, isNight: true)
        let without = try scene(dapples: false, fireflies: false, isNight: true)
        XCTAssertEqual(differencePoints(withDapples, without), 0, "夜里不该有阳光光斑")
    }

    /// 夜里：流萤画得出来。
    func testFirefliesShowAtNight() throws {
        let withFlies = try scene(dapples: false, fireflies: true, isNight: true)
        let without = try scene(dapples: false, fireflies: false, isNight: true)
        XCTAssertGreaterThan(differencePoints(withFlies, without), 30, "夜里没有流萤")
    }

    /// 白天：流萤**整层不画**（白天看不见萤火虫）。
    ///
    /// 反证：把 `ForestFireflies` 里 `guard theme.isNight` 那句删掉 → 红。
    func testFirefliesVanishInDaylight() throws {
        let withFlies = try scene(dapples: false, fireflies: true)
        let without = try scene(dapples: false, fireflies: false)
        XCTAssertEqual(differencePoints(withFlies, without), 0, "白天不该有萤火虫")
    }

    /// 静态档两遍零差异（布局与明暗是纯函数）。
    ///
    /// ⚠️ 必须显式传 `still: true`：活体档是**墙上时钟**驱动的
    /// （`now = context.date.timeIntervalSince(origin)`，`origin` 是 `@State Date()`），
    /// 第一帧的 elapsed 取决于宿主布局花了多久 —— 机器一忙两遍就对不上
    /// （同一条坑 2026-10-23 全量跑在 `ForestDragonfliesRenderTests` 上实测差 278，
    /// 单跑必绿：典型负载型偶发）。
    func testStillFrameIsDeterministic() throws {
        let first = try scene(dapples: true, fireflies: true, still: true)
        let second = try scene(dapples: true, fireflies: true, still: true)
        XCTAssertEqual(differencePoints(first, second), 0, "静态档不许抖")
    }

    /// `reduceMotion`：光斑还在（关动效 ≠ 关内容），且两遍一致（冻结）。
    ///
    /// 反证：把冻结档改成「整层不画」→ 红在第一条。
    func testReduceMotionKeepsDapplesFrozen() throws {
        let frozen = try scene(dapples: true, fireflies: false, reduceMotion: true)
        let again = try scene(dapples: true, fireflies: false, reduceMotion: true)
        let blank = try scene(dapples: false, fireflies: false, reduceMotion: true)
        XCTAssertGreaterThan(differencePoints(frozen, blank), 60, "关掉动效后光斑不该消失")
        XCTAssertEqual(differencePoints(frozen, again), 0, "减弱动效下必须冻结")
    }
}
