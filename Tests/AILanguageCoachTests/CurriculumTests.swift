import AIDomain
import AIInfrastructure
import XCTest

/// CEFR 课程体系（P1-2）单测。
///
/// 覆盖三件事：
/// 1. **分级解析**：素材里的 `level: "A1-A2"` 能被解析成档位序列，垃圾串不瞎猜。
/// 2. **覆盖度与过关判定**：目标句 / 目标词都从学员**真说过的话**算出来，
///    判定三项独立、结果分三档，且「下次补哪一句」是那个真的没说到的句子。
/// 3. **课程阶梯**：档位归组、关卡按 `level_bindings` 挂档、区间场景不重复计星。
///
/// 全部是纯函数，不碰模型 / 数据库 / 资源 bundle 以外的任何东西。
final class CurriculumTests: XCTestCase {

    // MARK: - 造数据

    /// 直接拼场景（字段全部显式给出，避免依赖素材文件内容）。
    private func scenario(
        id: String = "s",
        level: String,
        maxTurns: Int = 12,
        vocabulary: [String] = [],
        sentences: [String] = []
    ) -> Scenario {
        Scenario(
            id: id,
            title: "T",
            titleZh: "题",
            category: "测试",
            difficulty: 3,
            level: level,
            objective: "o",
            aiRole: "ai",
            learnerRole: "learner",
            opening: "hi",
            targetVocabulary: vocabulary,
            targetGrammar: [],
            targetSentences: sentences,
            maxTurns: maxTurns
        )
    }

    private func treeLevel(_ id: String, scenario: String?, state: LevelState = .locked,
                           required: Int = 3, earned: Int = 0) -> TreeLevel {
        TreeLevel(id: id, title: id, subtitle: "", heightFraction: 0.1, branch: .left,
                  state: state, requiredStars: required, earnedStars: earned, scenarioID: scenario)
    }

    // MARK: - 1. 等级解析

    func testParseReadsLevelRangeInTextOrder() {
        XCTAssertEqual(CEFRLevel.parse("A1-A2"), [.a1, .a2], "区间按文本出现顺序，不能反过来")
        XCTAssertEqual(CEFRLevel.parse("B1"), [.b1])
        XCTAssertEqual(CEFRLevel.parse("a2 - b1"), [.a2, .b1], "空格 / 大小写不敏感")
        XCTAssertEqual(CEFRLevel.parse("B1-B2"), [.b1, .b2])
    }

    func testParseReturnsEmptyForUnrecognizableText() {
        XCTAssertTrue(CEFRLevel.parse("").isEmpty)
        XCTAssertTrue(CEFRLevel.parse("beginner").isEmpty, "解析不出就返回空，不瞎猜一档")
        XCTAssertTrue(CEFRLevel.parse("X9").isEmpty)
    }

    func testCodeAndOrderAreConsistent() {
        XCTAssertEqual(CEFRLevel.a1.code, "A1")
        XCTAssertEqual(CEFRLevel.b2.code, "B2")
        XCTAssertTrue(CEFRLevel.a1 < CEFRLevel.b2)
        XCTAssertEqual(CEFRLevel.allCases.map(\.order), [0, 1, 2, 3])
    }

    // MARK: - 2. 过关标准

    func testPassCriteriaGetsStricterWithLevel() {
        let ratios = CEFRLevel.allCases.map(\.passCriteria.minimumTurnRatio)
        XCTAssertEqual(ratios, ratios.sorted(), "档位越高，轮次要求不能反而变松")
        let sentences = CEFRLevel.allCases.map(\.passCriteria.minimumTargetSentences)
        XCTAssertEqual(sentences, sentences.sorted())
        let words = CEFRLevel.allCases.map(\.passCriteria.minimumTargetWords)
        XCTAssertEqual(words, words.sorted())
    }

