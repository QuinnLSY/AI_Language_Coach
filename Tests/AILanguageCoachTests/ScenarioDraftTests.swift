import AIDomain
import AIInfrastructure
import XCTest

/// 一句话生成情景（⑦）：输入校验、模型输出解析、落盘、来源标记。
///
/// 与 `MaterialKitTests` 同款的「领域规则 + 落盘」两层，**不依赖任何真实模型**：
/// 生成链路上的请求那一半由 `ScenarioDraftFlowTests`（桩服务）负责。
final class ScenarioDraftTests: XCTestCase {

    /// 一份「模型照规矩输出」的样板（键 = `Prompts/scenario_draft.txt` 里要求的那五个）。
    private let sampleOutput = """
    title: Ordering an oat milk latte | 咖啡店换燕麦奶
    scene: barista | customer | order a latte and ask to swap the milk | 2 | Hi! What can I get for you today?
    sentence: Could I get a latte with oat milk instead?
    sentence: Does it cost extra to swap the milk?
    sentence: Thanks, that's all I need.
    vocabulary: oat milk | n. | 燕麦奶 | Could I have oat milk instead?
    vocabulary: swap | v. | 换掉 | Can I swap the milk?
    quest: Order your drink and change one thing about it
    """

    // MARK: - 输入校验

    func testInputIssuesCoverEmptyTooShortAndTooLong() {
        XCTAssertNil(ScenarioDraftRule.inputIssue(for: "在咖啡店点一杯拿铁"), "正常描述不该报问题")
        XCTAssertEqual(ScenarioDraftRule.inputIssue(for: "   \n  "), .empty, "全是空白 = 空")
        XCTAssertEqual(ScenarioDraftRule.inputIssue(for: "练口语"), .tooShort(actual: 3))
        // 恰好到下限：4 个字就够（下限是「够不够具体」，不是「够不够长」）。
        XCTAssertNil(ScenarioDraftRule.inputIssue(for: "点杯咖啡"))

        let long = String(repeating: "a", count: ScenarioDraftRule.maximumLength + 1)
        XCTAssertEqual(
            ScenarioDraftRule.inputIssue(for: long),
            .tooLong(actual: ScenarioDraftRule.maximumLength + 1),
            "超上限要报实际字数，用户才知道要删多少"
        )
        let exactlyMax = String(repeating: "a", count: ScenarioDraftRule.maximumLength)
        XCTAssertNil(ScenarioDraftRule.inputIssue(for: exactlyMax), "正好到上限不算超")
    }

    func testSanitizeNormalizesNewlinesAndTrims() {
        XCTAssertEqual(ScenarioDraftRule.sanitized("  a\r\nb\rc  "), "a\nb\nc")
        // 与材料不同：情景描述**不截断**（上限只用来报错，不静默改用户输入）。
        let long = String(repeating: "a", count: ScenarioDraftRule.maximumLength + 100)
        XCTAssertEqual(ScenarioDraftRule.sanitized(long).count, long.count)
    }

    // MARK: - 稳定 id（同一句话重复生成 = 覆盖，不是堆积）

    func testStableIDIsDeterministicAndWhitespaceInsensitive() {
        let first = ScenarioDraftRule.stableID(prompt: "在咖啡店点一杯拿铁")
        XCTAssertEqual(first, ScenarioDraftRule.stableID(prompt: "在咖啡店点一杯拿铁"))
        XCTAssertEqual(
            first,
            ScenarioDraftRule.stableID(prompt: "  在咖啡店点一杯拿铁\n"),
            "只差首尾空白算同一个描述（清洗后才参与指纹）"
        )
        XCTAssertNotEqual(first, ScenarioDraftRule.stableID(prompt: "在咖啡店点一杯美式"), "改了描述就是新情景")
        XCTAssertTrue(first.hasPrefix("custom-scenario-"))
    }

    /// 指纹必须跨进程稳定 —— 换实现（例如图省事用 `Hasher`）这里就会红。
    ///
    /// 用**独立重写**的一份 FNV-1a 当对照，而不是把当前实现的输出抄进期望值：
    /// 抄下来的期望值只能证明「没改过」，证明不了「算得对」。
    func testStableFingerprintMatchesIndependentFNV1a() {
        func reference(_ text: String) -> String {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
        }
        for text in ["", "a", "在咖啡店点一杯拿铁 | oat milk", "100% done"] {
            XCTAssertEqual(
                StableFingerprint.hex(prefix: "p", of: text),
                "p-" + reference(text),
                "指纹与独立实现不一致：\(text)"
            )
        }
        XCTAssertTrue(
            StableFingerprint.hex(prefix: "100%", of: "x").hasPrefix("100%-"),
            "prefix 里的 `%` 属于用户可控文本一类，绝不能被当成格式符"
        )
    }

