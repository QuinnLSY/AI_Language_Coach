import Foundation

// MARK: - 教学决策（Implementation Plan §11 Phase 7 — Teacher Agent）
//
// 计划验收点：「Teacher decisions are represented as structured data and are not
// directly coupled to UI.」所以这里只有数据 + 一个纯函数策略，没有任何 UI / 网络。
//
// ⚠️ **本层绝不自己调模型**。项目有一条费用护栏：一次操作 = 一个模型 = 一次请求。
// 如果 Teacher / Grammar / Conversation 三个 Agent 各自发一次 LLM 请求，一次对话就变成
// 四次计费、四份延迟。正确的做法（也正是计划 Phase 10 的意图）是把教学判断**从
// prompt 里抽出来**成为结构化决策，再渲染回**那唯一一次**请求的提示词里。

/// 本轮老师该怎么回。
public struct TeacherDecision: Codable, Sendable, Equatable {

    /// 回复形态。
    public enum ResponseMode: String, Codable, Sendable, Equatable, CaseIterable {
        /// 正常推进对话。
        case conversation
        /// 以纠正为主（先把这一处讲清楚）。
        case correction
        /// 反复练同一处（学员反复犯同一个错）。
        case drill
        /// 先鼓励、把话头递回去（学员答得太短 / 太拘谨）。
        case encouragement
        /// 收尾（情景到点 / 学员想结束）。
        case wrapUp

        public var displayName: String {
            switch self {
            case .conversation: "对话推进"
            case .correction: "重点纠错"
            case .drill: "反复练习"
            case .encouragement: "鼓励多说"
            case .wrapUp: "收尾"
            }
        }

        /// 注入 Prompt 的英文指令片段。
        public var instruction: String {
            switch self {
            case .conversation: "Keep the conversation moving naturally."
            case .correction: "Spend a moment on the mistake below, then move on."
            case .drill: "The learner keeps repeating this mistake — work it once more into a new sentence."
            case .encouragement: "The learner has been answering briefly — make it easy and inviting to say more."
            case .wrapUp: "Wrap the scene up warmly and let the learner finish."
            }
        }
    }

    public var responseMode: ResponseMode
    public var correctionLevel: CorrectionIntensity
    /// 本轮难度（1...5）。
    public var difficulty: Int
    /// 学习重点（稳定标识，如 `past_tense`、`pronunciation.intonation`）。
    public var learningFocus: [String]
    public var shouldCorrect: Bool

    public init(
        responseMode: ResponseMode = .conversation,
        correctionLevel: CorrectionIntensity = .balanced,
        difficulty: Int = 2,
        learningFocus: [String] = [],
        shouldCorrect: Bool = false
    ) {
        self.responseMode = responseMode
        self.correctionLevel = correctionLevel
        self.difficulty = ConversationContext.clampDifficulty(difficulty)
        self.learningFocus = learningFocus
        self.shouldCorrect = shouldCorrect
    }

    /// JSON 键名用 snake_case：对齐计划文档给出的契约
    /// （`response_mode` / `correction_level` / `learning_focus` / `should_correct`），
    /// 将来直接把它作为结构化输出契约时不用改协议。
    private enum CodingKeys: String, CodingKey {
        case responseMode = "response_mode"
        case correctionLevel = "correction_level"
        case difficulty
        case learningFocus = "learning_focus"
        case shouldCorrect = "should_correct"
    }
}

// MARK: - Teacher Agent（纯函数策略）

/// 教学控制：由「学员画像 + 上下文 + 本轮原文 + 语法分析 + 学习记忆」推出本轮决策。
///
/// 规则全部是**确定性**的，且刻意保持可解释：每一条都能说清「为什么这样调」。
/// 不做情绪猜测（纯文本判不出「学员受挫」，硬猜会让老师做出莫名其妙的反应）。
public enum TeacherAgent {

    /// 反复错误累计多少次才升级为「反复练」。
    public static let drillThreshold = 2

    public struct Input: Sendable {
        public var profile: LearnerProfile
        public var context: ConversationContext
        /// 学员本轮说的原话。
        public var learnerText: String
        /// 本轮语法分析。**nil = 生成前尚不可知**（老师的回复还没出来，还没有 `[[FIX]]` 可解析）。
        ///
        /// 应用不做本地语法检查，所以「学员这句话错在哪」只有 LLM 能回答。
        /// 生成前就**不去猜**学员说对说错，只按历史与表现定教学意图；
        /// 生成后拿到分析可以再调一次，得到更精确的决策。
        public var grammar: GrammarAnalysis?
        public var memory: LearningMemory

