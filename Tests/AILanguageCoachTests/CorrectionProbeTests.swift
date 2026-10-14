import AIDomain
import AIInterfaces
import AIInfrastructure
import AIProviders
import AppCore
@testable import AIServices
@testable import AppUI
import XCTest

/// 「老师指出错误 → 必须有改一改卡片」这条链路的回归（用户 2026-09-24 报障）。
///
/// **现场取证**（真实库 + 真实对话流水）：老师两次口头纠正 ——
/// 「For comparing food, we use "compared to"」与「be careful with the spelling of "prefer"」——
/// 界面上却一张卡片都没有，`corrections` 表从 09-13 起就再没新增过一条。
/// 原因不在卡片，也不在错题本：老师的回复里**根本没有 `[[FIX]]` 行**，
/// 而卡片 / 错题本 / 「老师记住了你什么」全都只认那一行。
///
/// 修法分三层，本文件三层都钉：
/// ① 提示词：**无错也必须收尾**，写成 `[[FIX]] NONE`（把「没找到错」变成一个看得见的动作）；
/// ② 解析层：报出「这一轮到底有没有交代」；
/// ③ 服务层：没交代就追问一次，把那一行逼出来（判据确定、命中才花钱、每会话封顶）。
@MainActor
final class CorrectionProbeTests: XCTestCase {

    // MARK: - ① 提示词：每轮必须收尾

    /// 无错时也要写 `[[FIX]] NONE` —— 少了这句，模型就会「什么也不写」，
    /// 而那与「忘了写」在下游完全无法区分。
    func testTeacherIsToldToConcludeEveryTurn() {
        let prompt = PromptBuilder.teacherSystemPrompt(
            learningLanguage: "English",
            nativeLanguage: "Chinese",
            proficiency: "A2",
            practiceMode: .conversation
        )
        XCTAssertTrue(prompt.contains("[[FIX]] NONE"), "无错时的收尾写法必须写在人设里")
        XCTAssertTrue(
            prompt.contains("Never finish a reply without one of the two"),
            "只给格式不够 —— 必须明说「不许不写」"
        )
        XCTAssertFalse(
            prompt.contains("do NOT output the line at all"),
            "旧口径（无错就什么都不写）必须删掉，否则模型两套指令打架"
        )
    }

    /// 追问提示词只问一件事，且**不带对话历史**（弱模型有历史就会抄句子）。
    func testProbePromptAsksForTheLineOnly() {
        let prompt = PromptBuilder.correctionProbePrompt(
            learningLanguage: "English",
            nativeLanguage: "Chinese",
            learnerMessage: "I perfer tea.",
            teacherReply: "Careful with the spelling of prefer."
        )
        XCTAssertTrue(prompt.contains("I perfer tea."))
        XCTAssertTrue(prompt.contains("Careful with the spelling of prefer."))
        XCTAssertTrue(prompt.contains("[[FIX]] the learner's original sentence"))
        XCTAssertTrue(prompt.contains("[[FIX]] NONE"), "无错时也要能明确回 NONE")
    }

    // MARK: - ② 解析层：交代没交代

    func testExtractCorrectionsReportsConcludedForBothOutcomes() {
        let withLine = ChatService.extractCorrections(
            "Nice try!\n[[FIX]] I perfer tea. => I prefer tea. => prefer 拼写"
        )
        XCTAssertTrue(withLine.didConclude, "落了纠错行 = 交代了")
        XCTAssertEqual(withLine.corrections.count, 1)
        XCTAssertFalse(withLine.cleanText.contains("[[FIX]]"), "纠错行不许留在正文里")

        let withNone = ChatService.extractCorrections("Great sentence!\n[[FIX]] NONE")
        XCTAssertTrue(withNone.didConclude, "写了 NONE 也算交代了")
        XCTAssertTrue(withNone.corrections.isEmpty, "NONE 不是一条纠错")
        XCTAssertFalse(withNone.cleanText.contains("NONE"), "NONE 不许被念出来/显示出来")

        let silent = ChatService.extractCorrections("Great sentence! What else do you like?")
        XCTAssertFalse(silent.didConclude, "什么都没写 = 漏了 —— 追问的判据就在这儿")
    }

