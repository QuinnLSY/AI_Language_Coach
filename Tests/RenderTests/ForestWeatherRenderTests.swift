import AppKit
import AIDomain
@testable import AppUI
import SwiftUI
import XCTest

/// 森林天气（#418-A）与年轮徽记（#418-B）的离屏渲染回归。
///
/// 判据走**墨迹差**，不比色值（离屏过色彩空间换算，见技能 macos-ui-verify）：
/// - 雨天 / 多云的天必须与晴天画面不同（雨层 / 云量真的画上去了）；
/// - 同一档渲染两遍必须逐像素一致（种子随机不许引入抖动）；
/// - 年轮徽记只在有练习记录时出现（树根的墨迹变化只在徽记区）。
@MainActor
final class ForestWeatherRenderTests: XCTestCase {

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

    private func sky(_ theme: ForestTheme) throws -> Render {
        try makeHost(
            ForestSky(theme: theme, showsCelestial: false, ambientStill: false)
                .environment(\.appMotion, AppMotionDescriptor(reduceMotion: true, reduceTransparency: true))
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

    /// 两帧之间**最大的 WCAG 对比度**（只看有明显差异的那些像素）。
    ///
    /// 为什么需要它（2026-10-01）：「像素有差异」这个判据太软 —— 雨丝颜色与晴空
    /// 几乎同色时（实测对比 1.14:1）差异像素照样上千，测试全绿，可用户**看不见在下雨**
    /// （设置页写着「今天是雨」，画面毫无变化）。差异要大到肉眼可辨才算数。
    private func maxContrast(_ lhs: Render, _ rhs: Render) -> Double {
        guard let a = lhs.rep.bitmapData, let b = rhs.rep.bitmapData else { return 0 }
        let width = lhs.rep.pixelsWide, height = lhs.rep.pixelsHigh
        var best = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let dr = abs(Int(a[o]) - Int(b[o]))
                let dg = abs(Int(a[o + 1]) - Int(b[o + 1]))
                let db = abs(Int(a[o + 2]) - Int(b[o + 2]))
                guard dr + dg + db > 24 else { continue }
                let la = Self.luminance(r: Int(a[o]), g: Int(a[o + 1]), b: Int(a[o + 2]))
                let lb = Self.luminance(r: Int(b[o]), g: Int(b[o + 1]), b: Int(b[o + 2]))
                let ratio = (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
                best = max(best, ratio)
            }
        }
        return best
    }

    /// WCAG 相对亮度（sRGB）。
    private static func luminance(r: Int, g: Int, b: Int) -> Double {
        func channel(_ value: Int) -> Double {
            let c = Double(value) / 255.0
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private func resolved(isNight: Bool, weather: ForestWeather?) -> ForestTheme {
        let base = ForestThemeResolver.resolve(
            mode: isNight ? .night : .day, systemIsDark: false,
            hour: isNight ? 22 : 12, month: 6,
            followsClock: false, followsSeason: false
        )
        return ForestTheme(palette: base.palette, moment: base.moment,
                           season: base.season, weather: weather)
    }

    // MARK: - 天气

    /// 白天：雨天与晴天画面必须可见地不同。
    ///
    /// 反证：把 ForestSky 里 `if theme.weather == .rain` 的 `RainLayer(color:)`
    /// 换成 `Color.clear`（雨层不装配）→ 红。
    func testDayRainDiffersFromClearSky() throws {
        let clear = try sky(resolved(isNight: false, weather: .clear))
        let rain = try sky(resolved(isNight: false, weather: .rain))
        XCTAssertGreaterThan(differencePoints(clear, rain), 40,
                             "雨丝层没有画上去（雨天与晴天画面无差异）")
        XCTAssertGreaterThan(maxContrast(clear, rain), 1.8,
                             "雨丝与天空太接近：像素有差异，人眼却看不出在下雨")
    }

    /// 夜里也下雨（换暗一档的颜色，但不是不下）。
    func testNightRainDiffersFromClearSky() throws {
        let clear = try sky(resolved(isNight: true, weather: .clear))
        let rain = try sky(resolved(isNight: true, weather: .rain))
        XCTAssertGreaterThan(differencePoints(clear, rain), 40,
                             "夜雨层没有画上去")
        XCTAssertGreaterThan(maxContrast(clear, rain), 1.8, "夜雨与夜空太接近，看不见在下雨")
    }

    /// 多云：云量加倍后画面必须可见地不同。
    func testCloudyDiffersFromClearSky() throws {
        let clear = try sky(resolved(isNight: false, weather: .clear))
        let cloudy = try sky(resolved(isNight: false, weather: .cloudy))
        XCTAssertGreaterThan(differencePoints(cloudy, clear), 40,
                             "多云的三朵加映云没有画上去")
    }

    /// 夜里也必须看得出多云：云此前只画在白天分支里 ——
    /// 设置页写着「今天是多云」，夜里回主界面一朵都没多。
    func testNightCloudyDiffersFromClearSky() throws {
        let clear = try sky(resolved(isNight: true, weather: .clear))
        let cloudy = try sky(resolved(isNight: true, weather: .cloudy))
        XCTAssertGreaterThan(differencePoints(cloudy, clear), 40,
                             "夜间的云量没有画上去")
    }

    /// 同一种天气渲染两遍必须零差异：雨丝用种子随机，不许每次布局换一场新雨。
    func testRainRendersDeterministically() throws {
        let first = try sky(resolved(isNight: false, weather: .rain))
        let second = try sky(resolved(isNight: false, weather: .rain))
        XCTAssertEqual(differencePoints(first, second), 0, "雨天渲染不许有任何抖动")
    }

    // MARK: - 年轮徽记

    /// 有练习记录时，树根底部出现徽记墨迹；没练过时那一带干干净净。
    ///
    /// 反证：把 TreeCanvas 里 `if TreeRings.showsEmblem(...)` 的条件改成 `false`
    /// （徽记不装配）→ 红。
    func testRingEmblemInkAppearsAtTrunkBase() throws {
        let progress = LearnerProgress.seed()
        let empty = try makeHost(
            TreeCanvas(theme: resolved(isNight: false, weather: nil), progress: progress,
                       studentAnimal: .bear, companionAnimal: nil,
                       annualSummary: .empty())
                .environment(\.appMotion, AppMotionDescriptor(reduceMotion: true, reduceTransparency: true))
                .frame(width: canvas.width, height: TreeCanvas.canvasHeight(for: progress)),
            size: CGSize(width: canvas.width, height: TreeCanvas.canvasHeight(for: progress))
        )
        let practiced = try makeHost(
            TreeCanvas(theme: resolved(isNight: false, weather: nil), progress: progress,
                       studentAnimal: .bear, companionAnimal: nil,
                       annualSummary: TreeAnnualSummary(practicedDays: 45, longestStreak: 7))
                .environment(\.appMotion, AppMotionDescriptor(reduceMotion: true, reduceTransparency: true))
                .frame(width: canvas.width, height: TreeCanvas.canvasHeight(for: progress)),
            size: CGSize(width: canvas.width, height: TreeCanvas.canvasHeight(for: progress))
        )
        // ⚠️ 徽记区按 `TreeRings.emblemY` 算（跟着位置走），所以**必须另配一条绝对判据**：
        // 只靠「徽记区有墨」的话，把位置整个挪进林带遮住区也照样绿（判据跟着实现漂移）。
        let emblemY = TreeRings.emblemY(canvasHeight: TreeCanvas.canvasHeight(for: progress))
        XCTAssertLessThan(emblemY, TreeCanvas.canvasHeight(for: progress) - TreeViewport.groundBandHeight,
                          "徽记画进了林间地面带的遮住区：滚到画布底也看不见")
        let emblemArea = CGRect(x: canvas.width / 2 - 40, y: emblemY - 45,
                                width: 80, height: 90)
        XCTAssertGreaterThan(differencePoints(empty, practiced, in: emblemArea), 20,
                             "年轮徽记没有画在树根（45 天 / 连续 7 天应当有一圈 + 火苗）")
        // 徽记区之外（同画布顶部）：两帧应当一致 —— 摘要只改徽记，不动风景别处。
        let topArea = CGRect(x: 0, y: 0, width: canvas.width, height: 400)
        XCTAssertEqual(differencePoints(empty, practiced, in: topArea), 0,
                       "年轮摘要不许改变徽记以外的任何画面")
    }
}