    // MARK: - 解析

    func testParseBuildsAFullScenarioFromKeyValueLines() throws {
        let draft = try XCTUnwrap(
            ScenarioDraftRule.parse(sampleOutput, prompt: "在咖啡店点一杯拿铁，想换成燕麦奶"),
            "照规矩的输出必须能整份解析出来"
        )
        let scenario = draft.scenario
        XCTAssertEqual(scenario.id, draft.id, "情景要能按 id 被查回来")
        XCTAssertEqual(scenario.id, ScenarioDraftRule.stableID(prompt: "在咖啡店点一杯拿铁，想换成燕麦奶"))
        XCTAssertEqual(scenario.title, "Ordering an oat milk latte")
        XCTAssertEqual(scenario.titleZh, "咖啡店换燕麦奶")
        XCTAssertEqual(scenario.aiRole, "barista")
        XCTAssertEqual(scenario.learnerRole, "customer")
        XCTAssertEqual(scenario.objective, "order a latte and ask to swap the milk")
        XCTAssertEqual(scenario.difficulty, 2)
        XCTAssertEqual(scenario.level, "A1-A2", "档位按难度推")
        XCTAssertEqual(scenario.opening, "Hi! What can I get for you today?")
        XCTAssertEqual(scenario.category, ScenarioDraftRule.category)
        XCTAssertEqual(scenario.origin, .custom, "自建情景必须带来源标记（删除入口靠它）")
        XCTAssertEqual(scenario.icon, "sparkles")
        XCTAssertEqual(scenario.correctionMode, .balanced)
        XCTAssertEqual(scenario.maxTurns, ScenarioDraftRule.maxTurns)
        XCTAssertEqual(scenario.targetSentences.count, 3)
        XCTAssertEqual(scenario.targetVocabulary, ["oat milk", "swap"])
        // 步骤一律留空：`ScenarioQuestRule.plan` 从目标句现推，不存第二份真相。
        XCTAssertTrue(scenario.questSteps.isEmpty)
        XCTAssertEqual(draft.prompt, "在咖啡店点一杯拿铁，想换成燕麦奶")
        XCTAssertEqual(draft.words.map(\.partOfSpeech), ["n.", "v."])
        XCTAssertEqual(draft.words.map(\.meaning), ["燕麦奶", "换掉"])
        XCTAssertEqual(draft.words.first?.example, "Could I have oat milk instead?")
    }

    /// 目标句不足两句 = 不是「自动出题」：练完没法逐句核对说没说到 → 整份作废。
    func testParseRequiresAtLeastTwoTargetSentences() throws {
        let boosted = sampleOutput + "\nsentence: One more line here.\n"
        let one = sampleOutput
            .split(separator: "\n")
            .filter { !$0.hasPrefix("sentence:") }
            .joined(separator: "\n")
            + "\nsentence: Only one sentence survives."
        XCTAssertNil(ScenarioDraftRule.parse(one, prompt: "点咖啡"))
        XCTAssertNotNil(ScenarioDraftRule.parse(boosted, prompt: "点咖啡"))
    }

    func testParseRejectsWhenCoreLinesAreMissing() {
        for key in ["title:", "scene:"] {
            let broken = sampleOutput
                .split(separator: "\n")
                .filter { !$0.hasPrefix(key) }
                .joined(separator: "\n")
            XCTAssertNil(
                ScenarioDraftRule.parse(broken, prompt: "点咖啡"),
                "缺 \(key) 必须整份失败：半成品会以「我的情景」的名义长期留在列表里"
            )
        }
        // 缺开场白（scene 行第 5 个子字段）：
        let noOpening = sampleOutput.replacingOccurrences(of: " | Hi! What can I get for you today?", with: "")
        XCTAssertNil(ScenarioDraftRule.parse(noOpening, prompt: "点咖啡"), "没有开场白，老师不知道从哪句开始")
    }

    /// 真实模型会写别名键与内嵌标签（与材料出题同一把尺）。
    func testParseToleratesKeyAliasesAndEmbeddedLabels() throws {
        let raw = """
        标题：Talking to the landlord | 跟房东谈漏水
        scene: AI Role: landlord | Learner Role: tenant | Goal: explain the leak | 3 | You said the kitchen is leaking?
        句子：The kitchen pipe is leaking.
        句子：Could you come by on Saturday morning?
        生词：pipe | n. | 水管 | The pipe under the sink is leaking.
        """
        let draft = try XCTUnwrap(ScenarioDraftRule.parse(raw, prompt: "跟房东说明厨房水管漏水"))
        XCTAssertEqual(draft.scenario.titleZh, "跟房东谈漏水")
        XCTAssertEqual(draft.scenario.aiRole, "landlord", "内嵌 `AI Role:` 标签要剥掉")
        XCTAssertEqual(draft.scenario.learnerRole, "tenant", "内嵌 `Learner Role:` 标签要剥掉")
        XCTAssertEqual(draft.scenario.objective, "explain the leak", "内嵌 `Goal:` 标签要剥掉")
        XCTAssertEqual(draft.scenario.difficulty, 3)
        XCTAssertEqual(draft.scenario.targetSentences.count, 2, "中文键「句子」与 `sentence` 等价")
        XCTAssertEqual(draft.words.map(\.word), ["pipe"])
    }