    func testNoneMarkerIsRecognizedInItsCommonSpellings() {
        for body in ["NONE", "none.", "None **", "None!", "无", "无错误。"] {
            XCTAssertTrue(
                GrammarCorrectionLine.isNoneMarker(body),
                "「\(body)」应当被认成「本轮无错」"
            )
        }
        for body in ["no mistakes here", "I prefer tea.", ""] {
            XCTAssertFalse(
                GrammarCorrectionLine.isNoneMarker(body),
                "「\(body)」不是无错标记，不能被吞掉"
            )
        }
    }

    // MARK: - ③ 服务层：漏行才追问

    func testProbeGateTruthTable() {
        typealias Gate = ChatService
        // 漏行 + 有学员发言 + 非考试 + 还有额度 → 追问
        XCTAssertTrue(Gate.shouldProbeCorrection(
            didConclude: false, hasLearnerMessage: true, probesUsed: 0, isExam: false
        ))
        // 已经交代过 → 不追问
        XCTAssertFalse(Gate.shouldProbeCorrection(
            didConclude: true, hasLearnerMessage: true, probesUsed: 0, isExam: false
        ))
        // 老师开场那条（本轮没有学员发言）→ 不追问
        XCTAssertFalse(Gate.shouldProbeCorrection(
            didConclude: false, hasLearnerMessage: false, probesUsed: 0, isExam: false
        ))
        // 考试模式 → 绝不追问（考场不纠错，作答路径零请求是硬口径）
        XCTAssertFalse(Gate.shouldProbeCorrection(
            didConclude: false, hasLearnerMessage: true, probesUsed: 0, isExam: true
        ))
        // 额度用尽 → 不再追问
        XCTAssertFalse(Gate.shouldProbeCorrection(
            didConclude: false, hasLearnerMessage: true,
            probesUsed: ChatService.correctionProbeLimit, isExam: false
        ))
        XCTAssertTrue(Gate.shouldProbeCorrection(
            didConclude: false, hasLearnerMessage: true,
            probesUsed: ChatService.correctionProbeLimit - 1, isExam: false
        ))
    }

    /// 端到端：老师把纠正讲在正文里、却没落行 → 追问一次 → 卡片出现（错题本同一份来源）。
    func testMissedCorrectionIsProbedIntoTheCard() async throws {
        let (chat, probes, cleanup) = try await makeChat(
            mainReply: "Nice! I noticed two small things. For comparing food, we use \"compared to\". "
                + "Which one do you want to try this weekend?",
            probeReply: "[[FIX]] Compare with chocolate cake, I perfer Portuguese egg tarts. "
                + "=> Compared to chocolate cake, I prefer Portuguese egg tarts. => 比较用 compared to；prefer 拼写"
        )
        defer { cleanup() }

        chat.send("Compare with chocolate cake, I perfer Portuguese egg tarts.")
        await waitUntil { !chat.messages.isEmpty && chat.isGenerating == false }
        await waitUntil { !chat.correctionsByMessage.isEmpty }

        XCTAssertEqual(probes.count, 1, "老师漏了收尾行，应当追问一次")
        XCTAssertEqual(chat.correctionCount, 1, "追问回来的纠错必须落成改一改卡片")
        let card = try XCTUnwrap(chat.correctionsByMessage.values.first?.first)
        XCTAssertTrue(card.original.contains("perfer"), "卡片要钉住学员原来那句")
        XCTAssertTrue(card.corrected.contains("prefer"))
        XCTAssertNil(chat.errorMessage)
    }

    /// 老师写了 NONE（明确说没错）→ 一个字都不多问。
    func testNothingIsProbedWhenTheTeacherSaidNone() async throws {
        let (chat, probes, cleanup) = try await makeChat(
            mainReply: "That is a lovely sentence! What else do you like?\n[[FIX]] NONE",
            probeReply: "[[FIX]] 这一行不该被用到。"
        )
        defer { cleanup() }

        chat.send("I like chocolate cake.")
        await waitUntil { !chat.messages.isEmpty && chat.isGenerating == false }

        XCTAssertEqual(probes.count, 0, "老师已经明确交代「没错」，不许再问")
        XCTAssertEqual(chat.correctionCount, 0)
    }

