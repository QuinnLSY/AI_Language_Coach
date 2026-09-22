import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 跟读页「上一句 / 换一句」的**离屏渲染**回归。
///
/// 逻辑（第几句能回、回到哪一句、分析在不在）由 `ShadowingSentenceStateTests` 钉住；
/// 这里只回答整页量不出来的那两件事：
/// ① **不是第一句时，真的多出了一整颗按钮**（整页被 `Spacer` 撑满，多一颗高度一点不变）；
/// ② 多出来的那颗在「换一句」**左边** —— 光看几何是分不出来的（往右加也一样变宽），
///    所以按**色相**判：两颗按钮的颜色天生不同（上一句是次要文字色、换一句是强调橘）。
///
/// ⚠️ 不碰真实数据、不请求模型；断言只钉「多出来多宽」与「左右哪颗是什么颜色」，
/// 不钉绝对色值（离屏过一次色彩空间换算，绝对色值本来就不可靠）。
@MainActor
final class ShadowingSentenceNavRenderTests: XCTestCase {

    private var window: NSWindow?

    // MARK: - 出图

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private func render(showsPrevious: Bool) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let content = AnyView(
            ZStack(alignment: .topLeading) {
                Color(hex: 0xE9EFE4)
                ShadowingSentenceNavButtons(
                    showsPrevious: showsPrevious, onPrevious: {}, onNext: {}
                )
            }
            .forestTheme(theme)
            .frame(width: 300, height: 44, alignment: .topLeading)
            .clipped()
        )
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 44)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 44)
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, scale: CGFloat(rep.pixelsHigh) / 44)
    }

    // MARK: - 取样

    private struct Pixel {
        let r: Int, g: Int, b: Int
        /// 明显暗于浅底 = 有墨（底色 0xE9EFE4 的和是 700）。
        var isInk: Bool { r + g + b < 600 }
        /// 「暖」= 偏向橘色。灰（次要文字色）的 r 与 b 几乎相等，橘色差得很远。
        var warmth: Int { r - b }
    }

    private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Pixel {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            return Pixel(r: 255, g: 255, b: 255)
        }
        // 透明像素不是墨（`usingColorSpace` 会把 alpha=0 解成黑色）。
        guard color.alphaComponent > 0.5 else { return Pixel(r: 255, g: 255, b: 255) }
        return Pixel(
            r: Int(color.redComponent * 255),
            g: Int(color.greenComponent * 255),
            b: Int(color.blueComponent * 255)
        )
    }

    private struct InkBox {
        var minX: Int, maxX: Int, minY: Int, maxY: Int
        func width(scale: CGFloat) -> CGFloat { CGFloat(maxX - minX + 1) / scale }
    }

    private func inkBox(_ render: Render) -> InkBox? {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for x in 0..<render.rep.pixelsWide {
            for y in 0..<render.rep.pixelsHigh where pixel(render.rep, x, y).isInk {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return InkBox(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    /// 某个横条区间里「有墨像素」的平均暖度（正 = 偏橘，接近 0 = 灰）。
    private func warmth(_ render: Render, fromX: Int, toX: Int, box: InkBox) -> Double {
        var sum = 0.0
        var count = 0
        for x in fromX...toX {
            for y in box.minY...box.maxY {
                let sample = pixel(render.rep, x, y)
                guard sample.isInk else { continue }
                sum += Double(sample.warmth)
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : Double.nan
    }

    private func dump(_ render: Render, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(render.rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 不是第一句就多出一整颗

    func testPreviousButtonAddsAWholeButtonWorthOfWidth() throws {
        let first = try render(showsPrevious: false)
        let later = try render(showsPrevious: true)
        let firstBox = try XCTUnwrap(inkBox(first), "第一句那一行应当画出了「换一句」")
        let laterBox = try XCTUnwrap(inkBox(later), "非第一句那一行应当画出了两颗按钮")
        try dump(first, name: "round308-nav-first-sentence.png")
        try dump(later, name: "round308-nav-later-sentence.png")

        let firstWidth = firstBox.width(scale: first.scale)
        let laterWidth = laterBox.width(scale: later.scale)
        let delta = laterWidth - firstWidth
        XCTAssertGreaterThan(
            delta, 35,
            "不是第一句时应当多出一整颗「上一句」（实测多出 \(delta)pt，"
                + "一句 \(firstWidth)pt → 非第一句 \(laterWidth)pt）"
        )
        XCTAssertLessThan(
            delta, 85,
            "多出来的应当**就是一颗按钮**（图标 + 三个字 + 一道间距），实测 \(delta)pt"
        )
        // 两颗都是靠左排的：起点不变，宽度增加。
        XCTAssertEqual(
            CGFloat(laterBox.minX - firstBox.minX) / later.scale, 0, accuracy: 1,
            "这一行是从左边排起的，起点不该动"
        )
    }

    // MARK: - ② 多出来的那颗在「换一句」左边

    func testPreviousButtonSitsToTheLeftOfTheNextButton() throws {
        let first = try render(showsPrevious: false)
        let later = try render(showsPrevious: true)
        let firstBox = try XCTUnwrap(inkBox(first))
        let laterBox = try XCTUnwrap(inkBox(later))

        func leadingBox(_ box: InkBox) -> (Int, Int) {
            (box.minX, box.minX + max((box.maxX - box.minX) / 5, 1))
        }
        func trailingBox(_ box: InkBox) -> (Int, Int) {
            (box.maxX - max((box.maxX - box.minX) / 5, 1), box.maxX)
        }

        // 只有一颗时：通体都是强调橘（点得动的那个）。
        let singleLeading = warmth(first, fromX: leadingBox(firstBox).0, toX: leadingBox(firstBox).1, box: firstBox)
        XCTAssertGreaterThan(singleLeading, 40, "「换一句」是强调橘（实测暖度 \(singleLeading)）")

        // 多出一颗后：**最左边那一块变灰了** —— 这正是「上一句在左边」。
        let laterLeading = warmth(later, fromX: leadingBox(laterBox).0, toX: leadingBox(laterBox).1, box: laterBox)
        let laterTrailing = warmth(later, fromX: trailingBox(laterBox).0, toX: trailingBox(laterBox).1, box: laterBox)
        XCTAssertLessThan(
            laterLeading, 30,
            "最左边的应当是「上一句」（次要文字色 = 灰），实测暖度 \(laterLeading)"
                + " —— 暖度还高就说明橘色的「换一句」被摆到了左边"
        )
        XCTAssertGreaterThan(
            laterTrailing, 40,
            "最右边的仍然是「换一句」（强调橘），实测暖度 \(laterTrailing)"
        )
    }

    /// 第一句时**不该**画出「上一句」：只用一颗按钮的颜色来判 ——
    /// 整行都该是橘的，出现一块灰就说明那颗多余的按钮漏出来了。
    func testFirstSentenceShowsNoGreyButton() throws {
        let first = try render(showsPrevious: false)
        let box = try XCTUnwrap(inkBox(first))
        for fraction in [0.0, 0.25, 0.5, 0.75] {
            let from = box.minX + Int(Double(box.maxX - box.minX) * fraction)
            let to = min(from + max((box.maxX - box.minX) / 4, 1), box.maxX)
            let value = warmth(first, fromX: from, toX: to, box: box)
            XCTAssertGreaterThan(
                value, 40,
                "第一句那一行通体都该是「换一句」的橘色，位置 \(Int(fraction * 100))% 处却是灰的"
                    + "（暖度 \(value)）—— 那就是「上一句」在没上一句时也画出来了"
            )
        }
    }
}
