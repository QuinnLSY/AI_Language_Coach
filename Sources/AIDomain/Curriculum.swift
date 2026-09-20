import Foundation

// MARK: - CEFR 课程体系（PRD §10 课程分级 / Implementation Plan §21–§22）
//
// 硬要求：**分级、覆盖度、过关判定全是纯函数**，本文件不 import 任何 UI / IO。
//
// 三条口径（写在这里，UI 只显示，不二次加工）：
// 1. **目标句命中**：目标句里的词有 `sentenceMatchThreshold` 以上出现在**同一句**
//    学员发言里就算说出来了 —— 允许漏掉冠词 / 介词，不要求背得一字不差。
// 2. **目标词命中**：词在学员说过的话里出现过（大小写、标点不敏感）。
// 3. **过关标准**按 CEFR 档递进：A1 说满一半轮次就赢，B2 要求说满八成且覆盖三句目标句。

/// CEFR 等级。只做到 B2 —— C1 以上不是这个产品要解决的问题。
public enum CEFRLevel: String, Codable, Sendable, Equatable, CaseIterable, Comparable {

    case a1
    case a2
    case b1
    case b2

    public var id: String { rawValue }

    /// 展示代号（`A1`）。
    public var code: String { rawValue.uppercased() }

    /// 中文档位名。
    public var displayName: String {
        switch self {
        case .a1: "入门"
        case .a2: "基础"
        case .b1: "进阶"
        case .b2: "自如"
        }
    }

    /// 这一档能做到什么（给学员看的 can-do，不是教学术语）。
    public var canDo: String {
        switch self {
        case .a1: "用短句应付眼前的事：问好、点单、问价"
        case .a2: "把日常小事说完整：约时间、说计划、讲经历"
        case .b1: "说出理由和看法，能对付一次没准备过的对话"
        case .b2: "就跑题也能聊下去：辩护观点、反驳、即兴开场"
        }
    }

    /// 排序权重。
    public var order: Int {
        switch self {
        case .a1: 0
        case .a2: 1
        case .b1: 2
        case .b2: 3
        }
    }

    public static func < (lhs: CEFRLevel, rhs: CEFRLevel) -> Bool { lhs.order < rhs.order }

    /// 解析 `level` 字符串（`"A1-A2"` / `"B1"` / `"a2 - b1"`）。解析不出返回空数组。
    public static func parse(_ text: String) -> [CEFRLevel] {
        let lowered = text.lowercased()
        // 顺序按文本出现位置，保证「A1-A2」得到 [a1, a2] 而不是反过来。
        let hits: [(offset: Int, level: CEFRLevel)] = CEFRLevel.allCases.compactMap { level in
            guard let range = lowered.range(of: level.rawValue) else { return nil }
            return (lowered.distance(from: lowered.startIndex, to: range.lowerBound), level)
        }
        return hits.sorted { $0.offset < $1.offset }.map(\.level)
    }

    /// 这一档的过关标准。
    public var passCriteria: CurriculumCriteria {
        switch self {
        case .a1: CurriculumCriteria(minimumTurnRatio: 0.5, minimumTargetSentences: 2, minimumTargetWords: 3)
        case .a2: CurriculumCriteria(minimumTurnRatio: 0.6, minimumTargetSentences: 2, minimumTargetWords: 4)
        case .b1: CurriculumCriteria(minimumTurnRatio: 0.7, minimumTargetSentences: 3, minimumTargetWords: 5)
        case .b2: CurriculumCriteria(minimumTurnRatio: 0.8, minimumTargetSentences: 3, minimumTargetWords: 6)
        }
    }
}

/// 一档的过关标准（可核对的三项）。
public struct CurriculumCriteria: Sendable, Equatable {
    /// 至少要说满多少比例的轮次（按 `maxTurns` 折算）。
    public var minimumTurnRatio: Double
    /// 至少要说出几句目标句。
    public var minimumTargetSentences: Int
    /// 至少要说出几个目标词。
    public var minimumTargetWords: Int

