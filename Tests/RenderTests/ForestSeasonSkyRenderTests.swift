import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 季节天空的离屏渲染回归（2026-10-22，用户报障「背景色始终同一个、不随季节变」）。
///
/// 判据走**区域墨迹差**，不比色值（离屏过色彩空间换算）：
/// - 四季的底色确实是四种（整窗背景跟着季节走）；
/// - 压在**62% 白面板**下面也还看得出区别 —— 这才是用户实际看到的那一层
///   （三栏面板只有 62% 不透明，天空是唯一透出来的底）；
/// - 夜档与季节无关（夜空是同一片天）。
@MainActor
final class ForestSeasonSkyRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let canvas = CGSize(width: 260, height: 180)

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

    /// 一片天；`throughPanel` 为真时再压上主界面那块 62% 白的面板底。
    private func scene(season: ForestSeason, night: Bool = false,
                       throughPanel: Bool = false) throws -> Render {
        // ⚠️ 显式构造：季节是判据的自变量，绝不能让它由「当前月份」推出来
        // （一月永远冬天 → 四帧全同，判据空转还全绿）。
        let themed = ForestTheme(palette: night ? .night : .day,
                                 moment: .noon,
                                 season: season)
        XCTAssertEqual(themed.season, season, "季节没钉住（判据会空转）")
        return try makeHost(
            ZStack {
                LinearGradient(colors: themed.sky, startPoint: .top, endPoint: .bottom)
                if throughPanel {
                    // 与 `levelPanel` 的同一条接线：`state.theme.surface.opacity(0.62)`
                    themed.surface.opacity(0.62)
                }
            }
            .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
    }

    private func differencePoints(_ lhs: Render, _ rhs: Render) -> Int {
        guard let a = lhs.rep.bitmapData, let b = rhs.rep.bitmapData else { return 0 }
        let width = lhs.rep.pixelsWide, height = lhs.rep.pixelsHigh
        let scale = lhs.scale
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
        return Int(Double(count) / (scale * scale))
    }

    /// 四季的底图两两不同（整窗背景跟着季节走）。
    ///
    /// 反证：把 `ForestTheme.sky` 里的 `seasonalSkyWash` 改成 `nil` → 四帧全同 → 红。
    func testFourSeasonsPaintFourDifferentBackgrounds() throws {
        var frames: [ForestSeason: Render] = [:]
        for season in ForestSeason.allCases {
            frames[season] = try scene(season: season)
        }
        let seasons = ForestSeason.allCases
        for i in 0..<seasons.count {
            for j in (i + 1)..<seasons.count {
                let lhs = try XCTUnwrap(frames[seasons[i]])
                let rhs = try XCTUnwrap(frames[seasons[j]])
                XCTAssertGreaterThan(
                    differencePoints(lhs, rhs), 2000,
                    "\(seasons[i]) 与 \(seasons[j]) 的底色几乎一样"
                )
            }
        }
    }

    /// 压上 62% 白面板之后**还看得出区别** —— 用户看到的就是这一层。
    ///
    /// 反证：把 `seasonalSkyWash` 的比例从 0.2~0.34 调到 0.02 → 红
    /// （面板把色温差冲淡到阈值以下）。
    func testTintSurvivesTheTranslucentPanel() throws {
        let winter = try scene(season: .winter, throughPanel: true)
        let summer = try scene(season: .summer, throughPanel: true)
        XCTAssertGreaterThan(differencePoints(winter, summer), 2000,
                             "隔着面板就分不出季节了 —— 背景等于没变")
    }

    /// 夜档与季节无关：同一片夜空。
    ///
    /// 反证：把 `seasonalSkyWash` 里的 `guard !isNight` 删掉 → 红。
    func testNightBackgroundIgnoresTheSeason() throws {
        let winter = try scene(season: .winter, night: true)
        let summer = try scene(season: .summer, night: true)
        XCTAssertEqual(differencePoints(winter, summer), 0, "夜空不该随季节变色")
    }
}
