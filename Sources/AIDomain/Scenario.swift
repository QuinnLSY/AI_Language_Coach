import AppCore
import Foundation

// MARK: - 情景对话（Role Play / Scenario System）
//
// 设计依据：Implementation Plan §21「Scenario System」、PRD §9–§10、技术设计 §35。
// **场景必须数据驱动**：本体只描述「场景是什么」，不描述「界面怎么画」，
// 因此 UI 不得内置任何场景数据，一律通过 Application Service 读取。

/// 纠错强度：老师在该场景里插话纠错的积极程度。
public enum ScenarioCorrectionMode: String, Codable, Sendable, CaseIterable {
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

    /// 注入 Prompt 的英文指令片段。
    public var instruction: String {
        switch self {
        case .gentle:
            "Only correct mistakes that block understanding; let small slips pass."
        case .balanced:
            "Correct clear mistakes, but stay in character and keep the role play flowing."
        case .strict:
            "Correct every noticeable mistake, including small ones, before moving the scene on."
        }
    }
}

/// 一个情景对话（Role Play）场景。
///
/// 字段全部来自 `Resources/Scenarios/*.json`，**代码里不得出现场景字面量**。
public struct Scenario: Codable, Sendable, Equatable, Identifiable {

    /// 稳定标识（如 `airport_checkin`）。
    public let id: String
    /// 学习语言标题（展示 + 注入 Prompt）。
    public var title: String
    /// 母语标题（UI 卡片主标题，对初学者更友好）。
    public var titleZh: String
    /// 展示分组（如「旅行」「日常」）。UI 只负责渲染，不解释语义。
    public var category: String
    /// 难度 1...5。
    public var difficulty: Int
    /// CEFR 水平区间（如 `A2-B1`）。
    public var level: String
    /// 学习目标（学习语言表述，注入 Prompt 让老师有的放矢）。
    public var objective: String
    /// AI 扮演的角色。
    public var aiRole: String
    /// 学员扮演的角色。
    public var learnerRole: String
    /// AI 的开场白（学习语言）：开始情景时直接抛给学员。
    public var opening: String
    /// 本场景希望学员用到的词。
    public var targetVocabulary: [String]
    /// 本场景希望学员用到的语法点。
    public var targetGrammar: [String]
    /// 期望轮次上限（学员发言计一轮）；到点老师收尾。
    public var maxTurns: Int
    /// 纠错强度。
    public var correctionMode: ScenarioCorrectionMode
    /// UI 图标（SF Symbol 名称）。
    public var icon: String

    public init(
        id: String,
        title: String,
        titleZh: String,
        category: String,
        difficulty: Int,
        level: String,
        objective: String,
        aiRole: String,
        learnerRole: String,
        opening: String,
        targetVocabulary: [String] = [],
        targetGrammar: [String] = [],
        maxTurns: Int = 12,
        correctionMode: ScenarioCorrectionMode = .balanced,
        icon: String = "bubble.left.and.bubble.right.fill"
    ) {
        self.id = id
        self.title = title
        self.titleZh = titleZh
        self.category = category
        self.difficulty = min(max(difficulty, 1), 5)
        self.level = level
        self.objective = objective
        self.aiRole = aiRole
        self.learnerRole = learnerRole
        self.opening = opening
        self.targetVocabulary = targetVocabulary
        self.targetGrammar = targetGrammar
        self.maxTurns = max(maxTurns, 1)
        self.correctionMode = correctionMode
        self.icon = icon
    }

    /// 难度圆点（UI 展示用）：`●●●○○`。
    public var difficultyDots: String {
        String(repeating: "●", count: min(max(difficulty, 0), 5))
            + String(repeating: "○", count: max(5 - difficulty, 0))
    }

    /// 按分组名归档（保持传入顺序；分组名按首次出现顺序）。
    /// 数据语义属于领域，UI 只渲染结果，不重复实现一遍分组逻辑。
    public static func groups(_ scenarios: [Scenario]) -> [(category: String, items: [Scenario])] {
        var order: [String] = []
        var buckets: [String: [Scenario]] = [:]
        for scenario in scenarios {
            if buckets[scenario.category] == nil { order.append(scenario.category) }
            buckets[scenario.category, default: []].append(scenario)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    // 缺字段一律降级为安全默认值，避免单个场景文件写坏导致整表加载失败。
    private enum CodingKeys: String, CodingKey {
        case id, title, titleZh, category, difficulty, level, objective
        case aiRole, learnerRole, opening, targetVocabulary, targetGrammar
        case maxTurns, correctionMode, icon
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        titleZh = try container.decodeIfPresent(String.self, forKey: .titleZh) ?? title
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "日常"
        difficulty = min(max(try container.decodeIfPresent(Int.self, forKey: .difficulty) ?? 3, 1), 5)
        level = try container.decodeIfPresent(String.self, forKey: .level) ?? "A2"
        objective = try container.decodeIfPresent(String.self, forKey: .objective) ?? ""
        aiRole = try container.decodeIfPresent(String.self, forKey: .aiRole) ?? "conversation partner"
        learnerRole = try container.decodeIfPresent(String.self, forKey: .learnerRole) ?? "learner"
        opening = try container.decodeIfPresent(String.self, forKey: .opening) ?? ""
        targetVocabulary = try container.decodeIfPresent([String].self, forKey: .targetVocabulary) ?? []
        targetGrammar = try container.decodeIfPresent([String].self, forKey: .targetGrammar) ?? []
        let turns = try container.decodeIfPresent(Int.self, forKey: .maxTurns) ?? 12
        maxTurns = max(turns, 1)
        correctionMode = try container.decodeIfPresent(ScenarioCorrectionMode.self, forKey: .correctionMode) ?? .balanced
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "bubble.left.and.bubble.right.fill"
    }
}

// MARK: - 进行中的情景会话状态

/// 一次情景练习的进度（由 ChatService 持有，UI 只读展示）。
public struct ScenarioProgress: Sendable, Equatable {
    public let scenario: Scenario
    /// 学员已发言轮数。
    public var turnsUsed: Int

    public init(scenario: Scenario, turnsUsed: Int = 0) {
        self.scenario = scenario
        self.turnsUsed = turnsUsed
    }

    /// 剩余轮数（不为负）。
    public var turnsRemaining: Int { max(scenario.maxTurns - turnsUsed, 0) }

    /// 是否已到收尾轮次。
    public var isFinalTurn: Bool { turnsRemaining <= 1 }

    /// 展示文案：`第 3/12 轮`。
    public var turnsText: String { "第 \(min(turnsUsed, scenario.maxTurns))/\(scenario.maxTurns) 轮" }
}