    public init(minimumTurnRatio: Double, minimumTargetSentences: Int, minimumTargetWords: Int) {
        self.minimumTurnRatio = min(max(minimumTurnRatio, 0), 1)
        self.minimumTargetSentences = max(minimumTargetSentences, 0)
        self.minimumTargetWords = max(minimumTargetWords, 0)
    }

    /// 「说满 8 轮 · 目标句 3 句 · 目标词 5 个」。
    public func summary(maxTurns: Int) -> String {
        "说满 \(requiredTurns(maxTurns: maxTurns)) 轮 · 目标句 \(minimumTargetSentences) 句 · 目标词 \(minimumTargetWords) 个"
    }

    /// 折算成这一关需要的轮数（向上取整，至少 1 轮）。
    public func requiredTurns(maxTurns: Int) -> Int {
        max(Int((Double(max(maxTurns, 1)) * minimumTurnRatio).rounded(.up)), 1)
    }
}

// MARK: - 覆盖度（学员实际说了什么）

/// 一次情景练习对课程目标的覆盖情况。全部由学员**真实说过的话**算出来。
public struct CurriculumCoverage: Sendable, Equatable {

    /// 学员这一局发了几轮（与 `ScenarioRewardRule.stars` 同一口径）。
    public var turnsUsed: Int
    public var maxTurns: Int
    /// 说出来的目标句 / 没说的目标句（保持素材顺序）。
    public var matchedSentences: [String]
    public var missingSentences: [String]
    /// 说出来的目标词 / 没说的目标词（保持素材顺序）。
    public var matchedWords: [String]
    public var missingWords: [String]

    public init(
        turnsUsed: Int,
        maxTurns: Int,
        matchedSentences: [String] = [],
        missingSentences: [String] = [],
        matchedWords: [String] = [],
        missingWords: [String] = []
    ) {
        self.turnsUsed = max(turnsUsed, 0)
        self.maxTurns = max(maxTurns, 1)
        self.matchedSentences = matchedSentences
        self.missingSentences = missingSentences
        self.matchedWords = matchedWords
        self.missingWords = missingWords
    }

    public var turnRatio: Double { min(Double(turnsUsed) / Double(maxTurns), 1) }

    public var sentenceTotal: Int { matchedSentences.count + missingSentences.count }
    public var wordTotal: Int { matchedWords.count + missingWords.count }

    /// 「目标句 2/4 · 目标词 5/6 · 轮次 7/12」。
    public var summary: String {
        "目标句 \(matchedSentences.count)/\(sentenceTotal) · 目标词 \(matchedWords.count)/\(wordTotal) · 轮次 \(turnsUsed)/\(maxTurns)"
    }
}

/// 过关判定。
public enum CurriculumVerdict: Sendable, Equatable {

    /// 主线任务完成 **且** 教学重点达标（需求 3 的通关口径）。
    case passed
    /// 两件里只做到了一件。
    case close
    /// 两件都还没做到。
    case notYet

    public var didPass: Bool { self == .passed }

    public var headline: String {
        switch self {
        case .passed: "这一关过了"
        case .close: "就差一点"
        case .notYet: "再练一轮"
        }
    }
}

/// 一次判定的完整结果。
public struct CurriculumAssessment: Sendable, Equatable {
    public var level: CEFRLevel
    public var coverage: CurriculumCoverage
    /// 主线任务完成情况（需求 3：通关条件之一）。
    public var quest: QuestProgress
    /// 教学重点达成情况（需求 3：通关条件之二）。
    public var focus: TeachingFocus
    public var verdict: CurriculumVerdict
    /// 逐条可核对的原因（达标说达标，没达标说差多少）。
    public var reasons: [String]
    /// 下次再练这一关时最该补上的目标句（nil = 全说到了）。
    public var nextSentence: String?