    func testRequiredTurnsRoundsUpAndNeverZero() {
        let criteria = CurriculumCriteria(minimumTurnRatio: 0.6, minimumTargetSentences: 2, minimumTargetWords: 3)
        XCTAssertEqual(criteria.requiredTurns(maxTurns: 12), 8, "7.2 向上取整成 8")
        XCTAssertEqual(criteria.requiredTurns(maxTurns: 1), 1, "最少也要 1 轮，不能是 0")
        XCTAssertEqual(criteria.requiredTurns(maxTurns: 0), 1, "maxTurns 归一化到 1")
    }

    func testCriteriaClampsOutOfRangeInput() {
        let criteria = CurriculumCriteria(minimumTurnRatio: 1.7, minimumTargetSentences: -3, minimumTargetWords: -1)
        XCTAssertEqual(criteria.minimumTurnRatio, 1)
        XCTAssertEqual(criteria.minimumTargetSentences, 0)
        XCTAssertEqual(criteria.minimumTargetWords, 0)
    }

    // MARK: - 3. 覆盖度

    func testCoverageMatchesSentenceDespiteDroppedArticles() {
        let s = scenario(level: "B1", sentences: ["In my opinion, working from home is better."])
        // 漏掉冠词 / 虚词仍算说到了（阈值 0.75 的用意）。
        let relaxed = CurriculumScorer.coverage(
            scenario: s,
            utterances: ["in my opinion working from home is better"]
        )
        XCTAssertEqual(relaxed.matchedSentences.count, 1, "允许漏虚词")
        XCTAssertTrue(relaxed.missingSentences.isEmpty)

        // 换掉实义词就不算。
        let wrong = CurriculumScorer.coverage(
            scenario: s,
            utterances: ["I like working from home"]
        )
        XCTAssertTrue(wrong.matchedSentences.isEmpty, "实义词被换掉不算说到")
        XCTAssertEqual(wrong.missingSentences.count, 1)
    }

    func testCoverageIsCaseAndPunctuationInsensitive() {
        let s = scenario(level: "A2", sentences: ["I prefer to study in the morning."])
        let covered = CurriculumScorer.coverage(
            scenario: s,
            utterances: ["I PREFER to study in the morning!!!"]
        )
        XCTAssertEqual(covered.matchedSentences.count, 1)
    }

    func testCoverageSplitsMatchedAndMissingKeepingMaterialOrder() {
        let s = scenario(
            level: "B1",
            sentences: ["one two three", "four five six", "seven eight nine"]
        )
        let covered = CurriculumScorer.coverage(scenario: s, utterances: ["seven eight nine", "one two three"])
        XCTAssertEqual(covered.matchedSentences, ["one two three", "seven eight nine"], "命中句保持素材顺序")
        XCTAssertEqual(covered.missingSentences, ["four five six"])
        XCTAssertEqual(covered.sentenceTotal, 3)
    }

    func testCoverageMatchesSingleWordAndPhraseVocabularyDifferently() {
        let s = scenario(
            level: "B1",
            vocabulary: ["prefer", "main course", "however"]
        )
        // `prefer` / `however` 单词命中；`main course` 必须整串相邻出现。
        let covered = CurriculumScorer.coverage(
            scenario: s,
            utterances: ["I prefer the main course, however it is pricey"]
        )
        XCTAssertEqual(covered.matchedWords, ["prefer", "main course", "however"])
        XCTAssertTrue(covered.missingWords.isEmpty)
    }

    func testPhraseVocabularyNeedsConsecutiveWords() {
        let s = scenario(level: "B1", vocabulary: ["main course"])
        let split = CurriculumScorer.coverage(scenario: s, utterances: ["I want the main, and a course"])
        XCTAssertTrue(split.matchedWords.isEmpty, "被别的词隔开就不算这个词组")
    }

    func testCoverageCountsTurnsByTurnsSpokenNotByContent() {
        let s = scenario(level: "A2", maxTurns: 10)
        // 轮次口径必须与星星规则一致：**发了几轮就算几轮**，
        // 只有附件没写字的那一轮也照样是一轮（否则同一局里会出现两个轮次数）。
        let covered = CurriculumScorer.coverage(scenario: s, utterances: ["hi", "   ", "ok then"])
        XCTAssertEqual(covered.turnsUsed, 3)
        XCTAssertEqual(ScenarioRewardRule.stars(turnsUsed: covered.turnsUsed, maxTurns: covered.maxTurns),
                       ScenarioRewardRule.stars(turnsUsed: 3, maxTurns: 10),
                       "课程覆盖度与星星规则必须放同一把尺子上")
        XCTAssertEqual(covered.maxTurns, 10)
        XCTAssertEqual(covered.turnRatio, 0.3, accuracy: 0.0001)
    }

