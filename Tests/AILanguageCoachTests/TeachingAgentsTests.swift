import AIDomain
import AIServices
import XCTest

/// 第 8 步 Grammar Agent：错误分类 / 定级 / 判重。
///
/// 验收点原文：「Grammar analysis is testable without a specific LLM provider」——
/// 所以这里一次模型请求都不发，全靠规则表。
final class GrammarAgentTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func analyze(_ original: String, _ corrected: String, explanation: String = "") -> GrammarAnalysis {
        GrammarAgent.analyze(
            corrections: [GrammarCorrection(original: original, corrected: corrected, explanation: explanation)]
        )
    }

    private func category(_ original: String, _ corrected: String) -> GrammarErrorCategory? {
        analyze(original, corrected).errors.first?.category
    }

    private func record(_ original: String, _ corrected: String) -> CorrectionRecord {
        CorrectionRecord(
            correction: GrammarCorrection(original: original, corrected: corrected, explanation: ""),
            createdAt: now
        )
    }

    // MARK: - 基本行为

    func testEmptyInputIsClean() {
        XCTAssertFalse(GrammarAgent.analyze(corrections: []).hasError)
        XCTAssertNil(GrammarAnalysis.clean.primary)
    }

    /// 老师偶尔会标出「原句 → 同一句」这类无信息行：不能算错误，否则污染重复统计。
    func testUnchangedOrEmptyTextIsNotAnError() {
        XCTAssertFalse(analyze("I went to school.", "I went to school.").hasError)
        XCTAssertFalse(analyze("  I went  to school ", "i went to school").hasError)
        XCTAssertFalse(analyze("", "I went to school.").hasError)
        XCTAssertFalse(analyze("I went to school.", "").hasError)
    }

    // MARK: - 分类

    func testWordOrderIsDetected() {
        XCTAssertEqual(category("I to school go.", "I go to school."), .wordOrder)
    }

    /// `I have went` → `I went`：**删掉**助动词同样是时态问题（只盯「加了什么」会漏掉一半）。
    func testTenseIsDetectedWhenAuxiliaryIsRemoved() {
        XCTAssertEqual(category("I have went to London.", "I went to London."), .verbTense)
        XCTAssertEqual(category("I go to London yesterday.", "I went to London yesterday."), .verbTense)
    }

    /// `go → goes` 是第三人称单数，**不是**复数。顺序判错的话解释会完全跑偏。
    func testThirdPersonSingularIsAgreementNotPlural() {
        XCTAssertEqual(category("He go to school.", "He goes to school."), .verbAgreement)
        XCTAssertEqual(category("She study English.", "She studies English."), .verbAgreement)
    }

    func testPluralIsDetected() {
        XCTAssertEqual(category("I have two apple.", "I have two apples."), .pluralNumber)
    }

    func testMissingArticleIsDetected() {
        XCTAssertEqual(category("I have apple.", "I have an apple."), .article)
        XCTAssertEqual(category("I saw the sun.", "I saw sun."), .article)
    }

    func testPrepositionSwapIsDetected() {
        XCTAssertEqual(category("I go to school in bus.", "I go to school by bus."), .preposition)
    }

    func testPronounSwapIsDetected() {
        XCTAssertEqual(category("Me is happy.", "I am happy."), .pronoun)
    }

    func testSpellingIsDetectedByEditDistance() {
        XCTAssertEqual(category("I recieve a letter.", "I receive a letter."), .spelling)
    }

    func testPunctuationOnlyChangeIsDetected() {
        XCTAssertEqual(category("Hello world", "Hello, world."), .punctuation)
    }

    func testUnknownDifferencesFallBackToOther() {
        // 拿不准就老实落 wordChoice / other —— 猜一个漂亮但错的类型会污染「反复错误」统计。
        XCTAssertEqual(category("I like cats.", "I admire cats."), .wordChoice)
    }

    // MARK: - 严重度

    func testSeverityEscalatesWhenWordsAreMissing() {
        let analysis = analyze("I go school", "I went to the new school in London")
        XCTAssertEqual(analysis.primary?.severity, .major)
    }

    func testSeverityStaysMinorForSmallSlips() {
        XCTAssertEqual(analyze("I have apple.", "I have an apple.").primary?.severity, .minor)
    }

    // MARK: - 判重

    func testRepeatedErrorIsFlaggedAgainstHistory() {
        let history = [record("I have went to London.", "I went to London.")]
        let analysis = GrammarAgent.analyze(
            corrections: [GrammarCorrection(original: "I have went to London.", corrected: "I went to London.", explanation: "")],
            history: history
        )
        XCTAssertTrue(analysis.hasRepeatedError)
        XCTAssertEqual(analysis.repeatedErrors.count, 1)
    }

    func testRepeatedErrorIsFlaggedWithinTheSameBatch() {
        let analysis = GrammarAgent.analyze(corrections: [
            GrammarCorrection(original: "He go home.", corrected: "He goes home.", explanation: ""),
            GrammarCorrection(original: "he go home", corrected: "he goes home", explanation: ""),
        ])
        XCTAssertEqual(analysis.errors.count, 2)
        XCTAssertFalse(analysis.errors[0].isRepeated, "第一次出现不算反复")
        XCTAssertTrue(analysis.errors[1].isRepeated, "同一批里的第二次就该算反复")
        XCTAssertEqual(analysis.errors[0].pattern, analysis.errors[1].pattern, "大小写与空白差异不应产生不同指纹")
    }

    func testSingleOccurrenceIsNotRepeated() {
        XCTAssertFalse(analyze("I have apple.", "I have an apple.").hasRepeatedError)
    }

    // MARK: - 汇总

    func testPrimaryPicksMostSevereThenEarliest() {
        let analysis = GrammarAgent.analyze(corrections: [
            GrammarCorrection(original: "I have apple.", corrected: "I have an apple.", explanation: ""),
            GrammarCorrection(original: "I go school", corrected: "I went to the new school in London", explanation: ""),
            GrammarCorrection(original: "I recieve it.", corrected: "I receive it.", explanation: ""),
        ])
        XCTAssertEqual(analysis.primary?.severity, .major)
        XCTAssertEqual(analysis.primary?.category, .preposition)
    }

    func testDominantCategoryCountsByFrequency() {
        let analysis = GrammarAgent.analyze(corrections: [
            GrammarCorrection(original: "I go to school in bus.", corrected: "I go to school by bus.", explanation: ""),
            GrammarCorrection(original: "I arrive in London.", corrected: "I arrive at London.", explanation: ""),
            GrammarCorrection(original: "I recieve a letter.", corrected: "I receive a letter.", explanation: ""),
        ])
        XCTAssertEqual(analysis.dominantCategory, .preposition)
    }

    func testExplanationsAreCarriedThrough() {
        let analysis = analyze("He go home.", "He goes home.", explanation: "Third person takes -s.")
        XCTAssertEqual(analysis.errors.first?.explanation, "Third person takes -s.")
    }

    func testAnalysisIsDeterministic() {
        let lhs = analyze("I have went to London.", "I went to London.")
        let rhs = analyze("I have went to London.", "I went to London.")
        XCTAssertEqual(lhs.errors.map(\.category), rhs.errors.map(\.category))
        XCTAssertEqual(lhs.errors.map(\.severity), rhs.errors.map(\.severity))
    }
}

