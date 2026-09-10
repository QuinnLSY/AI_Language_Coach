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
        XCTAssertEqual(chat.messages.last?.role, .assistant, "进入情景应由老师开场")
        XCTAssertEqual(chat.messages.last?.content, "Welcome! Table for one?")
        XCTAssertEqual(chat.scenarioProgress?.turnsUsed, 0, "开场白不计入学员轮次")

        chat.send("Yes, please.")
        XCTAssertEqual(chat.scenarioProgress?.turnsUsed, 1, "学员发言记一轮")

        chat.endScenario()
        XCTAssertNil(chat.scenarioProgress)
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
