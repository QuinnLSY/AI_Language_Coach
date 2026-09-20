import AIDomain
import AIInfrastructure
import AppCore
import XCTest

/// 主线任务 / 教学重点 / 前情提要 / 自动复盘策略的纯函数回归（需求 3–6）。
///
/// 全部不碰 IO：`ScenarioQuestRule`、`ScenarioBriefingBuilder`、`PracticeReviewPolicy`、
/// `PracticeResumeRule` 都是纯函数，所以这些用例跑起来是毫秒级的。
final class QuestTests: XCTestCase {

    private func scenario(
        id: String = "test",
        maxTurns: Int = 10,
        vocabulary: [String] = [],
        sentences: [String] = [],
        mainQuest: String = "",
        steps: [QuestStep] = []
    ) -> Scenario {
        Scenario(
            id: id, title: id, titleZh: "测试情景", category: "测试", difficulty: 2, level: "A2",
            objective: "objective", aiRole: "ai", learnerRole: "learner", opening: "Hello there.",
            targetVocabulary: vocabulary, targetGrammar: [],
            targetSentences: sentences, mainQuest: mainQuest, questSteps: steps, maxTurns: maxTurns
        )
    }

    // MARK: - 主线任务计划

    func testPlanUsesAuthoredStepsWhenMaterialProvidesThem() {
        let s = scenario(
            mainQuest: "Order a drink and pay.",
            steps: [
                QuestStep(text: "Say hello", anchors: ["hello there"]),
                QuestStep(text: "Order", anchors: ["one latte please"]),
            ]
        )
        let plan = ScenarioQuestRule.plan(for: s)
        XCTAssertEqual(plan.title, "Order a drink and pay.")
        XCTAssertEqual(plan.total, 2)
        XCTAssertEqual(plan.steps[0].id, "test-s1", "素材没写 id 时按场景 id + 序号补")
        XCTAssertEqual(plan.steps[1].id, "test-s2")
    }

    func testPlanFallsBackToObjectiveThenTitle() {
        let derived = ScenarioQuestRule.plan(for: scenario())
        XCTAssertEqual(derived.title, "objective", "没写 mainQuest 就用 objective")
        XCTAssertTrue(derived.isEmpty, "既没目标句也没目标词 → 没有主线")
    }

    /// 随包素材的守卫：**每一关都要有主线任务**（需求 3），而且每一步都要有可判定的锚点。
    func testBundledScenariosAllCarryUsableQuests() {
        let scenarios = ScenarioCatalog.bundled()
        XCTAssertFalse(scenarios.isEmpty)
        for scenario in scenarios {
            let plan = scenario.questPlan
            XCTAssertGreaterThan(plan.total, 0, "「\(scenario.id)」没有主线任务")
            XCTAssertEqual(
                plan.anchoredSteps.count, plan.total,
                "「\(scenario.id)」有步骤没有锚点 —— 那一步永远不会被判定完成"
            )
            for step in plan.steps {
                for anchor in step.anchors {
                    XCTAssertTrue(
                        scenario.targetSentences.contains(anchor)
                            || scenario.targetVocabulary.contains(anchor),
                        "「\(scenario.id)」第 \(step.id) 步的锚点「\(anchor)」不在目标句/目标词里，判定口径会分裂"
                    )
                }
            }
        }
    }

    // MARK: - 进度（并集 / 当前节点）

    func testProgressMarksCurrentStepAsFirstUnfinishedAnchoredStep() {
        let plan = QuestPlan(title: "t", steps: [
            QuestStep(id: "a", text: "A", anchors: ["alpha"]),
            QuestStep(id: "b", text: "B", anchors: ["bravo"]),
            QuestStep(id: "c", text: "C", anchors: ["charlie"]),
        ])
        let progress = ScenarioQuestRule.progress(plan: plan, utterances: ["bravo"])
        XCTAssertEqual(progress.completedStepIDs, ["b"])
        XCTAssertEqual(progress.currentStep?.id, "a", "当前节点是第一个未完成的步骤")
        XCTAssertEqual(progress.summary, "主线任务 1/3")
        XCTAssertFalse(progress.isComplete)
    }

