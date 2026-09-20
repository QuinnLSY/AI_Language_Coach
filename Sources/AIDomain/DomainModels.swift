import AppCore
import Foundation

// MARK: - 对话

public enum ChatRole: String, Codable, Sendable, CaseIterable {
    case system
    case user
    case assistant
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var role: ChatRole
    public var content: String
    public var createdAt: Date
    /// 推理模型的思考过程（展示用，可折叠；旧消息/旧库无此字段）。
    public var reasoning: String?
    /// 随这条消息发出的附件（图片 / 视频 / 文件）。旧消息 / 旧库无此字段 = 空数组。
    public var attachments: [ChatAttachment]

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        createdAt: Date = Date(),
        reasoning: String? = nil,
        attachments: [ChatAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.reasoning = reasoning
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, createdAt, reasoning, attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ChatRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
    }

    /// 有没有附件（空文本 + 有附件也是一条合法消息）。
    public var hasAttachments: Bool { !attachments.isEmpty }
}

// MARK: - 闯关（大树）

public enum LevelState: String, Codable, Sendable, CaseIterable {
    case locked
    case unlocked
    case inProgress
    case completed

    /// 母语展示名（情景卡片与大树立联动时用，避免 UI 各写一套映射）。
    public var displayName: String {
        switch self {
        case .locked: "未解锁"
        case .unlocked: "可以开始"
        case .inProgress: "正在学"
        case .completed: "已过关"
        }
    }
}

/// 树上的一个关卡节点。UI 只渲染，不内置业务数据。
public struct TreeLevel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var subtitle: String
    /// 0...1 的相对高度，0=树根，1=树冠。
    public var heightFraction: Double
    /// 树枝朝向：左 / 右，用于左右交错布局。
    public var branch: BranchSide
    public var state: LevelState
    public var requiredStars: Int
    public var earnedStars: Int
    /// 绑定到哪个情景（Scenario.id）：绑定后点这一关直接进入该情景，通关结算也记在它头上。
    /// **不落库**——绑定关系来自资源文件（`Resources/Levels/level_bindings.json`），加载进度时统一注入。
    public var scenarioID: String?

    public enum BranchSide: String, Codable, Sendable, CaseIterable { case left, right }

    public init(
        id: String,
        title: String,
        subtitle: String,
        heightFraction: Double,
        branch: BranchSide,
        state: LevelState = .locked,
        requiredStars: Int = 3,
        earnedStars: Int = 0,
        scenarioID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.heightFraction = heightFraction
        self.branch = branch
        self.state = state
        self.requiredStars = requiredStars
        self.earnedStars = earnedStars
        self.scenarioID = scenarioID
    }
}

public struct LearnerProgress: Codable, Sendable, Equatable {
    public var totalStars: Int
    /// 0...1 大树攀登进度。
    public var climbFraction: Double
    public var levels: [TreeLevel]

    public init(totalStars: Int = 0, climbFraction: Double = 0, levels: [TreeLevel] = []) {
        self.totalStars = totalStars
        self.climbFraction = climbFraction
        self.levels = levels
    }

    /// 学员**正在学**的那一关（树上高亮它、宿主据此定位视口）。
    ///
    /// 没有「正在学」的关卡时退回第一关：全新学员还没开张，起点就是树根营地。
    /// 放在领域层而不是视图里 —— 树上高亮、滚动定位两处都要用同一个判据，
    /// 各写一份迟早出现「圈在这格、视口停在那格」。
    public var currentLevelID: String {
        (levels.first { $0.state == .inProgress } ?? levels.first)?.id ?? ""
    }
}

// MARK: - 关卡种子目录（首次启动写入数据库，此后以数据库为准）

public extension LearnerProgress {

