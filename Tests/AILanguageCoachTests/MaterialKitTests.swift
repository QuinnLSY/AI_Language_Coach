import AIDomain
import AIInfrastructure
import XCTest

/// 上传材料自动出题的**领域规则与落盘**（#208）。
final class MaterialKitTests: XCTestCase {

    private let sampleOutput = """
    title: Onboarding at a small startup | 小公司入职第一天
    scenario: HR manager | new employee | introduce yourself and ask about the team | 3 | Welcome! Tell me a bit about yourself.
    vocabulary: onboarding | n. | 入职引导 | The onboarding takes two days.
    vocabulary: colleague | n. | 同事 | My colleagues are very friendly.
    sentence: I joined the team last Monday. | 我上周一入职。 | joined 连读
    sentence: Could you tell me where my desk is? | 你能告诉我我的工位在哪吗？ | Could you 弱读
    """

    private let sampleMaterial = """
    Dear new hires, welcome to the company. Your onboarding takes two days. On the first day you will meet your
    colleagues and learn about the team. Please ask questions whenever something is unclear. Your desk is on the
    second floor next to the meeting room, and everyone is happy to show you around.
    """

    // MARK: - 输入校验

    func testInputIssues() {
        XCTAssertEqual(MaterialKitRule.inputIssue(for: "   \n "), .empty)
        guard case .tooShort(let actual) = MaterialKitRule.inputIssue(for: "too short") else {
            return XCTFail("太短的输入要报 tooShort")
        }
        XCTAssertEqual(actual, "too short".count)
        XCTAssertNil(MaterialKitRule.inputIssue(for: sampleMaterial), "够长的材料不该报问题")
    }

    func testSanitizeTruncatesToMaximumLength() {
        let long = String(repeating: "a", count: MaterialKitRule.maximumLength + 500)
        XCTAssertEqual(MaterialKitRule.sanitized(long).count, MaterialKitRule.maximumLength)
        XCTAssertEqual(
            MaterialKitRule.sanitized("  a\r\nb\rc  "),
            "a\nb\nc",
            "换行统一成 \\n、去首尾空白"
        )
    }

    // MARK: - 稳定 id

    func testStableIDIsDeterministicAndContentSensitive() {
        let first = MaterialKitRule.stableID(title: "Onboarding", text: sampleMaterial)
        let again = MaterialKitRule.stableID(title: "Onboarding", text: sampleMaterial)
        XCTAssertEqual(first, again, "同一份材料重复生成必须是同一个 id（覆盖而非堆积）")
        XCTAssertNotEqual(
            first,
            MaterialKitRule.stableID(title: "Onboarding", text: sampleMaterial + " One more line."),
            "内容改了就该是新材料"
        )
        XCTAssertTrue(first.hasPrefix("material-"))
    }

    // MARK: - 解析

    func testParseBuildsFullKit() throws {
        let kit = try XCTUnwrap(
            MaterialKitRule.parse(sampleOutput, text: sampleMaterial),
            "完整的模型输出必须能整份拆出来"
        )
        XCTAssertEqual(kit.title, "Onboarding at a small startup")
        let scenario = try XCTUnwrap(kit.scenario)
        XCTAssertEqual(scenario.titleZh, "小公司入职第一天")
        XCTAssertEqual(scenario.aiRole, "HR manager")
        XCTAssertEqual(scenario.learnerRole, "new employee")
        XCTAssertEqual(scenario.opening, "Welcome! Tell me a bit about yourself.")
        XCTAssertEqual(scenario.difficulty, 3)
        XCTAssertEqual(scenario.category, "我的材料")
        XCTAssertEqual(scenario.targetVocabulary, ["onboarding", "colleague"])
        XCTAssertEqual(scenario.targetSentences.count, 2, "目标句 = 跟读句（练完逐句核对）")
        XCTAssertEqual(kit.words.map(\.meaning), ["入职引导", "同事"])
        XCTAssertEqual(kit.drills.count, 2)
        XCTAssertEqual(kit.drills[0].translation, "我上周一入职。")
        XCTAssertEqual(kit.drills[0].focus, "joined 连读")
    }

    func testParseRejectsWhenCoreLinesMissing() {
        // 缺 title
        let noTitle = sampleOutput
            .split(separator: "\n")
            .filter { !$0.hasPrefix("title:") }
            .joined(separator: "\n")
        XCTAssertNil(MaterialKitRule.parse(noTitle, text: sampleMaterial))
        // 缺 scenario
        let noScenario = sampleOutput
            .split(separator: "\n")
            .filter { !$0.hasPrefix("scenario:") }
            .joined(separator: "\n")
        XCTAssertNil(MaterialKitRule.parse(noScenario, text: sampleMaterial))
        // 缺开场白（scenario 行第 5 个字段）
        let noOpening = sampleOutput.replacingOccurrences(
            of: " | Welcome! Tell me a bit about yourself.",
            with: ""
        )
        XCTAssertNil(MaterialKitRule.parse(noOpening, text: sampleMaterial))
    }

    func testParseDropsOnlyBrokenLines() {
        let broken = "title: OK | 可以\nscenario: teacher | learner | practice asking | 2 | Let us begin.\n"
            + "vocabulary: |||\ngarbage line without fields\nsentence: Hello there. | 你好啊。\n"
        let kit = MaterialKitRule.parse(broken, text: sampleMaterial)
        XCTAssertNotNil(kit, "只有坏行被丢掉，整份不该报废")
        XCTAssertEqual(kit?.drills.count, 1)
        XCTAssertEqual(kit?.words.count, 0, "三个子字段全空的生词行要丢掉")
    }