/// 第 7 步 Teacher Agent：教学决策。
final class TeacherAgentTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func decide(
        proficiency: LearnerProfile.Proficiency = .intermediate,
        learnerText: String = "I went to London last week.",
        grammar: GrammarAnalysis? = nil,
        context: ConversationContext = ConversationContext(),
        memory: LearningMemory = .empty
    ) -> TeacherDecision {
        TeacherAgent.decide(
            TeacherAgent.Input(
                profile: LearnerProfile(proficiency: proficiency),
                context: context,
                learnerText: learnerText,
                grammar: grammar,
                memory: memory
            )
        )
    }

    private func recurring(_ original: String, _ corrected: String, count: Int) -> LearningMemory {
        LearningMemory(
            recurringErrors: [
                RecurringError(original: original, corrected: corrected, explanation: "", count: count, lastSeen: now)
            ]
        )
    }

    private func terseContext() -> ConversationContext {
        var context = ConversationContext()
        for text in ["ok", "yes", "fine"] {
            context.append(ConversationTurn(speaker: .learner, text: text))
        }
        return context
    }

    // MARK: - 纠错强度

    func testBeginnerGetsGentlerTreatment() {
        XCTAssertEqual(decide(proficiency: .beginner).correctionLevel, .gentle)
        XCTAssertEqual(decide(proficiency: .advanced).correctionLevel, .strict)
        XCTAssertEqual(decide(proficiency: .intermediate).correctionLevel, .balanced)
    }

    /// 情景里以场景为准：场景的 strict 是设计意图，不该被学员水平悄悄改掉。
    func testScenarioCorrectionModeWinsOverProficiency() {
        let context = ConversationContext(
            scenario: ScenarioFocus(id: "debate", title: "Debate", correctionMode: .strict, turnsRemaining: 5)
        )
        XCTAssertEqual(decide(proficiency: .beginner, context: context).correctionLevel, .strict)
    }

    // MARK: - 反复错误 → 集中练

    func testRecurringErrorSwitchesToDrillAndRaisesIntensity() {
        let decision = decide(memory: recurring("I have went to London.", "I went to London.", count: 3))
        XCTAssertEqual(decision.responseMode, .drill)
        XCTAssertEqual(decision.correctionLevel, .strict, "反复犯的错要把强度提上去")
        XCTAssertTrue(decision.learningFocus.contains(GrammarErrorCategory.verbTense.rawValue))
    }

    func testSingleOccurrenceDoesNotTriggerDrill() {
        let decision = decide(memory: recurring("I have went to London.", "I went to London.", count: 1))
        XCTAssertEqual(decision.responseMode, .conversation)
    }

    // MARK: - 要不要纠 / 形态

    func testTerseLearnerIsEncouragedAndNotEmptyCorrected() {
        let decision = decide(context: terseContext())
        XCTAssertEqual(decision.responseMode, .encouragement)
        XCTAssertFalse(decision.shouldCorrect, "学员只蹦了单词：先请他多说，而不是挑错")
    }

    func testWrapUpSceneSkipsCorrection() {
        let context = ConversationContext(
            scenario: ScenarioFocus(id: "cafe", title: "Cafe", turnsRemaining: 1)
        )
        let decision = decide(context: context)
        XCTAssertEqual(decision.responseMode, .wrapUp)
        XCTAssertFalse(decision.shouldCorrect)
    }

    func testKnownErrorTriggersCorrectionMode() {
        let decision = decide(grammar: GrammarAgent.analyze(corrections: [
            GrammarCorrection(original: "He go home.", corrected: "He goes home.", explanation: ""),
        ]))
        XCTAssertTrue(decision.shouldCorrect)
        XCTAssertEqual(decision.responseMode, .correction)
        XCTAssertTrue(decision.learningFocus.contains(GrammarErrorCategory.verbAgreement.rawValue))
    }

    // MARK: - 难度

    /// 生成前拿不到本轮分析 —— 这时**不许**动难度（否则会一路顶到 5）。
    func testDifficultyIsUntouchedWhenAnalysisIsUnknown() {
        XCTAssertEqual(decide(context: ConversationContext(difficulty: 3)).difficulty, 3)
        XCTAssertEqual(decide(context: ConversationContext(difficulty: 5)).difficulty, 5)
    }

    func testDifficultyRisesOnCleanTurn() {
        XCTAssertEqual(decide(grammar: .clean, context: ConversationContext(difficulty: 3)).difficulty, 4)
        XCTAssertEqual(decide(grammar: .clean, context: ConversationContext(difficulty: 5)).difficulty, 5)
    }

    func testDifficultyDropsOnMajorError() {
        let analysis = GrammarAgent.analyze(corrections: [
            GrammarCorrection(original: "I go school", corrected: "I went to the new school in London", explanation: ""),
        ])
        XCTAssertEqual(decide(grammar: analysis, context: ConversationContext(difficulty: 3)).difficulty, 2)
    }

    func testDifficultyStaysWhenRecurringErrorIsStillUnresolved() {
        let decision = decide(
            grammar: .clean,
            context: ConversationContext(difficulty: 3),
            memory: recurring("He go home.", "He goes home.", count: 4)
        )
        XCTAssertEqual(decision.difficulty, 3, "老毛病还没解决就先别加难度")
    }

    // MARK: - 学习重点

    func testWeakPronunciationDimensionsEnterLearningFocus() {
        let memory = LearningMemory(
            weakDimensions: [WeakDimension(dimension: .intonation, averageScore: 60, sampleCount: 3)]
        )
        let decision = decide(memory: memory)
        XCTAssertTrue(decision.learningFocus.contains("pronunciation.intonation"))
    }

    func testThinPronunciationSampleIsIgnored() {
        let memory = LearningMemory(
            weakDimensions: [WeakDimension(dimension: .intonation, averageScore: 60, sampleCount: 1)]
        )
        XCTAssertFalse(decide(memory: memory).learningFocus.contains("pronunciation.intonation"))
    }

    func testDecisionIsDeterministicAndCodable() throws {
        let input = TeacherAgent.Input(
            profile: LearnerProfile(proficiency: .intermediate),
            context: ConversationContext(difficulty: 3),
            learnerText: "hello",
            grammar: nil,
            memory: .empty
        )
        XCTAssertEqual(TeacherAgent.decide(input), TeacherAgent.decide(input))

        // JSON 键名对齐计划的契约（snake_case）。
        let data = try JSONEncoder().encode(TeacherAgent.decide(input))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("response_mode"))
        XCTAssertTrue(json.contains("learning_focus"))
    }
}

