@testable import AppUI
import AIDomain
import AppKit
import SwiftUI
import XCTest

/// 年度记录悬停浮卡的**列让开**回归（2026-09-24 报障）。
///
/// 报障原文：浮卡挡住了要看的那一天的方格以及同一列上下的其他格子，
/// 「对查看同列其他方格造成不便」。
///
/// 判据（遮挡的物理含义）：同一个焦点（同一格、同一圈焦点环），鼠标只在格子里
/// 挪一下位置，被查看那一列就应当**逐像素不变** —— 浮卡压根没碰到它。
/// 老实现里浮卡跟着鼠标走（鼠标 + 12pt），鼠标落在格子偏左时它的左缘正切在
/// 同一格里，整条列也被顺带盖住 → 那一列必变。
///
/// 为什么拿「两帧对比」而不是跟「无浮卡」比：浮卡出现的同时还会给被查看那格描一圈
/// 焦点环，无浮卡的基准帧少了这圈环，比对区天然有差。两帧都带同一个焦点、
/// 浮卡又都被赶到同一侧，环互相抵消，剩下的差只可能来自浮卡自己。
///
/// ⚠️ hover 离屏搭不出来（合成事件会崩测试进程）—— 焦点走 `previewFocus` 钩子注入。
/// `previewFocus` 的落点与真实 hover 用**同一套坐标（热图坐标）**：卡片自己按已知
/// 布局加偏移（`heatmapFrame(in:)`）—— 不许再退回 preference，它在这一层根本到不了
/// （见 `AnnualRecapCard` 里那段说明）。
@MainActor
final class AnnualTooltipColumnAvoidanceRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 400
    private let columnCount = 12
    private let focusedColumn = 5
    private let focusedRow = 3
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    // MARK: - 造数据

    /// 12 周的网格（真机是 53 周）。**格子必须够大**（这里 ≈21pt）：53 周的格子在
    /// 真机窄栏里只有 9pt 宽，老落点「鼠标 + 12」切不进去，报障就复现不出来。
    private func makeRecap() -> AnnualRecap {
        var recap = AnnualRecap.empty(now: now, goalMinutes: 15)
        let template = recap.weeks.flatMap { $0 }.compactMap { $0 }.last!
        let base = Calendar.current.startOfDay(for: now)
        recap.weeks = (0..<columnCount).map { column in
            (0..<7).map { row -> AnnualRecap.Cell? in
                var cell = template
                let day = Calendar.current.date(
                    byAdding: .day,
                    value: -(columnCount - 1 - column) * 7 + row,
                    to: base
                )!
                cell.day = day
                cell.isToday = false
                cell.intensity = .none
                cell.goalReached = false
                cell.tasksDone = 0
                cell.activity = DailyActivity(day: day)
                return cell
            }
        }
        recap.months = []
        recap.rowLabels = ["日", nil, "二", nil, "四", nil, nil]
        return recap
    }

    private func focusedDay(_ recap: AnnualRecap) -> Date {
        recap.weeks[focusedColumn][focusedRow]!.day
    }

    // MARK: - 几何

    /// 热图左上角在整卡里的位置：卡内边距 16 + 表头固定高 18 + 段落间距 10。
    ///
    /// 与 `AnnualRecapCard.Layout` 对齐。**这个数算错了用例不会静默通过**：
    /// 下面有一句自检要求这条列带里找得到被查看那格的焦点环。
    private let heatmapOrigin = CGPoint(x: 16, y: 44)

    private var metrics: AnnualHeatmapMetrics {
        AnnualHeatmapMetrics(width: cardWidth - 32, columns: columnCount)
    }

    /// 被查看那一列在**整卡坐标**里的横向范围（热图坐标 + 偏移）。
    private var focusedColumnX: ClosedRange<CGFloat> {
        let strip = metrics.columnStrip(column: focusedColumn)
        return (strip.minX + heatmapOrigin.x)...(strip.maxX + heatmapOrigin.x)
    }

    /// 两个落点：都在被查看那一格横向范围内 —— 注意是**热图坐标**，
    /// 与真实 `onContinuousHover` 给的那一套完全一致（卡片自己加偏移）。
    /// 纵向差 30pt：保证两帧的浮卡不会落在同一处，下面那句自检才有意义。
    private var leftAnchor: CGPoint {
        CGPoint(x: metrics.columnStrip(column: focusedColumn).minX + 2, y: 106)
    }
    private var rightAnchor: CGPoint {
        CGPoint(x: metrics.columnStrip(column: focusedColumn).maxX - 2, y: 136)
    }

    // MARK: - 出图

    private func render(recap: AnnualRecap, focus: AnnualRecapCard.Focus?) throws -> NSBitmapImageRep {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let content = AnyView(
            AnnualRecapCard(recap: recap, previewFocus: focus)
                .forestTheme(theme)
                .frame(width: cardWidth)
                .background(Color(hex: 0xE9EFE4))
        )
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 360)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        // 让 RunLoop 转一会儿（布局稳定、动画走完）。
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
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

    /// 两帧在某个横向区间里（整幅高度）的差异像素数。
    ///
    /// ⚠️ 容差 ±8 抵消离屏渲染的逐通道量化噪声，判据只看「变没变」不比色值。
    private func changedPixels(
        in left: NSBitmapImageRep,
        _ right: NSBitmapImageRep,
        columns: Range<Int>
    ) throws -> Int {
        let a = try rgba(left), b = try rgba(right)
        var count = 0
        for y in 0..<min(a.height, b.height) {
            for x in columns.clamped(to: 0..<min(a.width, b.width)) {
                let offset = (y * a.width + x) * 4
                for channel in 0..<3
                where abs(Int(a.bytes[offset + channel]) - Int(b.bytes[offset + channel])) > 8 {
                    count += 1
                    break
                }
            }
        }
        return count
    }

    /// 两帧差异像素的包围盒（单位：pt）。差异只可能来自浮卡自己
    /// （焦点环两帧同款，抵掉了）。
    private func changedBounds(
        in left: NSBitmapImageRep,
        _ right: NSBitmapImageRep
    ) throws -> CGRect {
        let a = try rgba(left), b = try rgba(right)
        var minX = a.width, minY = a.height, maxX = -1, maxY = -1
        for y in 0..<min(a.height, b.height) {
            for x in 0..<min(a.width, b.width) {
                let offset = (y * a.width + x) * 4
                var changed = false
                for channel in 0..<3
                where abs(Int(a.bytes[offset + channel]) - Int(b.bytes[offset + channel])) > 8 {
                    changed = true
                    break
                }
                guard changed else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .zero }
        let scale = Double(a.width) / Double(cardWidth)
        return CGRect(
            x: Double(minX) / scale, y: Double(minY) / scale,
            width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale
        )
    }

    // MARK: - 用例

    func testTooltipNeverTouchesTheFocusedColumn() throws {
        let recap = makeRecap()
        let day = focusedDay(recap)
        let plain = try render(recap: recap, focus: nil)   // 预热 + 自检基准
        let left = try render(recap: recap, focus: .init(day: day, point: leftAnchor))
        let right = try render(recap: recap, focus: .init(day: day, point: rightAnchor))

        let scale = Double(left.pixelsWide) / Double(cardWidth)
        let band = Int(focusedColumnX.lowerBound * scale)..<Int(focusedColumnX.upperBound * scale)

        // 夹具自检：这条带子里必须能看到「点开某天」的那圈焦点环 —— 证明几何算对了地方。
        let ring = try changedPixels(in: plain, left, columns: band)
        XCTAssertGreaterThan(
            ring, 50,
            "夹具自检失败：列带 \(band) 里没有焦点环（差 \(ring) 像素）—— 偏移算错了"
        )

        let inColumn = try changedPixels(in: left, right, columns: band)
        XCTAssertEqual(
            inColumn, 0,
            "被查看那一列（卡片 x \(focusedColumnX)，像素 \(band)）在两帧之间变了 \(inColumn) 像素 —— 浮卡压到那一列上了"
        )

        // 夹具自检：两帧必须真的不一样（浮卡纵向挪了 30pt），否则上面那条是空断言。
        let everywhere = try changedPixels(in: left, right, columns: 0..<left.pixelsWide)
        XCTAssertGreaterThan(
            everywhere, 500,
            "两帧几乎一样（差 \(everywhere) 像素）—— 浮卡没有跟着落点走，夹具失效了"
        )

        // 落点还得**真的贴着鼠标**：变化区（= 浮卡自己）的顶边 ≈ 鼠标整卡坐标 + 12。
        // 少加「热图在整卡里的偏移」时浮卡会被画到鼠标左上（纵 −43），这条是它的哨兵。
        let bounds = try changedBounds(in: left, right)
        XCTAssertEqual(
            Double(bounds.minY), Double(leftAnchor.y + heatmapOrigin.y + 12), accuracy: 14,
            "浮卡没落在鼠标下方（实测顶边 \(bounds.minY)pt）—— 热图偏移没算进去？"
        )
        XCTAssertEqual(
            Double(bounds.minX), Double(rightAnchor.x + heatmapOrigin.x + 12), accuracy: 14,
            "浮卡没落在「被查看那一列右侧 + margin」处（实测左缘 \(bounds.minX)pt）—— 列让开没生效？"
        )
        try dump(left, name: "tooltip-column-avoid-left-anchor.png")
        try dump(right, name: "tooltip-column-avoid-right-anchor.png")
    }

    // MARK: - 落盘（人眼复核用）

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
