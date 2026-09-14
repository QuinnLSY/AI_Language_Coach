import Foundation

// MARK: - 对话方向 + 响应计划（Implementation Plan §13 Phase 9 / §14 Phase 10）
//
// Phase 9 的要点：Conversation Agent **不直接产出最终话术**，而是给出「往哪个方向聊」；
// 真正把方向 + 教学决策收敛成一份可执行的计划，是 Phase 10 的 Response Planner。
//
// Phase 10 的原话是：「This prevents the LLM prompt from becoming the single location
// of business logic.」—— 这正是本文件存在的理由：教学逻辑在这里（可单测、可断言），
// prompt 只是它的一个渲染目标。

/// 对话该往哪走（Conversation Agent 的输出）。
public struct ConversationDirection: Codable, Sendable, Equatable {

    public enum Move: String, Codable, Sendable, Equatable, CaseIterable {
        /// 延续当前话题。
        case continueTopic = "continue_topic"
        /// 换个话题（学员答得太短 / 话题聊干了）。
        case shiftTopic = "shift_topic"
        /// 拉回情景主线（别让角色扮演跑题）。
        case returnToScenario = "return_to_scenario"
        /// 收尾。
        case closeOut = "close_out"

        public var displayName: String {
            switch self {
            case .continueTopic: "延续话题"
            case .shiftTopic: "换个话题"
            case .returnToScenario: "回到情景"
            case .closeOut: "收尾结束"
            }
        }

        /// 注入 Prompt 的英文指令片段。
        public var instruction: String {
            switch self {
            case .continueTopic: "Stay on the current topic."
            case .shiftTopic: "Offer a fresh angle or a concrete new topic."
            case .returnToScenario: "Stay in character and keep the scene on track."
            case .closeOut: "Close the scene out warmly."
            }
        }
    }

    public var move: Move
    /// 本轮话题（学习语言表述；nil = 不指定，交给模型自己接）。
    public var topic: String?
    /// 是否要在回复末尾抛回一个问题（保持对话继续）。
    public var asksFollowUp: Bool
    /// 给老师的参与度提示（如「学员这几轮都只答一个词」）。
    public var engagementCue: String?

    public init(
        move: Move,
        topic: String? = nil,
        asksFollowUp: Bool = true,
        engagementCue: String? = nil
    ) {
        self.move = move
        self.topic = topic
        self.asksFollowUp = asksFollowUp
        self.engagementCue = engagementCue
    }
}

public enum ConversationAgent {

    /// 学员连续答得过短时给老师的提示（学习语言，直接进 prompt 语境）。
    public static let tersenessCue = "The learner has been answering very briefly; offer a concrete angle and invite a longer answer."

    public static func direct(
        context: ConversationContext,
        decision: TeacherDecision
    ) -> ConversationDirection {
        // 情景优先：在角色扮演里跑题，比「对话不流畅」更伤体验。
        if let scenario = context.scenario {
            if scenario.isWrapUp || decision.responseMode == .wrapUp {
                return ConversationDirection(move: .closeOut, topic: scenario.title, asksFollowUp: false)
            }
            return ConversationDirection(move: .returnToScenario, topic: scenario.title, asksFollowUp: true)
        }

        // 学员只蹦单词 → 明确换个角度，并请老师把话头铺开一点。
        if context.learnerIsTerse() {
            return ConversationDirection(
                move: .shiftTopic,
                topic: context.currentTopic,
                asksFollowUp: true,
                engagementCue: tersenessCue
            )
        }

        // 还没有话题（刚开场）→ 用学习目标或待复习词起个话头。
        if context.currentTopic == nil {
            let seed = context.learningGoals.first ?? context.targetVocabulary.first
            return ConversationDirection(move: .continueTopic, topic: seed, asksFollowUp: true)
        }

        return ConversationDirection(move: .continueTopic, topic: context.currentTopic, asksFollowUp: true)
    }
}

// MARK: - Response Plan（Phase 10）

/// 一份可执行的回复计划：**做什么**（接话 / 纠正 / 解释 / 追问 / 带出目标词）。
///
/// 字段名对齐计划文档的 JSON 契约（`next_question` / `target_vocabulary`…）。
public struct ResponsePlan: Codable, Sendable, Equatable {

    public enum Intent: String, Codable, Sendable, Equatable, CaseIterable {
        case conversation
        case correctAndContinue = "correct_and_continue"
        case drillFocus = "drill_focus"
        case encourage
        case wrapUp = "wrap_up"

        public var displayName: String {
            switch self {
            case .conversation: "顺势接话"
            case .correctAndContinue: "纠正后继续"
            case .drillFocus: "集中练一处"
            case .encourage: "鼓励多说"
            case .wrapUp: "收尾"
            }
        }
    }

    /// 纠错指令。
    public struct Correction: Codable, Sendable, Equatable {
        public enum Style: String, Codable, Sendable, Equatable, CaseIterable {
            /// 一句话点出来。
            case brief
            /// 说清为什么。
            case detailed
        }

        public var show: Bool
        public var style: Style
        /// 最多讲几处（一次讲太多，学员一处也记不住）。
        public var maxItems: Int

        public init(show: Bool = false, style: Style = .brief, maxItems: Int = 1) {
            self.show = show
            self.style = style
            self.maxItems = max(maxItems, 0)
        }
    }