    static func seed() -> LearnerProgress {
        // ⚠️ **全新起点**：所有关卡 0 星、只有第一关开放（`unlocked`），其余锁定。
        //
        // 需求 1「清零闯关进度、从零开始学习」的落点之一：种子必须是零进度，
        // 否则老用户删掉库以后又会拿到一份「已经过完三关」的假进度。
        // 存量库的旧进度由 `LearningDatabase` 的 v8 → v9 迁移清空（见那边注释）。
        let levels: [TreeLevel] = [
            TreeLevel(id: "l1", title: "树根营地", subtitle: "打招呼", heightFraction: 0.06, branch: .left,
                      state: .unlocked, requiredStars: 3, earnedStars: 0),
            TreeLevel(id: "l2", title: "苔藓石阶", subtitle: "自我介绍", heightFraction: 0.18, branch: .right,
                      state: .locked, requiredStars: 3, earnedStars: 0),
            TreeLevel(id: "l3", title: "松鼠枝桠", subtitle: "点咖啡", heightFraction: 0.30, branch: .left,
                      state: .locked, requiredStars: 4, earnedStars: 0),
            TreeLevel(id: "l4", title: "蜂鸟花丛", subtitle: "过去时", heightFraction: 0.42, branch: .right,
                      state: .locked, requiredStars: 4, earnedStars: 0),
            TreeLevel(id: "l5", title: "溪流平台", subtitle: "问路", heightFraction: 0.54, branch: .left,
                      state: .locked, requiredStars: 5, earnedStars: 0),
            TreeLevel(id: "l6", title: "云雀高枝", subtitle: "观点表达", heightFraction: 0.66, branch: .right,
                      state: .locked, requiredStars: 5, earnedStars: 0),
            TreeLevel(id: "l7", title: "星语树冠", subtitle: "辩论", heightFraction: 0.78, branch: .left,
                      state: .locked, requiredStars: 6, earnedStars: 0),
            TreeLevel(id: "l8", title: "日出观景台", subtitle: "自由演讲", heightFraction: 0.92, branch: .right,
                      state: .locked, requiredStars: 6, earnedStars: 0),
        ]
        return LearnerProgress(totalStars: 0, climbFraction: 0, levels: levels)
    }

    /// 零进度：所有关卡 0 星，第 `unlockedIndex` 关开放，其余锁定。
    ///
    /// 保留各关的既有元数据（标题 / 需求星数），只把状态与星数归零 ——
    /// 「重置闯关进度」不该顺手改掉关卡本身的设计。
    func zeroed(unlocking index: Int = 0) -> LearnerProgress {
        var copy = self
        for position in copy.levels.indices {
            copy.levels[position].earnedStars = 0
            copy.levels[position].state = position == index ? .unlocked : .locked
        }
        copy.recalculateSummary()
        return copy
    }

    /// 星星数变化后重算汇总字段。
    mutating func recalculateSummary() {
        totalStars = levels.reduce(0) { $0 + $1.earnedStars }
        let requiredTotal = max(levels.reduce(0) { $0 + $1.requiredStars }, 1)
        climbFraction = min(Double(totalStars) / Double(requiredTotal), 1)
    }

    /// 注入「关卡 → 情景」绑定（纯函数，绑定表来自资源文件）。
    /// 绑定表里没有的关卡一律置空——不残留数据库里的旧值。
    mutating func applyScenarioBindings(_ bindings: [String: String]) {
        for index in levels.indices {
            levels[index].scenarioID = bindings[levels[index].id]
        }
    }

    /// 绑定到某个情景的关卡（没有则 nil）。用于「情景通关 → 记到哪一关」。
    func level(boundToScenario scenarioID: String) -> TreeLevel? {
        levels.first { $0.scenarioID == scenarioID }
    }
}

// MARK: - 学习者

public struct LearnerProfile: Codable, Sendable, Equatable {
    public var displayName: String
    public var learningLanguage: String
    public var nativeLanguage: String
    public var proficiency: Proficiency
    public var focusAreas: [String]

    public enum Proficiency: String, Codable, Sendable, CaseIterable {
        case beginner, intermediate, advanced
        public var displayName: String {
            switch self {
            case .beginner: "萌新"
            case .intermediate: "进阶"
            case .advanced: "熟练"
            }
        }
    }