    /// 圈错 / 多余的键：整行丢掉就行。
    ///
    /// ⚠️ 特别注意「值里带冒号」的行（`At 9:30 I'll be there.`）：它的首个冒号在值里，
    /// 于是键被认成 `at9` —— 走到 `default` 分支丢掉，**绝不能**因此把整份判废。
    func testParseSkipsUnknownAndColonNoisyLines() throws {
        let raw = sampleOutput
            + "\nAt 9:30 I'll be there.\nno colon in this line at all\nnote: 这一行不是任何已知键\n"
        let draft = try XCTUnwrap(ScenarioDraftRule.parse(raw, prompt: "点咖啡"))
        XCTAssertEqual(draft.scenario.targetSentences.count, 3, "多余的行不许混进目标句")
        XCTAssertEqual(draft.words.count, 2)
    }

    func testParseCapsSentencesAndVocabulary() throws {
        var lines = [
            "title: Big scene | 大场景",
            "scene: a | b | c | 3 | Let us start.",
        ]
        for index in 0..<20 { lines.append("sentence: Sentence number \(index) here.") }
        for index in 0..<20 { lines.append("vocabulary: word\(index) | n. | 释\(index) | Example \(index).") }
        let draft = try XCTUnwrap(ScenarioDraftRule.parse(lines.joined(separator: "\n"), prompt: "点咖啡"))
        XCTAssertEqual(draft.scenario.targetSentences.count, ScenarioDraftRule.maximumTargetSentences)
        XCTAssertEqual(draft.words.count, ScenarioDraftRule.maximumTargetVocabulary)
    }

    func testCefrBandCoversEveryDifficulty() {
        XCTAssertEqual(ScenarioDraftRule.cefrBand(for: 1), "A1-A2")
        XCTAssertEqual(ScenarioDraftRule.cefrBand(for: 2), "A1-A2")
        XCTAssertEqual(ScenarioDraftRule.cefrBand(for: 3), "A2-B1")
        XCTAssertEqual(ScenarioDraftRule.cefrBand(for: 4), "B1-B2")
        XCTAssertEqual(ScenarioDraftRule.cefrBand(for: 5), "B2-C1")
    }

    // MARK: - 「自动出题」真的能判定

    /// 目标句就是题目：生成出来的情景必须**自带可判定的主线步骤**，
    /// 否则学员会遇到「练完一局，界面上没有任何一步能打勾」。
    func testDraftScenarioIsJudgedByItsOwnTargetSentences() throws {
        let draft = try XCTUnwrap(ScenarioDraftRule.parse(sampleOutput, prompt: "点咖啡"))
        let plan = draft.scenario.questPlan
        XCTAssertFalse(plan.title.isEmpty, "主线任务要有标题")
        XCTAssertEqual(plan.steps.count, 3, "三句目标句 → 三步")
        XCTAssertEqual(plan.anchoredSteps.count, 3, "每一步都要有锚点，否则没法自动判定")

        // 一句没说 → 一步都没完成；把目标句都说了 → 整局完成。
        let untouched = ScenarioQuestRule.progress(plan: plan, utterances: [])
        XCTAssertEqual(untouched.doneCount, 0)
        XCTAssertFalse(untouched.isComplete)

        let spoken = ScenarioQuestRule.progress(
            plan: plan,
            utterances: ["Sure, could I get a latte with oat milk instead?",
                        "Does it cost extra to swap the milk?",
                        "Thanks, that's all I need."]
        )
        XCTAssertEqual(spoken.doneCount, 3)
        XCTAssertTrue(spoken.isComplete, "说到目标句就该判定完成 —— 这是「自动出题」的唯一含义")
    }

