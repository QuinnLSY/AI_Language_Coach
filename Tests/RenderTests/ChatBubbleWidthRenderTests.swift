import AIInfrastructure
import AIInterfaces
import AIProviders
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 学员气泡宽度的**离屏渲染**回归（用户 2026-09-24 报障：
/// 短句气泡被拉满整行，右侧留一大片空白）。
///
/// 口径本体由 `BubbleWidthRuleTests` 钉（纯函数），这里钉**用户眼睛能看到的那件事**：
/// 同一页里，短句的气泡明显比长句窄。
///
/// ⚠️ 判据用「每行最长墨段宽度」，而不是去找「气泡在哪一行」：
/// 排版位置会随字号/内边距漂移，而「最长那一段有多宽」不依赖位置。
/// ⚠️ 扫描带**避开顶部标题与底部输入框**（它们各自有接近满宽的横条，
/// 会把两帧的最大值一起抬到满宽，判据就恒真了）。
/// ⚠️ 一律不碰真实数据：配置写临时文件、库开 `:memory:`。
@MainActor
final class ChatBubbleWidthRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 820, height: 620)

    private func waitUntil(
        _ condition: @MainActor @escaping () -> Bool, timeout: TimeInterval = 6
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    /// ⚠️ 老师的回复刻意压成一个点：**图里最宽的那一段只可能是学员气泡**。
    /// 用 mock 的默认那句（`Hello! Let's practice together.`）不行 —— 它自己也会被
    /// `layoutWidth` 排成 200 多 pt，量出来的「最宽墨段」就可能来自老师，判据立刻失真。
    private func makeChat(learnerSays text: String) async throws -> ChatService {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-bubble-width-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        let providerConfig = ProviderConfig(
            id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model"
        )
        try await store.updateProvider(providerConfig)
        try await store.selectModel("mock-model", for: .llm)
        let services = CoachServices(config: store, databasePath: ":memory:")
        try await services.bootstrapLLM()

        let mock = MockLLMProvider(providerID: "ollama.llm") { request in
            let last = request.messages.last?.content ?? ""
            // 漏行追问那条要合规收尾，免得多花一次请求把用例拖长。
            if last.contains("checking ONE turn of a") { return "[[FIX]] NONE" }
            return "."
        }
        try await mock.initialize(config: providerConfig)
        try await mock.load()
        await services.llm.register(mock)

        let chat = ChatService(services: services)
        chat.send(text)
        await waitUntil { chat.messages.count >= 2 && chat.isGenerating == false }
        return chat
    }

    private func chatView(_ chat: ChatService) -> ChatView {
        ChatView(
            chat: chat,
            modelName: "mock-model",
            health: .connected(model: "mock-model"),
            onSpeakTap: { _ in },
            onSpeechRateChange: { _ in },
            // ⚠️ **必须给查词上下文**：气泡正文只有走 `WordLookupText`（AppKit 那条路）时
            // 才经过 `sizeThatFits` —— 那条分支正是这次要修的地方。
            // 不给的话 `MarkdownText` 退回 SwiftUI `Text`，而 `Text` 本来就贴内容，
            // 于是这条用例在任何实现下都绿（首版就是这么假绿的）。
            // `card` 返回 nil：出图不查词，只要它走那条布局路径。
            wordLookup: WordLookupContext(card: { _ in nil }, onProbe: { _ in }),
            onSend: { _ in },
            onDeleteMessage: { _ in },
            onResendEditedMessage: { _, _ in },
            onRegenerateReply: { _ in },
            canMutateMessages: true
        )
    }

    private func render(_ view: some View) throws -> NSBitmapImageRep {
        // 动物动画不关，画面永不静止（眨眼 3.2s / 跳动 `.repeatForever`）。
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = saved }

        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(
            rootView: AnyView(
                view.forestTheme(theme)
                    .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                    .clipped()
            )
        )
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        // 等一段够长的稳定期：消息区有入场动画，截在中途会让两帧不可比。
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 扫描带里「每行最长的连续非背景像素段」的最大值（背景取图角落采样，不写死色值）。
    private func widestInkRun(_ rep: NSBitmapImageRep, rows: Range<Int>) throws -> CGFloat {
        let image = try rgba(rep)
        let scale = Double(image.height) / Double(canvas.height)
        // 背景色：左上角往里一点（避开圆角与阴影）。
        let sample = (Int(6 * scale) * image.width + Int(6 * scale)) * 4
        let background = (
            r: Int(image.bytes[sample]),
            g: Int(image.bytes[sample + 1]),
            b: Int(image.bytes[sample + 2])
        )
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * image.width + x) * 4
            let r = Int(image.bytes[offset]), g = Int(image.bytes[offset + 1]), b = Int(image.bytes[offset + 2])
            return abs(r - background.r) > 8 || abs(g - background.g) > 8 || abs(b - background.b) > 8
        }
        var widest: CGFloat = 0
        for y in rows {
            let row = min(Int(Double(y) * scale), image.height - 1)
            var run = 0
            var best = 0
            for x in 0..<image.width {
                if isInk(x, row) {
                    run += 1
                    best = max(best, run)
                } else {
                    run = 0
                }
            }
            widest = max(widest, CGFloat(best) / scale)
        }
        return widest
    }

    // MARK: - 用例

    /// 短句气泡贴着内容（地板 64pt 附近）；长句气泡按列宽折行。
    ///
    /// 两条都是**单帧绝对判据**，不靠两帧相减：图里最宽的那一段就是学员气泡
    /// （老师那条被压成一个点，见 `makeChat`）。修复前两者都是「吃满可用宽度」，
    /// 短句那条会量到 ≈700 → 红。
    func testShortLearnerBubbleHugsItsText() async throws {
        _ = try render(chatView(try await makeChat(learnerSays: "Ok.")))   // 预热

        let short = try render(chatView(try await makeChat(learnerSays: "Ok.")))
        let long = try render(chatView(try await makeChat(
            learnerSays: "I would like to order a large cappuccino with oat milk, "
                + "and my friend will have a pot of green tea with two slices of lemon cake, please."
        )))
        try dump(short, name: "round4-bubble-short.png")
        try dump(long, name: "round4-bubble-long.png")

        let rows = 95..<Int(canvas.height * 0.55)
        let shortWidest = try widestInkRun(short, rows: rows)
        let longWidest = try widestInkRun(long, rows: rows)

        XCTAssertLessThan(
            shortWidest, 150,
            "短句气泡该贴着内容（≈66pt），实测 \(shortWidest) —— 快到列宽说明又被拉满了"
        )
        XCTAssertGreaterThanOrEqual(
            shortWidest, LearnerBubbleActionRow.totalWidth,
            "再短也不能窄过它自己那三颗图标（地板 \(LearnerBubbleActionRow.totalWidth)）"
        )
        XCTAssertGreaterThan(
            longWidest, 400,
            "长句气泡仍要按列宽折行（实测 \(longWidest)）—— 别把「贴内容」做成「不许换行」"
        )
    }

    // MARK: - 出图与像素

    private struct Image {
        var bytes: [UInt8]
        var width: Int
        var height: Int
    }

    private func rgba(_ rep: NSBitmapImageRep) throws -> Image {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
            )
        )
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return Image(
            bytes: Array(UnsafeBufferPointer(start: bitmap.bitmapData, count: width * height * 4)),
            width: width,
            height: height
        )
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".workbuddy/verify")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent(name))
    }
}
