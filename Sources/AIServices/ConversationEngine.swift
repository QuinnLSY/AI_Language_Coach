import AIDomain
import Foundation
import Observation

/// 一轮对话的教学计划：决策 → 对话方向 → 响应计划。
///
/// **全部由纯函数算出，不含任何模型请求**（没有计费、没有 fan-out）。
/// 它是「业务逻辑」的落点；`PromptBuilder` 只是把它渲染成提示词的一段。
///
/// 注意它**不含本轮语法分析**：老师的回复还没生成，此刻无从知道学员错在哪。
/// 生成后的分析由 `ConversationEngine.analyzeReply` 单独产出。
public struct TurnPlan: Sendable, Equatable {
    public var decision: TeacherDecision
    public var direction: ConversationDirection
    public var plan: ResponsePlan

    public init(
        decision: TeacherDecision,
        direction: ConversationDirection,
        plan: ResponsePlan
    ) {
        self.decision = decision
        self.direction = direction
        self.plan = plan
    }

    /// 本轮有没有要告诉老师的东西。
    public var hasAnythingToTeach: Bool {
        plan.isWorthInstructing || !decision.learningFocus.isEmpty
    }
}

/// 对话引擎：状态机 + 上下文的持有者，以及各 Agent 的编排点。
///
/// 它**不认识 Provider、不发请求、不管持久化**——那些是 `CoachServices` 与 `ChatService` 的事。
/// 这样拆分之后，「对话进行到哪一步」「这一轮该怎么教」都能在没有网络、没有数据库的
/// 单测里被直接断言。
@MainActor
@Observable
public final class ConversationEngine {

    /// 当前阶段（UI 可直接观察）。
    public private(set) var state: ConversationState
    /// 决策所需的静态事实。
    public private(set) var context: ConversationContext

    private var machine: ConversationStateMachine

    public init(context: ConversationContext = .initial, state: ConversationState = .idle) {
        self.context = context
        self.machine = ConversationStateMachine(state: state)
        self.state = state
    }

    // MARK: - 状态

    /// 送回一个事件，返回转移后的状态（非法事件保持原样）。
    @discardableResult
    public func send(_ event: ConversationEvent) -> ConversationState {
        let next = machine.send(event)
        state = next
        return next
    }

    /// 开新一轮：状态复位，但**上下文保留**（学员画像 / 记忆 / 难度都该跟着人走）。
    public func reset() {
        _ = send(.reset)
    }

    /// 转移轨迹（调试用）。
    public var trail: [ConversationState] { machine.trail }

    // MARK: - 上下文

    public func updateContext(_ transform: (inout ConversationContext) -> Void) {
        transform(&context)
    }

    /// 同步学员画像。
    public func syncProfile(_ profile: LearnerProfile) {
        context.userProfile = profile
    }

    /// 同步进行中的情景（nil = 退出情景）。
    public func syncScenario(_ focus: ScenarioFocus?) {
        context.scenario = focus
        // 进情景时难度跟场景走（场景自带难度），退出时保留最后的难度，不做「跳回 2」的突降。
        if let focus { context.setDifficulty(scenarioDifficulty(focus)) }
    }

    /// 把跨会话记忆折进上下文：已知错误、待复习词、发音弱项。
    ///
    /// 已知错误是**合并**而不是覆盖：本轮刚发现的错（`analyzeReply` 写的）与库里算出来的
    /// 是同一类事实，覆盖会把「刚纠正过的」冲掉，而那一处恰恰是最该被继续盯住的。
    public func syncMemory(_ memory: LearningMemory) {
        var errors = memory.recurringErrors.prefix(5).map { "\($0.original) -> \($0.corrected)" }
        for existing in context.knownErrors where !errors.contains(existing) {
            errors.append(existing)
        }
        context.knownErrors = Array(errors.prefix(8))

        var vocabulary = memory.focusWords
        if let scenarioWords = context.scenario?.targetVocabulary {
            for word in scenarioWords where !vocabulary.contains(word) { vocabulary.append(word) }
        }
        context.targetVocabulary = Array(vocabulary.prefix(8))
    }

