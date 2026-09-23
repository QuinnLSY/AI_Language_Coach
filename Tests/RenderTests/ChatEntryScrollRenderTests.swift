import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 进入练习页自动定位到最后一条对话（任务 #6）的**离屏渲染**回归。
///
/// 报障：每次从其他页面进练习页，都停在对话开头。
/// 根因：练习页是 `if/else` 切出来的 —— 回来时 `ChatView` 是**重建**的，
/// SwiftUI `ScrollView` 初始 offset 在顶部。
/// 修法：`.task` 里等一帧布局后**无动画**滚到底。
///
/// 断言不走像素：SwiftUI 的 `ScrollView` 在 macOS 上宿主在真的 `NSScrollView`
/// 里，渲染完直接读它的 `contentOffset` ——
/// 定位到底 ≈ `contentHeight - containerHeight`；停在顶 = 0。
/// 反证：摘掉 `.task` 那次定位 → offset 归 0 → 红。
@MainActor
final class ChatEntryScrollRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 560, height: 480)

    // MARK: - 夹具

    private func waitUntil(
        _ condition: @MainActor @escaping () -> Bool, timeout: TimeInterval = 6
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    /// 一段足够长到溢出视口的对话（招呼 + 4 轮问答 = 9 条）。
    private func makeChat() async throws -> ChatService {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-entry-scroll-\(UUID().uuidString).json")
        )
        try await store.updateProvider(
            ProviderConfig(id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        let chat = ChatService(services: CoachServices(config: store, databasePath: ":memory:"))
        chat.greetIfNeeded()
        await waitUntil { !chat.messages.isEmpty && !chat.isGenerating }
        for round in 0..<4 {
            chat.send("round \(round): here comes a learner line long enough to wrap a little.")
            await waitUntil { !chat.isGenerating && chat.messages.count >= 3 + (round + 1) * 2 }
        }
        return chat
    }

    private func render(_ chat: ChatService) {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let savedAnimalAnimations = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = savedAnimalAnimations }

        let content = AnyView(
            ChatView(
                chat: chat,
                modelName: "mock-model",
                health: .connected(model: "mock-model"),
                onSpeakTap: { _ in },
                onSpeechRateChange: { _ in },
                onSend: { _ in },
                onDeleteMessage: { _ in },
                onResendEditedMessage: { _, _ in },
                onRegenerateReply: { _ in }
            )
            .forestTheme(theme)
            .frame(width: canvas.width, height: canvas.height)
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
    }

    /// 深度优先找视图树里的 `NSScrollView`（SwiftUI 的 ScrollView 在 macOS 上有真宿主）。
    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = findScrollView(child) { return found }
        }
        return nil
    }

    // MARK: - 断言

    func testEnteringThePracticePageLandsAtTheLatestMessage() async throws {
        let chat = try await makeChat()
        let messagesBefore = chat.messages.count
        XCTAssertGreaterThanOrEqual(messagesBefore, 9, "夹具要有足够长的对话才溢得出视口")

        render(chat)
        // `.task` 睡 120ms 后定位；多留余量，等它做完。
        try await Task.sleep(nanoseconds: 600_000_000)

        let host = try XCTUnwrap(window?.contentView, "窗口没建起来")
        let scroll = try XCTUnwrap(findScrollView(host), "SwiftUI ScrollView 的 NSScrollView 宿主没找到 —— macOS 实现变了，别再读 offset")
        let clip = scroll.contentView
        let documentHeight = scroll.documentView?.frame.height ?? 0
        let visibleHeight = clip.bounds.height
        let offset = clip.bounds.origin.y
        XCTAssertGreaterThan(
            documentHeight, visibleHeight + 96,
            "内容必须溢出视口超过按钮阈值，否则这个测试证明不了任何事（\(documentHeight) vs \(visibleHeight)）"
        )
        XCTAssertGreaterThanOrEqual(
            offset, documentHeight - visibleHeight - 40,
            "进入练习页应定位到最后：offset \(offset)，底部应在 \(documentHeight - visibleHeight) 附近 —— 停在顶就是这条红"
        )
    }
}
