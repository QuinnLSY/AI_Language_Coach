import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 打卡徽章悬浮卡的**离屏渲染**回归（2026-09-24 报障：点过徽章之后原生
/// `.help` 气泡不再弹出）。悬浮说明已改成 `.onHover` 驱动的自绘卡，
/// 这里钉用户眼睛能看到的那件事：悬浮卡真的画在徽章**下方**、且有墨。
///
/// ⚠️ hover 路径离屏搭不出来（合成事件会崩测试进程）—— 出图走
/// `previewShowsTip` 测试钩子直接把卡点亮（见 StreakBadgeView）。
/// ⚠️ 判据用**墨量**不比色值（离屏过色彩空间换算）。
@MainActor
final class StreakBadgeTipRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 300, height: 140)

    private func render(showsTip: Bool) throws -> NSBitmapImageRep {
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = saved }

        let badge = StreakBadgeView(
            badge: TodayPanel.StreakBadge(days: 14, isAtRisk: true),
            previewShowsTip: showsTip
        )
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(
            rootView: AnyView(
                badge.forestTheme(theme)
                    .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                    .clipped()
            )
        )
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 一块扫描带里的墨像素数（背景取图角落采样，不写死色值）。
    private func inkPixels(_ rep: NSBitmapImageRep, rows: Range<Int>) -> Int {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard let base = rep.bitmapData else { return 0 }
        let scale = Double(height) / Double(canvas.height)
        let sample = (Int(2 * scale) * width + Int(2 * scale)) * 4
        let background = (r: Int(base[sample]), g: Int(base[sample + 1]), b: Int(base[sample + 2]))
        var count = 0
        for y in rows {
            let row = min(Int(Double(y) * scale), height - 1)
            for x in 0..<width {
                let offset = (row * width + x) * 4
                let r = Int(base[offset]), g = Int(base[offset + 1]), b = Int(base[offset + 2])
                if abs(r - background.r) > 8 || abs(g - background.g) > 8 || abs(b - background.b) > 8 {
                    count += 1
                }
            }
        }
        return count
    }

    /// 悬浮卡画在徽章下方：徽章胶囊本身高约 21pt，悬浮卡从 ≈27pt 往下铺 ——
    /// 扫描带取 45pt 以下，那里**只有悬浮卡**可能有墨。
    func testTipCardDrawsBelowTheBadge() throws {
        let plain = try render(showsTip: false)
        let withTip = try render(showsTip: true)
        let rows = 45..<Int(canvas.height) - 5
        let plainInk = inkPixels(plain, rows: rows)
        let tipInk = inkPixels(withTip, rows: rows)

        XCTAssertEqual(plainInk, 0, "没悬浮时徽章下方不该有任何墨（实测 \(plainInk)）")
        XCTAssertGreaterThan(
            tipInk, 400,
            "悬浮卡必须真的画出来（下方墨像素 \(tipInk)）—— 0 或接近 0 说明卡没挂上"
        )
    }
}
