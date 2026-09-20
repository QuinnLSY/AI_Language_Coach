import Foundation

// MARK: - 主线任务（Main Quest）与教学重点（Teaching Focus）
//
// 设计口径（需求 3）：**通关 = 完成主线任务 + 教学重点达标**，两者缺一不可。
//
// 1. **主线任务**：这一局要按顺序推进的几步。数据驱动（场景 JSON 的 `mainQuest` / `questSteps`），
//    缺字段时从 `targetSentences` 自动推导 —— 保证任何场景都有主线可用，新增素材不用改代码。
// 2. **教学重点**：目标句 / 目标词的覆盖量，阈值按场景的 CEFR 档位走（`CurriculumCriteria`）。
//    语法点（`targetGrammar`）只在界面上做提示，**不参与判定**：从自由文本里判断「用了哪个语法」
//    不可靠，把它当门槛会出现「说了却不认」的冤枉判定。
// 3. **轮次**只算「开口量」，进星星与提示语，**不再单独当通关门槛**：
//    说满轮次却没说到点子上，不算过关。
//
// 本文件全部是纯函数，不 import 任何 UI / IO。

/// 主线任务的一步。
public struct QuestStep: Codable, Sendable, Equatable, Identifiable {

    /// 稳定标识。素材里留空时由 `ScenarioQuestRule.plan` 按场景 id + 序号补。
    public let id: String
    /// 这一步要做什么（学习语言，展示 + 注入 Prompt）。
    public var text: String
    /// 母语提示（对初学者友好；可为空）。
    public var hint: String
    /// 命中**任一**锚点就算完成（锚点 = 目标句或目标词）。空 = 该步不参与判定。
    public var anchors: [String]

    public init(id: String = "", text: String, hint: String = "", anchors: [String] = []) {
        self.id = id
        self.text = text
        self.hint = hint
        self.anchors = anchors
    }
}

/// 一个场景的主线任务计划。
public struct QuestPlan: Codable, Sendable, Equatable {

    public var title: String
    public var steps: [QuestStep]

    public init(title: String, steps: [QuestStep]) {
        self.title = title
        self.steps = steps
    }

    public var isEmpty: Bool { steps.isEmpty }
    public var total: Int { steps.count }
    /// 有锚点、真正参与判定的步骤。
    public var anchoredSteps: [QuestStep] { steps.filter { !$0.anchors.isEmpty } }
}

/// 一步的实时状态（UI 直接渲染）。
public struct QuestStepState: Sendable, Equatable, Identifiable {

    public let id: String
    public let index: Int
    public let text: String
    public let hint: String
    public let isDone: Bool
    /// 是否是「现在该做的那一步」（第一个还没完成的步骤）。
    public let isCurrent: Bool

    public init(id: String, index: Int, text: String, hint: String, isDone: Bool, isCurrent: Bool) {
        self.id = id
        self.index = index
        self.text = text
        self.hint = hint
        self.isDone = isDone
        self.isCurrent = isCurrent
    }

    /// 给界面的序号标记：`① ② ③`，超出用数字。
    public var marker: String {
        let markers = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"]
        let position = index + 1
        return markers.indices.contains(index) ? markers[index] : "\(position)."
    }
}

/// 主线任务的实时进度。
public struct QuestProgress: Sendable, Equatable {

    public var title: String
    public var steps: [QuestStepState]
    /// 已完成步骤 id（含**上一局就已完成**的，见 `alreadyDone`）。
    public var completedStepIDs: [String]

    public init(title: String, steps: [QuestStepState], completedStepIDs: [String]) {
        self.title = title
        self.steps = steps
        self.completedStepIDs = completedStepIDs
    }

    public var total: Int { steps.count }
    public var doneCount: Int { steps.filter(\.isDone).count }
    /// 没有步骤时视为「没有主线」——不当成已完成，避免空计划把玩家蒙过去。
    public var isComplete: Bool { !steps.isEmpty && steps.allSatisfy(\.isDone) }

    /// 当前节点：第一个未完成的**可判定**步骤（没有锚点的步骤不占这个位置）。
    ///
    /// ⚠️ 必须读 `isCurrent` 而不是 `steps.first { !$0.isDone }` ——
    /// 后一种写法会把「没有锚点、根本判不了完成」的步骤当成当前节点，
    /// 老师于是会一直催学员做一件永远做不完的事。
    public var currentStep: QuestStepState? { steps.first(where: \.isCurrent) }

    /// `主线任务 2/3`。
    public var summary: String { "主线任务 \(doneCount)/\(total)" }

    /// 当前节点的一句话（0 步时为「」）。
    public var currentText: String { currentStep?.text ?? "" }

    /// 给「前情提要」用的一行：已完成几步、下一步是什么。
    public var briefingLine: String {
        guard total > 0 else { return "" }
        if isComplete { return "主线任务已全部完成（\(doneCount)/\(total)）" }
        let next = currentStep?.text ?? ""
        if doneCount == 0 { return "主线任务还没开始：\(next)" }
        return "主线任务已完成 \(doneCount)/\(total)，接着做：\(next)"
    }