    /// 没有锚点的步骤**既不阻塞也不冒充完成**（素材写漏锚点时不能凭空给过）。
    func testStepWithoutAnchorsIsNeverMarkedDone() {
        let plan = QuestPlan(title: "t", steps: [
            QuestStep(id: "a", text: "A", anchors: ["alpha"]),
            QuestStep(id: "b", text: "B", anchors: []),
        ])
        let progress = ScenarioQuestRule.progress(plan: plan, utterances: ["alpha"])
        XCTAssertEqual(progress.completedStepIDs, ["a"])
        XCTAssertFalse(progress.isComplete, "没锚点的那一步不算完成")
        XCTAssertNil(progress.currentStep, "无锚点步骤不抢「当前节点」的位置")
    }

    /// 整份计划都没有锚点（素材极简）：退化为「开口即算推进」，否则这一关永远过不去。
    func testPlanWithoutAnyAnchorDegradesToSpeakingOnce() {
        let plan = QuestPlan(title: "t", steps: [QuestStep(id: "a", text: "A")])
        XCTAssertFalse(ScenarioQuestRule.progress(plan: plan, utterances: []).isComplete)
        XCTAssertTrue(ScenarioQuestRule.progress(plan: plan, utterances: ["hi"]).isComplete)
    }

    func testEmptyPlanIsNeverComplete() {
        let progress = ScenarioQuestRule.progress(plan: QuestPlan(title: "t", steps: []), utterances: ["hi"])
        XCTAssertEqual(progress.total, 0)
        XCTAssertFalse(progress.isComplete, "没有步骤不等于做完")
        XCTAssertEqual(progress.summary, "主线任务 0/0")
    }

    func testQuestRecordMergingKeepsOldStepsAndDedupes() {
        let record = ScenarioQuestRecord(
            scenarioID: "s", sessionID: UUID(), doneStepIDs: ["a", "b"], isComplete: false
        )
        let merged = record.merging(doneStepIDs: ["b", "c"], complete: false, sessionID: nil)
        XCTAssertEqual(merged.doneStepIDs, ["a", "b", "c"], "并集且不重复")
        XCTAssertFalse(merged.isComplete)
        let completed = merged.merging(doneStepIDs: [], complete: true, sessionID: nil)
        XCTAssertTrue(completed.isComplete, "一旦整体完成就不再退回")
        XCTAssertEqual(completed.doneStepIDs, ["a", "b", "c"])
    }

    // MARK: - 教学重点

    func testFocusRequiresBothSentencesAndWords() {
        let s = scenario(vocabulary: ["prefer", "reason"], sentences: ["I prefer tea", "The reason is simple"])
        let coverage = CurriculumScorer.coverage(scenario: s, utterances: ["I prefer tea"])
        let focus = CurriculumScorer.focus(scenario: s, coverage: coverage)
        XCTAssertEqual(focus.sentenceItems.count, 2)
        XCTAssertEqual(focus.wordItems.count, 2)
        XCTAssertEqual(focus.matchedSentences, 1)
        XCTAssertFalse(focus.isSatisfied, "目标词一个没用上，重点就没达标")
        // 没拿到的：目标句第 2 句 + 目标词 reason（prefer 已经在第一句里出现了）。
        XCTAssertEqual(focus.missingItems.count, 2)
        XCTAssertEqual(focus.missingItems.map(\.text), ["The reason is simple", "reason"])
    }

    func testEmptyFocusIsReportedAsEmpty() {
        let s = scenario()
        let coverage = CurriculumScorer.coverage(scenario: s, utterances: ["hi"])
        XCTAssertTrue(CurriculumScorer.focus(scenario: s, coverage: coverage).isEmpty)
    }

    // MARK: - 前情提要

