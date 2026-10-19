import AIDomain
import AIInfrastructure
import AIInterfaces
import AIProviders
import AIServices
import AppCore
import XCTest

/// 练习页「这关还差什么」常驻进度（#598）。
///
/// 背景：通关 = 主线任务完成 + 教学重点达标（#189 起的口径），但练习页原来只有
/// 静态素材信息（角色 / 等级 / objective / 目标词 chips）—— 学员练到一半想知道
/// 「还差什么」，只能去读前情提要那一大段文字，而教学重点在练习中**根本没有**
/// 实时重算（进入时的 focusItems 是 turnsUsed:0 的占位）。
///
/// 本文件两层判据：
/// - **行为**：`ChatService.liveFocus` 与 `briefing.quest` 随发言实时推进，
///   且与结算走同一条纯函数链（`CurriculumScorer.coverage` → `.focus`）；
/// - **源码哨兵**：`scenarioStrip` 渲染的是**实时**真源（`chat.liveFocus` /
///   `briefing?.quest`），不是进入时的那份占位快照。
@MainActor
final class PracticeProgressTests: XCTestCase {

    // MARK: - 测试基建

    private struct Fixture {
        let services: CoachServices
        let directory: URL
    }

    /// 临时配置 + `:memory:` 学习库 + 一个「活着」的 LLM 桩。
    ///
    /// 桩只要能让 `generate` 返回一句话：本用例看的是**学员那句话**之后
    /// 实时进度的变化，老师的回复内容无关（但发送链路要能正常收尾，
    /// 否则 `isGenerating` 挂着，下一句发不出去）。
    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await store.updateProvider(
            ProviderConfig(id: "mock.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        let services = CoachServices(config: store, databasePath: ":memory:")
        try await services.bootstrapLLM()
        await services.llm.register(AliveLLMProvider())
        return Fixture(services: services, directory: directory)
    }

    /// A2 咖啡店：两句目标句 + 四个目标词。
    ///
    /// A2 门槛（`CurriculumCriteria`）= 目标句 2 · 目标词 4 —— 素材刚好等于门槛，
    /// 断言里的期望数因此是确定的 2 与 4，不靠运行时反推。
    private func makeScenario() -> Scenario {
        Scenario(
            id: "cafe_progress_test", title: "At the cafe", titleZh: "在咖啡店",
            category: "测试", difficulty: 2, level: "A2",
            objective: "Order food and drinks politely.",
            aiRole: "waiter", learnerRole: "customer", opening: "Hi, what can I get you?",
            targetVocabulary: ["coffee", "main course", "water", "bread"],
            targetGrammar: ["would like"],
            targetSentences: ["I'd like a coffee, please.", "Could I have the main course?"],
            maxTurns: 12
        )
    }

    private func makeChat(_ fixture: Fixture) -> ChatService {
        ChatService(services: fixture.services)
    }

    // MARK: - 行为：实时教学重点

    /// 学员每说一句，教学重点的命中数就动一格 —— 且与结算判定同源。
    ///
    /// 反证：把 `liveFocus` 改成读 `briefing?.focusItems`（进入时的占位）或直接
    /// 返回 `.empty` → 本条红在 matchedWords / wordItems 的断言上。
    func testLiveFocusTracksUtterancesTurnByTurn() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chat = makeChat(fixture)
        let scenario = makeScenario()
        chat.startScenario(scenario, briefing: ScenarioBriefingBuilder.build(scenario: scenario))

        // 进入时：一句没说，全部未命中；主线停在第一步。
        let entry = chat.liveFocus
        XCTAssertFalse(entry.isEmpty, "有目标句 / 目标词就不是空重点")
        XCTAssertEqual(entry.matchedSentences, 0)
        XCTAssertEqual(entry.matchedWords, 0)
        XCTAssertEqual(entry.requiredSentences, 2, "A2 门槛 2 句，素材正好 2 句")
        XCTAssertEqual(entry.requiredWords, 4, "A2 门槛 4 词，素材正好 4 词")
        XCTAssertEqual(chat.briefing?.quest.doneCount, 0)
        XCTAssertEqual(chat.briefing?.quest.currentText, "I'd like a coffee, please.")

        // 第一句：完整说出目标句 ①，用上 coffee。
        chat.send("I'd like a coffee, please.")
        await waitForAssistantReply(chat, expected: 1)
        let afterFirst = chat.liveFocus
        XCTAssertEqual(afterFirst.matchedSentences, 1, "整句说出 → 目标句 ① 命中")
        XCTAssertEqual(afterFirst.matchedWords, 1, "只用上 coffee 一个词")
        XCTAssertEqual(afterFirst.summary, "目标句 1/2 · 目标词 1/4")
        XCTAssertFalse(afterFirst.isSatisfied)
        XCTAssertEqual(hit(of: "coffee", in: afterFirst), true)
        XCTAssertEqual(hit(of: "main course", in: afterFirst), false)
        XCTAssertEqual(hit(of: "bread", in: afterFirst), false)
        // 主线的「当前节点」跟着这一句往前走（常驻进度行的右半截读它）。
        XCTAssertEqual(chat.briefing?.quest.doneCount, 1)
        XCTAssertEqual(chat.briefing?.quest.currentText, "Could I have the main course?")

        // 第二句：说出目标句 ②，用上 main course 与 bread（coffee 仍算 ——
        // 覆盖度是整局并集，不是「只看最近一句」）。
        chat.send("Could I have the main course and some bread?")
        await waitForAssistantReply(chat, expected: 2)
        let afterSecond = chat.liveFocus
        XCTAssertEqual(afterSecond.matchedSentences, 2)
        XCTAssertEqual(afterSecond.matchedWords, 3, "coffee + main course + bread；water 还没说")
        XCTAssertEqual(afterSecond.summary, "目标句 2/2 · 目标词 3/4")
        XCTAssertEqual(hit(of: "water", in: afterSecond), false, "没说到的词必须保持未命中")
        XCTAssertTrue(chat.briefing?.quest.isComplete == true, "两句目标句都是主线锚点，说完即完成")
    }