    /// 解释指令。
    public struct Explanation: Codable, Sendable, Equatable {
        public enum Length: String, Codable, Sendable, Equatable, CaseIterable {
            case none
            case short
            case full
        }

        public var show: Bool
        public var length: Length

        public init(show: Bool = false, length: Length = .none) {
            self.show = show
            self.length = length
        }
    }

    public var intent: Intent
    /// 先接住学员这句话（好教学的默认：先回应人，再纠正话）。
    public var acknowledgement: Bool
    public var correction: Correction
    public var explanation: Explanation
    public var nextQuestion: Bool
    public var targetVocabulary: [String]
    /// 本轮要讲的那一处（`correction.show == false` 时为 nil）。
    public var focusError: GrammarError?

    public init(
        intent: Intent = .conversation,
        acknowledgement: Bool = true,
        correction: Correction = Correction(),
        explanation: Explanation = Explanation(),
        nextQuestion: Bool = true,
        targetVocabulary: [String] = [],
        focusError: GrammarError? = nil
    ) {
        self.intent = intent
        self.acknowledgement = acknowledgement
        self.correction = correction
        self.explanation = explanation
        self.nextQuestion = nextQuestion
        self.targetVocabulary = targetVocabulary
        self.focusError = focusError
    }

    private enum CodingKeys: String, CodingKey {
        case intent, acknowledgement, correction, explanation
        case nextQuestion = "next_question"
        case targetVocabulary = "target_vocabulary"
        case focusError = "focus_error"
    }

    /// 这份计划值不值得告诉老师。
    ///
    /// 「什么都不用做」的轮次不该注入指令：否则每轮都塞一段「不要纠正」的废话，
    /// 既白占上下文，也可能让模型误以为**必须**找出个错来才叫完成任务。
    public var isWorthInstructing: Bool {
        correction.show || !targetVocabulary.isEmpty || !nextQuestion || intent != .conversation
    }
}

/// 把「教学决策 + 语法分析 + 对话方向」收敛成一份可执行计划。
public enum ResponsePlanner {

    /// 一次最多带出几个目标词（多了老师会硬塞，反而失真）。
    public static let vocabularyLimit = 3

    public static func plan(
        decision: TeacherDecision,
        grammar: GrammarAnalysis,
        direction: ConversationDirection,
        context: ConversationContext
    ) -> ResponsePlan {
        let intent = Self.intent(decision: decision)

        // 纠错：决策说「该纠」就展示。
        // ⚠️ 这里**不能**要求 `grammar.hasError`：生成前的决策只有「允不允许纠」，
        //    本轮具体错在哪要等老师回复（`[[FIX]]` 解析）才知道。要求 hasError 会让
        //    纠错指令永远发不出去 —— 老师永远不会纠错。
        let showsCorrection = decision.shouldCorrect
        let primary = showsCorrection ? grammar.primary : nil

        let correction = ResponsePlan.Correction(
            show: showsCorrection,
            // 严格档才展开讲；温和 / 适中都用一句话点出来。
            style: decision.correctionLevel == .strict ? .detailed : .brief,
            maxItems: Self.maxItems(for: decision.correctionLevel)
        )

        let explanation = ResponsePlan.Explanation(
            // 温和档不解释（只示范正确说法）；适中一句；严格说清。
            show: showsCorrection && decision.correctionLevel != .gentle,
            length: showsCorrection ? Self.explanationLength(for: decision.correctionLevel) : .none
        )

        return ResponsePlan(
            intent: intent,
            acknowledgement: true,
            correction: correction,
            explanation: explanation,
            // 收尾轮不再追问，否则情景永远结束不了。
            nextQuestion: direction.asksFollowUp && intent != .wrapUp,
            targetVocabulary: Self.vocabulary(context: context, focusError: primary),
            focusError: primary
        )
    }

    static func intent(decision: TeacherDecision) -> ResponsePlan.Intent {
        switch decision.responseMode {
        case .conversation: .conversation
        case .correction: .correctAndContinue
        case .drill: .drillFocus
        case .encouragement: .encourage
        case .wrapUp: .wrapUp
        }
    }

    static func maxItems(for level: CorrectionIntensity) -> Int {
        switch level {
        case .gentle: 1
        case .balanced: 2
        case .strict: 3
        }
    }

    static func explanationLength(for level: CorrectionIntensity) -> ResponsePlan.Explanation.Length {
        switch level {
        case .gentle: .none
        case .balanced: .short
        case .strict: .full
        }
    }

    /// 目标词：优先用场景 / 记忆给的待复习词；没有的话，就把本轮纠正里
    /// **新增出来的那个词**带出去 —— 让老师顺手用一遍刚教的词，比空着更有教学价值。
    static func vocabulary(context: ConversationContext, focusError: GrammarError?) -> [String] {
        var result: [String] = []
        for word in context.targetVocabulary where !result.contains(word) {
            result.append(word)
            if result.count >= vocabularyLimit { return result }
        }
        guard let focusError else { return result }
        let originalWords = Set(GrammarAgent.words(focusError.original).map { $0.lowercased() })
        for word in GrammarAgent.words(focusError.corrected)
        where !originalWords.contains(word.lowercased())
            && !result.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            result.append(word)
            if result.count >= vocabularyLimit { break }
        }
        return result
    }
}
