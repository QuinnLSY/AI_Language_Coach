import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 聊天输入框（`MultilineComposerField`）的**离屏渲染**冒烟。
///
/// 为什么单开这一个文件：输入框的 Coordinator 改成 `@MainActor` 隔离之后，
/// 高度上报这条路要走一次 `DispatchQueue.main.async` + `MainActor.assumeIsolated`
/// ——它走不通（或者被放到非主线程上）会**当场 trap**，纯函数测试完全测不到。
/// 所以这里只钉两件「真跑起来才看得出来」的事：
/// 1. 输入的文字真的画出来了（AppKit 的 text view 真的建起来了）；
/// 2. 量出的高度真的回了话（上报那条异步路是通的，且没在主线程之外被调用）。
///
/// 全是离屏位图，不需要屏幕亮着、不碰真实数据。
@MainActor
final class ComposerFieldRenderTests: XCTestCase {

    private var window: NSWindow?
    private let width: CGFloat = 420

    /// 把 `@Binding` 兜在 SwiftUI 里：输入框自己不管状态，只按绑定读写。
    private struct Harness: View {
        @State private var text: String
        @State private var height: CGFloat = 0
        @State private var focused = false
        let onHeight: @MainActor (CGFloat) -> Void

        init(_ text: String, onHeight: @escaping @MainActor (CGFloat) -> Void) {
            _text = State(initialValue: text)
            self.onHeight = onHeight
        }

        var body: some View {
            MultilineComposerField(
                text: $text,
                measuredHeight: $height,
                isFocused: $focused,
                textColor: .labelColor,
                insertionColor: .controlAccentColor,
                onSubmit: {}
            )
            .frame(width: 420, height: max(height, 24))
            .background(Color.white)
            .onChange(of: height) { _, value in onHeight(value) }
        }
    }

    // MARK: - 渲染

    /// ⚠️ 必须**等一轮**再出图：text view 的尺寸是 `reportHeight` 在下个主循环回合里
    /// 手工设上去的（document view 不参与 autoresizing），第一帧它的 frame 还是 0×0，
    /// 此刻出图只能拍到空白——这不是输入框坏了，是拍早了。
    private func render(
        _ text: String,
        onHeight: @escaping @MainActor (CGFloat) -> Void = { _ in }
    ) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: Harness(text, onHeight: onHeight))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 64)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        try? await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func diff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        var count = 0
        for x in 0..<width {
            for y in 0..<height {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                let delta = abs(ca.redComponent - cb.redComponent)
                    + abs(ca.greenComponent - cb.greenComponent)
                    + abs(ca.blueComponent - cb.blueComponent)
                if delta > 0.12 { count += 1 }
            }
        }
        return count
    }

    // MARK: - 用例

    /// 输入框里的字必须真的画出来 —— 空串与有字两趟出图要有可见差异。
    /// ⚠️ 反证：两边都给空串，差异 0，此条立刻变红。
    func testComposerDrawsTypedText() async throws {
        let blank = try await render("")
        // ⚠️ 已反证：这里若也传空串，差异为 0，用例立刻变红。
        let typed = try await render("hello, how are you doing today?")
        let signal = diff(blank, typed)
        XCTAssertGreaterThan(signal, 100, "输入的文字必须真的画在输入框里，实测 \(signal) 像素")
    }

    /// 高度必须真的回话：初始值 0，只有 `reportHeight` 那条异步路走通才会被改成正数。
    /// ⚠️ 这条同时是 `MainActor.assumeIsolated` 的护栏：不在主线程上调用会 trap，
    /// 表现为用例崩溃而不是断言失败。
    func testComposerReportsMeasuredHeight() async throws {
        var reported: [CGFloat] = []
        _ = try await render("one line") { reported.append($0) }

        let latest = try XCTUnwrap(reported.last, "输入框必须上报量出的高度（初始值 0，没上报就是 0）")
        XCTAssertGreaterThan(latest, 0, "量出的高度必须是正数，实测 \(latest)")
    }
}
