import AppCore
import Foundation

// MARK: - 任务前情提要（Scenario Briefing）
//
// 需求 3/5/6：进入（或继续）一个情景任务前，先自动总结「之前练到哪了」，
// 再开始当前任务，让学员一进来就知道**该说什么、说到哪算完成**。
//
// 前情提要由三份材料合成（全部是本地已有数据，**不额外发请求**）：
// 1. 主线任务进度（`ScenarioQuestRule` + 库里记的已完成步骤）；
// 2. 该情景最近一次复盘（`SessionReview`：做得好的 / 要改进的 / 建议）；
// 3. 最近更新的词汇（复盘提取进词汇本的词）。
//
// 纯函数，不 import UI / IO。

/// 进任务前的「前情提要」。
///
/// ⚠️ 主线任务进度是**算出来的**而不是存下来的：`plan` + `persistedStepIDs` + 本局发言
/// 三者一算就有，存一份就会出现「界面显示的进度」与「判定用的进度」两处真相。
public struct ScenarioBriefing: Sendable, Equatable {

    public var scenarioID: String
    public var scenarioTitle: String
    /// 素材里写好的角色开场白：**给老师当参考，不直接贴给学员**（需求 6）。
    public var characterOpening: String
    /// 主线任务计划（可复算，故原样保留，不只保留渲染结果）。
    public var plan: QuestPlan
    /// 库里已记下的「已完成步骤」id（上一局推到的位置）。
    public var persistedStepIDs: Set<String>
    /// 本局学员说过的话（实时追加，用于刷新当前节点）。
    public var liveUtterances: [String]
    /// 本关的教学重点（进入时都还是「未达成」，只作提示）。
    public var focusSummary: String
    public var focusItems: [TeachingFocusItem]
    /// 上一次练这一关的复盘（可能来自更早的会话）。
    public var lastReviewHeadline: String?
    public var lastReviewImprovements: [String]
    public var lastReviewSuggestion: String?
    /// 上次复盘里新记进词汇本的词。
    public var newWords: [String]
    /// 之前练过这一关（有复盘或已推进过步骤）。
    public var hasHistory: Bool

    public init(
        scenarioID: String,
        scenarioTitle: String,
        characterOpening: String = "",
        plan: QuestPlan,
        persistedStepIDs: Set<String> = [],
        liveUtterances: [String] = [],
        focusSummary: String = "",
        focusItems: [TeachingFocusItem] = [],
        lastReviewHeadline: String? = nil,
        lastReviewImprovements: [String] = [],
        lastReviewSuggestion: String? = nil,
        newWords: [String] = [],
        hasHistory: Bool = false
    ) {
        self.scenarioID = scenarioID
        self.scenarioTitle = scenarioTitle
        self.characterOpening = characterOpening
        self.plan = plan
        self.persistedStepIDs = persistedStepIDs
        self.liveUtterances = liveUtterances
        self.focusSummary = focusSummary
        self.focusItems = focusItems
        self.lastReviewHeadline = lastReviewHeadline
        self.lastReviewImprovements = lastReviewImprovements
        self.lastReviewSuggestion = lastReviewSuggestion
        self.newWords = newWords
        self.hasHistory = hasHistory
    }

    public var questTitle: String { plan.title }

    /// 主线任务实时进度（本局发言 + 库里进度，并集）。
    public var quest: QuestProgress {
        ScenarioQuestRule.progress(
            plan: plan, utterances: liveUtterances, alreadyDone: persistedStepIDs
        )
    }

    /// 带上本局最新发言的副本（每轮发言后刷新当前节点用）。
    public func refreshed(utterances: [String]) -> ScenarioBriefing {
        var copy = self
        copy.liveUtterances = utterances
        return copy
    }

    /// 首次进入（没有任何历史）：前情提要退化为「任务介绍」。
    public var isFirstTime: Bool { !hasHistory }

