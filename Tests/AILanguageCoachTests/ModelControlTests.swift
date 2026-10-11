import AIDomain
import AIInterfaces
import AIServices
import AIInfrastructure
import AppCore
@testable import AppUI
import XCTest

/// 模型启停、错误文案、语音拼写纠正、token 分档、夜晚锁定等纯逻辑的回归测试。
@MainActor
final class ModelControlTests: XCTestCase {

    // MARK: - 错误文案必须点明「哪个模型」

    func testLabelCombinesProviderAndModel() {
        XCTAssertEqual(ModelDiagnostics.label(providerName: "本地模型", model: "qwen3:8b"), "本地模型 · qwen3:8b")
        XCTAssertEqual(ModelDiagnostics.label(providerName: "DeepSeek", model: nil), "DeepSeek")
        XCTAssertEqual(ModelDiagnostics.label(providerName: nil, model: "gpt-x"), "gpt-x")
        XCTAssertEqual(ModelDiagnostics.label(providerName: "", model: "  "), "模型")
    }

    func testErrorDescriptionNamesTheFailingModel() {
        let text = ModelDiagnostics.describe(
            providerName: "本地模型",
            model: "qwen3:8b",
            error: AIProviderError.connectionFailed("Could not connect to the server.")
        )
        XCTAssertTrue(text.contains("本地模型 · qwen3:8b"), text)
        XCTAssertTrue(text.contains("连接失败"), text)
        XCTAssertTrue(text.contains("启动"), "应当给出可操作建议：\(text)")
    }

    func testHealthDescriptionNamesTheFailingModel() {
        let text = ModelDiagnostics.describe(
            providerName: "教师语音",
            model: "vivian",
            health: .runtimeUnavailable(reason: "Connection refused")
        )
        XCTAssertTrue(text.contains("教师语音 · vivian"), text)
        XCTAssertTrue(text.contains("服务未启动或不可达"), text)
    }

    func testNotInitializedMessagePointsToStartupWait() {
        let text = ModelDiagnostics.describe(
            providerName: "本地模型", model: "qwen3:8b", error: AIProviderError.notInitialized
        )
        XCTAssertTrue(text.contains("正在启动中"), text)
        XCTAssertTrue(text.contains("qwen3:8b"), text)
    }

    func testStoppedHintTellsUserWhereToStart() {
        let text = ModelDiagnostics.stoppedHint(providerName: "本地模型", model: "qwen3:8b")
        XCTAssertTrue(text.contains("已关闭"), text)
        XCTAssertTrue(text.contains("启动"), text)
        XCTAssertTrue(text.contains("设置"), text)
    }

    // MARK: - 本地服务启停命令（真实执行，用无害命令验证）

    /// ⚠️ 这些用例**真的**执行 shell，所以必须先拿到用户授权（#S2-6 的闸门）。
    /// 这正是闸门该有的样子：没有授权，命令一条都跑不出去。
    override func setUp() {
        super.setUp()
        ShellCommandApproval.revokeAll()
    }

    override func tearDown() {
        ShellCommandApproval.revokeAll()
        super.tearDown()
    }

