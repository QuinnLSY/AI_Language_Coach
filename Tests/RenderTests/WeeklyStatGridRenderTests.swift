@testable import AppUI
import SwiftUI
import XCTest

/// 「本周小结」数字格网格（任务 #4）：**同列居中对齐**。
///
/// 报障：卡片里同列的信息没有居中对齐。原来第二行只有两格 + Spacer ——
/// 第二行的列宽是第一行的两倍，「同列」错位；且每格内部值与标签贴左。
///
/// 修法（`WeeklyStatGrid`）：两行共用**等宽 4 列**（空位占格），格内居中。
///
/// 断言走几何墨迹（同一帧内量出来的，不跨帧比对，无收敛问题）：
/// ① 格内居中 —— 单格行的墨迹中心 ≈ 它那一列的中点；
/// ② 两行同列 —— 第一行第 1 列与第二行第 1 列的墨迹中心是同一个 x。
/// 反证：去掉空位占格 → 第二行列宽翻倍 → ② 红。
@MainActor
final class WeeklyStatGridRenderTests: XCTestCase {

    private var window: NSWindow?

    private let canvas = CGSize(width: 400, height: 120)

    // MARK: - 出图

    private func capture(_ grid: WeeklyStatGrid) throws -> NSBitmapImageRep {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let content = AnyView(
            grid.forestTheme(theme)
                .padding(8)
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

    // MARK: - 像素辅助（逐通道容差 8，与其它渲染测试同一把尺）

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

    private func isInk(
        _ pixel: (r: Int, g: Int, b: Int), background: (r: Int, g: Int, b: Int) = (255, 255, 255)
    ) -> Bool {
        abs(pixel.r - background.r) > 8 || abs(pixel.g - background.g) > 8
            || abs(pixel.b - background.b) > 8
    }

    /// 某个矩形带（pt）里的墨迹水平中心（pt）。没有墨返回 nil。
    private func inkCenterX(
        _ rep: NSBitmapImageRep, xFrom: Int, xTo: Int, yFrom: Int, yTo: Int
    ) throws -> Double? {
        let image = try rgba(rep)
        let scale = Double(image.width) / Double(canvas.width)
        var minX = Int.max, maxX = -1
        for y in Int(Double(yFrom) * scale)..<min(Int(Double(yTo) * scale), image.height) {
            for x in Int(Double(xFrom) * scale)..<min(Int(Double(xTo) * scale), image.width) {
                let offset = (y * image.width + x) * 4
                let pixel = (
                    r: Int(image.bytes[offset]), g: Int(image.bytes[offset + 1]), b: Int(image.bytes[offset + 2])
                )
                if isInk(pixel) {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        guard maxX >= minX else { return nil }
        return (Double(minX) + Double(maxX)) / 2 / scale
    }

    // MARK: - ① 格内居中

    func testChipContentIsCenteredInItsColumn() throws {
        // 只放一个格：它的列 = 4 等分的第一列（其余是空位占格）。
        // 预热 + 断言同一帧：墨迹中心应落在第一列的中点附近。
        _ = try capture(WeeklyStatGrid(top: [], bottom: []))
        let rep = try capture(
            WeeklyStatGrid(
                top: [.init(value: "37 分", label: "本周开口")],
                bottom: []
            )
        )
        // 第一列：x ∈ [8(padding), 8 + (384 - 3*14)/4]；中点 ≈ 8 + 85.5/2 ≈ 50.8pt。
        // 用整行的前半幅来量（第二列是空的，不会混进来）。
        let center = try XCTUnwrap(
            try inkCenterX(rep, xFrom: 8, xTo: 200, yFrom: 8, yTo: 50),
            "格子里一个像素墨都没有 —— 夹具坏了"
        )
        let columnWidth = (canvas.width - 16 - 3 * 14) / 4   // 85.5
        let expected = 8 + columnWidth / 2                     // ≈ 50.75
        XCTAssertEqual(
            center, expected, accuracy: 6,
            "格内容要居中：实测墨迹中心 \(center)，列中点 \(expected) —— 差太远就是又贴左了"
        )
    }

    // MARK: - ② 两行同列

    func testSecondRowColumnsLineUpWithTheFirstRow() throws {
        _ = try capture(WeeklyStatGrid(top: [], bottom: []))
        // ⚠️ 必须用**真实卡片的 4+2 形状**：第一行 4 格、第二行 2 格。
        // 两行都放 2 格的话，占格不参与判定（两行天然等宽），反证会假绿。
        let rep = try capture(
            WeeklyStatGrid(
                top: [
                    .init(value: "37 分", label: "本周开口"),
                    .init(value: "-1", label: "批注比上周少"),
                    .init(value: "12 词", label: "本周新增词汇"),
                    .init(value: "5 天", label: "连续练习"),
                ],
                bottom: [
                    .init(value: "2 篇", label: "本周写作"),
                    .init(value: "1 篇", label: "本周阅读"),
                ]
            )
        )
        // 两行的 y 带（padding 8 起，每格 ~34pt 高 + 12pt 行距）。
        // ⚠️ x 带只盖**第一列**（8 + 列宽 85.5 ≈ 93.5 截止）：
        // 第二列从 107.5 起，量宽了会把它的墨混进来（实测 105 vs 100.25 就是这么来的）。
        let row1Center = try XCTUnwrap(
            try inkCenterX(rep, xFrom: 8, xTo: 94, yFrom: 8, yTo: 40),
            "第一行第 1 列没有墨"
        )
        let row2Center = try XCTUnwrap(
            try inkCenterX(rep, xFrom: 8, xTo: 94, yFrom: 46, yTo: 78),
            "第二行第 1 列没有墨"
        )
        XCTAssertEqual(
            row1Center, row2Center, accuracy: 4,
            "两行的第 1 列必须落在同一个 x 上（同列）：第一行 \(row1Center) vs 第二行 \(row2Center)"
        )
    }
}
