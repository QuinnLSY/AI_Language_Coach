import Foundation

// MARK: - 学习计划（V1.2 Personalized Learning Plan）
//
// 动机：能力定位卡已经能说「你现在是 A2，距 B1 还差…」，今日任务卡已经能说「今天做这三项」，
// 但两者之间**没有桥** —— 「还差什么」只是一句文字说明，与「这个阶段到底该练什么」不相连。
// 于是「能力定位」是状态、「今日任务」是日程，中间少了一层**阶段路线**。
//
// 本文件把已有的真源聚合成**阶段层**（我在哪 → 要去哪 → 这个阶段练什么），
// 与「今日层」（`DailyPlan`）上下分层：一个说方向，一个说今天。
//
// ⚠️ 全是纯函数与纯数据：不碰模型、不碰 IO、不碰 UI。
// 动作只表达为**领域层枚举**（`LearningPlanFocus.Action`），由 AppUI 映射到具体 `openXxx`
// —— AIDomain 看不到 AppState，这条边界不能被一个「跳转」需求捅破。
//
// ⚠️ 不新增真源：`level` / `gaps` / `nextLevel` 全部**透传** `PlacementEstimate`，
// 「今天做什么」原样收 `DailyPlan`。这里只做**聚合与排序**，
// 任何一处口径变化都必须改在它原本的真源里（`PlacementEstimator` / `DailyPlanner`）。

/// 计划里一条「练什么」。
///
/// ⚠️ 只承载领域层信息：`action` 是抽象枚举，不带方法名 / 视图 / URL，
/// 由 AppUI 那一层决定它落到哪个动作上。
public struct LearningPlanFocus: Sendable, Equatable, Identifiable {

    /// 这项计划落到哪一类练习上。
    public enum Action: String, Sendable, Equatable, CaseIterable {
        /// 错题定向复练：改掉反复犯的错（`AppState.startErrorDrill`）。
        case errorDrill
        /// 顽固音素专项：最小对立对（`AppState.startPhonemeDrill(for:)`）。
        case phonemeDrill
        /// 词汇复习：到期单词（`AppState.openVocabulary`）。
        case vocabulary
        /// 跟读：听示范 + 录音 + 逐词反馈（`AppState.openShadowing`）。
        case shadowing
        /// 开口对话（`AppState.openPractice`）。
        case conversation

        /// 这类练习的短标签（「改掉反复犯的错」）。**不带数字** —— 数量是另一回事。
        ///
        /// ⚠️ 只有这一份：`LearningPlanner.focusItems` 与自适应建议卡（它只拿到 `Action`，
        /// 也要有个说法）都从这里取。写两遍就一定会漂移。
        public var title: String {
            switch self {
            case .errorDrill: "改掉反复犯的错"
            case .phonemeDrill: "练顽固音素"
            case .vocabulary: "清掉到期单词"
            case .shadowing: "跟读"
            case .conversation: "开口对话"
            }
        }

        /// SF Symbol 名：计划卡与建议卡共用同一套图标，别为同一件事换第二套。
        public var symbolName: String {
            switch self {
            case .errorDrill: "arrow.triangle.2.circlepath"
            case .phonemeDrill: "waveform"
            case .vocabulary: "text.book.closed.fill"
            case .shadowing: "waveform.badge.mic"
            case .conversation: "bubble.left.and.bubble.right.fill"
            }
        }
    }

    public var action: Action
    /// 短标题（「改掉反复犯的错」）。**不带数字** —— 数量交给 `pendingText`，两处各说各的。
    public var title: String
    /// 依据 —— 必须是**可核对的说法**（「学习记忆里攒了 3 处还没练掉的错」），
    /// 不是形容词（「你该练练了」）。与 `DailyTask.reason` 同一条纪律。
    public var reason: String
    /// 待办数量（≥ 0）。
    public var pending: Int
    /// 数量的单位（「处」「个」「词」）。
    public var unit: String

    public var id: String { action.rawValue }

    public init(action: Action, title: String, reason: String, pending: Int, unit: String) {
        self.action = action
        self.title = title
        self.reason = reason
        self.pending = max(pending, 0)
        self.unit = unit
    }

    /// 「3 处」。
    public var pendingText: String { "\(pending) \(unit)" }
}

/// 阶段层：我在哪 → 要去哪 → 这个阶段练什么。
public struct LearningPlanStage: Sendable, Equatable {

    /// 当前档（样本不够时为 nil）。
    public var currentLevel: CEFRLevel?
    /// 目标档（`PlacementEstimate.nextLevel`；已到顶为 nil）。
    public var targetLevel: CEFRLevel?
    /// 估计是否可信（样本够不够）。
    public var isConfident: Bool
    /// 差距说明：**透传** `PlacementEstimate.gaps`，不在这里重算 —— 与能力定位卡说同一个数。
    public var gaps: [String]
    /// 这个阶段的重点：**只含有实际待办**的项。
    public var focus: [LearningPlanFocus]

