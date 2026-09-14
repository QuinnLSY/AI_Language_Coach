import AIDomain
import AppCore
import XCTest

/// 第 6 步（Conversation Engine）：对话状态机与上下文。
///
/// 验收点原文：转移确定 / 可暂停恢复 / 可安全结束 / 上下文可序列化。
/// 这些全部是不需要网络与数据库的纯逻辑，所以这里能直接钉死它们。
final class ConversationStateMachineTests: XCTestCase {

    // MARK: - 确定性转移

    func testLinearFlowReachesIdleAgain() {
        var machine = ConversationStateMachine()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.send(.beginListening), .listening)
        XCTAssertEqual(machine.send(.learnerSpoke), .processing)
        XCTAssertEqual(machine.send(.generationStarted), .processing)
        XCTAssertEqual(machine.send(.firstToken), .responding)
        XCTAssertEqual(machine.send(.generationFinished), .idle)
    }

    /// 「确定性」= 同一串事件永远得到同一串状态。
    func testSameEventSequenceIsAlwaysIdentical() {
        let events: [ConversationEvent] = [
            .beginListening, .learnerSpoke, .generationStarted, .firstToken, .generationFinished,
        ]
        var first = ConversationStateMachine()
        var second = ConversationStateMachine()
        for event in events { first.send(event) }
        for event in events { second.send(event) }
        XCTAssertEqual(first.state, second.state)
        XCTAssertEqual(first.trail, second.trail)
    }

    /// 非法事件一律 no-op：不许把状态搅乱（否则 UI 会闪出莫名其妙的状态）。
    func testIllegalEventKeepsStateUnchanged() {
        var machine = ConversationStateMachine()
        XCTAssertEqual(machine.send(.firstToken), .idle)
        XCTAssertEqual(machine.send(.generationFinished), .idle)
        XCTAssertEqual(machine.trail, [.idle], "no-op 不该进轨迹")
    }

    // MARK: - 暂停 / 恢复

    func testPauseThenResumeReturnsToPreviousState() {
        var machine = ConversationStateMachine()
        machine.send(.learnerSpoke) // → processing
        XCTAssertEqual(machine.send(.pause), .paused)
        XCTAssertEqual(machine.send(.resume), .processing, "恢复要回到暂停前的阶段，而不是掉回 idle")
    }

    func testPausedStateSwallowsStreamingEvents() {
        var machine = ConversationStateMachine()
        machine.send(.learnerSpoke)
        machine.send(.pause)
        XCTAssertEqual(machine.send(.firstToken), .paused)
        XCTAssertEqual(machine.send(.generationFinished), .paused)
        XCTAssertEqual(machine.send(.generationFailed), .paused)
    }

    func testPauseFromIdleResumesToIdle() {
        var machine = ConversationStateMachine()
        XCTAssertEqual(machine.send(.pause), .paused)
        XCTAssertEqual(machine.send(.resume), .idle)
    }

    // MARK: - 安全结束

    func testTerminateLandsOnCompletedFromEveryState() {
        for state in ConversationState.allCases where state != .completed {
            var machine = ConversationStateMachine(state: state)
            XCTAssertEqual(machine.send(.terminate), .completed, "\(state.rawValue) 应能安全结束")
        }
    }

    func testTerminateIsIdempotent() {
        var machine = ConversationStateMachine()
        XCTAssertEqual(machine.send(.terminate), .completed)
        XCTAssertEqual(machine.send(.terminate), .completed)
    }

    /// 出错**不是**死掉：学员再开口必须能继续（否则一次失败就永久卡住）。
    ///
    /// 两条复活路径要**各自从 error 出发**来验：前一条断言会把状态推走，
    /// 写在同一条链上等于在验 `processing` 上的转移，而不是在验 error 的复活能力。
    func testErrorStateIsRevivedByNewInput() {
        var fromSpeech = ConversationStateMachine()
        fromSpeech.send(.learnerSpoke) // → processing
        XCTAssertEqual(fromSpeech.send(.generationFailed), .error)
        XCTAssertEqual(fromSpeech.send(.learnerSpoke), .processing, "出错后学员再开口要能继续")

        var fromListening = ConversationStateMachine()
        fromListening.send(.learnerSpoke) // → processing
        XCTAssertEqual(fromListening.send(.generationFailed), .error)
        XCTAssertEqual(fromListening.send(.beginListening), .listening, "出错后可以重新开始收音")
    }

    func testResetReturnsToIdleFromEveryState() {
        for state in ConversationState.allCases {
            var machine = ConversationStateMachine(state: state)
            XCTAssertEqual(machine.send(.reset), .idle)
        }
    }

    // MARK: - 状态语义

    func testStateFlags() {
        XCTAssertTrue(ConversationState.processing.isActive)
        XCTAssertTrue(ConversationState.responding.isActive)
        XCTAssertFalse(ConversationState.idle.isActive)
        XCTAssertFalse(ConversationState.paused.isActive)
        XCTAssertTrue(ConversationState.completed.isSettled)
        XCTAssertTrue(ConversationState.error.isSettled)
        XCTAssertFalse(ConversationState.listening.isSettled)
    }

    func testTrailIsBounded() {
        var machine = ConversationStateMachine()
        for _ in 0..<80 { machine.send(.pause); machine.send(.resume) }
        XCTAssertLessThanOrEqual(machine.trail.count, 32)
    }

    func testStateIsCodable() throws {
        let data = try JSONEncoder().encode(ConversationState.responding)
        XCTAssertEqual(try JSONDecoder().decode(ConversationState.self, from: data), .responding)
    }
}

