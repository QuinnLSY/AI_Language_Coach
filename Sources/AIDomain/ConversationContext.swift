import Foundation

// MARK: - 对话上下文（Implementation Plan §10 Phase 6）
//
// 计划要求上下文可序列化，并给出字段清单。这里逐项对上：
// recentTurns / currentTopic / scenario / userProfile / learningGoals /
// knownErrors / targetVocabulary / teacherPreference / difficulty。
//
// 它刻意**不持有** Provider、不持有 Conversation，只装「这一轮决策需要知道的静态事实」，
// 这样 TeacherAgent / ConversationAgent 才能是纯函数，也才能在测试里直接构造。

/// 纠错强度（gentle / balanced / strict）。
///
/// 与 `ScenarioCorrectionMode` 是同一套语义：场景自带纠错强度（来自 JSON 数据），
/// 老师决策层也要表达纠错强度。这里不合并两者——场景数据属于数据层、
/// 决策强度属于策略层，混用会让「改场景 JSON 就改了教学策略」这种耦合悄悄成立。
public enum CorrectionIntensity: String, Codable, Sendable, Equatable, CaseIterable {
    case gentle
    case balanced
    case strict

    public var displayName: String {
        switch self {
        case .gentle: "温和"
        case .balanced: "适中"
        case .strict: "严格"
        }
    }

    /// 升一档（已到严格则保持）。
    public var intensified: CorrectionIntensity {
        switch self {
        case .gentle: .balanced
        case .balanced: .strict
        case .strict: .strict
        }
    }

    /// 降一档（已到温和则保持）。
    public var relaxed: CorrectionIntensity {
        switch self {
        case .gentle: .gentle
        case .balanced: .gentle
        case .strict: .balanced
        }
    }

    /// 由场景的纠错强度映射过来（唯一一处映射，避免两边各写一套）。
    public init(_ mode: ScenarioCorrectionMode) {
        switch mode {
        case .gentle: self = .gentle
        case .balanced: self = .balanced
        case .strict: self = .strict
        }
    }

    /// 注入 Prompt 的英文指令片段（与 `ScenarioCorrectionMode.instruction` 同风格：
    /// 短指令表放代码里、长 Prompt 放 `Resources/Prompts/`）。
    public var instruction: String {
        switch self {
        case .gentle: "Only fix mistakes that block understanding; let small slips pass."
        case .balanced: "Fix clear mistakes briefly, without breaking the flow."
        case .strict: "Fix every noticeable mistake, including small ones."
        }
    }
}

/// 一轮对话（学员或老师）。比 `ChatMessage` 轻，只保留决策需要的信息。
public struct ConversationTurn: Codable, Sendable, Equatable, Identifiable {
    public enum Speaker: String, Codable, Sendable, Equatable {
        case learner
        case teacher
    }

    public let id: UUID
    public var speaker: Speaker
    public var text: String
    public var at: Date

    public init(id: UUID = UUID(), speaker: Speaker, text: String, at: Date = Date()) {
        self.id = id
        self.speaker = speaker
        self.text = text
        // 时间戳统一截到整秒。ISO8601 不携带毫秒，不截断的话「编码 → 解码」得到的
        // 上下文与原对象并不相等（round-trip 断言会红，读起来像数据被改过）。
        // 轮次时间只需秒级精度，统一在入口截断比在每个序列化点打补丁可靠。
        self.at = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.down))
    }

    /// 词数：中英混排都能用。
    ///
    /// 规则刻意分成两半再相加，避免重复计数：
    /// - 含非中日韩字符的 token 记 1 个词（英文按空白 / 标点切）；
    /// - 纯 CJK 的 token 按**字数**算（中文没有空白，按词切不出来）。
    ///
    /// 用途是「学员这句话是不是太短了」这类判断，所以 `"我想去伦敦"` 该是 5 而不是 1，
    /// `"I 想去 London"` 该是 4 而不是 3 或 5 —— 两种写法都要能用。
    public var wordCount: Int {
        let latin = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .filter { token in
                token.unicodeScalars.contains { !(0x4E00...0x9FFF).contains($0.value) }
            }
            .count
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return latin + cjk
    }
}

/// 进行中情景的**决策视图**（只带教学决策用得上的字段，不塞整个 `Scenario`）。
public struct ScenarioFocus: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var correctionMode: ScenarioCorrectionMode
    public var targetVocabulary: [String]
    public var targetGrammar: [String]
    /// 剩余轮次（0 = 该收尾了）。
    public var turnsRemaining: Int

    public init(
        id: String,
        title: String,
        correctionMode: ScenarioCorrectionMode = .balanced,
        targetVocabulary: [String] = [],
        targetGrammar: [String] = [],
        turnsRemaining: Int = 0
    ) {
        self.id = id
        self.title = title
        self.correctionMode = correctionMode
        self.targetVocabulary = targetVocabulary
        self.targetGrammar = targetGrammar
        self.turnsRemaining = max(turnsRemaining, 0)
    }

    /// 该收尾了（最后一轮）。
    public var isWrapUp: Bool { turnsRemaining <= 1 }

    /// 从情景本体 + 进度构造（唯一一处映射）。
    public init(scenario: Scenario, turnsRemaining: Int) {
        self.init(
            id: scenario.id,
            title: scenario.title,
            correctionMode: scenario.correctionMode,
            targetVocabulary: scenario.targetVocabulary,
            targetGrammar: scenario.targetGrammar,
            turnsRemaining: turnsRemaining
        )
    }
}