    func testBriefingLinesCarryQuestFocusAndReview() {
        let s = scenario(
            maxTurns: 10,
            vocabulary: ["menu"],
            sentences: ["may I see the menu"],
            mainQuest: "Order a meal."
        )
        let review = SessionReview(
            sessionID: UUID(), headline: "这次点餐很顺", newWords: ["appetizer"],
            improvements: ["时态要统一"], suggestion: "下次试着加一句寒暄"
        )
        let briefing = ScenarioBriefingBuilder.build(
            scenario: s, questDone: [], review: review
        )
        XCTAssertFalse(briefing.isFirstTime, "有复盘就算有历史")
        let joined = briefing.lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("Order a meal."), "要有主线任务标题")
        XCTAssertTrue(joined.contains("教学重点"), "要有教学重点")
        XCTAssertTrue(joined.contains("这次点餐很顺"), "要有上次复盘的一句话")
        XCTAssertTrue(joined.contains("时态要统一"))
        XCTAssertTrue(joined.contains("appetizer"), "要带上上次新记的词")
        XCTAssertTrue(briefing.factsBlock.contains("Hello there."), "角色开场白要作为参考给到老师")
    }

    func testBriefingTreatsFreshScenarioAsFirstTime() {
        let briefing = ScenarioBriefingBuilder.build(scenario: scenario(sentences: ["hello there"]))
        XCTAssertTrue(briefing.isFirstTime)
        XCTAssertTrue(briefing.lines.contains { $0.contains("第一次") })
        XCTAssertFalse(briefing.factsBlock.contains("Last session summary"))
    }

    func testBriefingRefreshesCurrentStepFromLiveUtterances() {
        let s = scenario(sentences: ["alpha beta", "gamma delta"])
        var briefing = ScenarioBriefingBuilder.build(scenario: s)
        XCTAssertEqual(briefing.quest.doneCount, 0)
        briefing = briefing.refreshed(utterances: ["alpha beta"])
        XCTAssertEqual(briefing.quest.doneCount, 1)
        XCTAssertEqual(briefing.quest.currentText, "gamma delta")
    }

    func testBriefingFallbackOpenerAlwaysHasSomethingToSay() {
        let fresh = ScenarioBriefingBuilder.build(scenario: scenario(sentences: ["alpha beta"]))
        XCTAssertFalse(fresh.fallbackOpener.isEmpty)
        XCTAssertTrue(fresh.fallbackOpener.contains("alpha beta"))

        let noQuest = ScenarioBriefingBuilder.build(scenario: scenario())
        XCTAssertFalse(noQuest.fallbackOpener.isEmpty, "就算没有主线也要有一句可说的话")
        XCTAssertFalse(noQuest.fallbackOpeningMessage(characterOpening: "Hi!").isEmpty)
    }

    // MARK: - 自动复盘策略

    func testShouldAutoReviewOnlyWhenThereIsNewContent() {
        XCTAssertFalse(
            PracticeReviewPolicy.shouldAutoReview(messageCount: 1, lastReviewedMessageCount: 0),
            "只有老师一句开场白不值得复盘"
        )
        XCTAssertTrue(PracticeReviewPolicy.shouldAutoReview(messageCount: 2, lastReviewedMessageCount: 0))
        XCTAssertFalse(
            PracticeReviewPolicy.shouldAutoReview(messageCount: 4, lastReviewedMessageCount: 4),
            "没有新内容就不重复复盘"
        )
        XCTAssertTrue(PracticeReviewPolicy.shouldAutoReview(messageCount: 6, lastReviewedMessageCount: 4))
    }

    /// ⚠️ 只有拿到**可用**的复盘才允许删练习流水。
    func testPurgeIsBlockedWithoutUsableReview() {
        XCTAssertFalse(PracticeReviewPolicy.canPurgeSource(nil), "没有复盘就不许删流水")
        let empty = SessionReview(sessionID: UUID())
        XCTAssertFalse(PracticeReviewPolicy.canPurgeSource(empty), "空复盘等于没复盘")
        let heuristic = SessionReview(
            sessionID: UUID(), headline: "规则版总结", source: .heuristic
        )
        XCTAssertTrue(PracticeReviewPolicy.canPurgeSource(heuristic), "规则兜底也算可用")
        let llm = SessionReview(sessionID: UUID(), headline: "模型总结")
        XCTAssertTrue(PracticeReviewPolicy.canPurgeSource(llm))
    }

    // MARK: - 启动时怎么继续

    func testResumeRulePrefersScenarioThenFreeTalkThenIdle() {
        XCTAssertEqual(
            PracticeResumeRule.action(latestScenarioID: "restaurant", latestMode: .freeTalk),
            .resumeScenario("restaurant"),
            "有情景就续做情景"
        )
        XCTAssertEqual(PracticeResumeRule.action(latestScenarioID: nil, latestMode: .freeTalk), .resumeFreeTalk)
        XCTAssertEqual(PracticeResumeRule.action(latestScenarioID: nil, latestMode: .conversation), .idle)
        XCTAssertEqual(PracticeResumeRule.action(latestScenarioID: "", latestMode: .conversation), .idle)
        XCTAssertEqual(PracticeResumeRule.action(latestScenarioID: nil, latestMode: nil), .idle)
        XCTAssertEqual(PracticeResumeRule.action(latestScenarioID: "x", latestMode: .conversation).kind, "scenario")
    }

    /// 主线任务已经跑完的那一关**不再自动续做**（否则启动即清零已完成的主线，
    /// 与大树上的「已过关」自相矛盾）——想重练得自己去点「开始任务」。
    func testResumeRuleSkipsCompletedQuestInsteadOfWipingIt() {
        XCTAssertEqual(
            PracticeResumeRule.action(latestScenarioID: "restaurant", latestMode: .conversation, questComplete: true),
            .idle,
            "主线已完成 → 当空闲处理，绝不自动重开"
        )
        XCTAssertEqual(
            PracticeResumeRule.action(latestScenarioID: "restaurant", latestMode: .conversation, questComplete: false),
            .resumeScenario("restaurant"),
            "主线没做完 → 照旧续做"
        )
        // 默认值必须保持「不做这个判断」的旧语义，免得别的调用点被静默改行为。
        XCTAssertEqual(
            PracticeResumeRule.action(latestScenarioID: "restaurant", latestMode: .conversation),
            .resumeScenario("restaurant")
        )
        // 随口练没有主线任务，completed 标志不该影响它。
        XCTAssertEqual(
            PracticeResumeRule.action(latestScenarioID: nil, latestMode: .freeTalk, questComplete: true),
            .resumeFreeTalk
        )
    }

    // MARK: - 难度与判定联动

    /// 主线任务完成 + 教学重点达标 = 过关；只做到一件 = 就差一点（需求 3）。
    ///
    /// 这里刻意让主线与目标句**解耦**（显式写 `questSteps`，第 3 步用了一个说不到的锚点），
    /// 才能真的验出「两件事分开判」，而不是靠它们恰好同步。
    func testVerdictCombinesQuestAndFocus() {
        let s = scenario(
            maxTurns: 6,
            vocabulary: ["alpha", "bravo", "charlie", "delta"],
            sentences: ["alpha bravo", "charlie delta", "echo foxtrot"],
            mainQuest: "Do three things",
            steps: [
                QuestStep(id: "s1", text: "first", anchors: ["alpha bravo"]),
                QuestStep(id: "s2", text: "second", anchors: ["charlie delta"]),
                QuestStep(id: "s3", text: "third", anchors: ["zulu yankee"]),
            ]
        )

        // 说了 s1 / s2：目标句 2/2（A2 只要 2 句）、目标词 4/4 都达标，但第 3 步没做。
        let close = CurriculumScorer.assess(
            scenario: s, utterances: ["alpha bravo", "charlie delta"]
        )
        XCTAssertTrue(close.isFocusSatisfied, "教学重点应达标：\(close.reasons)")
        XCTAssertFalse(close.isQuestSatisfied)
        XCTAssertEqual(close.verdict, .close, "\(close.reasons)")
        XCTAssertEqual(close.quest.currentStep?.id, "s3")

        // 第 3 步在上一局已经做了（库里记着）→ 两件事都成 → 过关。
        let passed = CurriculumScorer.assess(
            scenario: s, utterances: ["alpha bravo", "charlie delta"], questDone: ["s3"]
        )
        XCTAssertEqual(passed.verdict, .passed, "\(passed.reasons)")
    }
}