    func testTurnRatioIsCappedAtOne() {
        let s = scenario(level: "A2", maxTurns: 2)
        let covered = CurriculumScorer.coverage(scenario: s, utterances: ["a", "b", "c", "d"])
        XCTAssertEqual(covered.turnRatio, 1, "超额发言不能让比例破 1")
    }

    // MARK: - 4. 过关判定

    func testAssessmentPassesWhenAllThreeCriteriaMet() {
        let s = scenario(
            level: "A2",
            maxTurns: 10,
            vocabulary: ["prefer", "reason", "however", "agree"],
            sentences: ["I prefer tea", "The reason is simple"]
        )
        let utterances = ["I prefer tea", "The reason is simple, however I also agree",
                          "1", "2", "3", "4", "5", "6", "7"]
        let result = CurriculumScorer.assess(scenario: s, utterances: utterances)
        XCTAssertEqual(result.verdict, .passed, "三项全达标应过关：\(result.reasons)")
        XCTAssertTrue(result.verdict.didPass)
        XCTAssertNil(result.nextSentence, "全说到了就没有「下次补哪句」")
    }

    func testAssessmentIsCloseWhenExactlyOneOfQuestAndFocusMisses() {
        // 需求 3 的口径：通关看**两件事** —— 主线任务 + 教学重点。
        // 这里刻意让「教学重点达标」而「主线任务差一步」：3 句目标句 → 3 步主线，
        // 说到 A、C 没说到 B，但 A2 只要求 2 句，所以重点过了、主线没过 = 就差一点。
        let s = scenario(
            level: "A2",
            maxTurns: 8,
            vocabulary: ["prefer", "reason", "however", "agree"],
            sentences: ["I prefer tea", "The reason is simple", "However I agree"]
        )
        let utterances = ["I prefer tea", "however I agree", "reason", "x", "x"]
        let result = CurriculumScorer.assess(scenario: s, utterances: utterances)
        XCTAssertEqual(result.verdict, .close, "只差一件事 = 就差一点：\(result.reasons)")
        XCTAssertFalse(result.isQuestSatisfied, "第 2 步没说到，主线任务不算完成")
        XCTAssertTrue(result.isFocusSatisfied, "目标句 2/2、目标词 4/4，教学重点达标")
        XCTAssertEqual(result.quest.doneCount, 2)
        XCTAssertEqual(result.quest.total, 3)
        XCTAssertEqual(result.nextSentence, "The reason is simple", "没说的那句就是下次该补的")
    }

    /// 反过来：主线任务全完成、教学重点没达标 —— 同样是「就差一点」。
    func testAssessmentIsCloseWhenQuestDoneButFocusShort() {
        let s = scenario(
            level: "B2",
            maxTurns: 10,
            vocabulary: ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"],
            sentences: ["alpha bravo"]
        )
        // 唯一一步主线做到（说了 alpha bravo），但 B2 要 3 句目标句 / 6 个目标词 —— 都差着。
        let result = CurriculumScorer.assess(scenario: s, utterances: ["alpha bravo", "x", "x", "x", "x", "x", "x", "x"])
        XCTAssertTrue(result.isQuestSatisfied, "主线任务已完成")
        XCTAssertFalse(result.isFocusSatisfied)
        XCTAssertEqual(result.verdict, .close, "\(result.reasons)")
    }

    /// 需求 3：**星星记开口量、通关看任务与重点** —— 两句都没做到就是「再练一轮」。
    func testAssessmentIsNotYetWhenBothQuestAndFocusMiss() {
        let s = scenario(level: "B2", maxTurns: 10, vocabulary: ["a", "b", "c"], sentences: ["fizz buzz"])
        let result = CurriculumScorer.assess(scenario: s, utterances: ["hello there"])
        XCTAssertEqual(result.verdict, .notYet)
        XCTAssertFalse(result.verdict.didPass)
    }

