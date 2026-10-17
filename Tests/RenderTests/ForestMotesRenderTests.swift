import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// P1-② 氛围微粒的离屏渲染回归。
///
/// 三条判据，各自守一句承诺：
/// 1. 微粒**真的画出来了**（开着氛围 vs 收起氛围，画面必须不同）；
/// 2. **关掉动效 ≠ 关掉内容**：`reduceMotion` 下微粒仍看得见 —— 停在中间亮度，
///    不是停在 opacity 0（早先最容易犯的错：把 `loopAnimation` 失效后的终值
///    设成了 0，一开「减弱动态效果」萤火虫就整片消失）；
/// 3. **静态档零抖动**：同一状态渲染两遍必须逐像素一致（与
///    `AmbientSkyRenderTests` 同一条纪律）。
///
/// 度量走墨迹差（不比色值 —— 离屏过色彩空间换算，见技能 macos-ui-verify）。
@MainActor
final class ForestMotesRenderTests: XCTestCase {

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

    /// `still`：氛围演出隐藏档（整层移除）。`reduceMotion`：系统「减弱动态效果」。
    private func motes(still: Bool, reduceMotion: Bool) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .night, systemIsDark: false,
                                                hour: 22, month: 6, followsClock: false, followsSeason: false)
        XCTAssertTrue(theme.isNight, "萤火虫这组必须取夜档")
        return try makeHost(
            ForestMotes(theme: theme, still: still)
                .environment(\.appMotion,
                             AppMotionDescriptor(reduceMotion: reduceMotion, reduceTransparency: true))
                .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
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

    /// 开着氛围 vs 收起氛围：夜里该有一片萤火虫。
    ///
    /// 反证：把 `ForestMotes.body` 里的 `ForEach` 删掉（或 `still` 恒为 true）→ 红。
    func testFirefliesShowUpWhenTheAmbienceIsOn() throws {
        let lively = try motes(still: false, reduceMotion: true)
        let hidden = try motes(still: true, reduceMotion: true)
        XCTAssertGreaterThan(differencePoints(lively, hidden), 40,
                             "收起氛围之后画面应当肉眼可见地不同 —— 萤火虫没画出来")
    }

    /// **关掉动效不该关掉内容**：`reduceMotion` 下微粒仍然要看得见。
    ///
    /// 这两张图都是 `reduceMotion: true`，区别只在氛围开关 —— 差异来自
    /// 「粒子在不在」，与动效无关。若哪天把 `loopAnimation` 失效后的终值
    /// 改成了 0（或把 `animates` 误接到 `motion.reduceMotion` 上），
    /// 这条会立刻红：那时两张图都会是空的。
    func testReducedMotionKeepsTheMotesVisible() throws {
        let reduced = try motes(still: false, reduceMotion: true)
        let hidden = try motes(still: true, reduceMotion: true)
        XCTAssertGreaterThan(differencePoints(reduced, hidden), 40,
                             "减弱动态效果下萤火虫整片消失 → 把「关动效」做成了「关内容」")
    }

    /// 静态档不许有任何抖动：同状态两遍必须逐像素一致。
    func testStillMotesRenderDeterministically() throws {
        let first = try motes(still: true, reduceMotion: true)
        let second = try motes(still: true, reduceMotion: true)
        XCTAssertEqual(differencePoints(first, second), 0, "静态档渲染不许有任何抖动")
    }

    /// 开着氛围 + 减弱动态效果：两张也必须一致 —— 这是「静止但可见」那一档
    /// 的稳定性（挡位定了，画面就不许再漂）。
    func testReducedMotionFrameIsStableAcrossRenders() throws {
        let first = try motes(still: false, reduceMotion: true)
        let second = try motes(still: false, reduceMotion: true)
        XCTAssertEqual(differencePoints(first, second), 0,
                       "reduceMotion 下粒子应当定在同一处，不许随抓取时刻漂移")
    }

    // MARK: 日夜必须是两种东西（用户报障回归）

    /// 透明背景上的微粒覆盖量（alpha > 16 的像素数，换算回点）。
    ///
    /// 为什么不比色值：萤火虫与飘絮的差别**不在颜色**，在「有没有光晕」——
    /// 光晕是半透明的，色值采样抓不到它，覆盖面积抓得到。
    private func inkOfMotes(theme: ForestTheme) throws -> Int {
        let size = CGSize(width: 420, height: 360)
        let view = ForestMotes(theme: theme, still: false)
            .environment(\.appMotion, AppMotionDescriptor(reduceMotion: true, reduceTransparency: true))
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.bitmapData else { return 0 }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                if data[(y * width + x) * 4 + 3] > 16 { count += 1 }
            }
        }
        let scale = CGFloat(rep.pixelsHigh) / max(size.height, 1)
        return Int(Double(count) / Double(scale * scale))
    }

    /// **用户报障回归（2026-10-18「白天和夜晚都是萤火虫」）**。
    ///
    /// 第一版把白天也画成「暖黄发光小圆点 + 一闪一闪」—— 而那正是萤火虫的
    /// 全部辨识特征，于是白天看着就是一林子萤火虫。修法是把飘絮做到与虫**相反**：
    /// 无光晕（直径 ×3.0 vs ×5.2）、米白、扁椭圆、明暗差 <0.1。
    ///
    /// 判据：夜里微粒的覆盖面积必须显著大于白天（光晕面积比 ≈3:1，
    /// 加上虫体更大更亮）。**反证**：把日间参数改回第一版（光晕 ×5.2、
    /// opacity 0.62）→ 两者接近 → 红。
    func testNightFirefliesPaintFarMoreThanDayPollen() throws {
        let day = ForestThemeResolver.resolve(mode: .day, systemIsDark: false,
                                              hour: 12, month: 6, followsClock: false, followsSeason: false)
        let night = ForestThemeResolver.resolve(mode: .night, systemIsDark: false,
                                                hour: 22, month: 6, followsClock: false, followsSeason: false)
        let dayInk = try inkOfMotes(theme: day)
        let nightInk = try inkOfMotes(theme: night)

        XCTAssertGreaterThan(dayInk, 0, "白天一粒都看不见 → 用户会以为白天没有微粒")
        XCTAssertGreaterThan(nightInk, dayInk,
                             "夜里的覆盖量不比白天多 → 两组微粒看起来是同一种东西（萤火虫）")
        XCTAssertGreaterThan(Double(nightInk), Double(dayInk) * 1.8,
                             "日夜覆盖量太接近 → 白天那一组还是有光晕，看着仍像萤火虫")
    }
}
