import AIDomain
import AIInfrastructure
import AIInterfaces
import AIProviders
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 练习页常驻进度行（#598）的**离屏渲染**回归。
///
/// 只钉用户真能看见的那一件事：**情景条里多出一行进度**（目标句 / 目标词的胶囊），
/// 而同样的情景在「没有进行中的练习」时那一行的位置是空的。
///
/// ⚠️ 不做文字断言：离屏图上读不出字，所以走**差分**——
/// 同一份情景条，只切换「这一局有没有在练」这一个变量，差异必须落在页面顶部
/// 的情景条那一带（消息区是空的，排版不会被顶得整页挪动）。
/// ⚠️ 组件自带底色（情景条铺了 `selection` 半透明底）→ `ink` 会退化成「卡的面积」，
/// 内容差异一律看 `difference`（见技能 `macos-ui-verify`）。
@MainActor
final class PracticeProgressRenderTests: XCTestCase {

    private var window: NSWindow?

    private let canvas = CGSize(width: 900, height: 640)

    // MARK: - 渲染

    private struct Render {
        var rep: NSBitmapImageRep
        /// 位图像素 / 视图点（按 pt 写断言时必须过这一道）。
        var scale: CGFloat
    }

    /// 同一条情景条、同一份素材，只换「这一局有没有在练」。
    ///
    /// `scenario` 两次都传（情景条本身必须在），差的那一行完全由
    /// `chat.liveFocus` 决定 —— 这正是 #598 要钉的真源。
    /// ⚠️ `briefing` 两次都传 nil：一旦带上前情提要，那一大段引导卡也会渲染，
    /// 差分就分不清「多出来的是进度行还是引导卡」。
    private func renderStrip(chat: ChatService, scenario: ScenarioProgress) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            ChatView(
                chat: chat,
                modelName: "stub-model",
                health: .connected(model: "mock-model"),
                scenario: scenario
            )
            .forestTheme(theme)
        ))
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, scale: CGFloat(rep.pixelsHigh) / max(canvas.height, 1))
    }

    // MARK: - ① 练了一局之后，情景条多出一行进度

    /// 反证：把 `ChatView.scenarioStrip` 里 `if ... { liveProgressRow(...) }` 删掉 →
    /// 两张图几乎一样 → 差异跌回噪声地板 → 变红。
    func testScenarioStripGrowsTheLiveProgressRow() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let scenario = makeScenario()
        // 对照组与实验组**说了一模一样的话**：差别只在 endScenario() 之后
        // `scenarioProgress` 没了 → `liveFocus` 空 → 那一行不画。
        // ⚠️ 这一步不能省：只拿「空会话」当对照的话，差异里混进整屏消息气泡，
        // 判据就退化成「有没有消息」而不是「有没有进度行」（实测 delta 16 万像素）。
        let live = ChatService(services: fixture.services)
        live.startScenario(scenario)
        live.send("I'd like a coffee, please.")
        await waitForAssistantReply(live, expected: 1)

        let ended = ChatService(services: fixture.services)
        ended.startScenario(scenario)
        ended.send("I'd like a coffee, please.")
        await waitForAssistantReply(ended, expected: 1)
        ended.endScenario()

        XCTAssertFalse(live.liveFocus.isEmpty, "实验组：练了一局，进度行有东西可画")
        XCTAssertTrue(ended.liveFocus.isEmpty, "对照组：同一份发言，但这一局已经退出")
        XCTAssertEqual(live.messages.count, ended.messages.count, "两组消息必须一样多")
        // 两次渲染喂的是**同一份**情景进度（轮数都一样），只有「有没有在练」不同。
        let progress = ScenarioProgress(scenario: scenario, turnsUsed: 1)

        let without = try renderStrip(chat: ended, scenario: progress)
        let withoutAgain = try renderStrip(chat: ended, scenario: progress)
        let with = try renderStrip(chat: live, scenario: progress)

        // 噪声地板：同一份输入的两次渲染之间不该有实质差异。
        let floor = diff(without, withoutAgain)
        XCTAssertLessThan(
            floor.total, 200,
            "同一份输入两次渲染之间不该出现实质差异；实测差了 \(floor.total) 像素"
        )
        let delta = diff(without, with)
        XCTAssertGreaterThan(
            delta.top, 3000,
            "练了一局之后情景条那一带必须真的多画出东西；实测顶部只差 \(delta.top) 像素"
        )
        // 差异必须落在**顶部情景条**那一带，而不是页面别处。
        XCTAssertLessThan(
            delta.peakTop, 320,
            "多出来的那一行应该在页面顶部的情景条里；实测差异最集中的一带在 \(delta.peakTop)pt"
        )
        try dump(without, name: "practice-progress-strip-without.png")
        try dump(with, name: "practice-progress-strip-with.png")
    }

    // MARK: - ② 说到的那个目标词被点亮

    /// 两组都练了一局，**命中数一模一样**，点亮的却是不同的词：
    /// 说到的那个目标词在 chip 上要点亮（主题色 + 深一档底），没说到的保持灰。
    ///
    /// ⚠️ 命中数必须相同：两枚 pill（目标句 / 目标词）的文案由它生成，
    /// 一旦不同，差异里就混进 pill 自己的字形差（实测 1226 像素，
    /// 而一颗 chip 的点亮只差 ~330 —— 判据会被顶成假绿）。命中数相同后，
    /// 情景条里可能变化的**只剩 chip**。
    /// ⚠️ 只量页面顶部 180pt（情景条那一带）：两条消息文案不同，气泡差异在
    /// ~210pt 以下，量进来同样会把判据顶成假绿（实测 8300 vs 327）。
    ///
    /// 反证：把 `targetWordChip` 里 `isHit` 的着色去掉 → 情景条里再无差别 → 变红。
    func testTargetWordChipLightsUpWhenTheWordIsSaid() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let scenario = makeScenario()
        let said = ChatService(services: fixture.services)
        said.startScenario(scenario)
        said.send("I'd like a coffee, please.")
        await waitForAssistantReply(said, expected: 1)

        // 对照组说的是**另一句目标句**、命中数一样，点亮的是「main course」而不是
        // 「coffee」—— 于是两枚 pill 逐字相同，情景条里会变的只剩 chip。
        let other = ChatService(services: fixture.services)
        other.startScenario(scenario)
        other.send("Could I have the main course?")
        await waitForAssistantReply(other, expected: 1)

        XCTAssertEqual(said.liveFocus.matchedWords, 1, "说了 coffee → 命中 1 个词")
        XCTAssertEqual(other.liveFocus.matchedWords, 1, "说了 main course → 同样命中 1 个词")
        XCTAssertEqual(
            said.liveFocus.summary, other.liveFocus.summary,
            "两枚 pill 的文案必须逐字相同，差异才只可能来自 chip"
        )
        XCTAssertEqual(said.liveFocus.wordItems.first { $0.text == "coffee" }?.isHit, true)
        XCTAssertEqual(other.liveFocus.wordItems.first { $0.text == "coffee" }?.isHit, false)

        let progress = ScenarioProgress(scenario: scenario, turnsUsed: 1)
        let plain = try renderStrip(chat: other, scenario: progress)
        let plainAgain = try renderStrip(chat: other, scenario: progress)
        let lit = try renderStrip(chat: said, scenario: progress)

        let floor = diff(plain, plainAgain)
        XCTAssertLessThan(floor.total, 200, "同一份输入两次渲染不该有差异；实测 \(floor.total)")
        let delta = diff(plain, lit)
        // 只看 `top`（情景条那一带）就够了：气泡差异按构造被排除在外，
        // 所以「差异 > 0」直接等价于「情景条里有什么变了」，而 pill 又逐字相同
        // （上面断言过 `summary`），变的只能是 chip。
        XCTAssertGreaterThan(
            delta.top, 400,
            "说到的目标词必须被点亮；实测情景条那一带只差 \(delta.top) 像素"
        )
        try dump(plain, name: "practice-progress-chip-plain.png")
        try dump(lit, name: "practice-progress-chip-lit.png")
    }

    // MARK: - 度量

    private struct Diff {
        /// 全页差异像素总数。
        var total: Int
        /// 页头 + 情景条那一带（顶部 180pt）里的差异像素数。
        ///
        /// ⚠️ 上界定在 180pt：消息气泡从 ~210pt 起（实测气泡差异峰值在 210pt
        /// 那一带），量进来会盖过情景条本身的变化。
        var top: Int
        /// 差异最集中的那一带的顶边（pt）。
        var peakTop: CGFloat
        /// 那一带的差异像素数。
        var peak: Int
    }

    /// 两张图的逐像素差分，按 10pt 一带统计。
    ///
    /// ⚠️ 不写死纵坐标：情景条上面还有页头，它的高度随窗口宽高走。
    private func diff(_ a: Render, _ b: Render) -> Diff {
        let scale = max(a.scale, 1)
        let band = Int(10 * scale)
        let topLimit = Int(180 * scale)
        var total = 0
        var topCount = 0
        var peak = 0
        var peakTop: CGFloat = 0
        var from = 0
        while from < a.rep.pixelsHigh {
            let bottom = min(from + band, a.rep.pixelsHigh)
            var count = 0
            for y in from..<bottom {
                for x in 0..<a.rep.pixelsWide {
                    guard let left = a.rep.colorAt(x: x, y: y),
                          let right = b.rep.colorAt(x: x, y: y) else { continue }
                    let delta = abs(left.redComponent - right.redComponent)
                        + abs(left.greenComponent - right.greenComponent)
                        + abs(left.blueComponent - right.blueComponent)
                    if delta > 0.08 { count += 1 }
                }
            }
            total += count
            if from < topLimit { topCount += count }
            if count > peak {
                peak = count
                peakTop = CGFloat(from) / scale
            }
            from = bottom
        }
        return Diff(total: total, top: topCount, peakTop: peakTop, peak: peak)
    }

    // MARK: - 基建

    private struct Fixture {
        let services: CoachServices
        let directory: URL
    }

    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-progress-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await store.updateProvider(
            ProviderConfig(id: "mock.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        let services = CoachServices(config: store, databasePath: ":memory:")
        try await services.bootstrapLLM()
        await services.llm.register(AliveProgressLLMProvider())
        return Fixture(services: services, directory: directory)
    }

    private func makeScenario() -> Scenario {
        Scenario(
            id: "cafe_progress_render", title: "At the cafe", titleZh: "在咖啡店",
            category: "测试", difficulty: 2, level: "A2",
            objective: "Order food and drinks politely.",
            aiRole: "waiter", learnerRole: "customer", opening: "Hi, what can I get you?",
            targetVocabulary: ["coffee", "main course", "water", "bread"],
            targetGrammar: ["would like"],
            targetSentences: ["I'd like a coffee, please.", "Could I have the main course?"],
            maxTurns: 12
        )
    }

    /// 等这一轮的老师回复落定（**且退出生成态**）：`isGenerating` 挂着时
    /// 界面上那一行还在流式刷新，离屏渲染会拍到半句话。
    private func waitForAssistantReply(_ chat: ChatService, expected: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let assistantCount = chat.messages.filter { $0.role == .assistant }.count
            if !chat.isGenerating && assistantCount >= expected { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func dump(_ render: Render, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(render.rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }
}

// MARK: - 桩

/// 活着的 LLM：让发送链路能正常收尾（老师说什么与本用例无关）。
private final class AliveProgressLLMProvider: LLMProvider, @unchecked Sendable {
    let providerID = "stub.progress.render.llm"
    let kind: AIProviderKind = .llm

    func initialize(config: ProviderConfig) async throws {}
    func load() async throws {}
    func unload() async {}
    func healthCheck() async -> ProviderHealth { .connected(model: "mock-model") }
    func capabilities() -> ProviderCapabilities {
        ProviderCapabilities(streaming: true, structuredOutput: true, multilingual: true)
    }
    func metadata() -> ProviderMetadata {
        ProviderMetadata(id: providerID, displayName: "活桩", runtime: .mock, version: "1.0")
    }
    func discoverModels() async throws -> [DiscoveredModel] { [] }
    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: "Of course, anything else?", model: request.model, finishReason: "stop")
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error> {
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMChunk(textDelta: "Of course, "))
            continuation.yield(LLMChunk(textDelta: "anything else?"))
            continuation.finish()
        }
    }
}
