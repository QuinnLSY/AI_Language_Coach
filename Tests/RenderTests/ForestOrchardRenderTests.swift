import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 秋天小果园的离屏渲染回归（#624）。
///
/// 判据走**区域墨迹差**，不比色值：
/// - 四棵画得出来，左右各两棵、中间给大树让空；
/// - 没注入风钟时**零抖动**；注入风钟推进后画面必须变 —— 树真的被风吹歪；
/// - 风停（减弱动效 / 氛围隐藏档）时树站直但**照样在**（关动效不许做成关内容）；
/// - 夜里也看得见；
/// - 树冠不戳出地面带上沿（整棵树框得住）。
@MainActor
final class ForestOrchardRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    /// 地面带的现实尺寸（宽取右栏面板的常见值，高是钉死的 150）。
    private let band = CGSize(width: 420, height: ForestSceneGeometry.groundBandHeight)

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

    /// - `grove`：画不画果园；
    /// - `clock`：注入的风钟（nil = 不注入，树站直）；
    /// - `width`：带宽（默认取右栏面板的常见值）；
    /// - `ruler`：在中间空地上压一根**正好一只小动物高**的标尺条（出图复核用）。
    private func scene(grove: Bool, isNight: Bool = false,
                       clock: ForestWindClock? = nil,
                       width: CGFloat? = nil, ruler: Bool = false) throws -> Render {
        let theme = ForestThemeResolver.resolve(
            mode: isNight ? .night : .day, systemIsDark: false,
            hour: isNight ? 22 : 12, month: 10,
            followsClock: true, followsSeason: true
        )
        XCTAssertEqual(theme.season, .autumn, "十月必须是秋天（否则这一组判据全空转）")
        let width = width ?? band.width
        let height = band.height
        let ground: ForestGroundSurface = { x in
            ForestSceneGeometry.hillSurfaceY(x: x, bandWidth: width, bandHeight: height)
        }
        let animal = ForestGroundPlan.referenceResidentSize(
            quantizedWidth: (width / 28).rounded() * 28)
        var view = AnyView(
            ZStack(alignment: .topLeading) {
                // 底色取秋草的黄绿：果园是画在草坡上的，判据要像它真的站在草上
                Color(red: 0.42, green: 0.50, blue: 0.28)
                if grove {
                    ForestOrchard(
                        theme: theme,
                        groundLine: ground,
                        quantizedWidth: (width / 28).rounded() * 28
                    )
                }
                if ruler {
                    // 标尺条：站在同一条坡面上，正好一只小动物高
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: 5, height: animal)
                        .offset(x: width * 0.49 - 2.5, y: ground(width * 0.49) - animal)
                }
            }
            .frame(width: width, height: height)
        )
        if let clock {
            view = AnyView(view.environment(\.forestWind, clock))
        }
        return try makeHost(
            view.environment(\.appMotion, AppMotionDescriptor(reduceMotion: false,
                                                              reduceTransparency: true)),
            size: CGSize(width: width, height: height)
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

    /// 四棵画得出来。
    ///
    /// 反证：把 `autumnGrove` 换成空数组 → 红。
    func testOrchardIsDrawn() throws {
        let withGrove = try scene(grove: true)
        let without = try scene(grove: false)
        XCTAssertGreaterThan(differencePoints(withGrove, without), 600, "草地上一棵树都没有")
    }

    /// 左两棵右两棵，**中间给大树让空**（不许长在正中间挡住它）。
    ///
    /// 反证：把 `lane` 全改成 0.5 → 红在第一条。
    func testTreesFlankTheBigTree() throws {
        let withGrove = try scene(grove: true)
        let without = try scene(grove: false)
        let middle = CGRect(x: band.width * 0.40, y: 0,
                            width: band.width * 0.20, height: band.height)
        let left = CGRect(x: 0, y: 0, width: band.width * 0.40, height: band.height)
        let right = CGRect(x: band.width * 0.60, y: 0,
                           width: band.width * 0.40, height: band.height)
        XCTAssertEqual(differencePoints(withGrove, without, in: middle), 0,
                       "中间长出了果树，挡住了大树")
        XCTAssertGreaterThan(differencePoints(withGrove, without, in: left), 200,
                             "左边没有果树")
        XCTAssertGreaterThan(differencePoints(withGrove, without, in: right), 200,
                             "右边没有果树")
    }

    /// 没注入风钟时零抖动（树站直，不自己乱晃）。
    func testWindlessFrameIsDeterministic() throws {
        let first = try scene(grove: true)
        let second = try scene(grove: true)
        XCTAssertEqual(differencePoints(first, second), 0, "静态帧不许抖")
    }

    /// 风相位推进后画面必须变 —— 树真的被风吹歪。
    ///
    /// 反证：把 `swayDegrees` 里的 `push` 删掉（树钉直）→ 红。
    func testTrunksLeanWhenTheWindAdvances() throws {
        let clock = ForestWindClock()
        clock.advance(to: Date(), blowing: true)
        let before = try scene(grove: true, clock: clock)
        clock.advance(to: Date().addingTimeInterval(1.6), blowing: true)
        let after = try scene(grove: true, clock: clock)
        XCTAssertGreaterThan(differencePoints(before, after), 60,
                             "风走了 1.6 秒，树一点没歪")
    }

    /// 风停（减弱动效 / 氛围隐藏档）：树站直，但**照样在** —— 关动效不许做成关内容。
    ///
    /// 反证：把 `blowing: false` 那支做成「整片果园不画」→ 红在第二条。
    func testFrozenWindStandsUprightButKeepsTheGrove() throws {
        let clock = ForestWindClock()
        clock.advance(to: Date(), blowing: true)
        clock.advance(to: Date().addingTimeInterval(2.0), blowing: false)
        let frozen = try scene(grove: true, clock: clock)
        let windless = try scene(grove: true)
        let empty = try scene(grove: false)
        XCTAssertEqual(differencePoints(frozen, windless), 0, "风停了树该站直")
        XCTAssertGreaterThan(differencePoints(frozen, empty), 600, "风停了果园不该跟着消失")
    }

    /// 夜里也看得见（夜里压暗，但不许暗到没了）。
    func testNightOrchardIsVisible() throws {
        let withGrove = try scene(grove: true, isNight: true)
        let without = try scene(grove: false, isNight: true)
        XCTAssertGreaterThan(differencePoints(withGrove, without), 600, "夜里的果园看不见")
    }

    /// 树冠不戳出地面带上沿 —— 整棵树框得住，`frame` 说多高就是多高。
    ///
    /// 反证：把 `animalHeights` 调到 3.5 → 红。
    func testCrownStaysBelowTheBandTop() throws {
        let withGrove = try scene(grove: true)
        let without = try scene(grove: false)
        let strip = CGRect(x: 0, y: 0, width: band.width, height: 3)
        XCTAssertEqual(differencePoints(withGrove, without, in: strip), 0,
                       "树冠戳出了地面带上沿")
    }

    // MARK: 出图（人眼复核）

    /// 出图：`.workbuddy/verify/`。
    ///
    /// 「两个半小动物高」这种事断言只能守住**换算**，守不住**看着对不对** ——
    /// 所以出两张图（白天 / 夜里），并在左边压一根**正好一只小动物高**的标尺条，
    /// 人眼一比就知道是不是两个半。
    func testDumpsOrchardForHumanReview() throws {
        for (name, night) in [("day", false), ("night", true)] {
            let render = try scene(grove: true, isNight: night, ruler: true)
            try dump(render.rep, name: "orchard-autumn-\(name)-20261021.png")
        }
        // 宽面板（小动物更大 → 果树更高）：看树冠会不会顶出地面带
        let wide = try scene(grove: true, width: 560, ruler: true)
        try dump(wide.rep, name: "orchard-autumn-wide-20261021.png")
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }
}
