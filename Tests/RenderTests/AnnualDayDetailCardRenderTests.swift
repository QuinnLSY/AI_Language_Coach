@testable import AppUI
import SwiftUI
import XCTest

/// 当日明细浮卡（#5）：**列式、高度自适应**。
///
/// 报障：明细被压在 footer 一行（`lineLimit(1)`），长日子后半截被省略。
/// 修法：悬停浮卡逐条一行 —— 有几行亮几行。
///
/// 断言（同一帧内量高度，不跨帧比对）：
/// ① 内容多的卡明显更高（高度随行数走）；
/// ② 每条都画出来了 —— 行与行之间的墨迹带数量与行数一致。
/// 反证：把卡片高度钉死 → ① 红。
@MainActor
final class AnnualDayDetailCardRenderTests: XCTestCase {

    private var window: NSWindow?

    private let canvas = CGSize(width: 260, height: 300)

    private let lines = [
        "9月15日",
        "12 分 0 秒",
        "4 轮对话",
        "跟读 2 次",
        "复习 3 词",
        "阅读 3 篇（答对 28/30）",
        "目标达成",
        "任务 1 / 3",
    ]

    // MARK: - 出图

    @discardableResult
    private func capture(lines: [Int]) throws -> NSBitmapImageRep {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let content = AnyView(
            AnnualDayDetailCard(lines: lines.map { self.lines[$0] })
                .forestTheme(theme)
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                .background(Color.white)
                .clipped()
        )
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: canvas)
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    // MARK: - 像素辅助（逐通道容差 8）

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

    private func isInk(_ pixel: (r: Int, g: Int, b: Int), reference: (r: Int, g: Int, b: Int)) -> Bool {
        abs(pixel.r - reference.r) > 8 || abs(pixel.g - reference.g) > 8
            || abs(pixel.b - reference.b) > 8
    }

    /// 逐行扫描：把画面切成「有墨 / 没墨」的横带，返回带高（pt）。
    /// 一行文字 = 一条带（行与行之间有空隙）。
    ///
    /// ⚠️ 参照色**在卡内采样**（右上角 padding 处），不是画布白底 ——
    /// 卡片自带浅色底，拿白当参照整张卡都是「墨」（实测 8 行被量成一条 158pt 的带）。
    /// 阴影在卡底下的细带（< 4pt）滤掉。
    private func inkBands(_ rep: NSBitmapImageRep) throws -> [Int] {
        let image = try rgba(rep)
        let scale = Double(image.height) / Double(canvas.height)
        let samplePoint = (x: Int(210 * scale), y: Int(3 * scale))
        let sampleOffset = (samplePoint.y * image.width + samplePoint.x) * 4
        let reference = (
            r: Int(image.bytes[sampleOffset]),
            g: Int(image.bytes[sampleOffset + 1]),
            b: Int(image.bytes[sampleOffset + 2])
        )
        var bands: [Int] = []
        var current: Int?
        // ⚠️ 只扫**卡内部**的列（12–204pt）：卡边缘有阴影，
        // 阴影让卡高范围内每一行都「有墨」，8 行文字会被并成一条带（实测 [153]）。
        let scanFrom = Int(12 * scale)
        let scanTo = Int(204 * scale)
        for y in 0..<image.height {
            var rowHasInk = false
            for x in scanFrom..<scanTo {
                let offset = (y * image.width + x) * 4
                if isInk(
                    (Int(image.bytes[offset]), Int(image.bytes[offset + 1]), Int(image.bytes[offset + 2])),
                    reference: reference
                ) {
                    rowHasInk = true
                    break
                }
            }
            if rowHasInk, current == nil { current = y }
            if !rowHasInk, let start = current {
                let heightPt = Int(Double(y - start) / scale)
                if heightPt >= 4 { bands.append(heightPt) }
                current = nil
            }
        }
        if let start = current {
            let heightPt = Int(Double(image.height - start) / scale)
            if heightPt >= 4 { bands.append(heightPt) }
        }
        return bands
    }

    // MARK: - ① 高度随内容走

    func testCardGrowsWithTheNumberOfLines() throws {
        _ = try capture(lines: [0])   // 预热
        let short = try capture(lines: [0, 6])
        let long = try capture(lines: [0, 1, 2, 3, 4, 5, 6, 7])
        let shortBands = try inkBands(short)
        let longBands = try inkBands(long)
        // 短卡 2 条带、长卡 8 条带 —— 每条都各占一行，一条不省。
        XCTAssertEqual(shortBands.count, 2, "短卡应有 2 条墨带，实测 \(shortBands)")
        XCTAssertEqual(longBands.count, 8, "长卡应有 8 条墨带，实测 \(longBands)")
        let shortLast = shortBands.reduce(0, +)
        let longLast = longBands.reduce(0, +)
        XCTAssertGreaterThan(
            longLast, shortLast * 2,
            "长卡的总墨高要明显大于短卡（高度随内容走）：\(longLast) vs \(shortLast)"
        )
    }

    // MARK: - ② 反证夹具自检：钉死高度会红

    func testLongCardLinesDoNotOverflowTheFixedWidth() throws {
        _ = try capture(lines: [0])
        let rep = try capture(lines: [0, 1, 2, 3, 4, 5, 6, 7])
        let image = try rgba(rep)
        let scale = Double(image.width) / Double(canvas.width)
        // 浮卡宽度 216 + 内边距，右边不能再有墨（画布 260 宽，浮卡右缘 ≈ 226）。
        // 参照色取画面右上角（浮卡之外，白底）。
        let limitX = Int(228 * scale)
        for y in 0..<image.height {
            for x in limitX..<image.width {
                let offset = (y * image.width + x) * 4
                XCTAssertFalse(
                    isInk(
                        (Int(image.bytes[offset]), Int(image.bytes[offset + 1]), Int(image.bytes[offset + 2])),
                        reference: (255, 255, 255)
                    ),
                    "y=\(y) 处浮卡右侧出现墨 —— 内容溢出了固定宽度"
                )
            }
        }
    }
}
