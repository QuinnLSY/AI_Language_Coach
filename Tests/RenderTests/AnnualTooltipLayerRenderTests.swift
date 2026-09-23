@testable import AppUI
import AIDomain
import SwiftUI
import XCTest

/// 悬停浮卡二轮（#5 后续）的两条渲染回归。
///
/// ① **z 序**：浮卡必须悬浮在整卡最上方 —— 旧实现把浮卡挂在热图层，
/// footer/footnote 是更晚的兄弟节点会画在浮卡头上（报障截图里
/// 「累计 27 小时…」一行字压在浮卡上）。修法：浮卡挂整卡层 + 落点钳整卡。
/// 离屏驱动不了鼠标，用 `previewFocus` 注入焦点出图。
///
/// 判据（遮挡的物理含义）：基帧（无浮卡）里的**深色文字像素**，在浮卡出现后
/// 变成了**浅色浮卡底** —— 说明文字被浮卡盖住了。若浮卡被压在文字下
/// （旧 bug），文字上下两帧都是深色 → 计数 ≈ 0。浮卡自己的文字不会混进来：
/// 它所在处基帧多半没有文字（基帧浅色 → 不满足「基帧深色」）。
///
/// ② **拖拽感**：跟随层的目标点变化时用弹簧动画逼近，不许瞬移。
/// 中途帧抓法与 `RecordsDisclosureRenderTests` 同款 —— 状态变更由组件
/// 自己的 `withAnimation` 建事务，出图前不做任何等待。
@MainActor
final class AnnualTooltipLayerRenderTests: XCTestCase {

    private var window: NSWindow?

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private let cardWidth: CGFloat = 820

    // MARK: - 造数据

    /// 全空网格：每个格子都在（今天那格 intensity == .none），
    /// 明细只有「日期 + 没有练习」两行 —— 浮卡矮，不会被翻到鼠标上方去。
    private var emptyRecap: AnnualRecap { AnnualRecap.empty(now: now, goalMinutes: 15) }

    private var today: Date {
        emptyRecap.weeks.flatMap { $0 }.compactMap { $0 }.last!.day
    }

    // MARK: - ① z 序：浮卡盖在 footer/footnote 之上