        public init(
            profile: LearnerProfile,
            context: ConversationContext,
            learnerText: String,
            grammar: GrammarAnalysis? = nil,
            memory: LearningMemory
        ) {
            self.profile = profile
            self.context = context
            self.learnerText = learnerText
            self.grammar = grammar
            self.memory = memory
        }
    }

    public static func decide(_ input: Input) -> TeacherDecision {
        let context = input.context
        let scenario = context.scenario

        // ① 基线：情景有场景自带的纠错强度就听场景的；否则听用户偏好。
        var correctionLevel = scenario.map { CorrectionIntensity($0.correctionMode) }
            ?? context.teacherPreference.correctionStyle

        // ② 水平校准：**只在非情景时**生效。情景里以场景为准 ——
        //    场景的 strict/gentle 是设计者对这个练习的意图，不该被学员水平悄悄改掉。
        if scenario == nil {
            switch input.profile.proficiency {
            case .beginner: correctionLevel = correctionLevel.relaxed
            case .intermediate: break
            case .advanced: correctionLevel = correctionLevel.intensified
            }
        }

        // ③ 跨会话反复错误：确实反复犯的，才把强度提上去、并把它列进学习重点。
        var focus: [String] = []
        var hasRecurring = false
        for error in input.memory.recurringErrors where error.count >= drillThreshold {
            hasRecurring = true
            let token = GrammarAgent.classify(original: error.original, corrected: error.corrected).rawValue
            if !focus.contains(token) { focus.append(token) }
        }
        if hasRecurring { correctionLevel = correctionLevel.intensified }

        // ④ 本轮**要不要纠**。
        //
        //    生成前能定的是「允不允许纠、纠到什么程度、最多讲几处」；
        //    具体挑哪一处交给提示词里的强度指令（`correctionLevel.instruction`）。
        var shouldCorrect = true
        if scenario?.isWrapUp == true {
            // 收尾时再插一句纠错，会把好不容易攒起来的收束感打散。
            shouldCorrect = false
        } else if input.grammar?.hasError == true {
            // 已拿到本轮分析（生成后复盘 / 测试）：有错就必须纠。
            shouldCorrect = true
        } else if context.learnerIsTerse() {
            // 学员就蹦了一个词 —— 没有可纠的东西，先请他多说。
            shouldCorrect = false
        }

        // ⑤ 本轮已分析出的错误 → 进学习重点。
        if let primary = input.grammar?.primary, !focus.contains(primary.category.rawValue) {
            focus.append(primary.category.rawValue)
        }

        // ⑥ 发音弱项（来自多次跟读的平均分）→ 也进学习重点。
        for weak in input.memory.weakDimensions where weak.sampleCount >= 2 {
            let token = "pronunciation." + weak.dimension.rawValue
            if !focus.contains(token) { focus.append(token) }
        }

        // ⑦ 难度微调。**只在拿到了本轮分析时才动** ——
        //    生成前没有「说对还是说错」的信息，凭它加难度会一路顶到 5（曾经踩过这个坑）。
        var difficulty = context.difficulty
        if let grammar = input.grammar {
            if grammar.hasError {
                if grammar.primary?.severity == .major { difficulty = max(difficulty - 1, 1) }
            } else if !hasRecurring {
                // 本轮全对、也没有历史顽固错 → 上一档。
                difficulty = min(difficulty + 1, 5)
            }
        }

        // ⑧ 形态：收尾 > 反复练 > 纠错 > 鼓励 > 常规。
        let mode: TeacherDecision.ResponseMode
        if scenario?.isWrapUp == true {
            mode = .wrapUp
        } else if hasRecurring {
            mode = .drill
        } else if input.grammar?.hasError == true {
            mode = .correction
        } else if context.learnerIsTerse() {
            mode = .encouragement
        } else {
            mode = .conversation
        }

        return TeacherDecision(
            responseMode: mode,
            correctionLevel: correctionLevel,
            difficulty: difficulty,
            learningFocus: focus,
            shouldCorrect: shouldCorrect
        )
    }
}