/// 第 9 / 10 步：对话方向与响应计划。
final class ResponsePlannerTests: XCTestCase {

    private func decision(
        mode: TeacherDecision.ResponseMode = .conversation,
        level: CorrectionIntensity = .balanced,
        shouldCorrect: Bool = true,
        focus: [String] = []
    ) -> TeacherDecision {
        TeacherDecision(
            responseMode: mode,
            correctionLevel: level,
            difficulty: 3,
            learningFocus: focus,
            shouldCorrect: shouldCorrect
        )
    }

    private var errorAnalysis: GrammarAnalysis {
        GrammarAgent.analyze(corrections: [
            GrammarCorrection(original: "He go home.", corrected: "He goes home.", explanation: ""),
        ])
    }

    private func plan(
        decision: TeacherDecision,
        grammar: GrammarAnalysis = .clean,
        direction: ConversationDirection = ConversationDirection(move: .continueTopic),
        context: ConversationContext = ConversationContext()
    ) -> ResponsePlan {
        ResponsePlanner.plan(decision: decision, grammar: grammar, direction: direction, context: context)
    }

    func testBalancedCorrectionIsBriefWithShortExplanation() {
        let result = plan(decision: decision(mode: .correction), grammar: errorAnalysis)
        XCTAssertEqual(result.intent, .correctAndContinue)
        XCTAssertTrue(result.correction.show)
        XCTAssertEqual(result.correction.style, .brief)
        XCTAssertEqual(result.correction.maxItems, 2)
        XCTAssertTrue(result.explanation.show)
        XCTAssertEqual(result.explanation.length, .short)
        XCTAssertNotNil(result.focusError)
    }

