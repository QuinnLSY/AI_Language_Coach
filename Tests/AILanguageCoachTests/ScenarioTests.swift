import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import XCTest

/// 第 21 步 情景对话（Scenario System）单测：
/// 覆盖场景解析容错、目录加载/去重、分组、Prompt 注入、会话联动。
/// **不依赖任何真实模型 / runtime**。
final class ScenarioTests: XCTestCase {

    // MARK: - 解析容错

    func testScenarioDecodesDefaultsAndClampsDifficulty() throws {
        let json = """
        { "id": "x", "title": "Somewhere", "difficulty": 9 }
        """
        let scenario = try JSONDecoder().decode(Scenario.self, from: Data(json.utf8))
        XCTAssertEqual(scenario.id, "x")
        XCTAssertEqual(scenario.titleZh, "Somewhere", "缺 titleZh 时回退到 title")
        XCTAssertEqual(scenario.difficulty, 5, "难度越界应夹取到 5")
        XCTAssertEqual(scenario.correctionMode, .balanced, "缺 correctionMode 用默认值")
        XCTAssertEqual(scenario.maxTurns, 12, "缺 maxTurns 用默认值")
        XCTAssertTrue(scenario.targetVocabulary.isEmpty)
        XCTAssertFalse(scenario.icon.isEmpty)
    }