    public init(
        currentLevel: CEFRLevel?,
        targetLevel: CEFRLevel?,
        isConfident: Bool,
        gaps: [String],
        focus: [LearningPlanFocus]
    ) {
        self.currentLevel = currentLevel
        self.targetLevel = targetLevel
        self.isConfident = isConfident
        self.gaps = gaps
        self.focus = focus
    }

    /// 「A2 → B1」；已到顶只说当前档；样本不够时说「还在观察中」。
    public var headline: String {
        guard isConfident, let current = currentLevel else { return "还在观察中" }
        guard let target = targetLevel else { return current.code }
        return "\(current.code) → \(target.code)"
    }

    /// 目标档「能做什么」—— 计划的靶子（样本不够时为 nil）。
    ///
    /// ⚠️ 刻意用**目标档**而不是当前档：能力定位卡已经说了当前档能做什么，
    /// 这里要回答的是「练到下一档，我能干什么」。
    public var targetCanDo: String? {
        guard isConfident, let target = targetLevel else { return nil }
        return target.canDo
    }

    /// 这个阶段还有没有可执行的重点。
    public var hasFocus: Bool { !focus.isEmpty }
}

/// 学习计划：阶段层 + 今日层。
public struct LearningPlan: Sendable, Equatable {

    public var stage: LearningPlanStage
    /// 今日任务：**原样收** `AppState.dailyPlan`，不重算（口径唯一）。
    public var today: DailyPlan

    public init(stage: LearningPlanStage, today: DailyPlan) {
        self.stage = stage
        self.today = today
    }

    /// 今天还没做完的项数。
    public var todayRemaining: Int { max(today.totalCount - today.completedCount, 0) }

    /// 计划整体是否「空」：阶段没重点、今天也没任务。
    public var isEmpty: Bool { !stage.hasFocus && today.tasks.isEmpty }
}

// MARK: - 聚合（纯函数）

/// 把已有的真源聚合成一份学习计划。
public enum LearningPlanner {

    /// 从各处真源拼出计划。
    ///
    /// - Parameters:
    ///   - estimate: 能力定位（`AppState.placementEstimate`，本身由 `PlacementEstimator` 派生）。
    ///   - dailyPlan: 今日任务（`AppState.dailyPlan`）—— 原样收进今日层。
    ///   - recurringErrorCount: 学习记忆里**还没练掉**的反复错（已排除攻克过的）。
    ///   - weakPhonemeCount: 顽固音素个数（`AppState.phonemeWeaknesses`）。
    ///   - dueVocabularyRemaining: 今天起初到期、还没复习的词数。
    public static func plan(
        estimate: PlacementEstimate,
        dailyPlan: DailyPlan,
        recurringErrorCount: Int,
        weakPhonemeCount: Int,
        dueVocabularyRemaining: Int
    ) -> LearningPlan {
        LearningPlan(
            stage: LearningPlanStage(
                currentLevel: estimate.level,
                targetLevel: estimate.nextLevel,
                isConfident: estimate.isConfident,
                gaps: estimate.gaps,
                focus: focusItems(
                    recurringErrorCount: recurringErrorCount,
                    weakPhonemeCount: weakPhonemeCount,
                    dueVocabularyRemaining: dueVocabularyRemaining
                )
            ),
            today: dailyPlan
        )
    }

    /// 重点项：只留下**有实际待办**的来源。
    ///
    /// 顺序是刻意的：错题与顽固音素都是**从他自己犯的错里长出来的**，比泛泛的词汇复习更值钱；
    /// 到期词汇必须清（不清会越攒越多），排第三。
    /// 「开口对话 / 跟读」不在这里重复出现 —— 它们已经是今日任务的项，属于**今天**这一层。
    static func focusItems(
        recurringErrorCount: Int,
        weakPhonemeCount: Int,
        dueVocabularyRemaining: Int
    ) -> [LearningPlanFocus] {
        var items: [LearningPlanFocus] = []

        if recurringErrorCount > 0 {
            items.append(LearningPlanFocus(
                action: .errorDrill,
                title: LearningPlanFocus.Action.errorDrill.title,
                reason: "学习记忆里攒了 \(recurringErrorCount) 处还没练掉的错",
                pending: recurringErrorCount,
                unit: "处"
            ))
        }

        if weakPhonemeCount > 0 {
            items.append(LearningPlanFocus(
                action: .phonemeDrill,
                title: LearningPlanFocus.Action.phonemeDrill.title,
                reason: "\(weakPhonemeCount) 个音反复念错（各已评够三次、错够两次）",
                pending: weakPhonemeCount,
                unit: "个"
            ))
        }

        if dueVocabularyRemaining > 0 {
            items.append(LearningPlanFocus(
                action: .vocabulary,
                title: LearningPlanFocus.Action.vocabulary.title,
                reason: "今天起初到期 \(dueVocabularyRemaining) 个词，还没复习",
                pending: dueVocabularyRemaining,
                unit: "词"
            ))
        }

        return items
    }
}