    public init(
        level: CEFRLevel,
        coverage: CurriculumCoverage,
        quest: QuestProgress = .empty(),
        focus: TeachingFocus = .empty,
        verdict: CurriculumVerdict,
        reasons: [String],
        nextSentence: String? = nil
    ) {
        self.level = level
        self.coverage = coverage
        self.quest = quest
        self.focus = focus
        self.verdict = verdict
        self.reasons = reasons
        self.nextSentence = nextSentence
    }

    /// 主线任务是否已完成（空主线视为「无需满足」，不阻塞通关）。
    public var isQuestSatisfied: Bool { quest.total == 0 || quest.isComplete }

    /// 教学重点是否达标（空重点视为「无需满足」）。
    public var isFocusSatisfied: Bool { focus.isEmpty || focus.isSatisfied }

    /// `主线任务 2/3 · 目标句 2/3 · 目标词 4/5`。
    public var summary: String {
        var parts: [String] = []
        if quest.total > 0 { parts.append(quest.summary) }
        if !focus.isEmpty { parts.append(focus.summary) }
        if parts.isEmpty { parts.append(coverage.summary) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 计分（纯函数）

public enum CurriculumScorer {

    /// 目标句命中阈值：目标句的词有这么大比例出现在**同一句**学员发言里就算说出来。
    ///
    /// 定在 0.75 是刻意的：允许漏掉冠词 / 介词 / 助动词（`I would like a coffee` 说成
    /// `I like coffee` 也算说到了这一句），但换掉实义词就不算。
    public static let sentenceMatchThreshold = 0.75

    /// 算覆盖度。`utterances` 是学员这一局说过的每一句话（按时间顺序）。
    public static func coverage(
        scenario: Scenario,
        utterances: [String]
    ) -> CurriculumCoverage {
        let lines = utterances.map { ShadowingScorer.words($0) }.filter { !$0.isEmpty }
        let saidWords = Set(lines.flatMap { $0 })

        let sentences = scenario.targetSentences
        let matchedSentences = sentences.filter { sentence in
            let target = ShadowingScorer.words(sentence)
            guard !target.isEmpty else { return false }
            // 只要**某一句**学员发言覆盖得够多，就算说到了。
            return lines.contains { line in recall(target, in: line) >= sentenceMatchThreshold }
        }
        let matchedWords = scenario.targetVocabulary.filter { word in
            let normalized = ShadowingScorer.words(word)
            guard !normalized.isEmpty else { return false }
            // 词组（「main course」）按整串匹配；单词按词匹配。
            if normalized.count == 1 { return saidWords.contains(normalized[0]) }
            return lines.contains { containsSequence(normalized, in: $0) }
        }

        return CurriculumCoverage(
            // 轮次按**学员发了几轮**算（含「只发附件没写字」的那一轮）——
            // 与 `ScenarioRewardRule.stars` 共用同一把尺子，否则同一局会出现两个轮次数。
            turnsUsed: utterances.count,
            maxTurns: scenario.maxTurns,
            matchedSentences: matchedSentences,
            missingSentences: sentences.filter { !matchedSentences.contains($0) },
            matchedWords: matchedWords,
            missingWords: scenario.targetVocabulary.filter { !matchedWords.contains($0) }
        )
    }

    /// 教学重点的**达标门槛**：档位要求与素材实际数量取小。
    ///
    /// ⚠️ 要求数不能超过素材实际有的数量：素材只写了 1 句目标句，却按 B1 要求「3 句」，
    /// 这一关就永远过不去。
    ///
    /// 单独开这个口子，是为了让**「开练之前」的界面**（情景卡片的「教学重点」标题）
    /// 也能报出与判定完全一致的门槛数。写在两处各算一遍，迟早算出两个数 ——
    /// 学员就会看到「卡片说 4 句、练起来说 0/2」这种自相矛盾的场面。
    public static func focusThreshold(for scenario: Scenario) -> (sentences: Int, words: Int) {
        let criteria = scenario.primaryLevel.passCriteria
        return (
            sentences: min(criteria.minimumTargetSentences, scenario.targetSentences.count),
            words: min(criteria.minimumTargetWords, scenario.targetVocabulary.count)
        )
    }

    /// 教学重点的达成情况（目标句 + 目标词；语法点只做提示、不参与判定）。
    public static func focus(scenario: Scenario, coverage: CurriculumCoverage) -> TeachingFocus {
        let sentenceItems = scenario.targetSentences.map { sentence in
            TeachingFocusItem(
                id: "s:\(sentence)", kind: .sentence, text: sentence,
                isHit: coverage.matchedSentences.contains(sentence)
            )
        }
        let wordItems = scenario.targetVocabulary.map { word in
            TeachingFocusItem(
                id: "w:\(word)", kind: .word, text: word,
                isHit: coverage.matchedWords.contains(word)
            )
        }
        let items = sentenceItems + wordItems
        guard !items.isEmpty else { return .empty }

        let threshold = focusThreshold(for: scenario)
        return TeachingFocus(
            items: items,
            matchedSentences: coverage.matchedSentences.count,
            requiredSentences: threshold.sentences,
            matchedWords: coverage.matchedWords.count,
            requiredWords: threshold.words
        )
    }

    /// 判定是否过关。
    ///
    /// **通关口径（需求 3）：主线任务完成 + 教学重点达标**，两者缺一不可。
    /// 轮次从「门槛」降为「开口量」——只进星星与提示语，不再单独决定胜负：
    /// 说满轮次却没说在点子上，本来就不该算过关。
    ///
    /// - Parameter questDone: 库里已记下的「已完成步骤」id（上一局推到的进度，只增不减）。
    public static func assess(
        scenario: Scenario,
        utterances: [String],
        questDone: Set<String> = []
    ) -> CurriculumAssessment {
        let covered = coverage(scenario: scenario, utterances: utterances)
        let level = scenario.primaryLevel
        let criteria = level.passCriteria
        let requiredTurns = criteria.requiredTurns(maxTurns: covered.maxTurns)
        let plan = scenario.questPlan
        let quest = ScenarioQuestRule.progress(plan: plan, utterances: utterances, alreadyDone: questDone)
        let teachingFocus = focus(scenario: scenario, coverage: covered)

        let turnsOK = covered.turnsUsed >= requiredTurns
        // 没有主线 / 没有重点的极简素材：不拿空条件卡人，退回「说满轮次即过关」。
        let questOK = quest.total > 0 ? quest.isComplete : turnsOK
        let focusOK = teachingFocus.isEmpty ? turnsOK : teachingFocus.isSatisfied

        var reasons: [String] = []
        if quest.total > 0 {
            reasons.append(quest.isComplete
                ? "主线任务全部完成（\(quest.doneCount)/\(quest.total)）"
                : "主线任务还差 \(quest.total - quest.doneCount) 步，下一步：\(quest.currentText)")
        } else {
            reasons.append("轮次 \(covered.turnsUsed)/\(covered.maxTurns)，这一档要求说满 \(requiredTurns) 轮")
        }
        if !teachingFocus.isEmpty {
            reasons.append(teachingFocus.isSatisfied
                ? "教学重点达标（\(teachingFocus.summary)）"
                : "教学重点还没达标（\(teachingFocus.summary)）")
        }
        if !covered.missingSentences.isEmpty {
            reasons.append("还没说到的句子：「\(covered.missingSentences[0])」")
        }
        if !turnsOK {
            reasons.append("只说了 \(covered.turnsUsed) 轮，建议说满 \(requiredTurns) 轮再来一次")
        }

        let missCount = [questOK, focusOK].filter { !$0 }.count
        let verdict: CurriculumVerdict = missCount == 0 ? .passed : (missCount == 1 ? .close : .notYet)

        return CurriculumAssessment(
            level: level,
            coverage: covered,
            quest: quest,
            focus: teachingFocus,
            verdict: verdict,
            reasons: reasons,
            nextSentence: covered.missingSentences.first
        )
    }

    // MARK: 内部匹配

    /// 目标词序列在学员词序列里的召回率（出现过的比例）。
    static func recall(_ target: [String], in line: [String]) -> Double {
        guard !target.isEmpty else { return 0 }
        let said = Set(line)
        let hit = target.filter { said.contains($0) }.count
        return Double(hit) / Double(target.count)
    }

    /// 连续子序列匹配（词组的整串匹配用）。
    static func containsSequence(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}

// MARK: - 课程阶梯（绑定成长之树）

/// 一档 CEFR 在大树上的进度。
public struct CurriculumStage: Sendable, Equatable {

    public var level: CEFRLevel
    /// 这一档覆盖到的情景（按素材顺序）。
    public var scenarios: [Scenario]
    /// 绑到大树上的关卡（`scenarioID` 命中本档任一情景的关卡）。
    public var levels: [TreeLevel]

    public init(level: CEFRLevel, scenarios: [Scenario], levels: [TreeLevel]) {
        self.level = level
        self.scenarios = scenarios
        self.levels = levels
    }

    public var scenarioCount: Int { scenarios.count }
    public var requiredStars: Int { levels.reduce(0) { $0 + $1.requiredStars } }
    public var earnedStars: Int { levels.reduce(0) { $0 + $1.earnedStars } }

    /// 这一档是否已经开放：只要有一个挂在这一档上的关卡不是「锁定」，就算开了。
    ///
    /// 刻意不用「攒够星才算开」——大树的开放与否由关卡自己管（`TreeLevel.state`），
    /// 课程阶梯只做汇总展示，不另立一套解锁规则，否则两处迟早对不上。
    public var isUnlocked: Bool { levels.contains { $0.state != .locked } }

    /// 这一档是否已经练完：挂在这一档上的关卡全部「完成」。
    public var isCompleted: Bool { !levels.isEmpty && levels.allSatisfy { $0.state == .completed } }

    /// 0...1。
    public var progress: Double {
        let required = max(requiredStars, 1)
        return min(Double(earnedStars) / Double(required), 1)
    }
}

public enum CurriculumLadder {

    /// 按 CEFR 把情景排成分级阶梯，并把大树关卡挂到对应档上。
    ///
    /// **绑定规则**（纯函数，不落库）：关卡先靠 `level_bindings.json` 找到情景，
    /// 再用那个情景的 CEFR 归到档上。绑了情景但该情景不在课程里的关卡不进任何档。
    public static func stages(scenarios: [Scenario], levels: [TreeLevel]) -> [CurriculumStage] {
        let scenarioByID = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id, $0) })
        return CEFRLevel.allCases.compactMap { level in
            let owned = scenarios.filter { $0.cefrLevels.contains(level) }
            let bound = levels.filter { treeLevel in
                guard let id = treeLevel.scenarioID, let scenario = scenarioByID[id] else { return false }
                return scenario.cefrLevels.contains(level)
            }
            guard !owned.isEmpty || !bound.isEmpty else { return nil }
            return CurriculumStage(level: level, scenarios: owned, levels: bound)
        }
    }

    /// 整条阶梯的完成度（0...1）。
    ///
    /// ⚠️ 必须**按关卡 id 去重**：一个区间场景（`A1-A2`）会同时出现在两档里，
    /// 直接对 `stages` 求和会把同一关的星数算两遍，进度被平白压低。
    public static func overallProgress(_ stages: [CurriculumStage]) -> Double {
        var seen = Set<String>()
        var required = 0
        var earned = 0
        for stage in stages {
            for level in stage.levels where seen.insert(level.id).inserted {
                required += level.requiredStars
                earned += level.earnedStars
            }
        }
        guard required > 0 else { return 0 }
        return min(Double(earned) / Double(required), 1)
    }
}
