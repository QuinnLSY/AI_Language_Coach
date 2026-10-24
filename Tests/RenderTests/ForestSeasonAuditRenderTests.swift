import AppKit
import AIDomain
@testable import AppUI
import SwiftUI
import XCTest

/// 四季装饰的**墨量审计**（一门一档，四季同一把尺）。
///
/// ⚠️ 2026-10-21 修正过一次**判据污染**，改之前和改之后的数字不能比：
/// 老办法是「整条 `ForestGroundBand` 按季渲染、与无季基线比 diff」，可草坡 / 草叶 /
/// 灌木本身也按季换色 —— 夏天那一档**恰好等于**无季原色（`seasonal()` 里
/// `case .summer: chosen = day`），于是它整片坡面的 diff 是 0，只有光斑那一点点
/// 被读到（2528）；春 / 秋 / 冬则连坡面换色的那两万多个像素一起算进来
/// （19377 / 31836）。那句「夏天只有春天的八分之一」**是尺子坏了，不是夏天空**。
///
/// 现在改成**只渲染各季的装饰组件**（压在该季自己的 `hillNear` 上），
/// 与同一块空白底比 —— 量到的就是装饰本身画了多少，四季同一把尺。
@MainActor
final class ForestSeasonAuditRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 420, height: 180)
    private let groundY: CGFloat = 150
    private let quantizedWidth: CGFloat = 420

    private func makeHost(_ view: some View, size: CGSize) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func theme(season: ForestSeason?, isNight: Bool) -> ForestTheme {
        let base = ForestThemeResolver.resolve(
            mode: isNight ? .night : .day, systemIsDark: false,
            hour: isNight ? 22 : 12, month: 3,
            followsClock: false, followsSeason: false
        )
        return ForestTheme(palette: base.palette, moment: base.moment,
                           season: season, weather: nil)
    }

    /// 某一季的**装饰组件**（不含草坡 / 草叶 / 灌木那些按季换色的底子）。
    @ViewBuilder
    private func decorations(season: ForestSeason, theme: ForestTheme) -> some View {
        // ⚠️ 先落到局部常量再进闭包：`ForestGroundSurface` 是 `@Sendable`，
        // 直接在闭包里写 `self.groundY` 会捕获整个（非 Sendable 的）测试用例。
        let groundY = self.groundY
        let groundLine: ForestGroundSurface = { _ in groundY }
        switch season {
        case .spring:
            ForestDandelions(theme: theme, groundLine: groundLine)
            ForestButterflies(theme: theme, groundLine: groundLine)
        case .summer:
            ForestDapples(theme: theme, groundLine: groundLine)
            ForestFireflies(theme: theme, groundLine: groundLine)
            ForestDragonflies(theme: theme, groundLine: groundLine)
        case .autumn:
            ForestOrchard(theme: theme, groundLine: groundLine,
                          quantizedWidth: quantizedWidth)
            ForestLeafPiles(theme: theme, groundLine: groundLine,
                            quantizedWidth: quantizedWidth)
            ForestPumpkins(theme: theme, groundLine: groundLine,
                           quantizedWidth: quantizedWidth)
        case .winter:
            ForestSnowField(theme: theme, groundLine: groundLine)
            ForestSnowmen(theme: theme, groundLine: groundLine,
                          quantizedWidth: quantizedWidth)
        }
    }

    /// 一块底 + （可选的）该季装饰。
    private func scene(season: ForestSeason, isNight: Bool, withDecorations: Bool) throws -> NSBitmapImageRep {
        let theme = self.theme(season: season, isNight: isNight)
        return try makeHost(
            ZStack {
                theme.hillNear
                if withDecorations { decorations(season: season, theme: theme) }
            }
            .environment(\.appMotion, AppMotionDescriptor(reduceMotion: true, reduceTransparency: true))
            .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
    }

    /// 两帧不同像素数（换算回点）。
    private func differencePoints(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        guard let a = lhs.bitmapData, let b = rhs.bitmapData else { return 0 }
        let width = min(lhs.pixelsWide, rhs.pixelsWide)
        let height = min(lhs.pixelsHigh, rhs.pixelsHigh)
        let scale = CGFloat(lhs.pixelsHigh) / max(canvas.height, 1)
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * lhs.pixelsWide + x) * 4
                let p = (y * rhs.pixelsWide + x) * 4
                if abs(Int(a[o]) - Int(b[p])) > 8
                    || abs(Int(a[o + 1]) - Int(b[p + 1])) > 8
                    || abs(Int(a[o + 2]) - Int(b[p + 2])) > 8 {
                    count += 1
                }
            }
        }
        return Int(Double(count) / (scale * scale))
    }

    /// 四季装饰**都在画东西**：白天与夜里各自的墨量都不许是空的。
    ///
    /// 这就是当初那份审计钉下来的东西 —— 「某一个季节其实只有一点点装饰」看不见，
    /// 因为每个组件自己的测试都是绿的，而画面上那一季就是空的。
    ///
    /// 门槛 200 点（画布 420×180 = 75600 点）：实测最紧的一档是夏夜 484，
    /// 留了两倍余量；再往上抬就会开始误报（春夜 661 之后就是它）。
    ///
    /// 反证：把某一季的装饰从 `decorations(season:)` 里删掉（或让它的夜里判据
    /// 恒假）→ 那条季节 / 那个光线红。
    func testSeasonDecorationsActuallyDrawInBothLights() throws {
        // 实测（2026-10-21，同一把尺）：春 690/661，夏 3133/484，
        // 秋 15274/15051，冬 75599/75600（day/night）。
        for night in [false, true] {
            for season in [ForestSeason.spring, .summer, .autumn, .winter] {
                let withDecorations = try scene(season: season, isNight: night, withDecorations: true)
                let bare = try scene(season: season, isNight: night, withDecorations: false)
                let ink = differencePoints(withDecorations, bare)
                XCTAssertGreaterThan(ink, 200,
                                     "\(season) 的装饰在\(night ? "夜里" : "白天")画了 \(ink) 点（整季空窗？）")
            }
        }
    }
}
