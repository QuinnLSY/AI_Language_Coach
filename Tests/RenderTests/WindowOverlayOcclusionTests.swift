import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 浮层遮挡（划词卡片骑在文字上）的回归 —— 两个用户实测报障共用同一个根因。
///
/// 根因：SwiftUI 画的浮层**不是 `NSView`**。`NSView.hitTest` 命中的是它**底下**的视图，
/// `NSTrackingArea` 也照样收 `mouseMoved`。于是：
/// ① 鼠标停在卡片上却把卡片**挡住的词**查了一遍（穿透，只有答案卡片这种大片压字的地方看得见）；
/// ② 卡片上显示的仍是底下正文的 I 型插入符。
/// 定稿：由 `WindowOverlayOcclusion` 统一登记浮层矩形，两个消费方按几何闭嘴。
@MainActor
final class WindowOverlayOcclusionTests: XCTestCase {

    override func tearDown() {
        MainActor.assumeIsolated {
            WindowOverlayOcclusion.removeAll()
            CursorPolicy.resetAppliedMemory()
        }
        super.tearDown()
    }

    private func makeWindow(width: CGFloat = 400, height: CGFloat = 300) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        return window
    }

    /// 真的探针视图：入窗登记、离窗注销。
    func testProbeRegistersOnWindowAndRetractsOnRemoval() throws {
        let window = makeWindow()
        let probe = WindowOverlayOcclusionProbe.ProbeView(frame: NSRect(x: 40, y: 60, width: 120, height: 80))
        window.contentView?.addSubview(probe)
        XCTAssertEqual(WindowOverlayOcclusion.registeredCount, 1, "入窗应当登记")
        XCTAssertTrue(WindowOverlayOcclusion.covers(NSPoint(x: 100, y: 100), in: window), "卡片内部应当算被盖住")
        XCTAssertFalse(WindowOverlayOcclusion.covers(NSPoint(x: 300, y: 100), in: window), "卡片外面不该算被盖住")
        XCTAssertFalse(WindowOverlayOcclusion.covers(NSPoint(x: 100, y: 100), in: nil), "没有窗口时一律不算")

        probe.removeFromSuperview()
        XCTAssertEqual(WindowOverlayOcclusion.registeredCount, 0, "离窗应当注销")
        XCTAssertFalse(WindowOverlayOcclusion.covers(NSPoint(x: 100, y: 100), in: window))
    }

    /// 浮层是先决条件：一旦盖上，连正文的 I 型插入符也要变成箭头。
    func testCursorTurnsIntoArrowUnderTheOverlay() throws {
        let window = makeWindow()
        let passage = WordLookupTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        passage.showsIBeamCursor = true
        window.contentView?.addSubview(passage)

        let point = NSPoint(x: 150, y: 30)
        XCTAssertTrue(
            CursorPolicy.resolvedCursor(forHitView: passage, windowPoint: point, in: window) === NSCursor.iBeam,
            "没有浮层时正文应当保留插入符"
        )

        let probe = WindowOverlayOcclusionProbe.ProbeView(frame: NSRect(x: 100, y: 10, width: 100, height: 40))
        window.contentView?.addSubview(probe)
        XCTAssertTrue(
            CursorPolicy.resolvedCursor(forHitView: passage, windowPoint: point, in: window) === NSCursor.arrow,
            "卡片压在正文上时必须是箭头（用户实测报障：卡片上是插入符）"
        )
    }

    // MARK: 穿透：卡片挡住的词不许再被查

    private func makeSentenceView() throws -> (WordLookupTextView, NSWindow, NSRange) {
        let window = makeWindow(width: 420, height: 200)
        let text = WordLookupTextView(frame: NSRect(x: 20, y: 100, width: 380, height: 40))
        text.isHoverLookupEnabled = true
        text.showsIBeamCursor = false
        window.contentView?.addSubview(text)
        text.apply(
            WordLookupTextBuilder.plain(
                "Marco bakes bread when it rains.",
                fontSize: 14,
                color: .black,
                lineSpacing: 2
            )
        )
        text.layoutSubtreeIfNeeded()
        try XCTUnwrap(text.layoutManager).ensureLayout(for: try XCTUnwrap(text.textContainer))
        return (text, window, NSRange(location: 0, length: 5))
    }

    /// 某个字符范围在**窗口坐标**里的中心点（用来精确落鼠标）。
    private func windowCenter(of range: NSRange, in text: WordLookupTextView) throws -> NSPoint {
        let layout = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let inset = text.textContainerInset
        return text.convert(
            NSPoint(x: rect.midX + inset.width, y: rect.midY + inset.height), to: nil
        )
    }

    private func mouseMovedEvent(at windowPoint: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )
    }

    /// 卡片压在某个词上 → 悬停不再上报（不发查词请求、也不换卡片内容）。
    func testHoverProbeIsSilencedUnderTheOverlay() async throws {
        let (text, window, firstWord) = try makeSentenceView()

        var probes: [String] = []
        text.onProbe = { probe in if let probe { probes.append(probe.text) } }

        // ① 没有卡片：悬停照常上报。
        let firstPoint = try windowCenter(of: firstWord, in: text)
        text.mouseMoved(with: try XCTUnwrap(mouseMovedEvent(at: firstPoint, in: window)))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(probes, ["Marco"], "没有卡片时悬停应当正常上报")

        // ② 卡片盖在这一带（盖住下一个词）：悬停闭嘴。
        let secondPoint = try windowCenter(of: NSRange(location: 6, length: 5), in: text)
        let probe = WindowOverlayOcclusionProbe.ProbeView(
            frame: NSRect(x: secondPoint.x - 60, y: secondPoint.y - 30, width: 120, height: 60)
        )
        window.contentView?.addSubview(probe)
        XCTAssertTrue(
            WindowOverlayOcclusion.covers(secondPoint, in: window),
            "前置条件：第二个词已经被卡片盖住"
        )

        text.mouseMoved(with: try XCTUnwrap(mouseMovedEvent(at: secondPoint, in: window)))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(probes, ["Marco"], "卡片挡住的词不许再上报（穿透）")
    }

    // MARK: 探针不参与交互

    /// 探针**绝不能参与命中测试** —— 「浮层上的按钮还能不能点到」的回归。
    ///
    /// 为什么这条值得单测：探针是个 `NSViewRepresentable`，AppKit 的命中测试**真的够得着它**
    /// （实测命中链：`ProbeView < AppKitPlatformViewHost<WindowOverlayOcclusionProbe> < NSHostingView`）。
    /// 它骑在气泡上，一旦被选中，气泡那几个按钮（朗读 / 收藏 / 查词典）就收不到点击 ——
    /// 与 `ScrollWheelPassthrough` 是同一条账。
    ///
    /// ⚠️ 这条钉的是**不变量**（探针永不出现在命中链里），不是某一行实现：
    /// 代码里有两道闸（探针自身的 `isHidden`、调用点的 `allowsHitTesting(false)`），
    /// 任留一道都过 —— 实测把两道**一起**撤掉才会红。这样将来谁优化掉其中一道，
    /// 只要不变量还成立就不会被误报拦住。
    ///
    /// ⚠️ 拓扑必须与实机同构：正文与浮层**住在同一个 SwiftUI 宿主里**
    /// （气泡是页面 `.overlay` 上的浮层）。各挂一个 `NSHostingView` 测不出这件事
    /// —— 那时最外层宿主先接住事件，探针有没有被排除都一样。
    func testOcclusionProbeNeverInterceptsHitTesting() throws {
        let window = makeWindow(width: 320, height: 220)

        let text = WordLookupText(
            attributed: WordLookupTextBuilder.plain(
                "Marco bakes bread.", fontSize: 14, color: .black, lineSpacing: 2
            ),
            onProbe: { _ in },
            showsIBeamCursor: true
        )
        let host = NSHostingView(
            rootView: ZStack {
                text.frame(width: 320, height: 220)
                // 浮层：一块盖在正文正中的色块，带遮挡声明。
                Color.clear.frame(width: 120, height: 80).windowOverlayOcclusion()
            }
        )
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()

        // 浮层正中（也是正文正中）。
        let inside = NSPoint(x: 160, y: 110)
        XCTAssertTrue(
            WindowOverlayOcclusion.covers(inside, in: window),
            "前置条件：浮层已登记，这一点确实被盖住（否则本测试没在测遮挡）"
        )

        let hit = try XCTUnwrap(
            CursorPolicy.hitTest(in: host, atWindowPoint: inside),
            "浮层之下的视图必须仍可命中（命中链要能穿透浮层）"
        )
        var chain: [String] = []
        var node: NSView? = hit
        while let current = node {
            chain.append(String(describing: type(of: current)))
            XCTAssertFalse(
                current is WindowOverlayOcclusionProbe.ProbeView,
                "探针不许参与命中测试（会吞掉气泡上按钮的点击），实际命中链：\(chain)"
            )
            node = current.superview
        }
        XCTAssertTrue(
            chain.contains { $0.contains("WordLookupTextView") },
            "命中必须落到浮层底下的正文上，实际命中链：\(chain)"
        )
    }

    /// 从卡片回到文字上，**同一个词**也要能重新探测（别被 `lastHoverWord` 记死）。
    func testHoverWorksAgainAfterLeavingTheOverlay() async throws {
        let (text, window, firstWord) = try makeSentenceView()
        var probes: [String] = []
        text.onProbe = { probe in if let probe { probes.append(probe.text) } }

        let point = try windowCenter(of: firstWord, in: text)
        let probe = WindowOverlayOcclusionProbe.ProbeView(
            frame: NSRect(x: point.x - 60, y: point.y - 30, width: 120, height: 60)
        )
        window.contentView?.addSubview(probe)

        text.mouseMoved(with: try XCTUnwrap(mouseMovedEvent(at: point, in: window)))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(probes.isEmpty, "卡片盖着时不该上报")

        probe.removeFromSuperview()
        text.mouseMoved(with: try XCTUnwrap(mouseMovedEvent(at: point, in: window)))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(probes, ["Marco"], "卡片收走后，同一个词应当能重新探测")
    }
}