    /// 空进度（没有计划时 UI 用）。
    public static func empty(title: String = "") -> QuestProgress {
        QuestProgress(title: title, steps: [], completedStepIDs: [])
    }
}

// MARK: - 判定规则（纯函数）

public enum ScenarioQuestRule {

    /// 从场景推导主线任务。
    ///
    /// 优先用素材里写好的 `mainQuest` / `questSteps`；没有就按目标句自动切成最多 3 步，
    /// 再退到目标词。这样「新加一个场景却忘了写主线」不会变成一局无所事事。
    public static func plan(for scenario: Scenario) -> QuestPlan {
        let title = scenario.mainQuest.isEmpty
            ? (scenario.objective.isEmpty ? scenario.titleZh : scenario.objective)
            : scenario.mainQuest

        if !scenario.questSteps.isEmpty {
            let steps = scenario.questSteps.enumerated().map { index, step in
                QuestStep(
                    id: step.id.isEmpty ? "\(scenario.id)-s\(index + 1)" : step.id,
                    text: step.text,
                    hint: step.hint,
                    anchors: step.anchors
                )
            }
            return QuestPlan(title: title, steps: steps)
        }

        if !scenario.targetSentences.isEmpty {
            return QuestPlan(title: title, steps: chunked(
                scenario.targetSentences,
                into: 3,
                scenarioID: scenario.id,
                hintPrefix: "用上这句"
            ))
        }

        if !scenario.targetVocabulary.isEmpty {
            return QuestPlan(title: title, steps: chunked(
                scenario.targetVocabulary,
                into: 3,
                scenarioID: scenario.id,
                hintPrefix: "用上这些词"
            ))
        }

        return QuestPlan(title: title, steps: [])
    }

    /// 算实时进度。
    ///
    /// - Parameters:
    ///   - plan: 主线任务计划。
    ///   - utterances: 学员**这一局**说过的每一句话（时间顺序）。
    ///   - alreadyDone: 库里已经记下的「已完成步骤」（上一局完成的）。
    ///
    /// ⚠️ **并集语义**：已完成步骤只增不减 —— 上一局推到的第 2 步，不会因为这一局没说到而退回去。
    /// 断点续做靠的就是这条，否则每次重开都在第一步原地踏步。
    public static func progress(
        plan: QuestPlan,
        utterances: [String],
        alreadyDone: Set<String> = []
    ) -> QuestProgress {
        let lines = utterances.map { ShadowingScorer.words($0) }.filter { !$0.isEmpty }
        let anchored = plan.anchoredSteps

        var states: [QuestStepState] = []
        var done: [String] = []
        for (index, step) in plan.steps.enumerated() {
            let hit: Bool
            if step.anchors.isEmpty {
                // 没锚点的步骤不参与判定：既不阻塞也不冒充完成。
                hit = false
            } else {
                hit = alreadyDone.contains(step.id)
                    || step.anchors.contains { isAnchorHit($0, lines: lines) }
            }
            if hit { done.append(step.id) }
            states.append(QuestStepState(
                id: step.id, index: index, text: step.text, hint: step.hint,
                isDone: hit, isCurrent: false
            ))
        }

        // 标记「当前节点」：
        // · 计划里有可判定步骤 → 取第一个未完成的**有锚点**步骤；
        // · 整份计划都没锚点（素材极简）→ 退化为「第一个未完成步骤」，
        //   否则老师会连一句可催的话都没有。
        let pending = states.indices.filter { !states[$0].isDone }
        let preferred = pending.first { !plan.steps[$0].anchors.isEmpty }
            ?? (anchored.isEmpty ? pending.first : nil)
        if let preferred {
            states[preferred] = QuestStepState(
                id: states[preferred].id, index: states[preferred].index,
                text: states[preferred].text, hint: states[preferred].hint,
                isDone: false, isCurrent: true
            )
        }

        // 整份计划都没有锚点（素材缺目标句又缺目标词）：退化为「开口即算推进」，
        // 不至于让这一关永远无法通关。
        if anchored.isEmpty && !plan.steps.isEmpty && !utterances.isEmpty {
            states = states.map {
                QuestStepState(id: $0.id, index: $0.index, text: $0.text, hint: $0.hint,
                               isDone: true, isCurrent: false)
            }
            done = plan.steps.map(\.id)
        }

        return QuestProgress(title: plan.title, steps: states, completedStepIDs: done)
    }

    /// 单个锚点是否被说到。
    ///
    /// 与 `CurriculumScorer.coverage` 同一口径：多词锚点按「同一句里的召回率 ≥ 阈值」算，
    /// 单词锚点按词命中算 —— 两处口径不一致会让界面出现「第 3 句说到了但第 3 步没完成」。
    public static func isAnchorHit(_ anchor: String, lines: [[String]]) -> Bool {
        let target = ShadowingScorer.words(anchor)
        guard !target.isEmpty else { return false }
        if target.count == 1 {
            return lines.contains { $0.contains(target[0]) }
        }
        return lines.contains { line in
            CurriculumScorer.recall(target, in: line) >= CurriculumScorer.sentenceMatchThreshold
        }
    }