    /// 不在情景里（随口练 / 普通练习）→ 空重点，界面据此不渲染进度元素。
    ///
    /// 反证：去掉 `guard let scenario = scenarioProgress?.scenario` →
    /// 本条红（会拿一个不存在的场景算出一堆 0/0）。
    func testLiveFocusIsEmptyOutsideScenario() {
        // 不起 LLM、不发消息：这条只验「没有进行中的情景」时的守卫。
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-progress-no-scenario-\(UUID().uuidString).json")
        )
        let chat = ChatService(services: CoachServices(config: store, databasePath: ":memory:"))
        XCTAssertTrue(chat.liveFocus.isEmpty, "没有进行中的情景就没有「这一关的重点」")
    }

    /// 退出情景后同样回落空重点（结算那一刻 `scenarioProgress` 已清）。
    func testLiveFocusIsEmptyAfterScenarioEnds() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chat = makeChat(fixture)
        let scenario = makeScenario()
        chat.startScenario(scenario, briefing: ScenarioBriefingBuilder.build(scenario: scenario))
        chat.send("I'd like a coffee, please.")
        XCTAssertFalse(chat.liveFocus.isEmpty)
        chat.endScenario()
        XCTAssertTrue(chat.liveFocus.isEmpty, "退出情景 → 这一局的覆盖度随之失效")
    }

    // MARK: - 源码哨兵：常驻进度行必须接实时真源

    /// `scenarioStrip` 必须渲染实时进度行，且读的是**实时**真源。
    ///
    /// 三种失效方式各红一处：
    /// - 删掉进度行 → 找不到 `liveProgressRow(`；
    /// - 改接进入时的占位快照（`briefing.focusItems`）→ `chat.liveFocus` 缺失 +
    ///   `focusItems` 出现（那是 turnsUsed:0 算的，练习中永远「全未达成」）；
    /// - 进度行不显示「还差哪一步」→ `currentStep` / 「还差：」缺失。
    func testScenarioStripRendersTheLiveProgressRow() throws {
        let src = try source("AppUI/Views/ChatView.swift")
        let strip = body(of: "private func scenarioStrip(", in: src)
        XCTAssertFalse(strip.isEmpty, "找不到 scenarioStrip")
        XCTAssertTrue(strip.contains("liveProgressRow("),
                      "情景条必须挂上常驻进度行（#598：这关还差什么）")
        XCTAssertTrue(strip.contains("chat.liveFocus"),
                      "教学重点必须读实时真源 chat.liveFocus")
        XCTAssertFalse(strip.contains("focusItems"),
                       "不许读 briefing.focusItems —— 那是进入时 turnsUsed:0 的占位")

        let row = body(of: "private func liveProgressRow(", in: src)
        XCTAssertFalse(row.isEmpty, "找不到 liveProgressRow")
        XCTAssertTrue(row.contains("quest.currentStep"), "进度行要指出当前节点")
        XCTAssertTrue(row.contains("还差："), "进度行要回答「还差什么」")
        XCTAssertTrue(row.contains("focus.matchedSentences") && row.contains("focus.requiredSentences"),
                      "目标句 pill 必须是「已命中/门槛」两个实数")

        let chip = body(of: "private func targetWordChip(", in: src)
        XCTAssertFalse(chip.isEmpty, "找不到 targetWordChip")
        XCTAssertTrue(chip.contains("isHit"), "目标词 chip 要按说到没说到着色")
    }

    // MARK: - 工具

    /// 等到这一轮的老师回复落定（**且退出生成态**）。
    ///
    /// 只数消息数不够：消息 append 与 defer 清 `isGenerating` 之间有窗口，
    /// 此刻发下一句会被 `guard !isGenerating` 静默丢掉 —— 测试就会
    /// 「第二句明明发了，覆盖度却不动」（本轮实测就是这个形态）。
    private func waitForAssistantReply(_ chat: ChatService, expected: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let assistantCount = chat.messages.filter { $0.role == .assistant }.count
            if !chat.isGenerating && assistantCount >= expected { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func hit(of word: String, in focus: TeachingFocus) -> Bool? {
        focus.wordItems.first { $0.text == word }?.isHit
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 取出函数体：从 `needle` 起到下一个成员声明为止。
    ///
    /// ⚠️ **整行注释先剔掉**（`//` / `///` 开头）：判据字符串一旦在注释里出现过，
    /// 哨兵就是假绿 —— 源码里写着「不许读 briefing.focusItems」的警示注释，
    /// 会把 `XCTAssertFalse(contains("focusItems"))` 直接顶红（本轮实测）。
    /// 与 `VoiceInputWiringTests.codeLines` 同一条纪律。
    private func body(of needle: String, in source: String) -> String {
        guard let range = source.range(of: needle) else { return "" }
        let rest = source[range.lowerBound...]
        let tail = rest.dropFirst(needle.count)
        let terminators = ["\n    public func ", "\n    private func ", "\n    func ",
                           "\n    public var ", "\n    private var ", "\n    var ",
                           "\n    public nonisolated ", "\n    // MARK:"]
        let ends = terminators.compactMap { tail.range(of: $0)?.lowerBound }
        let raw = ends.min().map { String(rest[..<$0]) } ?? String(rest)
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

// MARK: - 桩

/// 活着的 LLM：generate 返回一句固定回复。本用例不关心老师说什么。
private final class AliveLLMProvider: LLMProvider, @unchecked Sendable {
    let providerID = "stub.alive.llm"
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
