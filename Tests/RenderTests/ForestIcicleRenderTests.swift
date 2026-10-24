import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 枝下沿冰柱（#628）的离屏渲染回归。
///
/// 判据走**区域墨迹差**，不比色值：
/// - 同一棵冬天的树，画冰柱 / 不画冰柱必须肉眼可辨；
/// - 夏天一个点都不许有（冰柱是冬装，夏天出现就是穿越）；
/// - 夜里的冰柱看得见（夜里压暗，但不许暗到没了）；
/// - 静态帧零抖动。
@MainActor
final class ForestIcicleRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let crownSize = CGSize(width: 380, height: 300)

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

    /// 一月 = 冬天；`month` 传别的就是别的季节（反证「夏天不许有冰柱」用七月）。
    private func theme(night: Bool, month: Int) -> ForestTheme {
        let theme = ForestThemeResolver.resolve(
            mode: night ? .night : .day, systemIsDark: false,
            hour: night ? 22 : 12, month: month,
            followsClock: true, followsSeason: true
        )
        return theme
    }

    /// 树冠（带天空底）：`icicles` 为 false 时出「同一棵树、没有冰柱」的对照图。
    private func crown(night: Bool = false, month: Int = 1,
                       icicles: Bool = true) throws -> Render {
        let theme = self.theme(night: night, month: month)
        if month == 1 {
            XCTAssertEqual(theme.season, .winter, "一月必须是冬天（否则这组判据全空转）")
        }
        let view = ZStack {
            LinearGradient(colors: theme.sky, startPoint: .top, endPoint: .bottom)
            TreeCrown(theme: theme, drawsIcicles: icicles)
        }
        .frame(width: crownSize.width, height: crownSize.height)
        return try makeHost(
            view.environment(\.appMotion, AppMotionDescriptor(reduceMotion: true,
                                                              reduceTransparency: true)),
            size: crownSize
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

    // MARK: - 判据

    /// 冰柱真的画出来了（同一棵树，有 / 无冰柱必须肉眼可辨）。
    ///
    /// 反证：把 `IcicleLayout.icicles` 改成恒返回 `[]` → 红。
    func testIciclesAreDrawn() throws {
        let withIcicles = try crown()
        let bare = try crown(icicles: false)
        XCTAssertGreaterThan(differencePoints(withIcicles, bare), 400,
                             "冬天的树冠上一根冰柱都没有")
    }

    /// 夏天一个点都不许有（冰柱是冬装）。
    ///
    /// 反证：把 `TreeCrown` 里的 `theme.season == .winter` 判断删掉 → 红。
    func testNoIciclesOutsideWinter() throws {
        let summer = try crown(month: 7, icicles: true)
        let summerBare = try crown(month: 7, icicles: false)
        XCTAssertEqual(differencePoints(summer, summerBare), 0,
                       "七月的树冠上出现了冰柱")
    }

    /// 夜里的冰柱看得见（夜里压暗，但不许暗到没了）。
    func testNightIciclesAreVisible() throws {
        let withIcicles = try crown(night: true)
        let bare = try crown(night: true, icicles: false)
        XCTAssertGreaterThan(differencePoints(withIcicles, bare), 250,
                             "夜里的冰柱看不见")
    }

    /// 静态帧零抖动（冰柱的种子是几何混出来的，不许随帧变）。
    func testStaticFrameIsDeterministic() throws {
        XCTAssertEqual(differencePoints(try crown(), try crown()), 0, "静态帧不许抖")
    }

    // MARK: - 出图（人眼复核）

    /// 出图：`.workbuddy/verify/`。「冰柱挂得可不可爱」断言管不了 —— 人眼看。
    func testDumpsIciclesForHumanReview() throws {
        try dump(try crown().rep, name: "icicle-day-20261021.png")
        try dump(try crown(night: true).rep, name: "icicle-night-20261021.png")
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