    func testAssessmentReasonsCoverQuestAndFocus() {
        let s = scenario(level: "A1", maxTurns: 8, vocabulary: ["menu"], sentences: ["may I see the menu"])
        let result = CurriculumScorer.assess(scenario: s, utterances: ["may I see the menu"])
        XCTAssertTrue(result.reasons.contains { $0.contains("主线任务") }, "\(result.reasons)")
        XCTAssertTrue(result.reasons.contains { $0.contains("教学重点") }, "\(result.reasons)")
        XCTAssertEqual(result.verdict, .passed, "\(result.reasons)")
    }

    /// 素材极简（既没目标句也没目标词）时不能拿空条件卡人：退回「说满轮次即过关」。
    func testAssessmentFallsBackToTurnsWhenNoQuestAndNoFocus() {
        let s = scenario(level: "A1", maxTurns: 4)
        let result = CurriculumScorer.assess(scenario: s, utterances: ["one", "two", "three"])
        XCTAssertEqual(result.quest.total, 0, "没有素材就没有主线")
        XCTAssertTrue(result.focus.isEmpty, "没有素材就没有重点")
        XCTAssertEqual(result.verdict, .passed, "A1 要求说满一半（2 轮），说了 3 轮应过关：\(result.reasons)")
    }

    /// ⚠️ 要求数不能超过素材实际有的数量：只写了 1 句目标句，按 B1 的「3 句」卡人
    /// 会让这一关**永远过不去**。
    func testRequiredCountsAreRelaxedWhenMaterialIsSparse() {
        let s = scenario(level: "B1", maxTurns: 8, vocabulary: ["menu"], sentences: ["may I see the menu"])
        let result = CurriculumScorer.assess(scenario: s, utterances: ["may I see the menu"])
        XCTAssertEqual(result.focus.requiredSentences, 1, "只有 1 句素材，就不能要求 2 句")
        XCTAssertEqual(result.focus.requiredWords, 1)
        XCTAssertTrue(result.isFocusSatisfied)
    }

    /// 开练之前界面要报的门槛数，必须与判定用的是**同一个** ——
    /// 情景卡片写「目标句 4 句」，练起来提要条写「目标句 0/2」，学员会以为漏了 2 句。
    func testFocusThresholdMatchesTheOneUsedByAssessment() {
        let full = scenario(
            level: "B1", maxTurns: 8,
            vocabulary: ["a", "b", "c", "d", "e", "f"],
            sentences: ["s1", "s2", "s3", "s4"]
        )
        let threshold = CurriculumScorer.focusThreshold(for: full)
        // B1 门槛是 3 句 / 5 词；素材是 4 句 / 6 词 → 取档位要求
        XCTAssertEqual(threshold.sentences, 3)
        XCTAssertEqual(threshold.words, 5)
        let assessed = CurriculumScorer.assess(scenario: full, utterances: [])
        XCTAssertEqual(threshold.sentences, assessed.focus.requiredSentences)
        XCTAssertEqual(threshold.words, assessed.focus.requiredWords)

        // 素材稀疏时必须一起放宽，且两边仍然一致
        let sparse = scenario(level: "B1", maxTurns: 8, vocabulary: ["menu"], sentences: ["may I see the menu"])
        let sparseThreshold = CurriculumScorer.focusThreshold(for: sparse)
        XCTAssertEqual(sparseThreshold.sentences, 1)
        XCTAssertEqual(sparseThreshold.words, 1)
        let sparseAssessed = CurriculumScorer.assess(scenario: sparse, utterances: [])
        XCTAssertEqual(sparseThreshold.sentences, sparseAssessed.focus.requiredSentences)
        XCTAssertEqual(sparseThreshold.words, sparseAssessed.focus.requiredWords)
    }