    /// 记一轮学员发言。
    public func recordLearner(_ text: String, at date: Date = Date()) {
        context.append(ConversationTurn(speaker: .learner, text: text, at: date))
    }

    /// 记一轮老师回复。
    public func recordTeacher(_ text: String, at date: Date = Date()) {
        context.append(ConversationTurn(speaker: .teacher, text: text, at: date))
    }

    /// 把已恢复的历史消息灌进上下文（重启后继续上次的会话）。
    public func replaceTurns(_ messages: [ChatMessage]) {
        context.recentTurns = messages.suffix(ConversationContext.turnWindow).map { message in
            ConversationTurn(
                id: message.id,
                speaker: message.role == .user ? .learner : .teacher,
                text: message.content,
                at: message.createdAt
            )
        }
    }

    // MARK: - 决策编排（纯函数，零请求）

    /// 算出本轮的教学计划（生成**前**）。
    ///
    /// - Parameters:
    ///   - learnerText: 学员本轮原话。
    ///   - memory: 跨会话记忆（反复错误 / 待复习词 / 发音弱项）。
    ///   - profile: 学员画像。
    public func planTurn(
        learnerText: String,
        memory: LearningMemory,
        profile: LearnerProfile
    ) -> TurnPlan {
        syncProfile(profile)
        syncMemory(memory)

        // ① 教学决策。生成前 `grammar` 未知，传 nil —— 不猜学员说对说错。
        let decision = TeacherAgent.decide(
            TeacherAgent.Input(
                profile: profile,
                context: context,
                learnerText: learnerText,
                grammar: nil,
                memory: memory
            )
        )

        // ② 对话方向。
        let direction = ConversationAgent.direct(context: context, decision: decision)

        // ③ 响应计划。
        let plan = ResponsePlanner.plan(
            decision: decision,
            grammar: .clean,
            direction: direction,
            context: context
        )

        // ④ 难度回写：下一轮的基线就是这一轮的结论（渐进调难 / 出错退档才生效）。
        context.setDifficulty(decision.difficulty)

        return TurnPlan(decision: decision, direction: direction, plan: plan)
    }

    /// 生成**后**：把老师标注的纠错结构化成 `GrammarAnalysis`（分类 / 定级 / 判重）。
    ///
    /// 结果用于落库、更新「已知错误」与 UI 展示，并成为**下一轮**决策的依据 ——
    /// 这正是「反复错误 → 集中练」得以生效的路径，且**不额外发任何请求**。
    ///
    /// - Parameter history: 历史纠错记录（时间新 → 旧），用于判重。
    public func analyzeReply(
        _ corrections: [GrammarCorrection],
        history: [CorrectionRecord] = []
    ) -> GrammarAnalysis {
        let analysis = GrammarAgent.analyze(corrections: corrections, history: history)
        guard analysis.hasError else { return analysis }
        // 去重口径与「反复错误」统计一致：同一处错误换了大小写 / 空格仍算同一处，
        // 否则已知错误列表里会堆出一串看起来不同的同一句话。
        var seen = Set(context.knownErrors.map { Self.normalizeLine($0) })
        for error in analysis.errors.prefix(5) {
            let line = "\(error.original) -> \(error.corrected)"
            guard seen.insert(Self.normalizeLine(line)).inserted else { continue }
            context.knownErrors.append(line)
        }
        if context.knownErrors.count > 8 {
            context.knownErrors.removeFirst(context.knownErrors.count - 8)
        }
        return analysis
    }

    /// 「原句 -> 改正」这类可读行的归一键（与 `GrammarAgent.pattern` 同口径，忽略标点）。
    private static func normalizeLine(_ line: String) -> String {
        MemoryRetriever.matchKey(line)
    }

    /// 由情景的难度（1...5）作为基线。
    private func scenarioDifficulty(_ focus: ScenarioFocus) -> Int {
        // ScenarioFocus 不带难度（决策视图刻意轻量）；用目标语法 / 词量做一个稳定近似：
        // 目标越多，练习强度越高。这是纯函数、结果稳定，不会随 UI 状态漂移。
        let signals = focus.targetGrammar.count + focus.targetVocabulary.count / 3
        return ConversationContext.clampDifficulty(2 + min(signals, 2))
    }
}
