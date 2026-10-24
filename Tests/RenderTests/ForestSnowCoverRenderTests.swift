import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 冬季积雪的离屏渲染回归（#626）。
///
/// 判据走**区域墨迹差**，不比色值：
/// - 同一棵冬天的树，画雪 / 不画雪必须肉眼可辨（雪真的盖在冠上）；
/// - 雪帽裁在冠的轮廓里 —— 画框四角一个点都不许变（雪不会飘到叶子外面）；
/// - 草地雪盖画得出来，且只在坡面以下（不许飘到半空）；
/// - 夜里的雪看得见（夜里压暗，但不许暗到没了）；
/// - 静态帧零抖动。
@MainActor
final class ForestSnowCoverRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let crownSize = CGSize(width: 380, height: 300)
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

    private func theme(night: Bool) -> ForestTheme {
        let theme = ForestThemeResolver.resolve(
            mode: night ? .night : .day, systemIsDark: false,
            hour: night ? 22 : 12, month: 1,
            followsClock: true, followsSeason: true
        )
        XCTAssertEqual(theme.season, .winter, "一月必须是冬天（否则这一组判据全空转）")
        return theme
    }

    /// 树冠（带天空底）：`snow` 为 false 时出「同一棵树、没有雪」的对照图；
    /// `limbSnow` 为 false 时只关枝上的雪线（冠上的雪还在）。
    private func crown(night: Bool = false, snow: Bool = true,
                       limbSnow: Bool = true) throws -> Render {
        let theme = self.theme(night: night)
        let view = ZStack {
            LinearGradient(colors: theme.sky, startPoint: .top, endPoint: .bottom)
            TreeCrown(theme: theme, drawsSnow: snow, drawsLimbSnow: limbSnow)
        }
        .frame(width: crownSize.width, height: crownSize.height)
        return try makeHost(
            view.environment(\.appMotion, AppMotionDescriptor(reduceMotion: true,
                                                              reduceTransparency: true)),
            size: crownSize
        )
    }

    /// 地面带：草坡底色 + 雪盖（`snow` 为 false 时不出雪）。
    private func ground(night: Bool = false, snow: Bool = true,
                        width: CGFloat? = nil) throws -> Render {
        let theme = self.theme(night: night)
        let width = width ?? band.width
        let height = band.height
        let surface: ForestGroundSurface = { x in
            ForestSceneGeometry.hillSurfaceY(x: x, bandWidth: width, bandHeight: height)
        }
        let view = ZStack(alignment: .topLeading) {
            Color(red: 0.42, green: 0.50, blue: 0.28)
            if snow {
                ForestSnowField(theme: theme, groundLine: surface)
            }
        }
        .frame(width: width, height: height)
        return try makeHost(
            view.environment(\.appMotion, AppMotionDescriptor(reduceMotion: true,
                                                              reduceTransparency: true)),
            size: CGSize(width: width, height: height)
        )
    }

    /// 地面带 + 上下各 30pt 天空（用来钉「雪不许越出地面带」）。
    private func groundWithSky(night: Bool = false, snow: Bool = true) throws -> Render {
        let theme = self.theme(night: night)
        let width = band.width
        let height = band.height
        let margin: CGFloat = 30
        let surface: ForestGroundSurface = { x in
            ForestSceneGeometry.hillSurfaceY(x: x, bandWidth: width, bandHeight: height)
        }
        let view = ZStack(alignment: .topLeading) {
            LinearGradient(colors: theme.sky, startPoint: .top, endPoint: .bottom)
            ZStack(alignment: .topLeading) {
                Color(red: 0.42, green: 0.50, blue: 0.28)
                if snow {
                    ForestSnowField(theme: theme, groundLine: surface)
                }
            }
            .frame(width: width, height: height)
            .offset(y: margin)
        }
        .frame(width: width, height: height + margin * 2)
        return try makeHost(
            view.environment(\.appMotion, AppMotionDescriptor(reduceMotion: true,
                                                              reduceTransparency: true)),
            size: CGSize(width: width, height: height + margin * 2)
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

    // MARK: 冠上的雪

    /// 雪真的盖在冠上（同一棵树，有冠雪 / 无冠雪必须肉眼可辨）。
    ///
    /// ⚠️ 对照组只关**冠上的雪**（`limbSnow: false`）：枝上那道白线也是雪，
    /// 留着它会把「冠上一顶雪帽也没有」撑成绿的（实测踩过 —— 判据要各管各的）。
    ///
    /// 反证：把 `caps` 返回空数组 → 红。
    func testWinterCrownIsCappedWithSnow() throws {
        let withSnow = try crown(limbSnow: false)
        let bare = try crown(snow: false)
        XCTAssertGreaterThan(differencePoints(withSnow, bare), 1200, "冬季树冠上一点雪都没有")
    }

    /// 枝上的雪线画得出来（同一棵树，有枝雪 / 无枝雪可辨）。
    ///
    /// 反证：把 `limbSnow` 返回 nil → 红。
    func testWinterLimbsCarrySnow() throws {
        let withSnow = try crown()
        let bare = try crown(limbSnow: false)
        XCTAssertGreaterThan(differencePoints(withSnow, bare), 300, "枝上没有雪线")
    }

    /// 雪帽**裁在冠的轮廓里**：画框四角一个点都不许变（雪不许飘在叶子外面）。
    ///
    /// 反证：把 `CrownSnow` 的 `.mask(CrownUnionShape…)` 删掉 → 红。
    func testSnowNeverLeavesTheCrown() throws {
        let withSnow = try crown()
        let bare = try crown(snow: false)
        let corners = [
            CGRect(x: 0, y: 0, width: 10, height: 10),
            CGRect(x: crownSize.width - 10, y: 0, width: 10, height: 10),
            CGRect(x: 0, y: crownSize.height - 10, width: 10, height: 10),
            CGRect(x: crownSize.width - 10, y: crownSize.height - 10, width: 10, height: 10),
        ]
        for (index, corner) in corners.enumerated() {
            XCTAssertEqual(differencePoints(withSnow, bare, in: corner), 0,
                           "雪飘到画框第 \(index + 1) 个角上去了（雪帽没裁在冠里）")
        }
    }

    /// 夜里的雪看得见（夜里的雪是月光白，不是不见了）。
    func testNightSnowIsVisible() throws {
        let withSnow = try crown(night: true)
        let bare = try crown(night: true, snow: false)
        XCTAssertGreaterThan(differencePoints(withSnow, bare), 600, "夜里的雪看不见")
    }

    /// 静态帧零抖动。
    func testStaticCrownIsDeterministic() throws {
        XCTAssertEqual(differencePoints(try crown(), try crown()), 0, "静态帧不许抖")
    }

    // MARK: 草地上的雪

    /// 草地雪盖画得出来。
    ///
    /// 反证：把 `ForestSnowField` 从地面带摘掉 → 红。
    func testGroundSnowIsDrawn() throws {
        let withSnow = try ground()
        let bare = try ground(snow: false)
        XCTAssertGreaterThan(differencePoints(withSnow, bare), 1200, "草地上没有雪")
    }

    /// 雪盖**铺满整块草地**（不是只沿坡线描一条白边），且**一 pixel 都不许上到天空里**。
    ///
    /// ⚠️ 这条判据 2026-10-22 掉了个头，因为原来的写法是错的：旧版断言「带顶那 1/4 也必须变白」，
    /// 于是把 `Rectangle` 铺到整带当成了正确行为 —— 可草坡是个鼓包（中间高、两角低），
    /// 带顶那一片**是天空**，雪铺上去就是一条直角边横着切过大树
    /// （用户 2026-10-22：「冬季背景只占了下面一块，还把大树遮住了」）。
    /// 现在按**坡线**逐列判：坡线以下必须全白，坡线以上一个点都不许变。
    ///
    /// 反证：把 `ForestSnowField` 的 `SnowFieldShape` 换回 `Rectangle()` → 红在「坡线以上」那条。
    func testSnowFillsTheSlopeButNeverTheSkyAboveIt() throws {
        let withSnow = try ground()
        let bare = try ground(snow: false)
        let above = differencePointsAboveSlope(withSnow, bare)
        let below = differencePointsBelowSlope(withSnow, bare)
        XCTAssertEqual(above, 0, "雪铺到坡线以上（天空）里去了 —— 那正是切过大树的那条直角边")
        XCTAssertGreaterThan(below, 1200, "坡面以下没被雪盖住 —— 雪只描了一条边")
    }

    /// 雪堆允许鼓出坡线多少 pt（`SnowDriftLayout` 的 `height` 上限 11 + `inset` 下限 0，
    /// 再留 3pt 抗锯齿余量）。判「雪有没有上到天空」时必须给它这点余量：
    /// 雪堆本来就是**堆在雪面上的**，把它算成「雪盖漏了」是判据写错了，不是实现写错了。
    private let driftSlack: CGFloat = 14

    /// 逐列比较：坡线**以上**（扣掉雪堆鼓出来的那点余量）有多少点变了。
    ///
    /// ⚠️ 余量要跟着屏幕缩放走：判据里的 `driftSlack` 是**点**，而循环跑在**像素**上
    /// （Retina 下 1 点 = 2 像素）—— 忘了换算就等于只给了 7pt 余量，
    /// 雪堆自己那 11pt 全被当成「漏雪」（实测 123 点，假的）。
    private func differencePointsAboveSlope(_ lhs: Render, _ rhs: Render) -> Int {
        let slack = driftSlack * lhs.scale
        return slopeDifference(lhs, rhs) { pixelY, surfaceY in pixelY < surfaceY - slack }
    }

    /// 逐列比较：坡线**以下**有多少点变了。
    private func differencePointsBelowSlope(_ lhs: Render, _ rhs: Render) -> Int {
        let slack = 2 * lhs.scale
        return slopeDifference(lhs, rhs) { pixelY, surfaceY in pixelY > surfaceY + slack }
    }

    /// 按坡线分侧数差异像素（换算回点）。
    private func slopeDifference(
        _ lhs: Render, _ rhs: Render,
        matching keep: (_ pixelY: CGFloat, _ surfaceY: CGFloat) -> Bool
    ) -> Int {
        guard let a = lhs.rep.bitmapData, let b = rhs.rep.bitmapData else { return 0 }
        let width = lhs.rep.pixelsWide, height = lhs.rep.pixelsHigh
        let scale = lhs.scale
        var count = 0
        for x in 0..<width {
            let surfaceY = ForestSceneGeometry.hillSurfaceY(
                x: CGFloat(x) / scale,
                bandWidth: band.width,
                bandHeight: band.height
            ) * scale
            for y in 0..<height where keep(CGFloat(y), surfaceY) {
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

    /// 雪盖**不越出地面带**：带子上下的天空各留 30pt，那两条一个点都不许变。
    ///
    /// 反证：把整片雪地 `Rectangle` 的 `height` 改成 `proxy.size.height * 3` → 红。
    func testSnowNeverLeavesTheGroundBand() throws {
        let withSnow = try groundWithSky()
        let bare = try groundWithSky(snow: false)
        let bandHeight = band.height
        let above = CGRect(x: 0, y: 0, width: band.width, height: 30)
        let below = CGRect(x: 0, y: 30 + bandHeight, width: band.width, height: 30)
        XCTAssertEqual(differencePoints(withSnow, bare, in: above), 0,
                       "雪飘到地面带上方的天空里去了")
        XCTAssertEqual(differencePoints(withSnow, bare, in: below), 0,
                       "雪漏到地面带下方去了")
    }

    /// 宽面板上雪盖照样铺满（坡面随宽度变化，雪盖得跟着走）。
    func testSnowFollowsTheWiderSlope() throws {
        let wide = try ground(width: 700)
        let bare = try ground(snow: false, width: 700)
        XCTAssertGreaterThan(differencePoints(wide, bare), 2000, "宽面板上没有雪")
    }

    // MARK: 出图（人眼复核）

    /// 出图：`.workbuddy/verify/`。
    ///
    /// 「雪压得自不自然」断言管不了 —— 出四张（树冠白天 / 夜里、地面带白天、宽面板）人眼看。
    func testDumpsSnowForHumanReview() throws {
        try dump(try crown().rep, name: "snow-crown-day-20261021.png")
        try dump(try crown(night: true).rep, name: "snow-crown-night-20261021.png")
        try dump(try ground().rep, name: "snow-ground-day-20261021.png")
        try dump(try ground(width: 700).rep, name: "snow-ground-wide-20261021.png")
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