    func testGentleHidesExplanationAndLimitsToOneItem() {
        let result = plan(decision: decision(mode: .correction, level: .gentle), grammar: errorAnalysis)
        XCTAssertEqual(result.correction.maxItems, 1)
        XCTAssertFalse(result.explanation.show)
        XCTAssertEqual(result.explanation.length, .none)
    }

    func testStrictExplainsFullyWithThreeItems() {
        let result = plan(decision: decision(mode: .correction, level: .strict), grammar: errorAnalysis)
        XCTAssertEqual(result.correction.style, .detailed)
        XCTAssertEqual(result.correction.maxItems, 3)
        XCTAssertEqual(result.explanation.length, .full)
    }

    /// 生成前只有「允不允许纠」，还没有本轮错误可引用：纠错指令仍要发出去，
    /// 但具体那一处是空的（这正是老师需要被授权去自己找错）。
    func testCorrectionDirectiveAppearsWithoutConcreteError() {
        let result = plan(decision: decision(mode: .correction), grammar: .clean)
        XCTAssertTrue(result.correction.show)
        XCTAssertNil(result.focusError)
    }

    func testNoCorrectionWhenDecisionSaysSo() {
        let result = plan(decision: decision(shouldCorrect: false), grammar: errorAnalysis)
        XCTAssertFalse(result.correction.show)
        XCTAssertNil(result.focusError)
    }