    /// 断点续做：库里已完成的步骤与这一局新完成的取**并集**，只增不减。
    func testQuestProgressUnionsStoredAndNewSteps() {
        let s = scenario(level: "A2", maxTurns: 8, sentences: ["alpha beta", "gamma delta", "epsilon zeta"])
        let plan = ScenarioQuestRule.plan(for: s)
        XCTAssertEqual(plan.total, 3)

        // 上一局完成了第 1 步（库里记着），这一局说了第 3 步的那句。
        let done = Set([plan.steps[0].id])
        let progress = ScenarioQuestRule.progress(
            plan: plan, utterances: ["epsilon zeta"], alreadyDone: done
        )
        XCTAssertEqual(progress.doneCount, 2, "旧进度不该被这一局没说到而抹掉")
        XCTAssertEqual(progress.completedStepIDs.count, 2)
        XCTAssertFalse(progress.isComplete, "第 2 步还没做")
        XCTAssertEqual(progress.currentStep?.id, plan.steps[1].id, "当前节点是第一个未完成的步骤")
    }

    /// 主线任务缺字段时从目标句推导，保证「新加场景忘了写主线」不会变成一局无所事事。
    func testQuestPlanFallsBackToTargetSentences() {
        let s = scenario(level: "A2", maxTurns: 6, sentences: ["one two", "three four"])
        XCTAssertTrue(s.mainQuest.isEmpty, "测试素材没写主线")
        let plan = ScenarioQuestRule.plan(for: s)
        XCTAssertEqual(plan.total, 2, "两句目标句切成两步")
        XCTAssertEqual(plan.anchoredSteps.count, 2)
        XCTAssertTrue(plan.anchoredSteps.allSatisfy { !$0.anchors.isEmpty })
    }

    func testAssessmentUsesTheScenariosPrimaryLevel() {
        // `A2-B1` 门槛按低的 A2 走 —— 标区间意味着「从这一档开始也能练」。
        let s = scenario(level: "A2-B1", maxTurns: 10, sentences: ["a b c"])
        let result = CurriculumScorer.assess(scenario: s, utterances: ["a b c"])
        XCTAssertEqual(result.level, .a2)
    }

    func testMissingSentenceIsBlankEntryNotDuplicated() {
        let s = scenario(level: "A1", maxTurns: 4, sentences: ["alpha beta", "gamma delta"])
        let result = CurriculumScorer.assess(scenario: s, utterances: ["alpha beta"])
        XCTAssertEqual(result.nextSentence, "gamma delta")
        XCTAssertEqual(result.coverage.missingSentences, ["gamma delta"])
    }

    // MARK: - 5. 课程阶梯

    func testStagesGroupScenariosByParsedLevel() {
        let scenarios = [
            scenario(id: "a", level: "A1-A2"),
            scenario(id: "b", level: "A2"),
            scenario(id: "c", level: "B1"),
            scenario(id: "d", level: "B2"),
        ]
        let stages = CurriculumLadder.stages(scenarios: scenarios, levels: [])
        XCTAssertEqual(stages.map(\.level), [.a1, .a2, .b1, .b2])
        XCTAssertEqual(stages.first { $0.level == .a1 }?.scenarios.map(\.id), ["a"])
        XCTAssertEqual(stages.first { $0.level == .a2 }?.scenarios.map(\.id), ["a", "b"], "区间场景在两档都露面")
        XCTAssertEqual(stages.first { $0.level == .b2 }?.scenarios.map(\.id), ["d"])
    }

    func testStagesSkipLevelsWithNoContentAtAll() {
        let scenarios = [scenario(id: "a", level: "B2")]
        let stages = CurriculumLadder.stages(scenarios: scenarios, levels: [])
        XCTAssertEqual(stages.map(\.level), [.b2], "没有内容的档位不出现")
    }

