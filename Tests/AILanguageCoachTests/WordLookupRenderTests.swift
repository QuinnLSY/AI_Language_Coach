import AIDomain
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 可划词文本（`WordLookupText` / `LookupText`）的**离屏渲染**守卫。
///
/// 这一层是 AppKit 的 `NSTextView`，它的自定尺寸（`sizeThatFits`）是全项目里最容易
/// 静默失效的一处：错的时候不会崩、不会红，只是「这块文本塌成一堆空白」——
/// 跟读页的参考句就是这样翻车的（`widthTracksTextView` 把手写的容器宽度改回 0，
/// 量出来的自然宽度是 0，`sizeThatFits` 于是返回 938 点高）。
/// 所以这里钉两条不变的量：
/// 1. **高度与普通 `Text` 同量级**（同一句话、同一字号，两倍以内）；
/// 2. **墨迹量与普通 `Text` 相当**（长句 > 短句）—— 证明字真的被画上去了。
@MainActor
final class WordLookupRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        let rep: NSBitmapImageRep
        let size: CGSize
    }

    private func render(_ view: AnyView, width: CGFloat) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).frame(width: width).background(Color.white)
        ))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 60)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let size = CGSize(width: width, height: max(20, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    /// 比背景暗的像素数 ≈ 画了多少字。
    private func ink(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.redComponent < 0.8 || color.greenComponent < 0.8 { count += 1 }
            }
        }
        return count
    }

    /// 宽/窄两种可用宽度下，可划词文本都要**画得出来且量得对**。
    func testLookupTextMeasuresAndDrawsLikePlainText() throws {
        let long = "When we first met, she was working as a nurse in a small clinic near the river, "
            + "and every morning she would walk along the bank before sunrise."
        let short = "I'd like to check in for the morning flight to Vancouver."
        let context = WordLookupContext(card: { _ in nil }, onProbe: { _ in })

        for (label, width) in [("600 宽", CGFloat(600)), ("240 宽", CGFloat(240))] {
            let plain = try render(
                AnyView(LookupText(text: long, fontSize: 15, context: nil)), width: width
            )
            let lookup = try render(
                AnyView(LookupText(text: long, fontSize: 15, context: context)), width: width
            )
            let single = try render(
                AnyView(LookupText(text: short, fontSize: 15, context: context)), width: width
            )

            // ① 高度与普通 Text 同量级 —— 平方级的差别说明 TextKit 量错了。
            XCTAssertLessThan(
                lookup.size.height, plain.size.height * 2,
                "\(label)：可划词文本的高度应当与普通 Text 同量级（实测 \(lookup.size.height) vs \(plain.size.height)）"
            )
            XCTAssertGreaterThan(lookup.size.height, single.size.height, "\(label)：长句应当比短句高")
            // ② 画出来的字一样多（多一点点/少一点点无所谓，差 0 就是字没画上去）。
            XCTAssertGreaterThan(
                ink(lookup.rep), 0,
                "\(label)：可划词的句子必须真的画出字形，实测墨迹 \(ink(lookup.rep))"
            )
            XCTAssertEqual(
                ink(lookup.rep), ink(plain.rep),
                "\(label)：同一句话的字形数量应当一致（实测 \(ink(lookup.rep)) vs \(ink(plain.rep))）"
            )
            // ③ 长句的墨迹明显多于短句 —— 证明整段都在，不是只画了第一行。
            XCTAssertGreaterThan(ink(lookup.rep), ink(single.rep) + 200, "\(label)：长句要画满几行")
        }
    }

    /// 窄宽度下必须**真的折行**（变矮变长），而不是被裁成一行。
    func testLookupTextWrapsWhenNarrow() throws {
        let long = "When we first met, she was working as a nurse in a small clinic near the river, "
            + "and every morning she would walk along the bank before sunrise."
        let context = WordLookupContext(card: { _ in nil }, onProbe: { _ in })

        let wide = try render(AnyView(LookupText(text: long, fontSize: 15, context: context)), width: 600)
        let narrow = try render(AnyView(LookupText(text: long, fontSize: 15, context: context)), width: 240)

        XCTAssertGreaterThan(
            narrow.size.height, wide.size.height + 20,
            "窄宽度应当折成多行（实测 \(wide.size.height) → \(narrow.size.height)）"
        )
        XCTAssertLessThanOrEqual(narrow.size.width, 240, "折行后宽度不得超过可用宽度")
    }

    /// 行内 markdown（对话气泡正文）要保留粗体 / 行内代码 —— 逐 run 重建富文本那一串代码唯一的验收方式。
    ///
    /// ⚠️ 这里**不比墨迹量**：加粗只让字形粗一点点，同一句话两版的墨迹差在 ±3% 内抖动
    /// （实测 1798 vs 1744，加粗那版反而更少），拿它当断言必然时红时绿。
    /// 要验的是「`重点` 这两个字身上的字体真的变粗了」，那只能看富文本属性。
    func testInlineMarkdownKeepsBoldAndCode() throws {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let attributed = WordLookupTextBuilder.inlineMarkdown(
            "这是 **重点** 一段话，还有 `print(1)` 行内代码",
            fontSize: 14, weight: .regular, color: .labelColor, lineSpacing: 3
        )

        // markdown 语法本身不能出现在文本里（`**` 与反引号都要被吃掉）。
        XCTAssertFalse(attributed.string.contains("**"), "** 是语法，不该被当成内容画出来")
        XCTAssertFalse(attributed.string.contains("`"), "反引号是语法，不该被当成内容画出来")
        XCTAssertTrue(attributed.string.contains("重点"), "加粗的字要留下来")
        XCTAssertTrue(attributed.string.contains("print(1)"), "行内代码的内容要留下来")

        let fonts = fontsByRange(in: attributed)
        // ⚠️ AppKit 的 `NSFont` 没有 `weight` 属性可读（那是 SwiftUI Font 才有的），
        // 字重只能从 symbolicTraits 上认。
        let boldTraits = fonts["重点"]?.fontDescriptor.symbolicTraits ?? []
        XCTAssertTrue(
            boldTraits.contains(.bold),
            "加粗那一段必须真的用粗体字（直接桥接 `AttributedString` 会丢掉它），实测 traits: \(boldTraits)"
        )
        let regularTraits = fonts["这是"]?.fontDescriptor.symbolicTraits ?? []
        XCTAssertFalse(
            regularTraits.contains(.bold), "没加粗的部分要保持常规字重，实测 traits: \(regularTraits)"
        )
        XCTAssertTrue(
            fonts["print(1)"]?.fontName.localizedCaseInsensitiveContains("mono") ?? false,
            "行内代码要换成等宽字体（实测 \(fonts["print(1)"]?.fontName ?? "nil")）"
        )
        // 颜色必须是主题色，而不是 `init` 里顺手写死的某个颜色。
        XCTAssertNotNil(theme)
    }

    /// 富文本里「每段通配 \(-range) → 字体」的索引。
    private func fontsByRange(in attributed: NSAttributedString) -> [String: NSFont] {
        var result: [String: NSFont] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let text = (attributed.string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            result[text] = font
        }
        return result
    }
}