    func testWrapUpStopsAskingQuestions() {
        let result = plan(
            decision: decision(mode: .wrapUp, shouldCorrect: false),
            direction: ConversationDirection(move: .closeOut, asksFollowUp: false)
        )
        XCTAssertEqual(result.intent, .wrapUp)
        XCTAssertFalse(result.nextQuestion)
    }

    func testTargetVocabularyComesFromContextFirst() {
        let context = ConversationContext(targetVocabulary: ["experience", "journey", "board", "extra"])
        let result = plan(decision: decision(), context: context)
        XCTAssertEqual(result.targetVocabulary, ["experience", "journey", "board"])
    }

    /// 没有待复习词时，就把本轮纠正里**新出现的那个词**带出去（顺手用一遍刚教的词）。
    func testTargetVocabularyFallsBackToCorrectedWord() {
        let result = plan(decision: decision(), grammar: errorAnalysis)
        XCTAssertEqual(result.targetVocabulary, ["goes"])
    }

    func testPlanIsCodableWithContractKeys() throws {
        let result = plan(decision: decision(mode: .correction), grammar: errorAnalysis)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertTrue(json.contains("next_question"))
        XCTAssertTrue(json.contains("target_vocabulary"))
        XCTAssertTrue(json.contains("correct_and_continue"))
    }
}

/// 第 9 步 Conversation Agent：往哪聊。
final class ConversationAgentTests: XCTestCase {

    private func direct(context: ConversationContext) -> ConversationDirection {
        ConversationAgent.direct(context: context, decision: TeacherDecision())
    }

    func testScenarioKeepsTheSceneOnTrack() {
        let context = ConversationContext(
            scenario: ScenarioFocus(id: "cafe", title: "Ordering coffee", turnsRemaining: 4)
        )
        let direction = direct(context: context)
        XCTAssertEqual(direction.move, .returnToScenario)
        XCTAssertEqual(direction.topic, "Ordering coffee")
        XCTAssertTrue(direction.asksFollowUp)
    }

    func testFinalScenarioTurnClosesOut() {
        let context = ConversationContext(
            scenario: ScenarioFocus(id: "cafe", title: "Ordering coffee", turnsRemaining: 1)
        )
        let direction = direct(context: context)
        XCTAssertEqual(direction.move, .closeOut)
        XCTAssertFalse(direction.asksFollowUp)
    }

    func testTerseLearnerGetsAFreshAngle() {
        var context = ConversationContext()
        for text in ["ok", "yes", "fine"] {
            context.append(ConversationTurn(speaker: .learner, text: text))
        }
        let direction = direct(context: context)
        XCTAssertEqual(direction.move, .shiftTopic)
        XCTAssertEqual(direction.engagementCue, ConversationAgent.tersenessCue)
    }

    func testFirstTurnSeedsTopicFromLearningGoal() {
        let context = ConversationContext(learningGoals: ["talk about your weekend"])
        XCTAssertEqual(direct(context: context).topic, "talk about your weekend")
    }

    func testExistingTopicIsContinued() {
        let context = ConversationContext(currentTopic: "food", learningGoals: ["ignored"])
        let direction = direct(context: context)
        XCTAssertEqual(direction.move, .continueTopic)
        XCTAssertEqual(direction.topic, "food")
    }
}

/// 第 6–10 步的编排：ConversationEngine（状态 + 上下文 + 一轮计划）。
@MainActor
final class ConversationEngineTests: XCTestCase {