    // MARK: 内部

    /// 把一组素材均分成最多 `count` 步（每步的锚点就是这一组的元素）。
    private static func chunked(
        _ items: [String],
        into count: Int,
        scenarioID: String,
        hintPrefix: String
    ) -> [QuestStep] {
        let size = max(Int((Double(items.count) / Double(max(count, 1))).rounded(.up)), 1)
        let groups = stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
        return groups.enumerated().map { index, group in
            QuestStep(
                id: "\(scenarioID)-s\(index + 1)",
                text: group.joined(separator: " / "),
                hint: "\(hintPrefix)：\(group.first ?? "")",
                anchors: group
            )
        }
    }
}

// MARK: - 落库记录

/// 库里的情景主线任务进度（`scenario_quests` 表一行）。
///
/// ⚠️ 步骤只增不减：这是「断点续做」的物理保证 —— 上一局推到的第 2 步，
/// 不会因为这一局没说到而退回去。
public struct ScenarioQuestRecord: Sendable, Equatable {

    public var scenarioID: String
    /// 最近一次推进它的会话（用于回溯「上次是这一局练的」）。
    public var sessionID: UUID?
    public var doneStepIDs: [String]
    /// 主线任务是否已整体完成（完成过的再进来会重新开始，见 `AppState.startScenario`）。
    public var isComplete: Bool
    public var updatedAt: Date

    public init(
        scenarioID: String,
        sessionID: UUID? = nil,
        doneStepIDs: [String] = [],
        isComplete: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.scenarioID = scenarioID
        self.sessionID = sessionID
        self.doneStepIDs = doneStepIDs
        self.isComplete = isComplete
        self.updatedAt = updatedAt
    }

    /// 合并新完成的一批步骤（并集，顺序按原记录 + 新来的，去重）。
    public func merging(doneStepIDs newIDs: [String], complete: Bool, sessionID: UUID?) -> ScenarioQuestRecord {
        var seen = Set<String>()
        var merged: [String] = []
        for id in doneStepIDs + newIDs where seen.insert(id).inserted {
            merged.append(id)
        }
        return ScenarioQuestRecord(
            scenarioID: scenarioID,
            sessionID: sessionID ?? self.sessionID,
            doneStepIDs: merged,
            // ⚠️ 这里必须用**参数** `complete`，不能写成 `isComplete` ——
            // 后者会解析成属性本身，于是「本次已整体完成」被静默忽略
            // （实测：合并时传 complete: true 却仍然回 false）。
            isComplete: complete || self.isComplete,
            updatedAt: Date()
        )
    }

    public var doneStepSet: Set<String> { Set(doneStepIDs) }
}

// MARK: - 落库记录（结束）

// MARK: - 教学重点（Teaching Focus）

/// 一条教学重点。
public struct TeachingFocusItem: Sendable, Equatable, Identifiable {

    public enum Kind: String, Sendable, Equatable {
        case sentence
        case word

        public var label: String {
            switch self {
            case .sentence: "目标句"
            case .word: "目标词"
            }
        }
    }

    public let id: String
    public let kind: Kind
    public let text: String
    public let isHit: Bool

    public init(id: String, kind: Kind, text: String, isHit: Bool) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isHit = isHit
    }
}

/// 一次练习对「教学重点」的达成情况。
public struct TeachingFocus: Sendable, Equatable {

    public var items: [TeachingFocusItem]
    public var matchedSentences: Int
    public var requiredSentences: Int
    public var matchedWords: Int
    public var requiredWords: Int

    public init(
        items: [TeachingFocusItem],
        matchedSentences: Int,
        requiredSentences: Int,
        matchedWords: Int,
        requiredWords: Int
    ) {
        self.items = items
        self.matchedSentences = matchedSentences
        self.requiredSentences = requiredSentences
        self.matchedWords = matchedWords
        self.requiredWords = requiredWords
    }

    /// 目标句与目标词**都**达标才算教学重点过关。
    public var isSatisfied: Bool {
        matchedSentences >= requiredSentences && matchedWords >= requiredWords
    }

    public var sentenceItems: [TeachingFocusItem] { items.filter { $0.kind == .sentence } }
    public var wordItems: [TeachingFocusItem] { items.filter { $0.kind == .word } }

    /// `目标句 2/3 · 目标词 4/5`。
    public var summary: String {
        "目标句 \(matchedSentences)/\(requiredSentences) · 目标词 \(matchedWords)/\(requiredWords)"
    }

    /// 还没拿到的重点（给「下次练这个」用）。
    public var missingItems: [TeachingFocusItem] { items.filter { !$0.isHit } }

    /// 空重点（场景没有目标句也没有目标词）。
    public static let empty = TeachingFocus(
        items: [], matchedSentences: 0, requiredSentences: 0, matchedWords: 0, requiredWords: 0
    )

    public var isEmpty: Bool { items.isEmpty }
}