    func testStagesBindTreeLevelsThroughScenarioID() {
        let scenarios = [scenario(id: "a", level: "B1"), scenario(id: "b", level: "B2")]
        let levels = [
            treeLevel("l1", scenario: "a", state: .completed, required: 4, earned: 4),
            treeLevel("l2", scenario: "b", state: .inProgress, required: 5, earned: 2),
            treeLevel("l3", scenario: nil),
            treeLevel("l4", scenario: "ghost", state: .locked),
        ]
        let stages = CurriculumLadder.stages(scenarios: scenarios, levels: levels)
        XCTAssertEqual(stages.first { $0.level == .b1 }?.levels.map(\.id), ["l1"])
        XCTAssertEqual(stages.first { $0.level == .b2 }?.levels.map(\.id), ["l2"])
        XCTAssertFalse(stages.contains { $0.levels.contains { $0.id == "l3" } }, "没绑场景的关卡不进任何档")
        XCTAssertFalse(stages.contains { $0.levels.contains { $0.id == "l4" } }, "绑了不存在的场景不算")
    }

    func testStageUnlockAndCompletionReadTheTreeState() {
        let scenarios = [scenario(id: "a", level: "A1")]
        let locked = CurriculumStage(level: .a1, scenarios: scenarios, levels: [treeLevel("l1", scenario: "a")])
        XCTAssertFalse(locked.isUnlocked)
        XCTAssertFalse(locked.isCompleted)
        XCTAssertEqual(locked.progress, 0)

        let open = CurriculumStage(
            level: .a1, scenarios: scenarios,
            levels: [treeLevel("l1", scenario: "a", state: .unlocked, required: 4, earned: 1)]
        )
        XCTAssertTrue(open.isUnlocked)
        XCTAssertFalse(open.isCompleted)
        XCTAssertEqual(open.progress, 0.25, accuracy: 0.0001)

        let done = CurriculumStage(
            level: .a1, scenarios: scenarios,
            levels: [treeLevel("l1", scenario: "a", state: .completed, required: 4, earned: 4)]
        )
        XCTAssertTrue(done.isCompleted)
        XCTAssertEqual(done.progress, 1, accuracy: 0.0001)
    }

    func testOverallProgressCountsIntervalLevelOnlyOnce() {
        // 同一个场景同时落在 A1 / A2 两档 —— 若不去重，星数会被算两遍，进度被压低。
        let scenarios = [scenario(id: "a", level: "A1-A2")]
        let levels = [treeLevel("l1", scenario: "a", state: .inProgress, required: 6, earned: 3)]
        let stages = CurriculumLadder.stages(scenarios: scenarios, levels: levels)
        XCTAssertEqual(stages.count, 2, "A1 / A2 两档都会出现")
        XCTAssertEqual(CurriculumLadder.overallProgress(stages), 0.5, accuracy: 0.0001)
    }

    func testOverallProgressIsZeroWithoutBoundLevels() {
        let stages = CurriculumLadder.stages(scenarios: [scenario(id: "a", level: "A1")], levels: [])
        XCTAssertEqual(CurriculumLadder.overallProgress(stages), 0)
        XCTAssertEqual(CurriculumLadder.overallProgress([]), 0)
    }

    // MARK: - 6. 素材完整性（内容层不能悄悄缺斤少两）

    func testEveryBundledScenarioDeclaresTargetSentences() {
        let scenarios = BundledScenarioFixture.all()
        XCTAssertFalse(scenarios.isEmpty, "内置场景应为空")
        for scenario in scenarios {
            XCTAssertFalse(
                scenario.targetSentences.isEmpty,
                "场景「\(scenario.id)」没写目标句 —— 课程体系就没法判定它过没过"
            )
        }
    }

    func testEveryBundledScenarioDeclaresAParsableLevel() {
        for scenario in BundledScenarioFixture.all() {
            XCTAssertFalse(
                scenario.cefrLevels.isEmpty,
                "场景「\(scenario.id)」的 level=\"\(scenario.level)\" 解析不出 CEFR 档位"
            )
        }
    }

    func testBundledLadderHasContentInEveryTier() {
        let scenarios = BundledScenarioFixture.all()
        let levels = BundledScenarioFixture.progress().levels
        let stages = CurriculumLadder.stages(scenarios: scenarios, levels: levels)
        XCTAssertEqual(stages.map(\.level), [.a1, .a2, .b1, .b2], "四档都要有内容，课程才是完整的阶梯")
        for stage in stages {
            XCTAssertFalse(stage.scenarios.isEmpty, "\(stage.level.code) 档没有情景")
        }
    }

