import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 查词结果卡在**实机那条路径**上的渲染回归（用户 09-18 报障：卡片一片空白）。
///
/// ⚠️ 这组用例补的是一个**覆盖漏洞**，值得说清楚：
/// `LookupText` 在 `lookup == nil` 时会退化成普通 SwiftUI `Text`
/// （见 `WordLookupSentence.swift` 的 `if let context`），而实机页面传的是
/// `state.wordLookupContext`（非 nil）→ 走 AppKit 文本视图。过去所有离屏渲染都用的是
/// 组件的默认参数 `lookup: nil`，于是**一直在验一条产品上永远不走的灰路径** ——
/// 固定搭配那一行的 `.fixedSize(horizontal: true)` 在 AppKit 路径上会把文本视图撑成
/// 一千万点宽（`sizeThatFits` 把超宽容器原样返回），整张卡片排版塌掉、看上去一片空白，
/// 而离屏用例全绿。所以：**任何关于这张卡的像素断言，都必须带上 `lookup:`。
@MainActor
final class DictionaryCardLivePathRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 620

    // MARK: - 造数据

    /// 一份「要什么有什么」的词条，含**固定搭配**（那一行正是崩掉的地方）。
    private func detail() -> DictionaryDetail {
        DictionaryDetail(
            word: "nominal",
            phoneticUS: "/ˈnɑːmɪnl/",
            phoneticUK: "/ˈnɒmɪnl/",
            senses: [
                DictionarySense(pos: "adj.", text: "名义上的；有名无实的",
                                explanation: "常用于正式语境，强调与实际不符。"),
                DictionarySense(pos: "n.", text: "名词性词语")
            ],
            collocations: [
                DictionaryCollocation(
                    phrase: "nominal fee", translation: "象征性费用",
                    example: "They charge a nominal fee for the service.",
                    exampleTranslation: "这项服务他们只收象征性费用。"
                )
            ],
            examples: [
                DictionaryExample(text: "He is the nominal head of the company.",
                                  translation: "他是公司名义上的负责人。")
            ],
            etymology: "源自拉丁语 nomen（名字）。"
        )
    }

    /// 实机页面注入的那份划词上下文（这里用不到浮层，全给空动作）。
    private func liveContext() -> WordLookupContext {
        WordLookupContext(card: { _ in nil }, onProbe: { _ in })
    }

    // MARK: - 离屏渲染

    private struct Shot {
        let rep: NSBitmapImageRep
        let size: CGSize
        /// 卡片里那几个 AppKit 文本视图（实机路径下才有）。
        let textViews: [NSTextView]
    }

    private func shoot(_ view: AnyView, width: CGFloat? = nil, name: String) throws -> Shot {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let target = width ?? cardWidth
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).frame(width: target).background(Color(hex: 0xE9EFE4))
        ))
        host.frame = NSRect(x: 0, y: 0, width: target, height: 400)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let size = CGSize(width: target, height: max(80, ceil(host.fittingSize.height)))
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

    /// 深色墨迹的像素数（文字是深墨，卡片底与分区底都是浅色）。
    private func darkInkCount(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.brightnessComponent < 0.55 { count += 1 }
            }
        }
        return count
    }

    // MARK: - ① 实机路径下卡片必须真的把字画出来

    /// 报障原样复现：带 `lookup:` 渲染（= 实机那条路），卡片上必须有大量深色文字。
    ///
    /// 崩掉的时候卡上只剩几个浅色的分区底色块，深色墨迹几乎为 0。
    func testCardOnLivePathActuallyDrawsItsText() throws {
        let shot = try shoot(
            AnyView(DictionaryWordDetailCard(detail: detail(), lookup: liveContext())),
            name: "round45-dictionary-card-live-path-day.png"
        )
        let ink = darkInkCount(shot.rep)
        XCTAssertGreaterThan(
            ink, 2_000,
            "实机路径下卡片应当画满文字；实测深色墨迹只有 \(ink) 像素 —— 卡片多半又塌成空白了"
        )
    }

    /// 灰路径（`lookup: nil`）与实机路径画出来的东西**必须同量级**。
    ///
    /// 两条路本该只是「文字能不能划词」的差别，版式该长一样。差出一个数量级，
    /// 就说明其中一条路的量算坏了 —— 这正是当时离屏用例全绿却漏掉真问题的原因。
    func testLivePathLooksLikeThePlainPath() throws {
        let plain = try shoot(
            AnyView(DictionaryWordDetailCard(detail: detail())),
            name: "round45-dictionary-card-plain-path-day.png"
        )
        let live = try shoot(
            AnyView(DictionaryWordDetailCard(detail: detail(), lookup: liveContext())),
            name: "round45-dictionary-card-live-path-day.png"
        )
        let plainInk = darkInkCount(plain.rep)
        let liveInk = darkInkCount(live.rep)
        XCTAssertGreaterThan(
            liveInk, plainInk / 2,
            "实机路径的墨迹（\(liveInk)）不该比灰路径（\(plainInk)）少一半以上 —— 两条路画的是同一张卡"
        )
        XCTAssertEqual(
            live.size.height, plain.size.height, accuracy: 40,
            "同一份词条在两条路径下的高度该接近（实测 \(live.size.height) vs \(plain.size.height)）"
        )
    }

    // MARK: - ② 直接钉根因：AppKit 文本视图的宽度必须是「内容宽度」

    /// 根因断言：卡片里的每个 AppKit 文本视图都必须是**正常宽度**、且落在卡片内。
    ///
    /// 崩掉时固定搭配那一行的 frame 是 `(-4999698, 510, 10000000, 16)` —— 一千万点宽、
    /// 原点在卡片左外侧五百万点。这条断言就是冲着那个数去的。
    func testAppKitTextViewWidthsStaySane() throws {
        let shot = try shoot(
            AnyView(DictionaryWordDetailCard(detail: detail(), lookup: liveContext())),
            name: "round45-dictionary-card-live-path-day.png"
        )
        XCTAssertFalse(shot.textViews.isEmpty, "实机路径下卡片应当在用 AppKit 文本视图，否则这条用例没意义")

        for text in shot.textViews {
            let frame = text.convert(text.bounds, to: nil)
            let content = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertLessThan(
                frame.width, 2_000,
                "文本视图「\(content.prefix(30))」宽 \(frame.width)pt —— 宽度算爆了（不限宽时应当回内容宽度）"
            )
            XCTAssertGreaterThanOrEqual(
                frame.minX, 0,
                "文本视图「\(content.prefix(30))」被摆到了卡片外侧（x=\(frame.minX)）"
            )
            XCTAssertLessThanOrEqual(
                frame.maxX, cardWidth + 1,
                "文本视图「\(content.prefix(30))」越过了卡片右边缘（maxX=\(frame.maxX)）"
            )
        }
    }

    /// `naturalWidth` 是纯函数，直接钉「按内容算」这条语义。
    func testNaturalWidthMeasuresTheContentNotTheContainer() {
        let sentence = WordLookupTextBuilder.plain(
            "nominal fee",
            fontSize: 13,
            weight: .bold,
            color: .labelColor,
            lineSpacing: 2
        )
        let width = WordLookupText.naturalWidth(of: sentence)
        XCTAssertGreaterThan(width, 40, "「nominal fee」不该量出个退化宽度（实测 \(width)）")
        XCTAssertLessThan(
            width, 300,
            "「nominal fee」的自然宽度只该是几十点；实测 \(width) —— 又把容器宽度原样返回了"
        )

        // 长句的自然宽度要**明显更宽**（不然就是没按内容算）。
        let long = WordLookupTextBuilder.plain(
            "They charge a nominal fee for the service.",
            fontSize: 13, color: .labelColor, lineSpacing: 2
        )
        XCTAssertGreaterThan(
            WordLookupText.naturalWidth(of: long), width * 2,
            "长句的自然宽度该明显大于短语，否则这个量根本没跟着内容走"
        )
    }

    // MARK: - ③ R4 那条口径在实机路径上也要成立

    /// 用户口径：固定搭配的中文译文要**紧跟在英文右边**。
    ///
    /// ⚠️ R4 当时只在 `lookup: nil` 的灰路径上验过 —— 而恰恰是那一处
    /// `.fixedSize(horizontal: true)` 在实机路径上把卡片搞崩了。
    /// 所以这一条必须在**带 `lookup:`** 的前提下重钉一遍。
    func testCollocationTranslationHugsThePhraseOnTheLivePath() throws {
        let only = DictionaryDetail(
            word: "nominal",
            collocations: [
                DictionaryCollocation(phrase: "nominal fee", translation: "象征性费用")
            ]
        )
        let shot = try shoot(
            AnyView(DictionaryWordDetailCard(detail: only, lookup: liveContext())),
            name: "round45-dictionary-collocation-live-path.png"
        )
        XCTAssertFalse(shot.textViews.isEmpty, "固定搭配的英文该由 AppKit 文本视图承载")

        let phrase = try XCTUnwrap(shot.textViews.first)
        // ⚠️ 视图自身的坐标系是左上原点（与 SwiftUI 同向），但它是 AppKit 视图树里的子视图，
        //    转窗口坐标会翻 y —— 这里只看**横向**，不受影响。
        let phraseFrame = phrase.convert(phrase.bounds, to: nil)
        let phraseRight = phraseFrame.maxX

        // 译文是普通 SwiftUI `Text`，从位图上看那一行剩下的墨迹。
        let block = try XCTUnwrap(lastTextBlock(in: shot.rep))
        let runs = inkRuns(in: shot.rep, rows: block)
        XCTAssertGreaterThanOrEqual(runs.count, 2, "搭配那一行应当既有英文也有中文译文")

        let gap = try XCTUnwrap(zip(runs, runs.dropFirst()).map { $1.lowerBound - $0.upperBound }.max())
        XCTAssertLessThanOrEqual(
            CGFloat(gap) / 2, 24,
            "英文与译文之间出现了空白（最大空隙 \(Double(gap) / 2)pt）—— 译文没有紧跟搭配"
        )
        XCTAssertLessThan(
            phraseRight, cardWidth - 60,
            "搭配本身被拉成了一千万点宽的怪物（右缘 \(phraseRight)pt）"
        )
    }

    // MARK: - 小件

    /// 图上最后一个**有文字**的行区间（从下往上挑第一块不是通栏的）。
    private func lastTextBlock(in rep: NSBitmapImageRep) -> ClosedRange<Int>? {
        var blocks: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0..<rep.pixelsHigh {
            let hasInk = rowHasInk(in: rep, row: y)
            if hasInk, start == nil { start = y }
            if !hasInk, let from = start { blocks.append(from...(y - 1)); start = nil }
        }
        if let from = start { blocks.append(from...(rep.pixelsHigh - 1)) }
        for block in blocks.reversed() {
            let runs = inkRuns(in: rep, rows: block)
            guard let first = runs.first, let last = runs.last else { continue }
            if CGFloat(last.upperBound - first.lowerBound) < CGFloat(rep.pixelsWide) * 0.9 { return block }
        }
        return nil
    }

    private func rowHasInk(in rep: NSBitmapImageRep, row: Int) -> Bool {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: row) else { continue }
            if color.brightnessComponent < 0.94 { return true }
        }
        return false
    }

    private func inkRuns(in rep: NSBitmapImageRep, rows: ClosedRange<Int>) -> [ClosedRange<Int>] {
        var inked = [Bool](repeating: false, count: rep.pixelsWide)
        for x in 0..<rep.pixelsWide {
            for y in rows {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.brightnessComponent < 0.9 { inked[x] = true; break }
            }
        }
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for x in 0..<inked.count {
            if inked[x] {
                if start == nil { start = x }
            } else if let from = start, x - from > 1 {
                runs.append(from...(x - 1)); start = nil
            }
        }
        if let from = start { runs.append(from...(inked.count - 1)) }
        return runs
    }

    private static func allTextViews(in view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        if let text = view as? NSTextView { found.append(text) }
        for subview in view.subviews { found.append(contentsOf: allTextViews(in: subview)) }
        return found
    }
}