    /// UI 逐行文案（母语，学员直接读）。空行不出现。
    public var lines: [String] {
        let progress = quest
        var result: [String] = []
        if !questTitle.isEmpty {
            result.append("这一关要做的：\(questTitle)")
        }
        if progress.total > 0 {
            result.append(progress.briefingLine)
        }
        if !focusSummary.isEmpty {
            result.append("教学重点：\(focusSummary)")
        }
        if let headline = lastReviewHeadline, !headline.isEmpty {
            result.append("上次复盘：\(headline)")
        }
        if let first = lastReviewImprovements.first, !first.isEmpty {
            result.append("要继续注意：\(first)")
        }
        if !newWords.isEmpty {
            result.append("上次新记的词：\(newWords.prefix(6).joined(separator: "、"))")
        }
        if let suggestion = lastReviewSuggestion, !suggestion.isEmpty {
            result.append("建议：\(suggestion)")
        }
        if isFirstTime {
            result.append("第一次来这一关，跟着老师一步步来就好。")
        }
        return result
    }

    /// 注入 Prompt 的英文块（只给事实，不给台词）。
    public var factsBlock: String {
        let progress = quest
        var rows: [String] = []
        if !questTitle.isEmpty { rows.append("- Task: \(questTitle)") }
        if progress.total > 0 {
            let done = progress.steps.filter(\.isDone).map(\.text)
            let todo = progress.steps.filter { !$0.isDone }.map(\.text)
            if !done.isEmpty { rows.append("- Steps already finished: \(done.joined(separator: " | "))") }
            if !todo.isEmpty { rows.append("- Steps still open: \(todo.joined(separator: " | "))") }
        }
        let next = progress.currentStep?.text ?? ""
        rows.append("- The learner must do this next: \(next.isEmpty ? "nothing left, wrap up warmly" : next)")
        if let step = progress.currentStep, !step.hint.isEmpty {
            rows.append("- Hint you can use if they stall: \(step.hint)")
        }
        if !focusSummary.isEmpty { rows.append("- Teaching focus: \(focusSummary)") }
        if let headline = lastReviewHeadline, !headline.isEmpty {
            rows.append("- Last session summary: \(headline)")
        }
        if let first = lastReviewImprovements.first, !first.isEmpty {
            rows.append("- Watch out for: \(first)")
        }
        if !newWords.isEmpty {
            rows.append("- Words to reuse: \(newWords.prefix(6).joined(separator: ", "))")
        }
        let opening = characterOpening.trimmingCharacters(in: .whitespacesAndNewlines)
        if !opening.isEmpty {
            rows.append("- Open the scene with something close to this line, in character: \"\(opening)\"")
        }
        return rows.joined(separator: "\n")
    }

    /// 本地模型没起来时的兜底开场白（母语，一句）。
    public var fallbackOpener: String {
        let progress = quest
        if progress.total > 0 {
            if progress.doneCount > 0 {
                return "上次我们已经推进到 \(progress.doneCount)/\(progress.total) 步，接着做：\(progress.currentText)"
            }
            return "这一关我们要做的是「\(questTitle)」，先从这一步开始：\(progress.currentText)"
        }
        if !focusSummary.isEmpty {
            return "这一关重点是 \(focusSummary)，我们开始吧。"
        }
        return "我们开始这一关的练习吧。"
    }

    /// 本地模型没起来时，老师开场白的兜底全文（角色开场白 + 任务引导）。
    public func fallbackOpeningMessage(characterOpening: String) -> String {
        let opening = characterOpening.trimmingCharacters(in: .whitespacesAndNewlines)
        let guide = fallbackOpener
        guard !opening.isEmpty else { return guide }
        return opening + "\n\n" + guide
    }
}

public enum ScenarioBriefingBuilder {

    /// 合成前情提要。
    ///
    /// - Parameters:
    ///   - scenario: 当前情景。
    ///   - questDone: 库里记的「已完成步骤」id。
    ///   - review: 该情景最近一次复盘（可为空）。
    ///   - newWords: 复盘里提取出的词（可空；为空则用复盘自带的 `newWords`）。
    public static func build(
        scenario: Scenario,
        questDone: Set<String> = [],
        review: SessionReview? = nil,
        newWords: [String] = []
    ) -> ScenarioBriefing {
        let plan = scenario.questPlan
        let focus = CurriculumScorer.focus(
            scenario: scenario,
            coverage: CurriculumCoverage(turnsUsed: 0, maxTurns: scenario.maxTurns)
        )

        let headline = review?.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestion = review?.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = newWords.isEmpty ? (review?.newWords ?? []) : newWords
        let hasHistory = review != nil || !questDone.isEmpty

        return ScenarioBriefing(
            scenarioID: scenario.id,
            scenarioTitle: scenario.titleZh,
            characterOpening: scenario.opening,
            plan: plan,
            persistedStepIDs: questDone,
            focusSummary: focus.isEmpty ? "" : focus.summary,
            focusItems: focus.items,
            lastReviewHeadline: (headline?.isEmpty ?? true) ? nil : headline,
            lastReviewImprovements: review?.improvements ?? [],
            lastReviewSuggestion: (suggestion?.isEmpty ?? true) ? nil : suggestion,
            newWords: words,
            hasHistory: hasHistory
        )
    }
}