    public init(
        displayName: String = "小探险家",
        learningLanguage: String = "en-US",
        nativeLanguage: String = "zh-CN",
        proficiency: Proficiency = .beginner,
        focusAreas: [String] = []
    ) {
        self.displayName = displayName
        self.learningLanguage = learningLanguage
        self.nativeLanguage = nativeLanguage
        self.proficiency = proficiency
        self.focusAreas = focusAreas
    }
}

// MARK: - 纠错 / 会话总结

public struct GrammarCorrection: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var original: String
    public var corrected: String
    public var explanation: String

    public init(id: UUID = UUID(), original: String, corrected: String, explanation: String) {
        self.id = id
        self.original = original
        self.corrected = corrected
        self.explanation = explanation
    }
}

public struct SessionSummary: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var messageCount: Int
    public var newStars: Int
    public var corrections: [GrammarCorrection]
    /// 本次会话进行的情景（`Scenario.id`；nil = 普通练习）。
    public var scenarioID: String?

    public init(
        sessionID: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date = Date(),
        messageCount: Int = 0,
        newStars: Int = 0,
        corrections: [GrammarCorrection] = [],
        scenarioID: String? = nil
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.messageCount = messageCount
        self.newStars = newStars
        self.corrections = corrections
        self.scenarioID = scenarioID
    }
}

// MARK: - 练习复盘（Session Review）

/// 一次练习结束后生成的学习复盘（Implementation Plan §25 / 学习记忆）。
/// 由 Application Service 依据会话流水 + 老师批注生成，落本地库，**不上传**。
public struct SessionReview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var sessionID: UUID
    public var createdAt: Date
    /// 本次练习时长（秒）。
    public var duration: TimeInterval
    public var messageCount: Int
    public var correctionCount: Int
    /// 一句话总结（母语）。
    public var headline: String
    /// 本次出现/值得记住的表达（学习语言）。
    public var newWords: [String]
    /// 做得好的地方（母语，1–3 条）。
    public var strengths: [String]
    /// 还需要改进的地方（母语，1–3 条）。
    public var improvements: [String]
    /// 下次练习建议（母语，一句）。
    public var suggestion: String

    /// 生成方式：LLM 生成 / 模型不可用时的规则兜底。
    public enum Source: String, Codable, Sendable {
        case llm
        case heuristic
    }

    public var source: Source

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        messageCount: Int = 0,
        correctionCount: Int = 0,
        headline: String = "",
        newWords: [String] = [],
        strengths: [String] = [],
        improvements: [String] = [],
        suggestion: String = "",
        source: Source = .llm
    ) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.duration = duration
        self.messageCount = messageCount
        self.correctionCount = correctionCount
        self.headline = headline
        self.newWords = newWords
        self.strengths = strengths
        self.improvements = improvements
        self.suggestion = suggestion
        self.source = source
    }

    /// 时长文案：「3 分 20 秒」/「48 秒」。
    public var durationText: String {
        let seconds = max(Int(duration), 0)
        if seconds < 60 { return "\(seconds) 秒" }
        return String(format: "%d 分 %d 秒", seconds / 60, seconds % 60)
    }

    /// 内容是否为空（无有效复盘信息时 UI 不展示）。
    public var isEmpty: Bool {
        headline.isEmpty && newWords.isEmpty && strengths.isEmpty && improvements.isEmpty && suggestion.isEmpty
    }
}

// MARK: - 会话

public struct ChatSession: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var startedAt: Date
    public var mode: PracticeMode
    public var messages: [ChatMessage]
    /// 本会话进行的情景（`Scenario.id`；nil = 普通练习）。落库到 `sessions.scenario_id`。
    public var scenarioID: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        mode: PracticeMode = .conversation,
        messages: [ChatMessage] = [],
        scenarioID: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.mode = mode
        self.messages = messages
        self.scenarioID = scenarioID
    }
}