    func testParseCapsWordsAndDrills() {
        var lines = ["title: Big | 大", "scenario: a | b | c | 2 | Hello there."]
        for index in 0..<20 {
            lines.append("vocabulary: word\(index) | n. | 释\(index) | Sentence \(index).")
        }
        for index in 0..<30 {
            lines.append("sentence: Sentence number \(index) here. | 句\(index)。")
        }
        let kit = MaterialKitRule.parse(lines.joined(separator: "\n"), text: sampleMaterial)
        XCTAssertEqual(kit?.words.count, MaterialKitRule.maxWords)
        XCTAssertEqual(kit?.drills.count, MaterialKitRule.maxDrills)
    }

    // MARK: - 真实模型输出容错（#211 实机实测 agnes-3.0-flash 的两种翻车形态）

    func testParseToleratesMissingKeysLikeRealModelOutput() throws {
        // 实测形态：整份不写键名，标题裸写首行，情景行键写成 `AI Role:` 且子字段带内嵌标签。
        let raw = """
        The Morning Standup | 晨会 | 练习职场沟通
        AI Role: Maya (Product Designer) | Learner Role: New Team Member | Goal: Discussing work efficiency | 3 | Would you like to share how you handled the change?
        experiment | n. | 实验 | The manager announced the experiment.
        Every Monday morning, our team gathers around the whiteboard. | 每周一早上我们围在白板旁。 | gathers 连读
        """
        let kit = try XCTUnwrap(
            MaterialKitRule.parse(raw, text: sampleMaterial),
            "真实模型的漏键输出必须能整份拆出来"
        )
        XCTAssertEqual(kit.title, "The Morning Standup")
        XCTAssertEqual(kit.scenario?.titleZh, "晨会")
        XCTAssertEqual(kit.scenario?.aiRole, "Maya (Product Designer)")
        XCTAssertEqual(kit.scenario?.learnerRole, "New Team Member", "内嵌 `Learner Role:` 标签要剥掉")
        XCTAssertEqual(kit.scenario?.objective, "Discussing work efficiency", "内嵌 `Goal:` 标签要剥掉")
        XCTAssertEqual(kit.scenario?.difficulty, 3)
        XCTAssertEqual(kit.scenario?.opening, "Would you like to share how you handled the change?")
        XCTAssertEqual(kit.words.map(\.word), ["experiment"], "4 字段的漏键行按生词收")
        XCTAssertEqual(kit.drills.count, 1, "2–3 字段的漏键行按跟读句收")
        XCTAssertEqual(kit.drills.first?.translation, "每周一早上我们围在白板旁。")
    }

    func testParseStillRejectsWhenKeysMissingAndNoUnkeyedFallback() {
        // 全部带键但缺 title 行：没有任何漏键行可兜底 → 仍要整份失败（报错重试，不许静默出残品）。
        let noTitle = sampleOutput
            .split(separator: "\n")
            .filter { !$0.hasPrefix("title:") }
            .joined(separator: "\n")
        XCTAssertNil(MaterialKitRule.parse(noTitle, text: sampleMaterial))
    }

    func testParseToleratesKeyedTitleWithUnkeyedBody() throws {
        // 混合形态：title 有键、其余行漏键。标题已被键行占住，漏键行只许当内容、不许抢标题。
        let raw = """
        title: Team Rituals | 团队仪式感
        Maya (Product Designer) | New Team Member | Talk about weekly meetings | 3 | Tell me about your first week.
        experiment | n. | 实验 | The manager announced the experiment.
        Every Monday morning, our team gathers around the whiteboard. | 每周一早上我们围在白板旁。
        """
        let kit = try XCTUnwrap(MaterialKitRule.parse(raw, text: sampleMaterial))
        XCTAssertEqual(kit.title, "Team Rituals")
        XCTAssertEqual(kit.scenario?.aiRole, "Maya (Product Designer)")
        XCTAssertEqual(kit.words.map(\.word), ["experiment"])
        XCTAssertEqual(kit.drills.count, 1)
    }

    // MARK: - 落盘

    /// 用临时目录当仓库（不碰真实 `.workbuddy/app-config/`），把目录一并交回，方便塞坏文件。
    private func makeStore() throws -> (store: MaterialStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("material-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (MaterialStore(directory: directory), directory)
    }

    func testStoreSaveListOverwriteDelete() async throws {
        let (store, _) = try makeStore()
        let kit = try XCTUnwrap(MaterialKitRule.parse(sampleOutput, text: sampleMaterial))
        try await store.save(kit)
        var all = await store.all()
        XCTAssertEqual(all.map(\.id), [kit.id])

        // 同 id 再存 = 覆盖（列表里只有一份，且是新内容）。
        // （重复生成同一份材料时 `MaterialKitRule.stableID` 会给出同一个 id。）
        let updated = MaterialKit(
            id: kit.id, title: "Updated title", createdAt: kit.createdAt,
            excerpt: kit.excerpt, scenario: kit.scenario, words: kit.words, drills: kit.drills
        )
        try await store.save(updated)
        all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "Updated title")

        await store.delete(id: kit.id)
        all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testStoreSkipsCorruptFileInsteadOfNukingDirectory() async throws {
        let (store, directory) = try makeStore()
        let kit = try XCTUnwrap(MaterialKitRule.parse(sampleOutput, text: sampleMaterial))
        try await store.save(kit)
        // 写一个坏文件进去（模拟写坏 / 手改坏）。
        try "not json".write(
            to: directory.appendingPathComponent("broken.json"),
            atomically: true,
            encoding: .utf8
        )

        let all = await store.all()
        XCTAssertEqual(all.map(\.id), [kit.id], "坏文件只被跳过，好的一份必须还在")
        let corrupt = await store.corruptIDs
        XCTAssertEqual(corrupt, ["broken.json"], "坏文件要留名，不许沉默")
    }
}