// MARK: - 练习复盘的自动化策略（纯函数）

/// 「什么时候自动复盘、复盘完能不能删流水」这一类判断集中在这里，便于单测。
public enum PracticeReviewPolicy {

    /// 值得复盘的最低消息数。
    ///
    /// 只有 1 条消息 = 老师说了句开场白学员就走了，复盘出来全是套话，
    /// 还会把「上次练习卡片」弄成一张空卡。
    public static let minimumMessages = 2

    /// 这次会话现在需要自动复盘吗。
    ///
    /// - Parameters:
    ///   - messageCount: 会话现在的消息数。
    ///   - lastReviewedMessageCount: 最近一次复盘记录下来的消息数（0 = 从没复盘过）。
    public static func shouldAutoReview(messageCount: Int, lastReviewedMessageCount: Int) -> Bool {
        messageCount >= minimumMessages && messageCount > lastReviewedMessageCount
    }

    /// 复盘产物可用吗（**只有拿到复盘才允许删练习流水**）。
    ///
    /// 规则兜底（`.heuristic`）也算可用：它至少把轮次 / 纠错数 / 错误原句留下来了，
    /// 比「什么都没留下就把流水删了」安全得多。
    public static func canPurgeSource(_ review: SessionReview?) -> Bool {
        guard let review else { return false }
        let hasContent = !review.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !review.strengths.isEmpty
            || !review.improvements.isEmpty
        return hasContent
    }
}

/// 启动（或点「开启新练习」）时该怎么继续。
public enum PracticeResumeAction: Sendable, Equatable {
    /// 上次在练某个情景：先给前情提要，再继续这个任务。
    case resumeScenario(String)
    /// 上次在随口练：用上次的复盘引导继续。
    case resumeFreeTalk
    /// 没有历史（或历史已被清干净）：老师主动开一个引子，等学员开口。
    case idle

    /// 给测试与 UI 用的稳定标识。
    public var kind: String {
        switch self {
        case .resumeScenario: "scenario"
        case .resumeFreeTalk: "freeTalk"
        case .idle: "idle"
        }
    }
}

public enum PracticeResumeRule {

    /// 用「最近一次会话」决定启动行为。
    ///
    /// ⚠️ 流水已被删除（复盘成功）的会话**仍然算数**：`sessions` 行留着，
    /// 所以「上次在练什么」永远答得出来 —— 这正是需求 6 想要的「继续上次」。
    ///
    /// ⚠️ `questComplete` 是「那一关的主线任务已经跑完」：这时**没有「没做完的事」可续**，
    /// 一律当空闲处理。启动就自动重开会把已完成的主线清零，学员看到「主线 0/3」，
    /// 而大树上那一格写着「已过关」—— 两处自相矛盾。想重练是主动行为（去卡片点「开始任务」）。
    ///
    /// - Parameters:
    ///   - latestScenarioID: 最近一次会话绑定的情景（nil = 不是情景对话）。
    ///   - latestMode: 最近一次会话的练习模式。
    ///   - questComplete: 该情景的主线任务是否已完成（无记录 / 非情景时为 false）。
    public static func action(
        latestScenarioID: String?,
        latestMode: PracticeMode?,
        questComplete: Bool = false
    ) -> PracticeResumeAction {
        if let latestScenarioID, !latestScenarioID.isEmpty {
            return questComplete ? .idle : .resumeScenario(latestScenarioID)
        }
        if latestMode == .freeTalk {
            return .resumeFreeTalk
        }
        return .idle
    }
}
