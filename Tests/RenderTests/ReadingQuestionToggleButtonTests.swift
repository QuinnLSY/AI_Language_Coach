import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 阅读题卡「展开 / 收起解析」按钮的离屏渲染回归（#233 后续）。
///
/// 需求原话：「阅读理解答案卡片的展开收起判定区太小了，做一个带边框的按钮，增大判定区」。
/// 三件事都得**能被断言**，不能只靠看：
/// ① 判定区尺寸真的够大（原来是个 9pt 的裸 chevron）；
/// ② 按钮**真的带边框**（不是又一个裸图标）—— 量边框那一圈有没有墨；
/// ③ 箭头朝向随状态翻转，且符合全应用口径（收起态 = 朝下 = 上宽下尖）。
///
/// ⚠️ 离屏渲染一律不碰真实数据；断言只钉「画出来了什么」，不钉绝对色值
/// （离屏过一次色彩空间换算，绝对色值本来也不可靠，见同目录另几支渲染测试）。
@MainActor
final class ReadingQuestionToggleButtonTests: XCTestCase {

    private var window: NSWindow?

    // MARK: - 出图

    /// 只渲染按钮本身，背景铺一块纯色（便于判「有墨」）。
    private func render(isExpanded: Bool) throws -> NSBitmapImageRep {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            ReadingQuestionToggleButton(isExpanded: isExpanded, onToggle: {})
                .forestTheme(theme)
                .padding(10)
                .background(Color(hex: 0xE9EFE4))
        ))
        let side = ReadingQuestionToggleButton.hitSize
        host.frame = NSRect(x: 0, y: 0, width: side.width + 20, height: side.height + 20)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    // MARK: - 取样

    private struct Pixel {
        let r: Int, g: Int, b: Int
        var isInk: Bool { r + g + b < 600 }  // 明显暗于浅底 = 有墨
    }

    private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Pixel {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            return Pixel(r: 0, g: 0, b: 0)
        }
        return Pixel(
            r: Int(color.redComponent * 255),
            g: Int(color.greenComponent * 255),
            b: Int(color.blueComponent * 255)
        )
    }

    /// 逐行的墨迹**横向跨度**（最右 - 最左）。用来判箭头朝向：朝下的箭头「上宽下尖」。
    private func inkSpanPerRow(_ rep: NSBitmapImageRep, x: Int, y: Int, w: Int, h: Int) -> [Int] {
        (y..<(y + h)).map { row in
            var minX = Int.max
            var maxX = Int.min
            for col in x..<(x + w) where pixel(rep, col, row).isInk {
                minX = min(minX, col)
                maxX = max(maxX, col)
            }
            return maxX >= minX ? maxX - minX + 1 : 0
        }
    }

    // MARK: - ① 判定区尺寸

    func testHitAreaIsComfortablyLargerThanTheOldTinyChevron() {
        let size = ReadingQuestionToggleButton.hitSize
        // 原来那个裸 chevron 是 9pt 字号，可视面积约 9×5 点；这里要求整块按钮至少 30×26。
        XCTAssertGreaterThanOrEqual(size.width, 30, "判定区宽度不够（用户抱怨的就是太小）")
        XCTAssertGreaterThanOrEqual(size.height, 26, "判定区高度不够")
        XCTAssertGreaterThanOrEqual(size.width * size.height, 800, "判定面积至少要超过 800 平方点")
    }

    /// 画出来的按钮（描边那一圈）就**占满**声明的判定区 —— 不能「只有 frame 大」。
    ///
    /// ⚠️ 这里刻意不写「出图尺寸 == hitSize + padding」：frame 是测试自己设的，那是句恒等废话。
    /// 真正要钉的是「用户看得见、点得到的那块，和声明的判定区一样大」——
    /// 否则只要有人把视觉缩小、frame 留着，判定区就名存实亡（用户抱怨的正是那个状态：
    /// 视觉是个 9pt 的裸箭头，判定区也跟着退化）。
    func testDrawnButtonFillsTheDeclaredHitSize() throws {
        let rep = try render(isExpanded: false)
        let side = ReadingQuestionToggleButton.hitSize
        let scale = CGFloat(rep.pixelsWide) / (side.width + 20)
        let inset = Int((10 * scale).rounded())
        let w = Int((side.width * scale).rounded())
        let h = Int((side.height * scale).rounded())

        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var count = 0
        for y in inset..<(inset + h) {
            for x in inset..<(inset + w) where pixel(rep, x, y).isInk {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 0, "按钮区域里一个墨点都没有")
        let drawnWidth = CGFloat(maxX - minX + 1) / scale
        let drawnHeight = CGFloat(maxY - minY + 1) / scale
        XCTAssertEqual(
            drawnWidth, side.width, accuracy: 1.5,
            "画出来的按钮宽度应当撑满判定区（实测 \(drawnWidth) vs 声明 \(side.width)）"
        )
        XCTAssertEqual(
            drawnHeight, side.height, accuracy: 1.5,
            "画出来的按钮高度应当撑满判定区（实测 \(drawnHeight) vs 声明 \(side.height)）"
        )
    }

    // MARK: - ② 真的带边框

    /// 边框那一圈必须**看得见**：四条边都要和按钮内部填色拉开明显差距。
    ///
    /// ⚠️ 判据故意与色值无关（只要求「差得够远」）：离屏过一次色彩空间换算，
    /// 钉死某个 RGB 的测试早晚会假报警。这里钉的正是用户那句话 ——「要一个带边框的按钮」。
    func testDrawsAVisibleBorderOnAllFourSides() throws {
        let rep = try render(isExpanded: false)
        let side = ReadingQuestionToggleButton.hitSize
        let scale = CGFloat(rep.pixelsWide) / (side.width + 20)
        let x0 = Int((10 * scale).rounded())
        let y0 = Int((10 * scale).rounded())
        let w = Int((side.width * scale).rounded())
        let h = Int((side.height * scale).rounded())

        // 按钮内部填色：从上下边框往里的中间取一条（避开描边本身）。
        let inner = pixel(rep, x0 + w / 2, y0 + Int((5 * scale).rounded()))
        let minimumDelta = 60

        func maxDeltaOn(_ points: [(Int, Int)]) -> Int {
            points.map { point in
                let sample = pixel(rep, point.0, point.1)
                return abs(sample.r - inner.r) + abs(sample.g - inner.g) + abs(sample.b - inner.b)
            }.max() ?? 0
        }

        let inset = Int((4 * scale).rounded())
        let topSamples = (0..<3).map { x0 + inset + ($0 + 1) * (w - inset * 2) / 4 }.map { ($0, y0) }
        let bottomSamples = (0..<3).map { x0 + inset + ($0 + 1) * (w - inset * 2) / 4 }.map { ($0, y0 + h - 1) }
        let leftSamples = (0..<3).map { y0 + inset + ($0 + 1) * (h - inset * 2) / 4 }.map { (x0, $0) }
        let rightSamples = (0..<3).map { y0 + inset + ($0 + 1) * (h - inset * 2) / 4 }.map { (x0 + w - 1, $0) }

        XCTAssertGreaterThan(maxDeltaOn(topSamples), minimumDelta, "上边框看不见")
        XCTAssertGreaterThan(maxDeltaOn(bottomSamples), minimumDelta, "下边框看不见")
        XCTAssertGreaterThan(maxDeltaOn(leftSamples), minimumDelta, "左边框看不见")
        XCTAssertGreaterThan(maxDeltaOn(rightSamples), minimumDelta, "右边框看不见")

        // 中心是箭头本体：必须比填色明显更深。
        let centerDelta = maxDeltaOn([
            (x0 + w / 2, y0 + h / 2),
            (x0 + w / 2 - Int(2 * scale), y0 + h / 2),
            (x0 + w / 2 + Int(2 * scale), y0 + h / 2),
        ])
        XCTAssertGreaterThan(centerDelta, minimumDelta, "按钮里应该有箭头")
    }

    // MARK: - ③ 箭头朝向

    /// 收起态 = 朝下（应用口径：图标画的是「点下去会发生什么」，解析卡向下长出）。
    func testCollapsedChevronPointsDown() throws {
        let rep = try render(isExpanded: false)
        let side = ReadingQuestionToggleButton.hitSize
        let scale = CGFloat(rep.pixelsWide) / (side.width + 20)
        let inset = Int((10 * scale).rounded())
        let w = Int((side.width * scale).rounded())
        let h = Int((side.height * scale).rounded())

        // ⚠️ 只看**内部**：把边框那 1 点（+2px 余量）切掉，否则量到的是边框不是箭头。
        let margin = Int((6 * scale).rounded())
        let spans = inkSpanPerRow(
            rep, x: inset + margin, y: inset + margin,
            w: w - margin * 2, h: h - margin * 2
        )
        let inked = spans.filter { $0 > 0 }
        let first = try XCTUnwrap(inked.first, "没量到箭头墨迹")
        let last = try XCTUnwrap(inked.last, "没量到箭头墨迹")
        XCTAssertGreaterThan(first, last, "收起态的箭头应该「上宽下尖」（朝下），实测 上\(first) vs 下\(last)")
    }

    func testExpandedChevronPointsUp() throws {
        let rep = try render(isExpanded: true)
        let side = ReadingQuestionToggleButton.hitSize
        let scale = CGFloat(rep.pixelsWide) / (side.width + 20)
        let inset = Int((10 * scale).rounded())
        let w = Int((side.width * scale).rounded())
        let h = Int((side.height * scale).rounded())

        let margin = Int((6 * scale).rounded())
        let spans = inkSpanPerRow(
            rep, x: inset + margin, y: inset + margin,
            w: w - margin * 2, h: h - margin * 2
        )
        let inked = spans.filter { $0 > 0 }
        let first = try XCTUnwrap(inked.first)
        let last = try XCTUnwrap(inked.last)
        XCTAssertLessThan(first, last, "展开态的箭头应该「上尖下宽」（朝上），实测 上\(first) vs 下\(last)")
    }

    /// 两种状态的提示文案不同 —— `.help` 本身测不了（AppKit 树里没有 toolTip），
    /// 但文案是纯数据，能测。
    func testHelpTextsDiffer() {
        XCTAssertNotEqual(ReadingQuestionToggleButton.expandHelp, ReadingQuestionToggleButton.collapseHelp)
        XCTAssertTrue(ReadingQuestionToggleButton.expandHelp.contains("展开"))
        XCTAssertTrue(ReadingQuestionToggleButton.collapseHelp.contains("收起"))
    }
}
