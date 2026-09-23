@testable import AppUI
import AIDomain
import SwiftUI
import XCTest

/// 当日明细浮卡（#5）：**列式、宽高都随内容自适应**，每行带板块图标。
///
/// 报障：明细被压在 footer 一行（`lineLimit(1)`），长日子后半截被省略。
/// 修法：悬停浮卡逐条一行 —— 有几行亮几行。
/// 二轮报障：宽度写死 216，短日子右边一大片空；行首没有图标看不出是哪类内容。
///
/// 断言（同一帧内量，不跨帧比对）：
/// ① 内容多的卡明显更高（高度随行数走）；
/// ② 每条都画出来了 —— 行与行之间的墨迹带数量与行数一致；
/// ③ 短内容的卡明显更窄（宽度随内容走），且右缘与 `measuredWidth` 对得上；
/// ④ 图标真的画在行首（文字起点左侧的图标列有墨）。
/// 反证见各用例注释。
@MainActor
final class AnnualDayDetailCardRenderTests: XCTestCase {

    private var window: NSWindow?

    private let canvas = CGSize(width: 320, height: 300)

    private let fixtureItems: [RecapDetailItem] = [
        RecapDetailItem(kind: .date, text: "9月15日"),
        RecapDetailItem(kind: .duration, text: "12 分 0 秒"),
        RecapDetailItem(kind: .conversation, text: "4 轮对话"),
        RecapDetailItem(kind: .shadowing, text: "跟读 2 次"),
        RecapDetailItem(kind: .vocabulary, text: "复习 3 词"),
        RecapDetailItem(kind: .reading, text: "阅读 3 篇（答对 28/30）"),
        RecapDetailItem(kind: .goal, text: "目标达成"),
        RecapDetailItem(kind: .tasks, text: "任务 1 / 3"),
    ]

    private let shortItems: [RecapDetailItem] = [
        RecapDetailItem(kind: .date, text: "9月15日"),
        RecapDetailItem(kind: .goal, text: "目标达成"),
    ]

    // MARK: - 出图