/// 老师偏好（由产品配置里的 `TeacherPersona` 推导）。
///
/// ⚠️ **只存档位，不存参数**：回复长度 / 纠错强度 / 是否允许母语提示都是计算属性。
/// 早先这三个字段各自存储，而它们之间没有任何约束 —— 出现「档位写着温和、
/// 强度却存着严格」这种组合时，没有任何地方能判它错，只能靠人眼发现。
public struct TeacherPreference: Codable, Sendable, Equatable {
    /// 回复长度倾向。
    public enum ResponseLength: String, Codable, Sendable, Equatable, CaseIterable {
        case brief
        case normal
        case detailed

        public var displayName: String {
            switch self {
            case .brief: "简短"
            case .normal: "适中"
            case .detailed: "详细"
            }
        }
    }

    /// 教学风格档位。
    public var persona: TeacherPersona

    public init(persona: TeacherPersona = .standard) {
        self.persona = persona
    }

    public var responseLength: ResponseLength { persona.responseLength }
    public var correctionStyle: CorrectionIntensity { persona.correctionStyle }
    /// 学员卡住时是否允许用母语解释。
    public var allowsNativeLanguageHints: Bool { persona.allowsNativeLanguageHints }

    public static let standard = TeacherPreference()
}

/// 一轮对话决策所需的全部静态事实。
public struct ConversationContext: Codable, Sendable, Equatable {

    /// 最近若干轮（**时间正序**：旧 → 新）。只保留窗口内的，避免上下文无限增长。
    public var recentTurns: [ConversationTurn]
    /// 当前话题（学习语言表述；nil = 还没形成话题）。
    public var currentTopic: String?
    /// 进行中的情景（nil = 普通练习）。
    public var scenario: ScenarioFocus?
    /// 学员画像。
    public var userProfile: LearnerProfile
    /// 学习目标（母语表述，如「能用过去时描述上周做了什么」）。
    public var learningGoals: [String]
    /// 已知错误（「原句 → 改正」的可读摘要，来自跨会话记忆）。
    public var knownErrors: [String]
    /// 本轮希望学员用到的词（场景目标词 / 待复习词）。
    public var targetVocabulary: [String]
    /// 老师偏好。
    public var teacherPreference: TeacherPreference
    /// 当前难度（1...5）。
    public var difficulty: Int

    /// turns 窗口上限：决策只看最近这些轮，超出的丢弃（保证上下文有界、可序列化也不膨胀）。
    public static let turnWindow = 12

    public init(
        recentTurns: [ConversationTurn] = [],
        currentTopic: String? = nil,
        scenario: ScenarioFocus? = nil,
        userProfile: LearnerProfile = LearnerProfile(),
        learningGoals: [String] = [],
        knownErrors: [String] = [],
        targetVocabulary: [String] = [],
        teacherPreference: TeacherPreference = .standard,
        difficulty: Int = 2
    ) {
        self.recentTurns = recentTurns
        self.currentTopic = currentTopic
        self.scenario = scenario
        self.userProfile = userProfile
        self.learningGoals = learningGoals
        self.knownErrors = knownErrors
        self.targetVocabulary = targetVocabulary
        self.teacherPreference = teacherPreference
        self.difficulty = Self.clampDifficulty(difficulty)
    }

    /// 新学员 / 新会话的初始上下文。
    public static let initial = ConversationContext()

    /// 难度合法区间 1...5（越界一律夹回，不信任外部赋值）。
    public static func clampDifficulty(_ value: Int) -> Int { min(max(value, 1), 5) }

    /// 学员最近的若干轮（时间正序）。
    public func learnerTurns(limit: Int = 3) -> [ConversationTurn] {
        Array(recentTurns.filter { $0.speaker == .learner }.suffix(limit))
    }

    /// 学员最近三轮是不是都很短（用于「别总答一个词」的引导）。
    ///
    /// 少于三轮不判定 —— 刚开口的学员本来就说得短。
    public func learnerIsTerse(threshold: Int = 4, window: Int = 3) -> Bool {
        let turns = learnerTurns(limit: window)
        guard turns.count >= window else { return false }
        return turns.allSatisfy { $0.wordCount <= threshold }
    }

    /// 追加一轮并裁剪窗口（时间正序，保留最新）。
    public mutating func append(_ turn: ConversationTurn) {
        recentTurns.append(turn)
        if recentTurns.count > Self.turnWindow {
            recentTurns.removeFirst(recentTurns.count - Self.turnWindow)
        }
    }

    public mutating func setDifficulty(_ value: Int) { difficulty = Self.clampDifficulty(value) }
}