/// 第 6 步（续）：对话上下文的字段与序列化。
final class ConversationContextTests: XCTestCase {

    private func contextWithTurns(_ texts: [String]) -> ConversationContext {
        var context = ConversationContext()
        for text in texts { context.append(ConversationTurn(speaker: .learner, text: text)) }
        return context
    }

    /// 验收点：Context can be serialized。
    func testContextRoundTripsThroughJSON() throws {
        var context = ConversationContext(
            currentTopic: "weekend plans",
            userProfile: LearnerProfile(displayName: "小鹅子", proficiency: .intermediate),
            learningGoals: ["能用过去时描述上周"],
            knownErrors: ["I go -> I went"],
            targetVocabulary: ["experience", "journey"],
            difficulty: 3
        )
        context.append(ConversationTurn(speaker: .learner, text: "I went to London."))
        context.append(ConversationTurn(speaker: .teacher, text: "Nice! What did you see?"))
        context.scenario = ScenarioFocus(
            id: "airport_checkin",
            title: "Airport check-in",
            correctionMode: .strict,
            targetVocabulary: ["boarding pass"],
            targetGrammar: ["present perfect"],
            turnsRemaining: 4
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConversationContext.self, from: encoder.encode(context))
        XCTAssertEqual(decoded, context)
    }

    func testTurnWindowKeepsNewestTurns() {
        let texts = (1...20).map { "turn \($0)" }
        let context = contextWithTurns(texts)
        XCTAssertEqual(context.recentTurns.count, ConversationContext.turnWindow)
        XCTAssertEqual(context.recentTurns.last?.text, "turn 20")
        XCTAssertEqual(context.recentTurns.first?.text, "turn 9")
    }

    func testDifficultyIsClampedOnEveryEntry() {
        XCTAssertEqual(ConversationContext(difficulty: 99).difficulty, 5)
        XCTAssertEqual(ConversationContext(difficulty: -3).difficulty, 1)
        var context = ConversationContext()
        context.setDifficulty(42)
        XCTAssertEqual(context.difficulty, 5)
    }

    /// 「学员答得太短」需要至少三轮才判定 —— 刚开口的人本来就说得短。
    func testLearnerIsTerseNeedsThreeTurns() {
        XCTAssertFalse(contextWithTurns(["ok", "yes"]).learnerIsTerse())
        XCTAssertTrue(contextWithTurns(["ok", "yes", "fine"]).learnerIsTerse())
        XCTAssertFalse(
            contextWithTurns(["I went to London last week", "It was rainy", "But I liked it"]).learnerIsTerse()
        )
    }

    /// 中英混排的词数：中文按字算，英文按词算（只按空白切会把整句算成 1 个词）。
    func testTurnWordCountHandlesCJK() {
        XCTAssertEqual(ConversationTurn(speaker: .learner, text: "hello world").wordCount, 2)
        XCTAssertEqual(ConversationTurn(speaker: .learner, text: "我想去伦敦").wordCount, 5)
        XCTAssertEqual(ConversationTurn(speaker: .learner, text: "I 想去 London").wordCount, 4)
    }

    func testLearnerTurnsReturnsMostRecentInOrder() {
        var context = ConversationContext()
        context.append(ConversationTurn(speaker: .teacher, text: "What did you do?"))
        context.append(ConversationTurn(speaker: .learner, text: "first"))
        context.append(ConversationTurn(speaker: .learner, text: "second"))
        XCTAssertEqual(context.learnerTurns(limit: 1).map(\.text), ["second"])
        XCTAssertEqual(context.learnerTurns(limit: 2).map(\.text), ["first", "second"])
    }

    func testScenarioFocusWrapUpAndMapping() {
        let scenario = Scenario(
            id: "cafe_order",
            title: "Ordering coffee",
            titleZh: "点咖啡",
            category: "日常",
            difficulty: 2,
            level: "A2",
            objective: "Order a drink",
            aiRole: "barista",
            learnerRole: "customer",
            opening: "Hi! What can I get you?",
            targetVocabulary: ["latte"],
            targetGrammar: ["polite requests"],
            maxTurns: 6,
            correctionMode: .gentle
        )
        let focus = ScenarioFocus(scenario: scenario, turnsRemaining: 1)
        XCTAssertEqual(focus.id, "cafe_order")
        XCTAssertEqual(focus.correctionMode, .gentle)
        XCTAssertTrue(focus.isWrapUp)
        XCTAssertFalse(ScenarioFocus(scenario: scenario, turnsRemaining: 3).isWrapUp)
    }

    /// 纠错强度的档位运算（升/降/映射）都必须幂等收敛，不能越界。
    func testCorrectionIntensitySteps() {
        XCTAssertEqual(CorrectionIntensity.gentle.intensified, .balanced)
        XCTAssertEqual(CorrectionIntensity.strict.intensified, .strict)
        XCTAssertEqual(CorrectionIntensity.gentle.relaxed, .gentle)
        XCTAssertEqual(CorrectionIntensity.strict.relaxed, .balanced)
        XCTAssertEqual(CorrectionIntensity(ScenarioCorrectionMode.strict), .strict)
        XCTAssertEqual(CorrectionIntensity(ScenarioCorrectionMode.gentle), .gentle)
    }
}
