import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 阅读正文（长段落 `WordLookupSentence`）的**高度口径**回归。
///
/// 背景事故：容器宽度刚变化时 `ensureLayout` 之后 `usedRect` 仍可能返回旧宽度下的
/// 陈旧矮高度，SwiftUI 拿它定 frame，正文按新宽度重排成更多行 → 卡片裁掉最后一行
/// （阅读短文「daily reminder…」半行消失，2026-09-19 实测报障）。
/// 修复后高度的权威是 `contentHeight`（`boundingRect` 实时量），这里把契约钉死。
@MainActor
final class ReadingPassageHeightTests: XCTestCase {

    private var longText: String {
        Array(repeating:
            "For most bakers, a rainy day just means a quiet shop. But for Marco, the owner of Cloud & Crust bakery, rain is a signal to start baking a special recipe.",
            count: 6
        ).joined(separator: " ")
    }

    private func paragraphAttributed(_ text: String) -> NSAttributedString {
        ReadingParagraphText.make(text, fontSize: 13, color: .black, lineSpacing: 4)
    }

    // MARK: 高度纯函数

    /// 陈旧矮 `usedRect` 不许顶掉实时量出来的真实高度（裁行事故的根因）。
    func testContentHeightDominatesStaleUsedRect() {
        let attributed = paragraphAttributed(longText)
        let expected = ceil(
            attributed.boundingRect(
                with: CGSize(width: 460, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
        )
        // 「陈旧值」：比真实高度矮的一块（事故里 usedRect 原样吐旧宽度的高度）。
        let stale = expected - 40
        let height = WordLookupText.contentHeight(of: attributed, width: 460, usedHeight: stale)
        XCTAssertEqual(height, expected, "高度必须以 boundingRect 实时量为权威")
        XCTAssertGreaterThan(height, stale)
    }

    /// 多段落（显式 \n + 段前距）的高度必须覆盖每一段 —— 段落间距不能被吞。
    func testContentHeightCoversEveryParagraph() {
        let multi = paragraphAttributed(longText + "\n\nOne stormy night, a boat knocked on the rocks.")
        let single = paragraphAttributed(longText)
        let multiHeight = WordLookupText.contentHeight(of: multi, width: 460, usedHeight: 0)
        let singleHeight = WordLookupText.contentHeight(of: single, width: 460, usedHeight: 0)
        XCTAssertGreaterThan(multiHeight, singleHeight + 19, "多一段就要多出至少一行")
    }

    // MARK: 集成：阅读页结构下文本视图 frame 必须覆盖排版内容

    private func makeCard(text: NSAttributedString) -> some View {
        let context = WordLookupContext(card: { _ in nil }, onProbe: { _ in })
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    LookupText(
                        text: "Weather-Following Baker",
                        fontSize: 15,
                        weight: .semibold,
                        lineSpacing: 3,
                        context: context
                    )
                    WordLookupSentence(attributed: text, context: context, hoverLookupEnabled: false)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 在页面同构的 ScrollView 层级里，正文的 frame 高度必须 ≥ 排版所需（每个正文视图都查）。
    func testEveryPassageTextViewFrameCoversContent() throws {
        let attributed = paragraphAttributed(longText)
        let host = NSHostingView(rootView: AnyView(makeCard(text: attributed)))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let size = CGSize(width: 620, height: max(80, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        var views: [WordLookupTextView] = []
        func walk(_ view: NSView) {
            if let tv = view as? WordLookupTextView { views.append(tv) }
            for child in view.subviews { walk(child) }
        }
        walk(host)
        XCTAssertGreaterThanOrEqual(views.count, 2, "标题与正文都应是可划词文本视图")
        for tv in views {
            let container = try XCTUnwrap(tv.textContainer)
            let layout = try XCTUnwrap(tv.layoutManager)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            XCTAssertGreaterThanOrEqual(
                tv.frame.height + 0.5, used.height,
                "正文 frame 高度必须覆盖排版内容（差 \((used.height - tv.frame.height))pt = 裁行）"
            )
        }
    }
}