    func testCommandsAreRefusedWithoutApproval() async {
        // 反向用例：未授权时必须拒绝，且错误要带出命令原文（UI 要靠它提示用户）。
        do {
            _ = try await LocalServiceRunner.run("echo should-not-run")
            XCTFail("未授权的命令不该被执行")
        } catch let failure as LocalServiceRunner.Failure {
            guard case .notApproved(let command) = failure else {
                return XCTFail("应是未授权错误，实际：\(failure)")
            }
            XCTAssertEqual(command, "echo should-not-run")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testRunCommandReturnsExitCodeAndOutput() async throws {
        ShellCommandApproval.approve("echo hello-service")
        let result = try await LocalServiceRunner.run("echo hello-service")
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.output, "hello-service")
    }

    func testStopTreatsExitCodeOneAsSuccess() async throws {
        // pkill 在「本来就没有该进程」时返回 1 —— 对「关闭」而言这就是幂等成功。
        let config = ProviderConfig(
            id: "local.x", kind: .tts, runtime: .externalLocalRuntime,
            serviceStopCommand: "exit 1"
        )
        ShellCommandApproval.approve("exit 1")
        do {
            try await LocalServiceControl.stop(config: config)
        } catch {
            XCTFail("退出码 1 不应报错：\(error)")
        }
    }

    func testStopReportsRealFailure() async throws {
        let config = ProviderConfig(
            id: "local.x", kind: .tts, runtime: .externalLocalRuntime,
            serviceStopCommand: "exit 7"
        )
        ShellCommandApproval.approve("exit 7")
        do {
            _ = try await LocalServiceControl.stop(config: config)
            XCTFail("退出码 7 应当报错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("7"), error.localizedDescription)
        }
    }

    func testStartWithoutEndpointOnlyRunsCommand() async throws {
        // 没有端点时不等待可达性，命令执行完即返回。
        let config = ProviderConfig(
            id: "local.x", kind: .tts, runtime: .externalLocalRuntime,
            serviceStartCommand: "true"
        )
        ShellCommandApproval.approve("true")
        try await LocalServiceControl.start(config: config, reachTimeout: 1)
    }

    func testEmptyCommandIsRejected() async {
        do {
            _ = try await LocalServiceRunner.run("   ")
            XCTFail("空命令应当报错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("启停命令"), error.localizedDescription)
        }
    }

    // MARK: - 语音拼写纠正规则（只纠错，不重写）

    func testAcceptsSmallSpellingFix() {
        XCTAssertEqual(
            SpellingFixRule.accepted(original: "I like to practize English.", candidate: "I like to practice English."),
            "I like to practice English."
        )
    }

    func testRejectsRewriteEvenIfItLooksBetter() {
        let original = "I go to park yesterday and see a big dog."
        let rewritten = "Yesterday I went to the park and saw a large dog."
        XCTAssertEqual(SpellingFixRule.accepted(original: original, candidate: rewritten), original,
                       "改动过大时必须保留原文")
    }

    func testExplanationOnSecondLineOnlyKeepsTheSentence() {
        // 模型在句子下面补了一句解释：只取首行句子，解释绝不混进输入框。
        let original = "I have a apple."
        let candidate = "I have an apple.\nThe article should be \"an\" before a vowel sound."
        XCTAssertEqual(SpellingFixRule.accepted(original: original, candidate: candidate), "I have an apple.")
    }

    func testChattyFirstLineIsRejected() {
        // 首行本身是「套话 + 句子」而非句子 → 属于改写，必须保留原文。
        let original = "I have a apple."
        let candidate = "Sure, here is the corrected sentence: I have an apple."
        XCTAssertEqual(SpellingFixRule.accepted(original: original, candidate: candidate), original)
    }

    func testSanitizeStripsQuotesAndFences() {
        XCTAssertEqual(SpellingFixRule.sanitize("\"Hello world\""), "Hello world")
        XCTAssertEqual(SpellingFixRule.sanitize("```\nI can swim.\n```"), "I can swim.")
        XCTAssertEqual(SpellingFixRule.sanitize("「你好」"), "你好")
    }

    func testEmptyCandidateKeepsOriginal() {
        XCTAssertEqual(SpellingFixRule.accepted(original: "I can swim.", candidate: "   "), "I can swim.")
    }

    func testChangeRatioIsZeroForIdenticalWords() {
        XCTAssertEqual(SpellingFixRule.changeRatio(["i", "am"], ["i", "am"]), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(SpellingFixRule.changeRatio(["i", "am"], ["you", "are"]), 0.9)
    }

    // MARK: - 语音输入与手打输入的合并

    func testMergedInputKeepsTypedTextAndAppendsSpeech() {
        XCTAssertEqual(VoiceTranscriptMerge.merged(base: "", voice: "hello"), "hello")
        XCTAssertEqual(VoiceTranscriptMerge.merged(base: "I want", voice: "a coffee"), "I want a coffee")
        XCTAssertEqual(VoiceTranscriptMerge.merged(base: "I want ", voice: "a coffee"), "I want a coffee")
        XCTAssertEqual(VoiceTranscriptMerge.merged(base: "typed only", voice: "  "), "typed only")
    }

    /// 回归：`ChatView` 的属性有默认值 `= nil`，手写 init 漏赋值**不会编译报错**。
    /// 曾因此让「模型关闭提示条」和「语音流式写入」双双静默失效（UI 截图才发现）。
    func testChatViewInitStoresStreamingAndStoppedInputs() {
        let chat = ChatService(services: CoachServices(config: ConfigStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-chatview-\(UUID().uuidString).json")), databasePath: ":memory:"))
        let view = ChatView(
            chat: chat,
            modelName: "qwen3:8b",
            health: .connected(model: "qwen3:8b"),
            voicePhase: .recording,
            voiceTranscript: "hello wor",
            modelStoppedNotice: "本地模型 · qwen3:8b 已关闭"
        )
        XCTAssertEqual(view.voicePhase, .recording, "voicePhase 必须被 init 存入，否则三颗语音按钮的语义全错")
        XCTAssertEqual(view.voiceTranscript, "hello wor", "voiceTranscript 必须被 init 存入，否则语音流式写不进输入框")
        XCTAssertEqual(view.modelStoppedNotice, "本地模型 · qwen3:8b 已关闭", "modelStoppedNotice 必须被 init 存入，否则关闭提示条不显示")
    }

    /// 同一类 bug 的新增面：预设提问 / 翻译回调 / 翻译失败提示同样带默认值，漏赋值不报错。
    func testChatViewInitStoresStarterQuestionsAndTranslateCallbacks() {
        let chat = ChatService(services: CoachServices(config: ConfigStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-chatview2-\(UUID().uuidString).json")), databasePath: ":memory:"))
        let questions = ["How was your day?", "Can you help me order a coffee?"]
        let view = ChatView(
            chat: chat,
            modelName: "qwen3:8b",
            health: .connected(model: "qwen3:8b"),
            starterQuestions: questions,
            onTranslate: { _ in },
            translationError: "翻译失败：模型未就绪"
        )
        XCTAssertEqual(view.starterQuestions, questions, "预设提问漏赋值 → 输入框永不轮换")
        XCTAssertNotNil(view.onTranslate, "翻译回调漏赋值 → 点翻译按钮没反应")
        XCTAssertEqual(view.translationError, "翻译失败：模型未就绪")
    }

    /// ⑦-B① 同一类 bug 的新面：话题卡也带默认值。
    ///
    /// ⚠️ 这里钉的是**装载**而不是「卡片长什么样」：手写 init 里漏一行赋值，
    /// 编译照样通过，界面上就是「卡永远不出现」——而没有任何报错。
    func testChatViewInitStoresKickoffCards() {
        let chat = ChatService(services: CoachServices(config: ConfigStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-chatview-kickoff-\(UUID().uuidString).json")), databasePath: ":memory:"))
        let cards = [
            KickoffSuggestion(
                kind: .todayWord, title: "用今天这个词开口", detail: "resilient",
                action: .send(text: "Can you help me use the word \"resilient\" in a sentence?")
            ),
            KickoffSuggestion(
                kind: .resume, title: "接着练《咖啡店点单》", detail: "上次练到 2/3 步",
                action: .openScenario(id: "s1")
            )
        ]
        let view = ChatView(
            chat: chat,
            modelName: "qwen3:8b",
            health: .connected(model: "qwen3:8b"),
            kickoffs: cards,
            onKickoff: { _ in }
        )
        XCTAssertEqual(view.kickoffs, cards, "话题卡漏赋值 → 空态永远只有一句问候，没有能点的东西")
        XCTAssertNotNil(view.onKickoff, "点了卡片没反应，等于推荐了个寂寞")
    }

    /// 同一类 bug 的第三面（需求 3/4）：前情提要 / 自动复盘回执 / 练习模式也带默认值。
    /// 漏赋值不会编译报错，但界面上就是「前情提要永远不出现」。
    func testChatViewInitStoresBriefingAndPracticeMode() {
        let chat = ChatService(services: CoachServices(config: ConfigStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-chatview3-\(UUID().uuidString).json")), databasePath: ":memory:"))
        let scenario = Scenario(
            id: "restaurant", title: "Restaurant", titleZh: "餐厅点餐", category: "日常",
            difficulty: 1, level: "A1", objective: "Order a meal", aiRole: "waiter",
            learnerRole: "customer", opening: "Good evening!",
            targetVocabulary: ["menu"], targetGrammar: [], targetSentences: ["Can I have the menu, please?"],
            maxTurns: 8
        )
        let briefing = ScenarioBriefingBuilder.build(scenario: scenario)
        // 复盘回执：文案与动作是**一个值**（跳转目标不许另存一份）。
        let notice = AppNotice(
            text: "上一段练习已自动复盘",
            action: NoticeAction(title: "去看复盘") { }
        )
        let view = ChatView(
            chat: chat,
            modelName: "qwen3:8b",
            health: .connected(model: "qwen3:8b"),
            practiceMode: .freeTalk,
            onStartFreeTalk: { },
            briefing: briefing,
            practiceNotice: notice
        )
        XCTAssertEqual(view.practiceMode, .freeTalk, "练习模式漏赋值 → 头部按钮文案就错了")
        XCTAssertNotNil(view.onStartFreeTalk, "开启新练习回调漏赋值 → 按钮点了没反应")
        XCTAssertEqual(view.briefing?.scenarioID, "restaurant", "前情提要漏赋值 → 学员看不到「上次练到哪」")
        XCTAssertEqual(view.practiceNotice?.text, "上一段练习已自动复盘")
        XCTAssertEqual(
            view.practiceNotice?.action?.title, "去看复盘",
            "复盘回执必须自带跳转，否则学员只知道「收进学习记录了」，还得自己去记录页里翻"
        )
    }

    // MARK: - 今日 token 分档（0–2000 督促 / 2000–20000 鼓励 / ≥20000 休息）

    func testNudgeTiersFollowNewThresholds() {
        XCTAssertEqual(TeacherCorner.nudgeTier(for: 0), 0)
        XCTAssertEqual(TeacherCorner.nudgeTier(for: 1_999), 0)
        XCTAssertEqual(TeacherCorner.nudgeTier(for: 2_000), 1)
        XCTAssertEqual(TeacherCorner.nudgeTier(for: 19_999), 1)
        XCTAssertEqual(TeacherCorner.nudgeTier(for: 20_000), 2)
        XCTAssertEqual(TeacherCorner.nudgeTier(for: 9_999_999), 2)
    }

    func testNudgePoolsDifferPerTier() {
        let urge = TeacherCorner.pool(for: 100)
        let cheer = TeacherCorner.pool(for: 10_000)
        let rest = TeacherCorner.pool(for: 100_000)
        XCTAssertFalse(urge.isEmpty)
        XCTAssertFalse(cheer.isEmpty)
        XCTAssertFalse(rest.isEmpty)
        XCTAssertNotEqual(urge, cheer)
        XCTAssertNotEqual(cheer, rest)
        XCTAssertEqual(TeacherCorner.pool(for: 0), urge)
        XCTAssertEqual(TeacherCorner.pool(for: 19_999), cheer)
    }

    func testNudgeTextIsNeverEmpty() {
        for tokens in [0, 2_000, 20_000, 5_000_000] {
            XCTAssertFalse(TeacherCorner.randomNudge(for: tokens).isEmpty)
        }
    }

    // MARK: - 夜晚锁定小动物活动开关

    func testNightLocksAnimalActivityToggleToOff() {
        XCTAssertFalse(AppState.animalActivityToggleValue(enabled: true, isNight: true),
                       "夜晚开关显示为未勾选")
        XCTAssertTrue(AppState.animalActivityToggleValue(enabled: true, isNight: false),
                      "白天恢复用户的选择")
        XCTAssertFalse(AppState.animalActivityToggleValue(enabled: false, isNight: false))
    }

    // MARK: - 配置里的启停命令

    func testBundledDefaultConfigDeclaresServiceCommands() throws {
        let config = try DefaultConfiguration.load()
        for id in ["local.asr", "local.tts"] {
            let provider = try XCTUnwrap(config.providers.first { $0.id == id }, id)
            XCTAssertFalse((provider.serviceStartCommand ?? "").isEmpty, "\(id) 缺少启动命令")
            XCTAssertFalse((provider.serviceStopCommand ?? "").isEmpty, "\(id) 缺少停止命令")
        }
        let ollama = try XCTUnwrap(config.providers.first { $0.id == "ollama.llm" })
        XCTAssertFalse((ollama.serviceStartCommand ?? "").isEmpty, "Ollama 缺少兜底启动命令")
    }

    /// 老配置文件（没有启停命令）也要能用：从内置默认配置补齐。
    func testStaleConfigGetsServiceCommandsBackfilled() {
        let stale = ProviderConfig(id: "local.tts", kind: .tts, runtime: .externalLocalRuntime)
        XCTAssertNil(stale.serviceStartCommand)
        let filled = CoachServices.fillServiceCommands(stale)
        XCTAssertFalse((filled.serviceStartCommand ?? "").isEmpty)
        XCTAssertFalse((filled.serviceStopCommand ?? "").isEmpty)
    }

    /// 已显式配置过的值不会被默认值覆盖。
    func testExplicitServiceCommandsAreKept() {
        let custom = ProviderConfig(
            id: "local.tts", kind: .tts, runtime: .externalLocalRuntime,
            serviceStartCommand: "my-start", serviceStopCommand: "my-stop"
        )
        let filled = CoachServices.fillServiceCommands(custom)
        XCTAssertEqual(filled.serviceStartCommand, "my-start")
        XCTAssertEqual(filled.serviceStopCommand, "my-stop")
    }

    // MARK: - 语音拼写纠正的端到端行为（Mock 模型）

    /// 模型给出的内容与原文差异过大时，必须保留原文（宁可不错，不可乱改）。
    func testSpellingCorrectionKeepsOriginalWhenModelRewrites() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-spell-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        let services = CoachServices(config: store, databasePath: ":memory:")
        try await services.bootstrapLLM()

        let original = "helo wrld"
        let result = await services.correctSpelling(original)
        XCTAssertEqual(result, original, "模型改写幅度过大时应保留识别原文")
    }

    /// 模型被关闭时，拼写纠正直接跳过（返回原文），不会卡住语音输入。
    func testSpellingCorrectionSkippedWhenModelStopped() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-spell2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        let services = CoachServices(config: store, databasePath: ":memory:")
        _ = try await services.setModelRunning(.llm, running: false)

        let result = await services.correctSpelling("helo wrld")
        XCTAssertEqual(result, "helo wrld")
    }
}
