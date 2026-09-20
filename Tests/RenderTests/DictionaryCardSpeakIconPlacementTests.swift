import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 用户口径（09-18 报障）：查词卡「固定搭配 / 例句」里的朗读图标要**紧跟句子右侧**，
/// 不许被推到卡片右缘（右对齐）。
///
/// 病根：例句的英文走 `LookupText`（AppKit `NSViewRepresentable`）。它没有 `Text` 那种
/// 「理想宽度」，是**贪心**视图 —— `sizeThatFits` 拿到有限宽度就原样返回，于是吃满整行，
/// 后面的朗读按钮被 `HStack` 一路顶到卡片最右边。修法是 `TextWithTrailingActionRow`：
/// 一行放得下就把句子钉在自然宽度、按钮紧贴其后；放不下才折行。
///
/// ⚠️ 断言必须带 `lookup:`（走实机那条 AppKit 路径）：`lookup: nil` 时 `LookupText`
/// 退化成普通 `Text`，那上面这个 bug 根本不会出现（灰路径下量的是另一套东西）。
@MainActor
final class DictionaryCardSpeakIconPlacementTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 620
    /// 离屏位图是 2x：像素 ÷ 2 = 点。
    private let scale: CGFloat = 2

    // MARK: - 造数据

    private func detail() -> DictionaryDetail {
        DictionaryDetail(
            word: "nominal",
            collocations: [
                DictionaryCollocation(
                    phrase: "nominal fee", translation: "象征性费用",
                    example: "They charge a nominal fee for the service.",
                    exampleTranslation: "这项服务他们只收象征性费用。"
                )
            ],
            examples: [
                DictionaryExample(text: "He is the nominal head of the company.",
                                  translation: "他是公司名义上的负责人。"),
                DictionaryExample(text: "The nominal price was far below the market value.",
                                  translation: "名义价格远低于市场价。")
            ]
        )
    }

    /// 走实机的划词上下文（浮层动作全给空）。
    private func liveContext() -> WordLookupContext {
        WordLookupContext(card: { _ in nil }, onProbe: { _ in })
    }

    /// 卡片本体。
    ///
    /// ⚠️ `isInVocabulary: true` 是**为了断言干净**：否则导航条右侧那颗「添加复习」胶囊
    /// 本身就是 `theme.accent` 着色的，会被下面认「朗读图标」的取色器一起当成图标抓出来。
    private func card() -> AnyView {
        AnyView(
            DictionaryWordDetailCard(
                detail: detail(),
                isInVocabulary: true,
                lookup: liveContext()
            )
        )
    }

    // MARK: - 离屏渲染

    private struct Shot {
        let rep: NSBitmapImageRep
        let size: CGSize
        let textViews: [NSTextView]
    }

    private func shoot(_ view: AnyView, name: String) throws -> Shot {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).frame(width: cardWidth).background(Color(hex: 0xE9EFE4))
        ))
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 400)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let size = CGSize(width: cardWidth, height: max(80, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: directory.appendingPathComponent(name))
        }
        return Shot(rep: rep, size: size, textViews: Self.allTextViews(in: host))
    }

    // MARK: - ① 朗读图标必须紧贴句末

    /// 卡上**每一个**朗读图标，左边 24pt 内都必须有文字（= 它跟着句子）。
    ///
    /// 右对齐的图标左边是一大片空白 —— 这条用例就是冲着那片空白去的。
    func testSpeakIconsHugTheSentenceOnTheLivePath() throws {
        let shot = try shoot(card(), name: "round46-card-speak-icons-day.png")
        let icons = accentIconBoxes(shot.rep)
        XCTAssertGreaterThanOrEqual(
            icons.count, 3,
            "卡上应当有词头 + 三条例句各自的朗读图标，实测只认出 \(icons.count) 个"
        )

        for icon in icons {
            let gap = leftGapToNearestInk(shot.rep, icon: icon)
            let where_ = "图标在第 \(icon.rows.lowerBound / 2)~\(icon.rows.upperBound / 2)pt 行、左缘 \(icon.columns.lowerBound / 2)pt"
            guard let gap else {
                XCTFail("\(where_)：左边 120pt 内一个字的墨迹都没有 —— 图标被推到行尾（右对齐）了")
                continue
            }
            XCTAssertLessThanOrEqual(
                Double(gap) / Double(scale), 24,
                "\(where_)：与左边最近的文字隔了 \(Double(gap) / Double(scale))pt —— 朗读图标没有紧跟句子"
            )
        }
    }

    /// 直接钉住机制：短例句的 AppKit 文本视图**不该被拉满整行**（那是贪心的症状）。
    func testExampleSentenceIsNotStretchedAcrossTheLine() throws {
        let shot = try shoot(card(), name: "round46-card-speak-icons-day.png")
        let sentences = shot.textViews.filter { $0.string.contains("nominal") }
        XCTAssertGreaterThanOrEqual(sentences.count, 3, "三条例句（含搭配里的那句）都该由 AppKit 文本视图承载")

        for text in sentences {
            let natural = WordLookupText.naturalWidth(of: text.attributedString())
            let frame = text.convert(text.bounds, to: nil)
            XCTAssertLessThanOrEqual(
                frame.width, max(natural, 1) + 4,
                "「\(text.string.prefix(24))…」的文本视图宽 \(frame.width)pt，自然宽度才 \(natural)pt —— 它被拉满整行了，后面的按钮必然被顶到行尾"
            )
        }
    }

    // MARK: - 小件

    /// 一个朗读图标的包围盒（像素坐标）。
    private struct IconBox {
        var columns: ClosedRange<Int>
        var rows: ClosedRange<Int>
    }

    /// 认出发音图标：`theme.accent`（白天 = 0x937008，深琥珀）。
    private func isAccentAmber(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        return r > g && g > b && (r - b) > 0.22 && max(r, g, b) < 0.8
    }

    /// 琥珀色像素的连通块（8 邻域），只留下「像一个小图标」的那些。
    private func accentIconBoxes(_ rep: NSBitmapImageRep) -> [IconBox] {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if isAccentAmber(color) { mask[y * width + x] = true }
            }
        }

        var visited = [Bool](repeating: false, count: width * height)
        var boxes: [IconBox] = []
        for start in 0..<(width * height) where mask[start] && !visited[start] {
            var stack = [start]
            visited[start] = true
            var minX = width, maxX = -1, minY = height, maxY = -1
            while let index = stack.popLast() {
                let x = index % width
                let y = index / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let next = ny * width + nx
                        if mask[next], !visited[next] { visited[next] = true; stack.append(next) }
                    }
                }
            }
            let box = IconBox(columns: minX...maxX, rows: minY...maxY)
            // 图标本体约 16pt（32px）见方；太小的当噪点、太大的当别的琥珀色块。
            if box.columns.count >= 14, box.columns.count <= 70,
               box.rows.count >= 14, box.rows.count <= 70 {
                boxes.append(box)
            }
        }
        return boxes
    }

    /// 图标左侧最近的**非琥珀色**墨迹（文字）与它的横向距离（像素）；找不到就是 nil。
    private func leftGapToNearestInk(_ rep: NSBitmapImageRep, icon: IconBox) -> Int? {
        let search = Int(120 * scale)
        var x = icon.columns.lowerBound - 1
        var steps = 0
        while x >= 0, steps < search {
            if columnHasTextInk(rep, x: x, rows: icon.rows) {
                return icon.columns.lowerBound - x - 1
            }
            x -= 1
            steps += 1
        }
        return nil
    }

    /// 这一列在给定行区间内有没有「文字墨迹」（排除琥珀色，免得认到图标自己身上）。
    private func columnHasTextInk(_ rep: NSBitmapImageRep, x: Int, rows: ClosedRange<Int>) -> Bool {
        for y in rows {
            guard y >= 0, y < rep.pixelsHigh, let color = rep.colorAt(x: x, y: y) else { continue }
            guard !isAccentAmber(color) else { continue }
            guard let rgb = color.usingColorSpace(.deviceRGB) else { continue }
            let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
            if luminance < 0.8 { return true }
        }
        return false
    }

    private static func allTextViews(in view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        if let text = view as? NSTextView { found.append(text) }
        for subview in view.subviews { found.append(contentsOf: allTextViews(in: subview)) }
        return found
    }
}
