import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 冬季雪人（#627）的离屏渲染回归。
///
/// 判据走**区域墨迹差**，不比色值：
/// - 三个雪人真的画出来了（同一片雪地，有 / 无雪人必须肉眼可辨）；
/// - 三个人分布在左 / 中 / 右三段（不是挤成一堆）；
/// - 红围巾是画面里唯一的暖色（雪地全冷色，先看见围巾才看见雪人）；
/// - 不越出地面带；夜里看得见；静态帧零抖动。
@MainActor
final class ForestSnowmanRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

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

    private func theme(night: Bool = false) -> ForestTheme {
        let theme = ForestThemeResolver.resolve(
            mode: night ? .night : .day, systemIsDark: false,
            hour: night ? 22 : 12, month: 1,
            followsClock: true, followsSeason: true
        )
        XCTAssertEqual(theme.season, .winter, "一月必须是冬天（否则这一组判据全空转）")
        return theme
    }

    /// 地面带：积雪 + 三个雪人（`snowmen` 为 false 时只出雪地，作对照）。
    private func scene(night: Bool = false, snowmen: Bool = true,
                       clock: ForestWindClock? = nil,
                       width: CGFloat? = nil, margin: CGFloat = 0) throws -> Render {
        let theme = self.theme(night: night)
        let width = width ?? band.width
        let height = band.height
        let qw = (width / 28).rounded() * 28
        let surface: ForestGroundSurface = { x in
            ForestSceneGeometry.hillSurfaceY(x: x, bandWidth: width, bandHeight: height)
        }
        var view = AnyView(
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: theme.sky, startPoint: .top, endPoint: .bottom)
                ZStack(alignment: .topLeading) {
                    Color(red: 0.42, green: 0.50, blue: 0.28)
                    ForestSnowField(theme: theme, groundLine: surface)
                    if snowmen {
                        ForestSnowmen(theme: theme, groundLine: surface, quantizedWidth: qw)
                    }
                }
                .frame(width: width, height: height)
                .offset(y: margin)
            }
            .frame(width: width, height: height + margin * 2)
        )
        if let clock {
            view = AnyView(view.environment(\.forestWind, clock))
        }
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

    /// 图里**暖色**（R 明显大于 B）的点数：红围巾是整片雪地里唯一的暖色。
    ///
    /// ⚠️ 比的是 R 与 B 的**关系**，不是某个具体色值 —— 离线渲染过色彩空间换算，
    /// 钉死 RGB 数字会随显示器配置飘。
    private func warmPoints(_ render: Render, in rect: CGRect? = nil) -> Int {
        guard let data = render.rep.bitmapData else { return 0 }
        let width = render.rep.pixelsWide, height = render.rep.pixelsHigh
        let scale = render.scale
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
                let red = Int(data[o]), green = Int(data[o + 1]), blue = Int(data[o + 2])
                if red - blue > 40, red - green > 30 { count += 1 }
            }
        }
        return Int(Double(count) / (scale * scale))
    }

    // MARK: - 判据

    /// 雪人真的画出来了。
    ///
    /// 反证：把 `ForestSnowmen` 从地面带摘掉 → 红。
    func testSnowmenAreDrawn() throws {
        let withMen = try scene()
        let bare = try scene(snowmen: false)
        XCTAssertGreaterThan(differencePoints(withMen, bare), 800, "雪地上没有雪人")
    }

    /// 三个人**分散**在左 / 中 / 右三段（挤成一堆就读成一个）。
    ///
    /// 反证：把三人的 `lane` 都改成 0.5 → 红（中段一大堆、左右两段近乎 0）。
    func testThreeSnowmenSpreadAcrossTheGlade() throws {
        let withMen = try scene()
        let bare = try scene(snowmen: false)
        let w = band.width
        let thirds: [CGRect] = [
            CGRect(x: 0, y: 0, width: w / 3, height: band.height),
            CGRect(x: w / 3, y: 0, width: w / 3, height: band.height),
            CGRect(x: w * 2 / 3, y: 0, width: w / 3, height: band.height),
        ]
        for (index, third) in thirds.enumerated() {
            XCTAssertGreaterThan(differencePoints(withMen, bare, in: third), 150,
                                 "第 \(index + 1) 段里没有雪人")
        }
    }

    /// 红围巾是画面里唯一的暖色：雪地里别的都是冷的。
    ///
    /// 反证：把围巾换成 `theme.snowShade` → 红。
    func testScarvesAreTheOnlyWarmSpot() throws {
        let withMen = try scene()
        let bare = try scene(snowmen: false)
        XCTAssertLessThan(warmPoints(bare), 40, "雪地里本来就有暖色（判据要换度量）")
        XCTAssertGreaterThan(warmPoints(withMen), 120, "雪人身上没有红围巾")
    }

    /// 不越出地面带（带子上下的天空一个点都不许变）。
    ///
    /// 反证：把 `SnowmanLayout.height` 乘 4 → 红。
    func testSnowmenNeverLeaveTheBand() throws {
        let margin: CGFloat = 30
        let withMen = try scene(margin: margin)
        let bare = try scene(snowmen: false, margin: margin)
        let above = CGRect(x: 0, y: 0, width: band.width, height: margin - 1)
        let below = CGRect(x: 0, y: margin + band.height + 1,
                           width: band.width, height: margin - 1)
        XCTAssertEqual(differencePoints(withMen, bare, in: above), 0,
                       "雪人戳到地面带上方的天空里去了")
        XCTAssertEqual(differencePoints(withMen, bare, in: below), 0,
                       "雪人漏到地面带下方去了")
    }

    /// 夜里的雪人看得见（雪人在夜里是月光白，不是不见了）。
    func testNightSnowmenAreVisible() throws {
        let withMen = try scene(night: true)
        let bare = try scene(night: true, snowmen: false)
        XCTAssertGreaterThan(differencePoints(withMen, bare), 500, "夜里的雪人看不见")
    }

    /// 静态帧零抖动。
    func testStaticGladeIsDeterministic() throws {
        XCTAssertEqual(differencePoints(try scene(), try scene()), 0, "静态帧不许抖")
    }

    /// 风只吹得动围巾的尾角：雪人自己是压实的雪，风再大也掰不动它。
    ///
    /// ⚠️ 逐個雪人判，不能把三人的区域 `union` 成一个大框：并集会盖住中间雪人的
    /// 围巾尾（它会动）→ 「本体不许动」恒有 22 点差（实测）。
    ///
    /// 反证：把 `tailGain` 改成 0 → 红在第一条；把雪人本体也叠上风位移 → 红在第二条。
    func testWindOnlyMovesTheScarfTail() throws {
        let clock = ForestWindClock()
        clock.advance(to: Date(), blowing: true)
        let calm = try scene(clock: clock)
        clock.advance(to: Date().addingTimeInterval(1.6), blowing: true)
        let gusty = try scene(clock: clock)

        let qw = (band.width / 28).rounded() * 28
        let bandWidth = band.width
        let bandHeight = band.height
        let surface: ForestGroundSurface = { x in
            ForestSceneGeometry.hillSurfaceY(x: x, bandWidth: bandWidth, bandHeight: bandHeight)
        }
        var swayed = 0
        for snowman in SnowmanLayout.winterGlade {
            let box = SnowmanLayout.frame(
                snowman, width: bandWidth, quantizedWidth: qw, groundLine: surface)
            // 尾角绕自己的顶转 ±20° 左右，底部会横向扫出几 pt —— 区域留出余量
            let tail = SnowmanLayout.scarfTailRect(in: box).insetBy(dx: -10, dy: -6)
            let crown = SnowmanLayout.hatRect(in: box)
                .union(SnowmanLayout.headRect(in: box))
            swayed += differencePoints(calm, gusty, in: tail)
            XCTAssertEqual(differencePoints(calm, gusty, in: crown), 0,
                           "雪人本体被风吹动了（它是压实的雪，掰不动）")
        }
        XCTAssertGreaterThan(swayed, 40, "风吹不动围巾的尾角（围巾是画死的）")
    }

    // MARK: - 出图（人眼复核）

    /// 出图：`.workbuddy/verify/`。
    ///
    /// 「雪人堆得可不可爱」断言管不了 —— 出三张（白天 / 夜里 / 宽面板）人眼看。
    func testDumpsSnowmenForHumanReview() throws {
        try dump(try scene().rep, name: "snowman-day-20261021.png")
        try dump(try scene(night: true).rep, name: "snowman-night-20261021.png")
        try dump(try scene(width: 560).rep, name: "snowman-wide-20261021.png")
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