    func testEngineStartsIdleAndFollowsEvents() {
        let engine = ConversationEngine()
        XCTAssertEqual(engine.state, .idle)
        engine.send(.learnerSpoke)
        XCTAssertEqual(engine.state, .processing)
        engine.send(.firstToken)
        XCTAssertEqual(engine.state, .responding)
        engine.send(.generationFinished)
        XCTAssertEqual(engine.state, .idle)
    }

    func testResetKeepsLearnerSpecificContext() {
        let engine = ConversationEngine()
        engine.syncProfile(LearnerProfile(displayName: "小鹅子", proficiency: .advanced))
        engine.recordLearner("hello")
        engine.reset()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.context.userProfile.displayName, "小鹅子", "画像属于人，不属于这一段会话")
        XCTAssertEqual(engine.context.recentTurns.count, 1)
    }

    func testPlanTurnProducesDecisionDirectionAndPlanWithoutRequests() {
        let engine = ConversationEngine()
        let plan = engine.planTurn(
            learnerText: "I went to London last week.",
            memory: .empty,
            profile: LearnerProfile(proficiency: .beginner)
        )
        XCTAssertEqual(plan.decision.correctionLevel, .gentle)
        XCTAssertEqual(plan.decision.responseMode, .conversation)
        // 生成前不知道本轮错在哪：不该有具体的待纠错误。
        XCTAssertNil(plan.plan.focusError)
        XCTAssertTrue(plan.hasAnythingToTeach, "纠错强度是每轮都要交代给老师的信息")
    }

    func testMemoryIsFoldedIntoContext() {
        let engine = ConversationEngine()
        let memory = LearningMemory(
            recurringErrors: [
                RecurringError(original: "He go home.", corrected: "He goes home.", explanation: "", count: 2, lastSeen: Date()),
            ],
            focusWords: ["journey"]
        )
        _ = engine.planTurn(learnerText: "hi", memory: memory, profile: LearnerProfile())
        XCTAssertEqual(engine.context.knownErrors, ["He go home. -> He goes home."])
        XCTAssertTrue(engine.context.targetVocabulary.contains("journey"))
    }

    func testAnalyzeReplyRecordsKnownErrorsAndFlagsRepeats() {
        let engine = ConversationEngine()
        let correction = GrammarCorrection(original: "He go home.", corrected: "He goes home.", explanation: "")
        let first = engine.analyzeReply([correction])
        XCTAssertTrue(first.hasError)
        XCTAssertEqual(engine.context.knownErrors.count, 1)

        // 第二条同源记录（换大小写）→ 判为反复。
        let second = engine.analyzeReply(
            [GrammarCorrection(original: "he go home", corrected: "he goes home", explanation: "")],
            history: [
                CorrectionRecord(
                    correction: GrammarCorrection(original: "He go home.", corrected: "He goes home.", explanation: ""),
                    createdAt: Date()
                ),
            ]
        )
        XCTAssertTrue(second.hasRepeatedError)
        XCTAssertEqual(engine.context.knownErrors.count, 1, "同一处错误不该在已知错误里堆两行")
    }

    func testReplaceTurnsKeepsWindow() {
        let engine = ConversationEngine()
        let messages = (1...20).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "m\(index)")
        }
        engine.replaceTurns(messages)
        XCTAssertEqual(engine.context.recentTurns.count, ConversationContext.turnWindow)
        XCTAssertEqual(engine.context.recentTurns.last?.text, "m20")
    }

    func testScenarioSyncDrivesDirection() {
        let engine = ConversationEngine()
        engine.syncScenario(ScenarioFocus(id: "cafe", title: "Cafe", turnsRemaining: 1))
        let plan = engine.planTurn(learnerText: "a coffee please", memory: .empty, profile: LearnerProfile())
        XCTAssertEqual(plan.decision.responseMode, .wrapUp)
        XCTAssertEqual(plan.direction.move, .closeOut)

        engine.syncScenario(nil)
        XCTAssertNil(engine.context.scenario)
    }
}