    func testScenarioRejectsMissingRequiredFields() {
        let json = """
        { "title": "No id here" }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(Scenario.self, from: Data(json.utf8))) { error in
            XCTAssertTrue(error is DecodingError, "缺少 id 必须显式报错，不得静默兜底")
        }
    }

    // MARK: - 目录加载

    func testCatalogLoadsValidFilesSkipsBrokenAndDeduplicates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-scenarios-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try write(#"{ "id": "b", "title": "B", "difficulty": 3 }"#, to: directory, name: "b.json")
        try write(#"{ "id": "a", "title": "A", "difficulty": 1 }"#, to: directory, name: "a.json")
        // 同 id 重复：只保留先出现的那份；文件名排序保证 a.json 先于 a_dup.json
        try write(#"{ "id": "a", "title": "A dup", "difficulty": 5 }"#, to: directory, name: "a_dup.json")
        // 坏文件：只跳过它，不影响其余场景
        try write("{ not json at all", to: directory, name: "c_broken.json")
        // 非 json 文件应被忽略
        try write("hello", to: directory, name: "readme.txt")

        let loaded = ScenarioCatalog.load(from: directory)
        XCTAssertEqual(loaded.map(\.id), ["a", "b"], "按难度升序、同 id 去重、坏文件跳过")
        XCTAssertEqual(loaded.first?.title, "A")
    }

    func testCatalogMissingDirectoryIsEmptyNotCrash() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-none-\(UUID().uuidString)")
        XCTAssertTrue(ScenarioCatalog.load(from: missing).isEmpty)
    }

    func testGroupedPreservesFirstAppearanceOrder() throws {
        let scenarios = [
            try scenario(id: "1", category: "旅行"),
            try scenario(id: "2", category: "日常"),
            try scenario(id: "3", category: "旅行"),
        ]
        let groups = Scenario.groups(scenarios)
        XCTAssertEqual(groups.map(\.category), ["旅行", "日常"])
        XCTAssertEqual(groups[0].items.map(\.id), ["1", "3"])
        XCTAssertEqual(groups[1].items.map(\.id), ["2"])
    }

    // MARK: - 随包资源

    func testBundledCatalogShipsInitialScenarios() {
        let scenarios = ScenarioCatalog.bundled()
        let ids = Set(scenarios.map(\.id))
        // Implementation Plan §21 要求的首批场景
        let expected: Set<String> = [
            "restaurant", "airport_checkin", "hotel_checkin",
            "shopping", "job_interview", "doctor_visit", "daily_small_talk",
        ]
        XCTAssertTrue(expected.isSubset(of: ids), "缺少内置场景：\(expected.subtracting(ids))")
        for scenario in scenarios {
            XCTAssertFalse(scenario.title.isEmpty)
            XCTAssertFalse(scenario.opening.isEmpty, "\(scenario.id) 缺开场白，进入情景会没有第一句")
            XCTAssertFalse(scenario.aiRole.isEmpty)
            XCTAssertFalse(scenario.learnerRole.isEmpty)
        }
    }

    // MARK: - Prompt 注入

    func testScenarioBlockSubstitutesEveryPlaceholder() throws {
        let scenario = try scenario(
            id: "airport_checkin",
            title: "Airport Check-in",
            aiRole: "a check-in agent",
            learnerRole: "a passenger",
            objective: "Complete check-in",
            vocabulary: ["boarding pass", "luggage"],
            grammar: ["present perfect"]
        )
        let block = PromptBuilder.scenarioBlock(
            scenario: scenario,
            turnsRemaining: 7,
            learningLanguage: "en-US",
            nativeLanguage: "zh-CN"
        )
        XCTAssertFalse(block.contains("{"), "模板占位符必须全部替换：\(block)")
        XCTAssertTrue(block.contains("Airport Check-in"))
        XCTAssertTrue(block.contains("a check-in agent"))
        XCTAssertTrue(block.contains("boarding pass, luggage"))
        XCTAssertTrue(block.contains("7 learner turns left"))
        XCTAssertTrue(block.contains("zh-CN"))
    }

    func testScenarioBlockMarksFinalTurn() throws {
        let scenario = try scenario(id: "s", title: "S")
        let block = PromptBuilder.scenarioBlock(
            scenario: scenario, turnsRemaining: 1,
            learningLanguage: "en-US", nativeLanguage: "zh-CN"
        )
        XCTAssertTrue(block.contains("final turn"))
        XCTAssertFalse(block.contains("{remaining_note}"))
    }

    func testCorrectionModeInstructionsDiffer() {
        let instructions = ScenarioCorrectionMode.allCases.map(\.instruction)
        XCTAssertEqual(Set(instructions).count, instructions.count, "三档纠错指令必须互不相同")
    }

    // MARK: - 轮次进度

    func testScenarioProgressCountsTurnsAndFinalTurn() throws {
        let scenario = try scenario(id: "s", title: "S", maxTurns: 3)
        var progress = ScenarioProgress(scenario: scenario)
        XCTAssertEqual(progress.turnsRemaining, 3)
        XCTAssertFalse(progress.isFinalTurn)
        XCTAssertEqual(progress.turnsText, "第 0/3 轮")

        progress.turnsUsed = 2
        XCTAssertEqual(progress.turnsRemaining, 1)
        XCTAssertTrue(progress.isFinalTurn, "只剩 1 轮即进入收尾")

        progress.turnsUsed = 5
        XCTAssertEqual(progress.turnsRemaining, 0, "超出上限不得为负")
        XCTAssertEqual(progress.turnsText, "第 3/3 轮")
    }

    // MARK: - 与会话联动

    @MainActor
    func testStartScenarioInjectsOpeningAndTracksTurns() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-scenario-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "mock.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let services = CoachServices(config: store, databasePath: ":memory:")
        let chat = ChatService(services: services)
        let scenario = try scenario(id: "restaurant", title: "Restaurant", opening: "Welcome! Table for one?")

        chat.startScenario(scenario)
        XCTAssertEqual(chat.scenarioProgress?.scenario.id, "restaurant")
        // ⚠️ 需求 3/6 之后**开场白不再由素材直接贴出**：老师那一句要带着前情提要和
        // 「现在做什么」，由 `deliverOpener()` 生成（模型没起来时走本地兜底）。
        // 所以刚进情景时消息是空的 —— 这是刻意的，不是漏了开场。
        XCTAssertTrue(chat.messages.isEmpty, "开场白改由老师生成，进入时不应先塞素材原句")
        XCTAssertEqual(chat.scenarioProgress?.turnsUsed, 0, "开场白不计入学员轮次")

        chat.send("Yes, please.")
        XCTAssertEqual(chat.scenarioProgress?.turnsUsed, 1, "学员发言记一轮")

        chat.endScenario()
        XCTAssertNil(chat.scenarioProgress)
    }

    @MainActor
    /// 需求 6：随口练与情景对话是两条不同的路 —— 随口练没有情景，老师也不讲主线任务。
    func testBeginFreeTalkClearsScenarioAndRemembersReview() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-scenario-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "mock.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let services = CoachServices(config: store, databasePath: ":memory:")
        let chat = ChatService(services: services)
        let scenario = try scenario(id: "restaurant", title: "Restaurant", opening: "Welcome! Table for one?")

        chat.startScenario(scenario)
        XCTAssertNotNil(chat.scenarioProgress)

        chat.beginFreeTalk(review: nil)
        XCTAssertNil(chat.scenarioProgress, "随口练不是情景对话")
        XCTAssertTrue(chat.messages.isEmpty, "开启新练习要清掉上一段（它已经复盘过了）")
    }

    @MainActor
    /// 落库时 `sessions.mode` 必须**如实**记录随口练。
    ///
    /// ⚠️ 这是 2026-09-17 实机抓到的：`persist()` 建会话行时没传 mode，而
    /// `ChatSession.mode` 有默认值 `.conversation` → 随口练的会话一直以「情景对话」入库。
    /// `PracticeResumeRule.action(latestScenarioID:latestMode:)` 正是拿 mode 判「上次在练什么」，
    /// 记错之后「上次随口练 → 带着复盘接着聊」这条路**永远走不到**，只会退化成一句普通招呼，
    /// 而且全程不报错 —— 只有查库才看得见。
    func testFreeTalkSessionIsRecordedAsFreeTalkInStore() async throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-scenario-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: configURL)
        try await store.updateProvider(
            ProviderConfig(id: "mock.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-freetalk-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let services = CoachServices(config: store, databasePath: dbPath)
        let chat = ChatService(services: services)
        chat.beginFreeTalk(review: nil)
        chat.send("hello there")
        chat.cancel()

        var stored = await services.latestChatSession()?.session
        for _ in 0..<60 where stored == nil {
            try? await Task.sleep(for: .milliseconds(20))
            stored = await services.latestChatSession()?.session
        }
        XCTAssertEqual(stored?.mode, .freeTalk, "随口练的会话必须以 freeTalk 入库")
        XCTAssertNil(stored?.scenarioID, "随口练不绑情景")
    }

    @MainActor
    /// 开新练习**不能抹掉上一段的 `scenario_id`**：那是「上次练的是什么话题」的唯一记录，
    /// 跨会话记忆的 `sessionFacts` 也读它来给老师提供话题。
    func testStartingNewPracticeKeepsPreviousSessionScenarioBinding() async throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-scenario-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: configURL)
        try await store.updateProvider(
            ProviderConfig(id: "mock.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-keepbinding-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let services = CoachServices(config: store, databasePath: dbPath)
        let chat = ChatService(services: services)
        let scenario = try scenario(id: "restaurant", title: "Restaurant")
        chat.startScenario(scenario, briefing: nil)

        var bound = await services.latestChatSession()?.session
        for _ in 0..<60 where bound == nil {
            try? await Task.sleep(for: .milliseconds(20))
            bound = await services.latestChatSession()?.session
        }
        XCTAssertEqual(bound?.scenarioID, "restaurant", "进情景就该落绑定")

        chat.beginNewSession()
        try? await Task.sleep(for: .milliseconds(150))

        let after = await services.latestChatSession()?.session
        XCTAssertEqual(
            after?.scenarioID, "restaurant",
            "上一段练的是哪个情景，不能被下一段的清理抹成 NULL"
        )
    }

    @MainActor
    func testClearResetsScenario() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-scenario-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "mock.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let services = CoachServices(config: store, databasePath: ":memory:")
        let chat = ChatService(services: services)
        chat.startScenario(try scenario(id: "s", title: "S"))
        chat.clear()
        XCTAssertNil(chat.scenarioProgress, "清空对话同时退出情景")
        XCTAssertTrue(chat.messages.isEmpty)
    }

    // MARK: - 本局取材（CEFR 覆盖度的输入）

    /// 发一句并等生成结束（`send` 在生成中会被挡掉，连着发会静默丢句）。
    @MainActor
    private func sendAndSettle(_ chat: ChatService, _ text: String) async {
        chat.send(text)
        var spins = 0
        while chat.isGenerating && spins < 400 {
            try? await Task.sleep(for: .milliseconds(10))
            spins += 1
        }
    }

    /// **只数这一局说过的话**：进情景之前的闲聊不算这一关的产出。
    /// 少了这条边界，「今天说得怎么样」就会被昨天/刚才的闲聊顶上去 —— 判定直接虚高。
    @MainActor
    func testScenarioUtterancesExcludeChatBeforeTheScenario() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-scenario-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "mock.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let services = CoachServices(config: store, databasePath: ":memory:")
        let chat = ChatService(services: services)

        // 情景之前先闲聊一句：它不属于这一关。
        await sendAndSettle(chat, "just chatting before the scenario")
        chat.startScenario(try scenario(id: "restaurant", title: "Restaurant", opening: "Welcome!"))
        await sendAndSettle(chat, "I prefer tea")
        await sendAndSettle(chat, "However I agree")

        XCTAssertEqual(
            chat.scenarioLearnerUtterances, ["I prefer tea", "However I agree"],
            "只应取到本局说过的两句，进情景前的闲聊不得混进来"
        )
        XCTAssertEqual(
            chat.scenarioProgress?.turnsUsed, chat.scenarioLearnerUtterances.count,
            "轮次口径与覆盖度取材必须同源，否则同一局会出现两个轮次数"
        )

        // 退出后必须取不到 —— 这正是 `endScenario` 之前要先取一次的原因。
        chat.endScenario()
        XCTAssertTrue(chat.scenarioLearnerUtterances.isEmpty, "退出情景后不该再能取到本局发言")
    }

    /// 端上恢复的历史会话没有「本局起点」可考：整段都算这一局，
    /// 与 `turnsUsed` 数全部学员发言保持同一口径。
    @MainActor
    func testRestoredSessionCountsTheWholeRun() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-scenario-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "mock.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let services = CoachServices(config: store, databasePath: ":memory:")
        let chat = ChatService(services: services)
        // 没进情景时说的一句，恢复后仍属于「这一整段会话」。
        await sendAndSettle(chat, "hello there")
        chat.startScenario(try scenario(id: "restaurant", title: "Restaurant", opening: "Welcome!"))
        await sendAndSettle(chat, "I prefer tea")

        XCTAssertEqual(chat.scenarioStartIndex, 1, "本局起点应记在开场白之前")
    }

    // MARK: - 关卡 ↔ 情景 绑定（第 22 步）

    func testLevelBindingsParseIgnoresNonStringValues() throws {
        let json = """
        { "l1": "restaurant", "l2": 42, "": "nope", "l3": "" }
        """
        let parsed = try XCTUnwrap(LevelBindingCatalog.parse(Data(json.utf8)))
        XCTAssertEqual(parsed, ["l1": "restaurant"], "非字符串 / 空键 / 空值一律忽略")
        XCTAssertNil(LevelBindingCatalog.parse(nil))
        XCTAssertNil(LevelBindingCatalog.parse(Data("not json".utf8)))
    }

    func testBundledLevelBindingsPointAtRealScenarios() {
        let bindings = LevelBindingCatalog.bundled()
        XCTAssertFalse(bindings.isEmpty, "内置关卡绑定表不应为空（Resources/Levels/level_bindings.json）")

        let scenarioIDs = Set(ScenarioCatalog.bundled().map(\.id))
        XCTAssertFalse(scenarioIDs.isEmpty, "内置场景资源应存在，否则绑定无从校验")
        for (level, scenario) in bindings {
            XCTAssertTrue(scenarioIDs.contains(scenario), "关卡 \(level) 绑定的场景 \(scenario) 不存在")
        }
    }

    func testApplyScenarioBindingsInjectsAndClearsStaleValues() {
        var progress = LearnerProgress.seed()
        progress.levels[0].scenarioID = "stale_value"
        progress.applyScenarioBindings(["l1": "restaurant", "l3": "hotel_checkin"])

        XCTAssertEqual(progress.levels[0].scenarioID, "restaurant", "绑定表有的关卡按表注入")
        XCTAssertEqual(progress.levels[2].scenarioID, "hotel_checkin")
        XCTAssertNil(progress.levels[1].scenarioID, "绑定表没有的关卡必须清空旧值")
        XCTAssertEqual(progress.level(boundToScenario: "hotel_checkin")?.id, "l3")
        XCTAssertNil(progress.level(boundToScenario: "no_such_scenario"))
    }

    // MARK: - 情景结算规则

    func testRewardStarsByTurns() {
        XCTAssertEqual(ScenarioRewardRule.stars(turnsUsed: 0, maxTurns: 12), 0, "一句没说没有星")
        XCTAssertEqual(ScenarioRewardRule.stars(turnsUsed: 1, maxTurns: 12), 1)
        XCTAssertEqual(ScenarioRewardRule.stars(turnsUsed: 6, maxTurns: 12), 2)
        XCTAssertEqual(ScenarioRewardRule.stars(turnsUsed: 12, maxTurns: 12), 3)
        XCTAssertEqual(ScenarioRewardRule.stars(turnsUsed: 20, maxTurns: 12), 3)
        XCTAssertEqual(ScenarioRewardRule.stars(turnsUsed: 3, maxTurns: 0), 0, "maxTurns 非法时不奖励")
    }

    func testRewardMessageWithoutBoundLevel() {
        let reward = ScenarioRewardRule.reward(
            scenarioTitle: "餐厅点餐", stars: 0, levelTitle: nil,
            didPass: false, willCompleteLevel: false
        )
        XCTAssertNil(reward.levelTitle)
        XCTAssertEqual(reward.stars, 0, "没绑定关卡就不动星星")
        XCTAssertTrue(reward.message.contains("餐厅点餐"))
    }

    func testRewardMessageOnLevelCompletion() {
        let reward = ScenarioRewardRule.reward(
            scenarioTitle: "餐厅点餐", stars: 3, levelTitle: "松鼠枝桠",
            didPass: true, willCompleteLevel: true
        )
        XCTAssertEqual(reward.stars, 3)
        XCTAssertEqual(reward.levelTitle, "松鼠枝桠")
        XCTAssertTrue(reward.didCompleteLevel)
        XCTAssertTrue(reward.message.contains("已点亮"))
    }

    /// 需求 3 的核心口径：**星星与通关是两件事**。
    /// 说了不少（有星）但主线/重点没达标 → 有星、但明说没过关、也不点亮关卡。
    func testRewardWithStarsButNotPassed() {
        let reward = ScenarioRewardRule.reward(
            scenarioTitle: "餐厅点餐", stars: 2, levelTitle: "松鼠枝桠",
            didPass: false, willCompleteLevel: false, shortfall: "主线任务还差 1 步"
        )
        XCTAssertEqual(reward.stars, 2, "没通关也照样记星（星星只记开口量）")
        XCTAssertFalse(reward.didCompleteLevel)
        XCTAssertTrue(reward.message.contains("还没过关"))
        XCTAssertTrue(reward.message.contains("主线任务还差 1 步"))
    }

    /// 目标达成但还没点亮关卡（比如星星没攒满）—— 不能反过来骗人说「已点亮」。
    func testRewardWhenTargetsMetButLevelNotLit() {
        let reward = ScenarioRewardRule.reward(
            scenarioTitle: "餐厅点餐", stars: 1, levelTitle: "松鼠枝桠",
            didPass: true, willCompleteLevel: false
        )
        XCTAssertFalse(reward.didCompleteLevel)
        XCTAssertTrue(reward.message.contains("目标达成"))
    }

    // MARK: - 加星是累计的（封顶到本关需求）

    func testStarAwardAccumulatesAndCapsAtRequirement() {
        // 蜂鸟花丛：已有 2/4，本次 1 星 → 3/4（没通关）
        let first = ScenarioRewardRule.award(earned: 2, scored: 1, required: 4)
        XCTAssertEqual(first.gained, 1)
        XCTAssertEqual(first.total, 3)
        XCTAssertFalse(first.didComplete)

        // 再练一次 +1 → 4/4 通关
        let second = ScenarioRewardRule.award(earned: first.total, scored: 1, required: 4)
        XCTAssertEqual(second.gained, 1)
        XCTAssertEqual(second.total, 4)
        XCTAssertTrue(second.didComplete)

        // 说满轮次一次拿 3 星，也不会超过本关需求
        let capped = ScenarioRewardRule.award(earned: 0, scored: 3, required: 5)
        XCTAssertEqual(capped.total, 3)
        XCTAssertFalse(capped.didComplete)

        // 已封顶时不再多给
        let maxed = ScenarioRewardRule.award(earned: 4, scored: 3, required: 4)
        XCTAssertEqual(maxed.gained, 0)
        XCTAssertTrue(maxed.didComplete)
    }

    func testStarAwardHandlesIllegalInput() {
        let award = ScenarioRewardRule.award(earned: 2, scored: -5, required: 4)
        XCTAssertEqual(award.gained, 0)
        XCTAssertEqual(award.total, 2)
        XCTAssertFalse(award.didComplete)
    }

    func testScenarioProgressCompletion() {
        let scenario = Scenario(
            id: "s", title: "T", titleZh: "标题", category: "日常", difficulty: 1, level: "A1",
            objective: "o", aiRole: "a", learnerRole: "b", opening: "hi", maxTurns: 4
        )
        var progress = ScenarioProgress(scenario: scenario, turnsUsed: 2)
        XCTAssertFalse(progress.isComplete)
        XCTAssertEqual(progress.completion, 0.5, accuracy: 0.0001)
        progress.turnsUsed = 4
        XCTAssertTrue(progress.isComplete)
        XCTAssertEqual(progress.turnsRemaining, 0)
        XCTAssertTrue(progress.isFinalTurn)
    }

    // MARK: - 工具

    private func scenario(
        id: String,
        title: String = "Title",
        category: String = "日常",
        aiRole: String = "partner",
        learnerRole: String = "learner",
        objective: String = "practice",
        opening: String = "Hi!",
        vocabulary: [String] = [],
        grammar: [String] = [],
        maxTurns: Int = 12
    ) throws -> Scenario {
        let payload: [String: Any] = [
            "id": id, "title": title, "category": category,
            "aiRole": aiRole, "learnerRole": learnerRole,
            "objective": objective, "opening": opening,
            "targetVocabulary": vocabulary, "targetGrammar": grammar,
            "maxTurns": maxTurns,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(Scenario.self, from: data)
    }

    private func write(_ content: String, to directory: URL, name: String) throws {
        try content.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