    // MARK: - 陈旧纠错（用户 2026-10-14 报障）

    /// 老师把两轮前的纠错原样重发成 `[[FIX]]` 行：卡片挂在与学员最新一句
    /// 毫无关系的回复下。解析层整条丢弃；这一轮因此仍算「没交代」→ 追问一次
    /// （追问结果过同一道闸，拿不到就当作本轮无纠错）。
    func testStaleCorrectionIsDroppedAndProbed() async throws {
        let (chat, probes, cleanup) = try await makeChat(
            mainReply: "Watermelon is a perfect summer treat! It is sweet and juicy.\n"
                + "[[FIX]] I has no idea about what to chat. => I have no idea what to chat about. => has 改为 have",
            probeReply: "[[FIX]] NONE"
        )
        defer { cleanup() }

        chat.send("I am eating watermelon.")
        await waitUntil { !chat.messages.isEmpty && chat.isGenerating == false }

        XCTAssertEqual(probes.count, 1, "陈旧行不算交代，应当追问一次")
        XCTAssertEqual(chat.correctionCount, 0, "陈旧纠错不许落成卡片 / 进错题本")
        XCTAssertFalse(chat.messages.last?.content.contains("[[FIX]]") ?? true, "纠错行不许漏进正文")
        XCTAssertNil(chat.errorMessage)
    }

    /// 同一轮里真纠错与陈旧纠错并存：只留本轮的，且不再追问。
    func testStaleLineBesideARealOneKeepsOnlyTheRealOne() async throws {
        let (chat, probes, cleanup) = try await makeChat(
            mainReply: "Good try!\n"
                + "[[FIX]] I eat fruit at my dinner today. => I ate fruit for dinner today. => 过去发生用 ate；for dinner\n"
                + "[[FIX]] I has no idea about what to chat. => I have no idea what to chat about. => has 改为 have",
            probeReply: "[[FIX]] 这一行不该被用到。"
        )
        defer { cleanup() }

        chat.send("I eat fruit at my dinner today.")
        await waitUntil { !chat.messages.isEmpty && chat.isGenerating == false }

        XCTAssertEqual(probes.count, 0, "这一轮有真纠错 = 交代过了，不许再问")
        XCTAssertEqual(chat.correctionCount, 1, "只留本轮这条")
        let card = try XCTUnwrap(chat.correctionsByMessage.values.first?.first)
        XCTAssertEqual(card.original, "I eat fruit at my dinner today.")
    }

    // MARK: - 夹具

    /// 追问调用计数器（`responder` 是 `@Sendable`，要自己管同步）。
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func waitUntil(
        _ condition: @MainActor @escaping () -> Bool, timeout: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    /// 主回复与追问回复分开给：`[[FIX]] NONE` 那句由用例自己写进 `mainReply`。
    private func makeChat(
        mainReply: String,
        probeReply: String?
    ) async throws -> (ChatService, Counter, () -> Void) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-probe-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        let providerConfig = ProviderConfig(
            id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model"
        )
        try await store.updateProvider(providerConfig)
        try await store.selectModel("mock-model", for: .llm)
        let services = CoachServices(config: store, databasePath: ":memory:")
        try await services.bootstrapLLM()

        // 追问提示词的特征开头（见 `PromptBuilder.correctionProbePrompt`）——
        // 用请求内容分辨「主回复」与「追问」，这样两条路径仍由同一个 provider 回答。
        let counter = Counter()
        let mock = MockLLMProvider(providerID: "ollama.llm") { request in
            let last = request.messages.last?.content ?? ""
            if last.contains("checking ONE turn of a") {
                counter.bump()
                return probeReply ?? "[[FIX]] NONE"
            }
            return mainReply
        }
        try await mock.initialize(config: providerConfig)
        try await mock.load()
        // 覆盖 `bootstrapLLM()` 注册的那个内置 mock（`register` 是单 provider 赋值）。
        await services.llm.register(mock)

        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: fileURL) }
        return (ChatService(services: services), counter, cleanup)
    }
}
