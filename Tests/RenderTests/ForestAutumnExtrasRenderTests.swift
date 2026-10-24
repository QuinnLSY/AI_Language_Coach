import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 秋天草地上的落叶堆与南瓜的离屏渲染回归（#625）。
///
/// 判据走**区域墨迹差**，不比色值：
/// - 落叶堆与南瓜各自画得出来（两个组件分开渲染，各自的墨迹才分得清）；
/// - 南瓜坐在中间那片空地上（两边外侧留给果树，不许去挤）；
/// - 没注入风钟时**零抖动**；注入风钟推进后画面必须变 —— 散叶真的被风推着挪；
/// - 夜里也看得见；
/// - 谁都不许戳出地面带上沿。
@MainActor
final class ForestAutumnExtrasRenderTests: XCTestCase {

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

    /// - `piles` / `pumpkins`：画哪一样（两个组件分开渲染，墨迹才分得清是谁的）；
    /// - `clock`：注入的风钟（nil = 不注入，散叶躺回原处）；
    /// - `width`：带宽（默认取右栏面板的常见值）；
    /// - `ruler`：压一根**正好一只小动物高**的标尺条（出图复核用）。
    private func scene(piles: Bool = false, pumpkins: Bool = false,
                       isNight: Bool = false, clock: ForestWindClock? = nil,
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
                // 底色取秋草的黄绿：落叶与南瓜是画在草坡上的
                Color(red: 0.42, green: 0.50, blue: 0.28)
                if piles {
                    ForestLeafPiles(
                        theme: theme,
                        groundLine: ground,
                        quantizedWidth: (width / 28).rounded() * 28
                    )
                }
                if pumpkins {
                    ForestPumpkins(
                        theme: theme,
                        groundLine: ground,
                        quantizedWidth: (width / 28).rounded() * 28
                    )
                }
                if ruler {
                    // 标尺条：站在同一条坡面上，正好一只小动物高（挨着南瓜比个头）
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: 5, height: animal)
                        .offset(x: width * 0.41 - 2.5, y: ground(width * 0.41) - animal)
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

    // MARK: 画得出来

    /// 落叶堆画得出来。
    ///
    /// 反证：把 `autumnGlade` 换成空数组 → 红。
    func testLeafPilesAreDrawn() throws {
        let withPiles = try scene(piles: true)
        let empty = try scene()
        XCTAssertGreaterThan(differencePoints(withPiles, empty), 400, "草地上一堆落叶都没有")
    }

    /// 南瓜画得出来。
    ///
    /// 反证：把 `autumnPatch` 换成空数组 → 红。
    func testPumpkinsAreDrawn() throws {
        let withGourds = try scene(pumpkins: true)
        let empty = try scene()
        XCTAssertGreaterThan(differencePoints(withGourds, empty), 250, "草地上一个南瓜都没有")
    }

    /// 南瓜坐在**中间那片空地**上（两边外侧留给果树 #624，不许去挤）。
    ///
    /// 反证：把 `lane` 的 `anchor` 改成 0.06 → 红在第一条。
    func testPumpkinsSitInTheMiddleOpen() throws {
        let withGourds = try scene(pumpkins: true)
        let empty = try scene()
        let middle = CGRect(x: band.width * 0.22, y: 0,
                            width: band.width * 0.56, height: band.height)
        let leftEdge = CGRect(x: 0, y: 0, width: band.width * 0.14, height: band.height)
        let rightEdge = CGRect(x: band.width * 0.86, y: 0,
                               width: band.width * 0.14, height: band.height)
        XCTAssertGreaterThan(differencePoints(withGourds, empty, in: middle), 250,
                             "中间空地上没有南瓜")
        XCTAssertEqual(differencePoints(withGourds, empty, in: leftEdge), 0,
                       "南瓜挤到左边跟果树打架了")
        XCTAssertEqual(differencePoints(withGourds, empty, in: rightEdge), 0,
                       "南瓜挤到右边跟果树打架了")
    }

    /// 落叶不许堆到地面带上沿去（它们躺在坡上，不是挂在半空）。
    ///
    /// 反证：把 `baseY` 改成常量 30 → 红。
    func testNothingInvadesTheBandTop() throws {
        let withAll = try scene(piles: true, pumpkins: true)
        let empty = try scene()
        let strip = CGRect(x: 0, y: 0, width: band.width, height: 3)
        XCTAssertEqual(differencePoints(withAll, empty, in: strip), 0,
                       "落叶 / 南瓜戳出了地面带上沿")
    }

    // MARK: 风

    /// 没注入风钟时零抖动（散叶躺回原处，不自己乱爬）。
    func testWindlessFrameIsDeterministic() throws {
        let first = try scene(piles: true, pumpkins: true)
        let second = try scene(piles: true, pumpkins: true)
        XCTAssertEqual(differencePoints(first, second), 0, "静态帧不许抖")
    }

    /// 风相位推进后画面必须变 —— 堆脚边那几片散叶真的被风推着挪。
    ///
    /// 只画落叶堆：南瓜是躺在地上的重东西（它明确**不**跟风），混进来会稀释判据。
    ///
    /// 反证：把 `drift` 去掉（散叶钉死）→ 红。
    func testLooseLeavesDriftWhenTheWindAdvances() throws {
        let clock = ForestWindClock()
        clock.advance(to: Date(), blowing: true)
        let before = try scene(piles: true, clock: clock)
        clock.advance(to: Date().addingTimeInterval(1.6), blowing: true)
        let after = try scene(piles: true, clock: clock)
        XCTAssertGreaterThan(differencePoints(before, after), 20,
                             "风走了 1.6 秒，散叶一动没动")
    }

    /// 风停（减弱动效 / 氛围隐藏档）：散叶躺回原处，但**照样在** ——
    /// 关动效不许做成关内容。
    ///
    /// 反证：把 `blowing: false` 那支做成「整片落叶不画」→ 红在第二条。
    func testFrozenWindSettlesButKeepsTheLeaves() throws {
        let clock = ForestWindClock()
        clock.advance(to: Date(), blowing: true)
        clock.advance(to: Date().addingTimeInterval(2.0), blowing: false)
        let frozen = try scene(piles: true, clock: clock)
        let windless = try scene(piles: true)
        let empty = try scene()
        XCTAssertEqual(differencePoints(frozen, windless), 0, "风停了散叶该躺回原处")
        XCTAssertGreaterThan(differencePoints(frozen, empty), 400, "风停了落叶不该跟着消失")
    }

    /// 南瓜**不跟风动**（是躺在地上的重东西，风推不动它）。
    ///
    /// 反证：给南瓜也接上风钟位移 → 红。
    func testPumpkinsDoNotMoveInTheWind() throws {
        let clock = ForestWindClock()
        clock.advance(to: Date(), blowing: true)
        let before = try scene(pumpkins: true, clock: clock)
        clock.advance(to: Date().addingTimeInterval(1.6), blowing: true)
        let after = try scene(pumpkins: true, clock: clock)
        XCTAssertEqual(differencePoints(before, after), 0, "南瓜被风吹走了")
    }

    // MARK: 日夜

    /// 夜里也看得见（夜里压暗，但不许暗到没了）。
    func testNightExtrasAreVisible() throws {
        let withAll = try scene(piles: true, pumpkins: true, isNight: true)
        let empty = try scene(isNight: true)
        XCTAssertGreaterThan(differencePoints(withAll, empty), 400, "夜里看不见落叶与南瓜")
    }

    // MARK: 出图（人眼复核）

    /// 出图：`.workbuddy/verify/`。
    ///
    /// 「比小动物矮一半还多」这种事断言只能守住**换算**，守不住**看着对不对** ——
    /// 所以出三张图（白天 / 夜里 / 宽面板），并在南瓜旁边压一根**正好一只小动物
    /// 高**的标尺条，人眼一比就知道南瓜是不是真比它矮一半还多。
    func testDumpsAutumnExtrasForHumanReview() throws {
        for (name, night) in [("day", false), ("night", true)] {
            let render = try scene(piles: true, pumpkins: true, isNight: night, ruler: true)
            try dump(render.rep, name: "autumn-extras-\(name)-20261021.png")
        }
        // 宽面板（小动物更大 → 落叶堆与南瓜跟着变大）：看会不会顶出地面带
        let wide = try scene(piles: true, pumpkins: true, width: 560, ruler: true)
        try dump(wide.rep, name: "autumn-extras-wide-20261021.png")
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