    @discardableResult
    private func capture(items: [RecapDetailItem]) throws -> NSBitmapImageRep {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let content = AnyView(
            AnnualDayDetailCard(items: items)
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

    /// 卡的右缘：在 y ∈ [20, 200] 带里找最右的一列墨（参照 = 画布白底）。
    /// 阴影会在右缘外拖 ~8pt，断言时留出这个余量。
    private func cardRightEdge(_ rep: NSBitmapImageRep) throws -> CGFloat {
        let image = try rgba(rep)
        let scale = Double(image.height) / Double(canvas.height)
        var right = 0
        for x in stride(from: image.width - 1, through: 0, by: -1) {
            var hasInk = false
            for y in stride(from: Int(20 * scale), to: Int(200 * scale), by: 2) where y < image.height {
                let offset = (y * image.width + x) * 4
                if isInk(
                    (Int(image.bytes[offset]), Int(image.bytes[offset + 1]), Int(image.bytes[offset + 2])),
                    reference: (255, 255, 255)
                ) {
                    hasInk = true
                    break
                }
            }
            if hasInk {
                right = x
                break
            }
        }
        return Double(right) / scale
    }

    /// 逐行扫描：把画面切成「有墨 / 没墨」的横带，返回带高（pt）。
    /// 一行文字 = 一条带（行与行之间有空隙）。
    ///
    /// ⚠️ 参照色**在卡内采样**（右上角 padding 处），不是画布白底 ——
    /// 卡片自带浅色底，拿白当参照整张卡都是「墨」（实测 8 行被量成一条 158pt 的带）。
    /// 采样点按 `measuredWidth` 算出的卡宽取在卡内 —— 宽度自适应后不再恒为 216。
    /// ⚠️ 只扫**卡内部**的列：卡边缘有阴影，会把整卡高都染成「有墨」。
    private func inkBands(_ rep: NSBitmapImageRep, cardWidth: CGFloat) throws -> [Int] {
        let image = try rgba(rep)
        let scale = Double(image.height) / Double(canvas.height)
        let samplePoint = (x: Int((cardWidth - 5) * scale), y: Int(3 * scale))
        let sampleOffset = (samplePoint.y * image.width + samplePoint.x) * 4
        let reference = (
            r: Int(image.bytes[sampleOffset]),
            g: Int(image.bytes[sampleOffset + 1]),
            b: Int(image.bytes[sampleOffset + 2])
        )
        var bands: [Int] = []
        var current: Int?
        let scanFrom = Int(12 * scale)
        let scanTo = Int((cardWidth - 12) * scale)
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
        _ = try capture(items: [fixtureItems[0]])   // 预热
        let short = try capture(items: shortItems)
        let long = try capture(items: fixtureItems)
        let shortBands = try inkBands(short, cardWidth: AnnualDayDetailCard.measuredWidth(items: shortItems))
        let longBands = try inkBands(long, cardWidth: AnnualDayDetailCard.measuredWidth(items: fixtureItems))
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

    // MARK: - ② 宽度随内容走（#5 二轮：不再写死 216）

    /// 短内容的卡要明显更窄，且渲染右缘与 `measuredWidth` 对得上（含阴影余量）。
    ///
    /// 反证：把实现的 `measuredWidth` 临时改成常量 216 → 短卡右缘变成 ~222，
    /// 断言 `shortRight ≤ shortExpected + 9`（≈110）变红。
    func testCardWidthAdaptsToTheContent() throws {
        _ = try capture(items: [fixtureItems[0]])   // 预热
        let shortExpected = AnnualDayDetailCard.measuredWidth(items: shortItems)
        let longExpected = AnnualDayDetailCard.measuredWidth(items: fixtureItems)
        XCTAssertLessThan(
            shortExpected, longExpected - 40,
            "两行短内容的卡应比八行长内容的窄一大截（实测 \(shortExpected) vs \(longExpected)）"
        )

        let short = try capture(items: shortItems)
        let shortRight = try cardRightEdge(short)
        XCTAssertLessThanOrEqual(
            shortRight, shortExpected + 9,
            "短卡右缘要贴着内容（阴影拖尾 ≤ 9pt）：实测 \(shortRight)，期望 ≈ \(shortExpected)"
        )
    }

    // MARK: - ③ 行首图标（#5 二轮：知道每行是什么学习内容）

    /// 图标列宽 11 + 间距 5，文字从 x = 26 起 —— 所以**每一行**的墨迹带里，
    /// x ∈ [21, 26) 必须有一条上下贯通的无墨竖缝（图标右缘与文字之间的空隙）。
    ///
    /// 反证：把行首图标砍掉 → 文字顶到 x = 10，缝被字形填死 → 红。
    /// （首版判据「图标列 x∈[13,24) 有墨」是假绿：没图标时文字本身就落在那里。）
    func testEachLineStartsWithASectionIcon() throws {
        _ = try capture(items: [fixtureItems[0]])   // 预热
        let rep = try capture(items: fixtureItems)
        let image = try rgba(rep)
        let scale = Double(image.height) / Double(canvas.height)
        let cardWidth = AnnualDayDetailCard.measuredWidth(items: fixtureItems)
        let sampleOffset = (Int(3 * scale) * image.width + Int((cardWidth - 5) * scale)) * 4
        let reference = (
            r: Int(image.bytes[sampleOffset]),
            g: Int(image.bytes[sampleOffset + 1]),
            b: Int(image.bytes[sampleOffset + 2])
        )

        // 先把每条行带（px 范围）切出来。
        var bands: [(top: Int, bottom: Int)] = []
        var current: Int?
        let scanFrom = Int(12 * scale), scanTo = Int((cardWidth - 12) * scale)
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
                // 与 inkBands 同一把尺：滤掉 < 4pt 的碎带（卡底阴影的细带）。
                if Double(y - start) / scale >= 4 { bands.append((start, y)) }
                current = nil
            }
        }
        XCTAssertEqual(bands.count, fixtureItems.count, "行带数应等于行数：\(bands.count)")
        try dump(rep, name: "round5-tooltip-detail-card.png")

        for (index, band) in bands.enumerated() {
            var hasGap = false
            for x in Int(21 * scale)..<Int(26 * scale) {
                var columnInk = false
                for y in band.top..<band.bottom {
                    let offset = (y * image.width + x) * 4
                    if isInk(
                        (Int(image.bytes[offset]), Int(image.bytes[offset + 1]), Int(image.bytes[offset + 2])),
                        reference: reference
                    ) {
                        columnInk = true
                        break
                    }
                }
                if !columnInk { hasGap = true; break }
            }
            XCTAssertTrue(
                hasGap,
                "第 \(index) 行（\(fixtureItems[index].text)）的图标与文字之间没有空隙 —— 图标没画出来"
            )
        }
    }

    // MARK: - ④ 内容不溢出卡宽

    func testLongCardLinesDoNotOverflowTheCardWidth() throws {
        _ = try capture(items: [fixtureItems[0]])
        let cardWidth = AnnualDayDetailCard.measuredWidth(items: fixtureItems)
        let rep = try capture(items: fixtureItems)
        let image = try rgba(rep)
        let scale = Double(image.width) / Double(canvas.width)
        // 卡右缘 + 阴影余量之外不能再有墨（画布 320 宽）。
        let limitX = Int((cardWidth + 12) * scale)
        for y in 0..<image.height {
            for x in limitX..<image.width {
                let offset = (y * image.width + x) * 4
                XCTAssertFalse(
                    isInk(
                        (Int(image.bytes[offset]), Int(image.bytes[offset + 1]), Int(image.bytes[offset + 2])),
                        reference: (255, 255, 255)
                    ),
                    "y=\(y) 处浮卡右侧出现墨 —— 内容溢出了自适应宽度"
                )
            }
        }
    }
}