    private func renderCard(previewFocus: AnnualRecapCard.Focus?) async throws -> NSBitmapImageRep {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let content = AnyView(
            AnnualRecapCard(recap: emptyRecap, previewFocus: previewFocus)
                .forestTheme(theme)
                .frame(width: cardWidth)
                .background(Color(hex: 0xE9EFE4))
        )
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 300)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        // 热图 frame 经 preference 传上来 —— ⚠️ 必须**让出主线程**它才会落地
        // （Thread.sleep 阻塞主线程的话 onPreferenceChange 永远不来，实测坐标差 30pt）。
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let size = CGSize(width: cardWidth, height: max(80, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func rgba(_ rep: NSBitmapImageRep) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let out = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(out.bitmapData)
        return (Array(UnsafeBufferPointer(start: data, count: width * height * 4)), width, height)
    }

    /// 卡下半部（footer/footnote 所在带）里的深色文字像素数。
    private func darkInkCount(_ rep: NSBitmapImageRep) throws -> Int {
        let image = try rgba(rep)
        let scale = Double(image.height) / 300.0
        var count = 0
        // 热图下缘 ≈ 卡高一半往上一点，footer/footnote 在下半部；全带宽扫描。
        for y in Int(150 * scale)..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                let r = Int(image.bytes[offset]), g = Int(image.bytes[offset + 1]), b = Int(image.bytes[offset + 2])
                if max(r, g, b) < 150 { count += 1 }
            }
        }
        return count
    }

    /// 「基帧深色文字、出卡后变浅」的像素数 —— 文字被浮卡盖住的物理证据。
    private func coveredInkCount(baseline: NSBitmapImageRep, withTooltip: NSBitmapImageRep) throws -> Int {
        let left = try rgba(baseline), right = try rgba(withTooltip)
        let scale = Double(left.height) / 300.0
        var count = 0
        for y in Int(150 * scale)..<min(left.height, right.height) {
            for x in 0..<min(left.width, right.width) {
                let offset = (y * left.width + x) * 4
                let base = (
                    r: Int(left.bytes[offset]), g: Int(left.bytes[offset + 1]), b: Int(left.bytes[offset + 2])
                )
                // 基帧深色 = footer/footnote 的文字墨。
                guard max(base.r, base.g, base.b) < 150 else { continue }
                let now = (
                    r: Int(right.bytes[offset]), g: Int(right.bytes[offset + 1]), b: Int(right.bytes[offset + 2])
                )
                // 出卡后变浅 = 被浮卡底盖住了。
                if min(now.r, now.g, now.b) > 190 { count += 1 }
            }
        }
        return count
    }

    func testTooltipFloatsAboveTheFooterText() async throws {
        // 预热
        _ = try await renderCard(previewFocus: nil)

        let baseline = try await renderCard(previewFocus: nil)
        let covered = try await renderCard(
            // previewFocus 的落点按**整卡坐标**解释（见实现的钩子注释）。
            // 卡高 ≈ 220pt：鼠标放 y=140，浮卡（两行高 ≈ 51pt）落在
            // (378, 152)–(468, 203)，正好盖住 footnote 第一行又不会高到触发翻转。
            previewFocus: AnnualRecapCard.Focus(day: today, point: CGPoint(x: 366, y: 140))
        )

        // 夹具自检：下半部确实有 footer/footnote 文字可遮。
        let footerInk = try darkInkCount(baseline)
        XCTAssertGreaterThan(
            footerInk, 300,
            "夹具自检失败：卡下半部没有深色文字（实测 \(footerInk)）—— 几何估算错了，先修夹具"
        )

        let erased = try coveredInkCount(baseline: baseline, withTooltip: covered)
        XCTAssertGreaterThan(
            erased, 15,
            "浮卡没有盖住 footer/footnote 文字（被遮墨 \(erased) 像素）—— 浮卡被压在文字下面了"
        )
        try dump(baseline, name: "round5-tooltip-zorder-baseline.png")
        try dump(covered, name: "round5-tooltip-zorder-covered.png")
    }

    // MARK: - ② 拖拽感：目标移动后弹簧逼近，不瞬移

    private static let followerItems = [
        RecapDetailItem(kind: .date, text: "9月15日"),
        RecapDetailItem(kind: .duration, text: "12 分 0 秒"),
        RecapDetailItem(kind: .conversation, text: "4 轮对话"),
    ]

    /// ⚠️ 裸改状态（不包 withAnimation）—— 动画事务必须由被测组件自己创建，
    /// 中途帧的存在性才能归因到组件里的弹簧动画。
    /// ⚠️ 变更延迟 100ms（`.task`）：onAppear 里直接改的话，首帧渲染前状态就变了，
    /// onChange 根本看不到「变化」（实测浮卡直接落在终点，没有动画可抓）。
    private struct FollowerFixture: View {
        @State private var target = CGPoint(x: 40, y: 60)
        var body: some View {
            Rectangle().fill(Color.black)
                // ⚠️ overlay(alignment: .topLeading) 而不是 ZStack：ZStack 会把浮卡
                // 居中，offset 240 直接把它推出 320 宽的画布（实测左缘量不到）。
                .overlay(alignment: .topLeading) {
                    AnnualTooltipFollower(items: AnnualTooltipLayerRenderTests.followerItems, target: target)
                }
                .frame(width: 320, height: 300)
                .task {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    target = CGPoint(x: 240, y: 60)
                }
        }
    }

    /// 浮卡左缘（黑底上第一列亮像素）。offset 就是左缘，阴影会往左拖 ~6pt。
    private func followerLeftEdge(_ rep: NSBitmapImageRep) throws -> CGFloat {
        let image = try rgba(rep)
        let scale = Double(image.height) / 300.0
        for x in 0..<image.width {
            for y in stride(from: Int(60 * scale), to: Int(150 * scale), by: 2) where y < image.height {
                let offset = (y * image.width + x) * 4
                let r = Int(image.bytes[offset]), g = Int(image.bytes[offset + 1]), b = Int(image.bytes[offset + 2])
                if r > 150 && g > 150 && b > 150 {
                    return Double(x) / scale
                }
            }
        }
        return 320
    }

    func testFollowerSpringsTowardTheTargetInsteadOfJumping() async throws {
        _ = try await captureFollower(settled: false)   // 预热
        let midFlight = try await captureFollower(settled: false)
        let settled = try await captureFollower(settled: true)

        let midEdge = try followerLeftEdge(midFlight)
        let settledEdge = try followerLeftEdge(settled)

        // 夹具自检：终态要真到位（target 240 - 阴影余量）。
        XCTAssertGreaterThan(
            settledEdge, 200,
            "夹具自检失败：静止态左缘 \(settledEdge) 没到目标 240 附近 —— 几何错了"
        )
        // 中途帧：弹簧还在路上。瞬移（反证态）会直接 ≈ settledEdge。
        XCTAssertLessThan(
            midEdge, settledEdge - 20,
            "中途帧左缘 \(midEdge) 已到达 \(settledEdge) —— 浮卡是瞬移的，没有拖拽感"
        )
        XCTAssertGreaterThan(midEdge, 30, "中途帧左缘 \(midEdge) 不该还在起点之前")
        try dump(midFlight, name: "round5-tooltip-follower-midflight.png")
        try dump(settled, name: "round5-tooltip-follower-settled.png")
    }

    private func captureFollower(settled: Bool) async throws -> NSBitmapImageRep {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let content = AnyView(
            FollowerFixture()
                .forestTheme(theme)
                .frame(width: 320, height: 300)
        )
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: CGSize(width: 320, height: 300))
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        if settled {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            host.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
        } else {
            // 夹具在 ~100ms 时改目标，这里在 ~200ms 出图 —— 弹簧（response 0.35）
            // 正走在半路上。反证态（瞬移）这一帧就已经在终点了。
            try await Task.sleep(nanoseconds: 200_000_000)
            host.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    // MARK: - 落盘

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
