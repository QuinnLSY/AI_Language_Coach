import AppKit
import AIDomain
@testable import AppUI
import SwiftUI
import XCTest

/// #600 学习节奏（丰季）的离屏渲染回归。
///
/// 判据走**墨迹差**，不比色值（离屏过色彩空间换算，见技能 macos-ui-verify）：
/// - 丰季（连胜一周 + 今日达标）的叶色/山丘必须与常态可见地不同（`lush` 盛档真的画上去了）；
/// - 夜里看不出叶色（既有约定）：夜档两帧必须**零差异** —— 盛档不许把夜景改坏；
/// - 成长 / 休憩与常态逐像素一致（非惩罚性：停滞不会让叶色变衰）；
/// - 同一档渲染两遍必须一致（`lush` 是纯函数，不许引入抖动）。
@MainActor
final class ForestMomentumRenderTests: XCTestCase {

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
            ForestSky(theme: theme, showsCelestial: false, ambientStill: true)
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

    /// 春天（3 月）+ 白天 + 跟随季节，按学习节奏解析。
    private func theme(momentum: ForestMomentum?, isNight: Bool = false) -> ForestTheme {
        ForestThemeResolver.resolve(
            mode: isNight ? .night : .day, systemIsDark: false,
            hour: isNight ? 23 : 12, month: 3,
            followsClock: true, followsSeason: true,
            momentum: momentum
        )
    }

    // MARK: - 丰季

    /// 白天：丰季山丘/林冠必须与常态可见地不同（`lush` 盛档画上去了）。
    ///
    /// 反证：把 `ForestTheme.seasonal` 里 `momentum == .flourishing` 那一支删掉
    /// （丰季不换盛档色）→ 红。
    func testDayFlourishingDiffersFromResting() throws {
        let resting = try sky(theme(momentum: nil))
        let flourishing = try sky(theme(momentum: .flourishing))
        XCTAssertGreaterThan(differencePoints(resting, flourishing), 40,
                             "丰季叶色没有变盛（画面与常态无差异）")
    }

    /// 四季都要能盛：春 / 夏 / 秋 / 冬各来一遍（盛档是 `seasonal` 的公共支路）。
    func testFlourishingWorksInEverySeason() throws {
        for month in [3, 6, 9, 12] {
            let resting = ForestThemeResolver.resolve(
                mode: .day, systemIsDark: false,
                hour: 12, month: month,
                followsClock: true, followsSeason: true
            )
            let flourishing = ForestThemeResolver.resolve(
                mode: .day, systemIsDark: false,
                hour: 12, month: month,
                followsClock: true, followsSeason: true,
                momentum: .flourishing
            )
            XCTAssertNotEqual(resting.foliage, flourishing.foliage,
                              "\(month) 月：丰季叶色必须与常态不同")
            XCTAssertNotEqual(resting.hillNear, flourishing.hillNear,
                              "\(month) 月：丰季山丘必须与常态不同")
        }
    }

    /// 夜里看不出叶色（既有约定）：夜档两帧必须零差异 —— 盛档不许把夜景改坏。
    ///
    /// 反证：把 `seasonal` 的夜档提前返回也涂上 lush（`if isNight { return lush(night) }`）→ 红。
    func testNightFlourishingChangesNothing() throws {
        let resting = try sky(theme(momentum: nil, isNight: true))
        let flourishing = try sky(theme(momentum: .flourishing, isNight: true))
        XCTAssertEqual(differencePoints(resting, flourishing), 0,
                       "夜档不许随学习节奏变（夜里看不出叶色，改了只会把夜景改坏）")
    }

    /// 成长 / 休憩与常态一致（非惩罚性：停滞不会让叶色变衰，成长也不提前盛）。
    func testGrowingAndRestingChangeNothing() throws {
        let resting = try sky(theme(momentum: nil))
        XCTAssertEqual(differencePoints(resting, try sky(theme(momentum: .growing))), 0,
                       "成长档不该改画面（只有丰季有正反馈）")
        XCTAssertEqual(differencePoints(resting, try sky(theme(momentum: .resting))), 0,
                       "休憩档不该改画面（非惩罚性设计）")
    }

    /// 同一个节奏渲染两遍必须零差异（`lush` 是纯函数）。
    func testFlourishingRendersDeterministically() throws {
        let first = try sky(theme(momentum: .flourishing))
        let second = try sky(theme(momentum: .flourishing))
        XCTAssertEqual(differencePoints(first, second), 0, "丰季渲染不许有任何抖动")
    }

    /// 没开季节跟随时，丰季也不显色（`seasonal` 的 `season == nil` 支路在前）——
    /// 但 `momentum` 字段必须在主题里（由接线测试钉）。
    func testFlourishingWithoutSeasonChangesNothing() throws {
        let theme = ForestThemeResolver.resolve(
            mode: .day, systemIsDark: false,
            hour: 12, month: 3,
            followsClock: true, followsSeason: false,
            momentum: .flourishing
        )
        XCTAssertEqual(theme.momentum, .flourishing)
        XCTAssertNil(theme.season)
        let plain = try sky(ForestThemeResolver.resolve(
            mode: .day, systemIsDark: false,
            hour: 12, month: 3,
            followsClock: true, followsSeason: false
        ))
        XCTAssertEqual(differencePoints(plain, try sky(theme)), 0,
                       "没开季节跟随时丰季不显色（季节都没有，何谈盛档）")
    }
}
