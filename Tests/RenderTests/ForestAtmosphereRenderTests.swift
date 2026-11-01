import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 森林氛围层的离屏渲染回归（2026-11-01：云跟风 + 地面云影 + 日夜连续光色推移）。
///
/// 三条判据都只能是**渲染**出来的，单测证不了：
/// 1. 云真的画在**画布里** —— 改造前它们被 `.offset(y: -210)` 推到了窗口上边缘之外
///    （天空层铺满整窗，负的 y 就是画外）。色值断言对此一无所知，只有对比
///    「有云 / 无云」两帧才看得见；
/// 2. 地面云影真的落在地上，且「林子完全安静」档下整个消失；
/// 3. 黄昏的山丘**确实**比正午暗（色值方向对了，画出来才对）。
///
/// ⚠️ 判据一律走**墨迹差 / 相对亮度**，不比绝对色值（离屏渲染会过一次色彩空间换算）。
@MainActor
final class ForestAtmosphereRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let canvas = CGSize(width: 420, height: 300)

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

    private func differencePoints(_ lhs: Render, _ rhs: Render, in rect: CGRect? = nil) -> Int {
        guard let a = lhs.rep.bitmapData, let b = rhs.rep.bitmapData else { return 0 }
        let width = lhs.rep.pixelsWide
        let height = lhs.rep.pixelsHigh
        let scale = lhs.scale
        let columns: Range<Int>
        let rows: Range<Int>
        if let rect {
            columns = Int(rect.minX * scale)..<min(Int(rect.maxX * scale), width)
            rows = Int(rect.minY * scale)..<min(Int(rect.maxY * scale), height)
        } else {
            columns = 0..<width
            rows = 0..<height
        }
        var count = 0
        for y in rows {
            for x in columns {
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

    /// 某块区域的平均亮度（0…1）。只用来**比较两帧**，不当绝对色值用。
    private func meanBrightness(_ render: Render, in rect: CGRect) -> Double {
        guard let data = render.rep.bitmapData else { return 0 }
        let width = render.rep.pixelsWide
        let height = render.rep.pixelsHigh
        let scale = render.scale
        let columns = Int(rect.minX * scale)..<min(Int(rect.maxX * scale), width)
        let rows = Int(rect.minY * scale)..<min(Int(rect.maxY * scale), height)
        guard !columns.isEmpty, !rows.isEmpty else { return 0 }
        var total = 0.0
        var count = 0
        for y in rows {
            for x in columns {
                let o = (y * width + x) * 4
                total += (Double(data[o]) + Double(data[o + 1]) + Double(data[o + 2])) / 3
                count += 1
            }
        }
        return count > 0 ? total / Double(count) / 255 : 0
    }

    // MARK: - 装置

    private func sky(hourProgress: Double? = nil, moment: ForestMoment? = nil,
                     still: Bool = false) throws -> Render {
        // ⚠️ `moment` 与 `hourProgress` 各管一层：时刻档位决定**天空**（`momentSkyHex`），
        // 精确时刻决定**插画的光**。出图时两者要一起给，否则会渲出「橘色的山 + 正午的蓝天空」
        // 这种应用里根本不会出现的组合。
        let theme = ForestTheme(palette: .day, moment: moment, hourProgress: hourProgress)
        return try makeHost(
            ForestSky(theme: theme, showsCelestial: false, ambientStill: still)
                // 关掉动画与减动态效果的干扰：这一层只在**静态帧**上比
                .environment(\.appMotion, AppMotionDescriptor(reduceMotion: false,
                                                              reduceTransparency: true))
                .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
    }

    private func shadows(still: Bool = false) throws -> Render {
        try makeHost(
            ZStack {
                // 草坡的近似底色（不读主题：要的是一块稳定的底，好让墨迹差说明问题）
                Color(hex: 0x3F9E67)
                ForestCloudShadows(theme: ForestTheme(palette: .day), still: still)
            }
            .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
    }

    private func plainGround() throws -> Render {
        try makeHost(Color(hex: 0x3F9E67).frame(width: canvas.width, height: canvas.height), size: canvas)
    }

    // MARK: - ① 云

    /// 云真的画在画布里：有云 / 无云两帧必须有可观差异。
    ///
    /// 反证：把 `Clouds` 的云改回 `.offset(y: -210)`（推到窗口上边缘之外）→ 两帧全同 → 红。
    func testCloudsActuallyLandInsideTheCanvas() throws {
        let withClouds = try sky()
        let withoutClouds = try sky(still: true)
        XCTAssertGreaterThan(differencePoints(withClouds, withoutClouds), 1500,
                             "天上的云不见了（两帧几乎一样）")
    }

    /// 云在**上半部**，不在画布顶上那条缝里。
    ///
    /// 改造前的坐标是「顶沿再往上 210pt」，云整个在画外；改后是 12%–30% 的画幅高度。
    /// 判据取最上面 6% —— 那里只该有天空渐变，不该有云的实心块。
    ///
    /// 反证：把 `Clouds.base` 的 y 比例改成 0.02 → 红。
    func testCloudsSitBelowTheTopEdge() throws {
        let withClouds = try sky()
        let withoutClouds = try sky(still: true)
        let top = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height * 0.06)
        XCTAssertEqual(differencePoints(withClouds, withoutClouds, in: top), 0,
                       "云贴到窗口上边缘了")
        let upper = CGRect(x: 0, y: canvas.height * 0.06,
                           width: canvas.width, height: canvas.height * 0.30)
        XCTAssertGreaterThan(differencePoints(withClouds, withoutClouds, in: upper), 800,
                             "上半部没有云")
    }

    // MARK: - ② 地面云影

    /// 云影落在草地上（画得出来）。
    ///
    /// 反证：`ForestCloudShadows` 里把 `strength` 设成 0 → 红。
    func testCloudShadowsDarkenTheGround() throws {
        let withShadow = try shadows()
        let bare = try plainGround()
        XCTAssertGreaterThan(differencePoints(withShadow, bare), 400, "草地上没有云影")
        // 方向也要对：云影是**压暗**，不是把草地照亮。
        XCTAssertLessThan(meanBrightness(withShadow, in: CGRect(x: 0, y: 0,
                                                                width: canvas.width,
                                                                height: canvas.height)),
                          meanBrightness(bare, in: CGRect(x: 0, y: 0,
                                                          width: canvas.width,
                                                          height: canvas.height)),
                          "云影把草地照亮了")
    }

    /// 「林子完全安静」档（连点天空 5 次）下云影一并收起 —— 与云收起来是同一句承诺。
    ///
    /// 反证：把 `if still { EmptyView() }` 去掉 → 红。
    func testCloudShadowsDisappearInTheStillMode() throws {
        XCTAssertEqual(differencePoints(try shadows(still: true), try plainGround()), 0,
                       "林子安静了，云影还留在地上")
    }

    /// 云影是静态确定的（没有风钟时停在初相位置）：渲染两遍逐像素一致。
    func testCloudShadowsAreDeterministicWithoutAWindClock() throws {
        XCTAssertEqual(differencePoints(try shadows(), try shadows()), 0)
    }

    // MARK: - ③ 日夜连续光色推移

    /// 黄昏的山丘**画出来**确实比正午暗（色值方向对了，像素也得对）。
    ///
    /// 判据取山丘那一条带（画布底部 30%）：那里只有山，没有天空与云。
    ///
    /// 反证：`seasonal(...)` 里去掉 `lit(...)`（回到「只有日夜二值」）→ 两帧相同 → 红。
    func testDuskHillsRenderDarkerThanNoon() throws {
        let noon = try sky(hourProgress: 12)
        let dusk = try sky(hourProgress: 19)
        let hills = CGRect(x: 0, y: canvas.height * 0.70,
                           width: canvas.width, height: canvas.height * 0.30)
        // 两帧必须真的不同（不只是同一张图重渲染）
        XCTAssertGreaterThan(differencePoints(noon, dusk, in: hills), 2000,
                             "黄昏的山丘与正午一模一样")
        XCTAssertLessThan(meanBrightness(dusk, in: hills), meanBrightness(noon, in: hills),
                          "黄昏的山丘比正午还亮")
    }

    // MARK: - 出图（人眼复核）

    func testDumpsAtmosphereFramesForHumanReview() throws {
        try dump(try sky().rep, name: "sky-clouds-day-20261101.png")
        try dump(try sky(hourProgress: 19, moment: .dusk).rep, name: "sky-clouds-dusk-20261101.png")
        try dump(try sky(hourProgress: 6, moment: .dawn).rep, name: "sky-clouds-dawn-20261101.png")
        try dump(try shadows().rep, name: "ground-cloud-shadows-20261101.png")
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