    /// 生成出来的情景必须与内置素材**同构**：练习链路（关卡绑定 / 判定 / 提要）读的是同一套字段。
    func testDraftScenarioHasTheSameShapeAsBundledScenarios() throws {
        let bundled = ScenarioCatalog.bundled()
        XCTAssertFalse(bundled.isEmpty, "测试环境必须能读到内置情景资源")
        let draft = try XCTUnwrap(ScenarioDraftRule.parse(sampleOutput, prompt: "点咖啡"))
        let scenario = draft.scenario

        for value in [scenario.title, scenario.titleZh, scenario.aiRole,
                      scenario.learnerRole, scenario.objective, scenario.opening] {
            XCTAssertFalse(value.isEmpty, "内置素材里这些字段都非空，生成出来的也必须非空")
        }
        XCTAssertFalse(scenario.cefrLevels.isEmpty, "档位要能被解析成 CEFR（课程阶梯靠它挂关卡）")
        XCTAssertGreaterThan(scenario.maxTurns, 0)
        XCTAssertGreaterThanOrEqual(scenario.targetSentences.count, 2)
        XCTAssertLessThanOrEqual(scenario.targetSentences.count, ScenarioDraftRule.maximumTargetSentences)
        for word in scenario.targetVocabulary {
            XCTAssertFalse(word.trimmingCharacters(in: .whitespaces).isEmpty, "目标词不许有空串")
        }
    }

    // MARK: - 来源标记（删除入口的判据）

    func testBundledScenariosAreBuiltInAndDraftsAreCustom() throws {
        for scenario in ScenarioCatalog.bundled() {
            XCTAssertEqual(
                scenario.origin, .builtIn,
                "内置 JSON 里没有 origin 字段，必须默认成 builtIn：\(scenario.id)"
            )
        }
        let draft = try XCTUnwrap(ScenarioDraftRule.parse(sampleOutput, prompt: "点咖啡"))
        XCTAssertEqual(draft.scenario.origin, .custom)

        // 存盘再读回来（UI 判据走的是读回来的这份）。
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ScenarioDraft.self, from: encoder.encode(draft))
        XCTAssertEqual(restored.scenario.origin, .custom, "来源标记必须能跨落盘存活")
        XCTAssertEqual(restored.scenario, draft.scenario)
        XCTAssertEqual(restored.words, draft.words)
    }

    // MARK: - 落盘

    /// 用临时目录当仓库（绝不碰真实的 `.workbuddy/app-config/`），目录一并交回以便塞坏文件。
    private func makeStore() throws -> (store: CustomScenarioStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scenario-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (CustomScenarioStore(directory: directory), directory)
    }

    func testStoreSaveListOverwriteDelete() async throws {
        let (store, _) = try makeStore()
        let first = try XCTUnwrap(ScenarioDraftRule.parse(sampleOutput, prompt: "点咖啡"))
        var second = try XCTUnwrap(ScenarioDraftRule.parse(sampleOutput, prompt: "跟房东谈漏水"))
        second.createdAt = first.createdAt.addingTimeInterval(60)

        try await store.save(first)
        try await store.save(second)
        var all = await store.all()
        XCTAssertEqual(all.map(\.id), [second.id, first.id], "按生成时间倒序（刚生成的排最前）")

        // 同 id 再存 = 覆盖。
        var renamed = first
        renamed.scenario.title = "Renamed"
        try await store.save(renamed)
        all = await store.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first { $0.id == first.id }?.scenario.title, "Renamed")

        await store.delete(id: first.id)
        all = await store.all()
        XCTAssertEqual(all.map(\.id), [second.id], "删一份不许连带清掉别人")
    }

    func testStoreSkipsCorruptFileInsteadOfNukingDirectory() async throws {
        let (store, directory) = try makeStore()
        let draft = try XCTUnwrap(ScenarioDraftRule.parse(sampleOutput, prompt: "点咖啡"))
        try await store.save(draft)
        try "not json".write(
            to: directory.appendingPathComponent("broken.json"),
            atomically: true,
            encoding: .utf8
        )

        let all = await store.all()
        XCTAssertEqual(all.map(\.id), [draft.id], "坏文件只跳过它自己，好的那份必须还在")
        let corrupt = await store.corruptIDs
        XCTAssertEqual(corrupt, ["broken.json"], "坏文件要留名，不许沉默")
    }

    // MARK: - 重构护栏：指纹抽取不得改变材料 id

    /// `MaterialKitRule.stableID` 的实现搬进了 `StableFingerprint`（情景生成要用同一套）。
    /// 这里用独立重写的算法对照，锁住「搬完之后结果一模一样」——
    /// 材料 id 一变，用户手里已有的材料会在列表里变成两份。
    func testMaterialStableIDUnchangedAfterExtractingTheFingerprint() {
        func reference(_ text: String) -> String {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            return String(format: "material-%08x", UInt32(truncatingIfNeeded: hash))
        }
        let long = String(repeating: "x", count: 3000)
        XCTAssertEqual(
            MaterialKitRule.stableID(title: "T", text: long),
            reference("T\u{1}" + String(long.prefix(2000))),
            "材料指纹取「标题 + 原文前 2000 字」"
        )
        XCTAssertEqual(
            MaterialKitRule.stableID(title: "T", text: long),
            MaterialKitRule.stableID(title: "T", text: long + "tail"),
            "指纹只取原文前 2000 字：第 2000 字之后的改动不算新材料"
        )
    }
}