    func testHighTiersAreBoundToTreeLevels() {
        let scenarios = BundledScenarioFixture.all()
        let levels = BundledScenarioFixture.progress().levels
        let stages = CurriculumLadder.stages(scenarios: scenarios, levels: levels)
        for code in [CEFRLevel.b1, .b2] {
            let stage = stages.first { $0.level == code }
            XCTAssertNotNil(stage)
            XCTAssertFalse(stage?.levels.isEmpty ?? true, "\(code.code) 档必须挂到大树关卡上，否则练完无处记星")
        }
    }

    /// 把「哪一档挂哪几关」钉死 —— 这是**素材 × 绑定表 × CEFR 解析**三者的联合产物，
    /// 任何一处改了这里就会红，改的人必须重新想一遍课程顺序。
    func testBundledLadderBindsTheExpectedTreeLevels() {
        let stages = CurriculumLadder.stages(
            scenarios: BundledScenarioFixture.all(),
            levels: BundledScenarioFixture.progress().levels
        )
        var bound: [CEFRLevel: [String]] = [:]
        for stage in stages { bound[stage.level] = stage.levels.map(\.id) }

        // l1 打招呼 / l3 点咖啡 都是 A1-A2，所以两档都露面（区间场景的本意）。
        XCTAssertEqual(bound[.a1], ["l1", "l3"])
        XCTAssertEqual(bound[.a2], ["l1", "l3", "l4", "l5"])
        // b1 档：自我介绍（B1-B2）、问路（A2-B1）、观点表达（B1）。
        XCTAssertEqual(bound[.b1], ["l2", "l5", "l6"])
        // b2 档：自我介绍（B1-B2）、辩论、自由演讲。
        XCTAssertEqual(bound[.b2], ["l2", "l7", "l8"])
    }

    /// 只有「绑了情景、且情景有目标句」的关卡才配拿星 —— 绑定表漏一格就没人记账。
    func testEveryBoundTreeLevelPointsAtAScenarioWithSentences() {
        let scenarios = BundledScenarioFixture.all()
        let byID = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id, $0) })
        for level in BundledScenarioFixture.progress().levels {
            guard let scenarioID = level.scenarioID else { continue }
            let scenario = byID[scenarioID]
            XCTAssertNotNil(scenario, "关卡 \(level.id) 绑的场景 \(scenarioID) 不存在")
            XCTAssertFalse(
                scenario?.targetSentences.isEmpty ?? true,
                "关卡 \(level.id) 绑的场景「\(scenarioID)」没有目标句 —— 这一关没有可判定的课程目标"
            )
        }
    }

    /// 每档的星星是「挂在这一档上的关卡」之和；两档共用一个区间场景是正常的。
    func testStageStarsAddUpFromItsOwnLevels() {
        let stages = CurriculumLadder.stages(
            scenarios: BundledScenarioFixture.all(),
            levels: BundledScenarioFixture.progress().levels
        )
        for stage in stages {
            XCTAssertEqual(stage.requiredStars, stage.levels.reduce(0) { $0 + $1.requiredStars })
            XCTAssertEqual(stage.earnedStars, stage.levels.reduce(0) { $0 + $1.earnedStars })
            XCTAssertLessThanOrEqual(stage.earnedStars, stage.requiredStars)
        }
    }
}

// MARK: - 素材夹具

/// 读取**随包发布**的场景与关卡绑定，用于内容完整性断言。
///
/// 与生产同一条加载路径（`ScenarioCatalog` / `LevelBindingCatalog`），
/// 素材改坏了这里就会红 —— 不必手工同步一份清单。
private enum BundledScenarioFixture {
    static func all() -> [Scenario] { ScenarioCatalog.bundled() }

    static func progress() -> LearnerProgress {
        var progress = LearnerProgress.seed()
        progress.applyScenarioBindings(LevelBindingCatalog.bundled())
        return progress
    }
}
