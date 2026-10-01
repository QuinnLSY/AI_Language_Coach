import AIDomain
import AIInfrastructure
import AIServices
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 矮窗下侧栏**不得被压扁**（#417 窄窗降级 + Xcode 27 SDK 回归）。
///
/// 2026-10-01 换 Xcode 27 SDK 重编后发现：侧栏自然高度（≈744pt）长过了最小窗口的
/// 内容区（720 窗 ≈690pt），SwiftUI 放不下时把 64pt 头栏**压扁** —— 徽章/标题贴到
/// 窗口顶边。修复是给 navList 套 ScrollView（矮窗时导航自己滚）。
///
/// 本用例钉的就是压扁症状：在最矮窗口高度下出图，
/// ①头栏下的**整宽分隔线**必须还在 55pt 之下（压扁时它会上移到 ~34）；
/// ②打卡徽章的顶边不得贴到窗口顶（压扁时 ~2pt，健康时 ~22pt）。
///
/// ⚠️ 画布高取 `AppLayoutMetrics.minWindowHeight` 本身 —— 阈值改了用例跟着改，
/// 不会出现「Metrics 说 640、测试还在量 720」的两张皮。
@MainActor
final class SidebarShortHeightRenderTests: XCTestCase {

    private var window: NSWindow?

    private func render() throws -> NSBitmapImageRep {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("sidebar-short-\(UUID().uuidString).json")
        )
        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        // 徽章只在连续 ≥1 天时出现：直接给快照。
        var snapshot = ProgressSnapshot.empty()
        snapshot.streakDays = 15
        state.progressSnapshot = snapshot

        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let height = AppLayoutMetrics.minWindowHeight
        let host = NSHostingView(rootView: AnyView(
            AppSidebar(state: state)
                .forestTheme(theme)
                .frame(width: AppSidebar.expandedWidth, height: height)
        ))
        host.frame = NSRect(origin: .zero, size: CGSize(width: AppSidebar.expandedWidth, height: height))
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
        // 出图便于人眼复核（量墨判据靠不住时先看图）。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: directory.appendingPathComponent("sidebar-short-height.png"))
        }
        return rep
    }

    /// 某一行里「完全不透明」像素的占比。
    ///
    /// ⚠️ 为什么不看 RGB：`cacheDisplay` **不往白底合成**，侧栏底色是
    /// `surfaceAlt.opacity(0.94)` → 裸位图里 RGB 是被透明度压暗的 (206,209,203)，
    /// PNG 导出（合成后）才是 (243,247,240)。按「与某个底色的距离」量必然全行误标
    /// （实测 90/90 全中，判据恒 0）。不透明度才是布局稳定的信号：
    /// 分隔线/条目底色 a=255，半透明底 a≈216。
    private func opaqueRatio(_ rep: NSBitmapImageRep, yPt: Int, xRange: ClosedRange<Int>) -> Double {
        let height = rep.pixelsHigh
        let scale = Double(height) / Double(AppLayoutMetrics.minWindowHeight)
        guard let data = rep.bitmapData else { return 0 }
        let width = rep.pixelsWide
        let y = min(Int(Double(yPt) * scale), height - 1)
        var opaque = 0
        var sampled = 0
        stride(from: xRange.lowerBound, to: xRange.upperBound, by: 2).forEach { xPt in
            let x = min(Int(Double(xPt) * scale), width - 1)
            let o = (y * width + x) * 4
            sampled += 1
            if Int(data[o + 3]) >= 250 { opaque += 1 }
        }
        return Double(opaque) / Double(max(sampled, 1))
    }

    /// 头栏下的第一条「整宽不透明横线」（分隔线）落在哪一行。
    private func firstFullWidthLine(_ rep: NSBitmapImageRep) -> Int? {
        for yPt in 0..<120 where opaqueRatio(rep, yPt: yPt, xRange: 20...200) > 0.7 {
            return yPt
        }
        return nil
    }

    /// 打卡徽章（红色系）最顶上那一行的 y。
    private func badgeTop(_ rep: NSBitmapImageRep) -> Int? {
        let height = rep.pixelsHigh
        let scale = Double(height) / Double(AppLayoutMetrics.minWindowHeight)
        let width = rep.pixelsWide
        guard let data = rep.bitmapData else { return nil }
        for y in 0..<Int(60 * scale) {
            var stride = 300
            while stride < min(width, 216 * Int(scale)) {
                let o = (y * width + stride) * 4
                let (r, g, b) = (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
                if r - g > 40 && r - b > 40 { return Int(Double(y) / scale) }
                stride += 2
            }
        }
        return nil
    }

    // MARK: - 用例

    ///
    /// 反证：撤掉 navList 的 ScrollView → 头栏被压扁，分隔线上移到 ~34、徽章贴顶，
    /// 两条判据同时精确红。
    func testSidebarKeepsItsHeaderAtShortestWindowHeight() throws {
        let rep = try render()

        let divider = try XCTUnwrap(firstFullWidthLine(rep), "找不到头栏下的整宽分隔线：夹具坏了")
        XCTAssertGreaterThanOrEqual(
            divider, 55,
            "头栏分隔线跑到了 y=\(divider)（健康时应为 ~64）：头栏被压扁了 —— "
                + "navList 缺 ScrollView，矮窗下整个 VStack 放不下被 SwiftUI 压缩"
        )

        let badge = try XCTUnwrap(badgeTop(rep), "没找到打卡徽章（红系墨）：夹具坏了")
        XCTAssertGreaterThanOrEqual(
            badge, 12,
            "徽章顶边 y=\(badge)（健康时应为 ~22）：贴到窗口顶了 —— 头栏被压扁"
        )
    }
}
