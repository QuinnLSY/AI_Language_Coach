import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 夏天风车的离屏渲染回归（#622；2026-10-22 改成「两座 + 站在坡上 + 看得清」）。
///
/// 判据走**区域墨迹差**，不比色值：
/// - 两座画得出来、左右都铺开（不是堆在一角）；
/// - **地面上方一点墨迹都没有**（风车不许再飘在半空）；
/// - 没注入风钟时**零抖动**（叶片停在各自的初相上）；
/// - 注入风钟推进相位后画面必须变 —— 叶片真的在转；
/// - 夜里也看得见。
@MainActor
final class ForestWindmillsRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    /// 右栏面板的现实尺寸（窄而高）。
    private let canvas = CGSize(width: 420, height: 700)

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

    /// - `clock`：注入的风钟（nil = 不注入，叶片停在初相）。
    private func scene(mills: Bool, isNight: Bool = false,
                       clock: ForestWindClock? = nil) throws -> Render {
        let theme = ForestThemeResolver.resolve(
            mode: isNight ? .night : .day, systemIsDark: false,
            hour: isNight ? 22 : 12, month: 6,
            followsClock: true, followsSeason: true
        )
        var view = AnyView(
            ZStack {
                Color.white
                if mills { ForestWindmills(theme: theme) }
            }
            .frame(width: canvas.width, height: canvas.height)
        )
        if let clock {
            view = AnyView(view.environment(\.forestWind, clock))
        }
        return try makeHost(
            view.environment(\.appMotion, AppMotionDescriptor(reduceMotion: false,
                                                              reduceTransparency: true)),
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

    /// 两座画得出来。
    ///
    /// 反证：把 `summerField` 换成空数组 → 红。
    func testWindmillsAreDrawn() throws {
        let withMills = try scene(mills: true)
        let without = try scene(mills: false)
        XCTAssertGreaterThan(differencePoints(withMills, without), 120, "草场上没有风车")
    }

    /// **地面上方一点墨迹都没有**：两座风车站在地面带里的远坡上，不再飘在半空。
    ///
    /// ⚠️ 留 `reachingRoom` = 34pt 的余量：风车比小动物高一档，塔尖会探出带顶一点点
    /// （果树也伸进去过，那是同一个「地面段」）。判据要抓的是「飘在半空」，不是「压线」。
    ///
    /// 反证：把 `groundY` 换回旧式 `panelHeight − 带高 + 26 − horizonSpan × depth`
    /// → 上半幅会冒出一排风车 → 红在第一条（用户 2026-10-22 的截图就是这个样子）。
    func testNothingFloatsAboveTheGroundBand() throws {
        let withMills = try scene(mills: true)
        let without = try scene(mills: false)
        let bandTop = canvas.height - ForestSceneGeometry.groundBandHeight
        let reachingRoom: CGFloat = 34
        let sky = CGRect(x: 0, y: 0, width: canvas.width, height: bandTop - reachingRoom)
        let band = CGRect(x: 0, y: bandTop, width: canvas.width,
                          height: ForestSceneGeometry.groundBandHeight)
        XCTAssertEqual(differencePoints(withMills, without, in: sky), 0,
                       "风车画到地面带上方去了 —— 又飘起来了")
        XCTAssertGreaterThan(differencePoints(withMills, without, in: band), 120,
                             "地面带里没有风车")
    }

    /// 左右都站了一座（错落，不是挤在一角）。
    ///
    /// 反证：把 `lane` 全压到 0.2 → 红在右半这条。
    func testWindmillsSpreadAcrossTheField() throws {
        let withMills = try scene(mills: true)
        let without = try scene(mills: false)
        let bandTop = canvas.height - ForestSceneGeometry.groundBandHeight
        let left = CGRect(x: 0, y: bandTop, width: canvas.width / 2,
                          height: ForestSceneGeometry.groundBandHeight)
        let right = CGRect(x: canvas.width / 2, y: bandTop,
                           width: canvas.width / 2,
                           height: ForestSceneGeometry.groundBandHeight)
        XCTAssertGreaterThan(differencePoints(withMills, without, in: left), 40,
                             "左半边没有风车")
        XCTAssertGreaterThan(differencePoints(withMills, without, in: right), 40,
                             "右半边没有风车")
    }

    /// 没注入风钟时零抖动（叶片停在各自的初相上，不自己乱转）。
    func testWindlessFrameIsDeterministic() throws {
        let first = try scene(mills: true)
        let second = try scene(mills: true)
        XCTAssertEqual(differencePoints(first, second), 0, "静态帧不许抖")
    }

    /// 风相位推进后画面必须变 —— 叶片真的被风推着转。
    ///
    /// 反证：把 `bladeAngle` 里的 `windPhase * mill.spinGain` 删掉（叶片钉死）→ 红。
    func testBladesTurnWhenTheWindAdvances() throws {
        let clock = ForestWindClock()
        clock.advance(to: Date(), blowing: true)
        let before = try scene(mills: true, clock: clock)
        clock.advance(to: Date().addingTimeInterval(1.6), blowing: true)
        let after = try scene(mills: true, clock: clock)
        XCTAssertGreaterThan(differencePoints(before, after), 30,
                             "风走了 1.6 秒，叶片一点没动")
    }

    /// 夜里也看得见（夜里压暗、融天，但不许暗到没了）。
    func testNightWindmillsAreVisible() throws {
        let withMills = try scene(mills: true, isNight: true)
        let without = try scene(mills: false, isNight: true)
        XCTAssertGreaterThan(differencePoints(withMills, without), 200, "夜里的风车看不见")
    }
}
